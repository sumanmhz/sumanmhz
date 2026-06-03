# ================================================================
# EMIS Lab PC Agent
# Deployed via GPO Startup Script - runs as SYSTEM
# Features:
#   - Polls for pending messages (popup to user)
#   - Enforces blocked websites (hosts file)
#   - Enforces blocked apps (kills processes)
#   - Exam mode (firewall whitelist + app whitelist)
#   - Reports login/logout/idle sessions
#   - Displays announcements on desktop
#   - Handles scheduled shutdown warnings
# ================================================================

$ApiBase = "http://10.10.100.3:8080/api/v1"
$PollInterval = 30  # seconds
$Hostname = $env:COMPUTERNAME
$AgentKey = "polling-agent"
$Headers = @{ "X-API-Key" = $AgentKey; "Content-Type" = "application/json" }
$HostsMarker = "# EMIS-MANAGED - DO NOT EDIT BELOW"
$HostsFile = "C:\Windows\System32\drivers\etc\hosts"

# Log file for troubleshooting
$LogFile = "C:\Windows\Temp\emis-poller.log"
function Write-Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts - $msg" | Out-File -Append -FilePath $LogFile -Encoding UTF8
    # Keep log under 1MB
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) {
        $lines = Get-Content $LogFile -Tail 500
        $lines | Set-Content $LogFile -Encoding UTF8
    }
}

Write-Log "EMIS Agent started for $Hostname"

# State tracking
$script:LastUser = $null
$script:IdleTicks = 0
$script:LastBlockedSites = @()
$script:ExamModeActive = $false

# --- Helper: Get idle time in minutes ---
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class IdleTime {
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    public static int GetIdleMinutes() {
        LASTINPUTINFO info = new LASTINPUTINFO();
        info.cbSize = (uint)Marshal.SizeOf(info);
        if (GetLastInputInfo(ref info)) {
            return (int)((Environment.TickCount - info.dwTime) / 60000);
        }
        return 0;
    }
}
"@

# --- Helper: Get logged-on username ---
function Get-LoggedOnUser {
    try {
        $user = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName
        if ($user) { return $user.Split('\')[-1] }
    } catch {}
    return $null
}

# --- Helper: Update hosts file with blocked sites ---
function Update-BlockedSites {
    param([string[]]$Sites)
    try {
        $content = ""
        if (Test-Path $HostsFile) {
            $lines = Get-Content $HostsFile -Encoding UTF8
            $clean = @($lines | Where-Object { $_ -notmatch $HostsMarker -and $_ -notmatch '^127\.0\.0\.1\s+\S+.*#EMIS$' })
            $content = ($clean -join "`r`n").TrimEnd()
        }
        if ($Sites.Count -gt 0) {
            $content += "`r`n$HostsMarker`r`n"
            foreach ($site in $Sites) {
                $content += "127.0.0.1 $site #EMIS`r`n"
                $content += "127.0.0.1 www.$site #EMIS`r`n"
            }
        }
        Set-Content -Path $HostsFile -Value $content -Encoding UTF8 -Force
        # Flush DNS cache
        ipconfig /flushdns 2>$null | Out-Null
    } catch {
        Write-Log "Failed to update hosts file: $($_.Exception.Message)"
    }
}

# --- Helper: Kill blocked apps ---
function Stop-BlockedApps {
    param([string[]]$Apps)
    foreach ($app in $Apps) {
        $procs = Get-Process -Name $app -ErrorAction SilentlyContinue
        foreach ($proc in $procs) {
            try { $proc.Kill(); Write-Log "Killed blocked app: $app (PID $($proc.Id))" } catch {}
        }
    }
}

# --- Helper: Enable exam firewall (block all, allow whitelist) ---
function Enable-ExamFirewall {
    param([string[]]$AllowedSites)
    try {
        # Remove old exam rules
        Get-NetFirewallRule -DisplayName "EMIS-Exam-*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        # Block all outbound
        New-NetFirewallRule -DisplayName "EMIS-Exam-BlockAll" -Direction Outbound -Action Block -Enabled True -Profile Any -ErrorAction Stop | Out-Null
        # Allow DNS (required for resolution)
        New-NetFirewallRule -DisplayName "EMIS-Exam-AllowDNS" -Direction Outbound -Action Allow -Protocol UDP -RemotePort 53 -Enabled True -Profile Any | Out-Null
        # Allow API server
        New-NetFirewallRule -DisplayName "EMIS-Exam-AllowAPI" -Direction Outbound -Action Allow -RemoteAddress 10.10.100.3 -Enabled True -Profile Any | Out-Null
        # Allow domain controller traffic
        New-NetFirewallRule -DisplayName "EMIS-Exam-AllowDC" -Direction Outbound -Action Allow -RemoteAddress 10.10.100.0/24 -Enabled True -Profile Any | Out-Null
        # Allow whitelisted sites by resolving to IPs
        $idx = 0
        foreach ($site in $AllowedSites) {
            try {
                $ips = [System.Net.Dns]::GetHostAddresses($site) | ForEach-Object { $_.IPAddressToString }
                foreach ($ip in $ips) {
                    $idx++
                    New-NetFirewallRule -DisplayName "EMIS-Exam-Allow$idx" -Direction Outbound -Action Allow -RemoteAddress $ip -Enabled True -Profile Any | Out-Null
                }
            } catch { Write-Log "Could not resolve $site for firewall whitelist" }
        }
        Write-Log "Exam firewall enabled. Allowed: $($AllowedSites -join ', ')"
    } catch {
        Write-Log "Failed to set exam firewall: $($_.Exception.Message)"
    }
}

# --- Helper: Disable exam firewall ---
function Disable-ExamFirewall {
    try {
        Get-NetFirewallRule -DisplayName "EMIS-Exam-*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        Write-Log "Exam firewall disabled"
    } catch {
        Write-Log "Failed to remove exam firewall: $($_.Exception.Message)"
    }
}

# --- Helper: Show announcement on desktop ---
function Show-Announcement {
    param([string]$Title, [string]$Message, [string]$Priority)
    try {
        $icon = if ($Priority -eq "high") { "Warning" } else { "Info" }
        & msg.exe * /TIME:120 "$Title`n$Message" 2>$null
    } catch {}
}

# Wait for network to be ready
$retries = 0
while ($retries -lt 10) {
    try {
        $null = Invoke-RestMethod -Uri "$ApiBase/health" -TimeoutSec 5
        Write-Log "API reachable"
        break
    } catch {
        $retries++
        Write-Log "Waiting for API... attempt $retries"
        Start-Sleep -Seconds 10
    }
}

# Auto-register this PC with the API (include MAC address for WOL)
try {
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notlike '*Virtual*' -and $_.InterfaceDescription -notlike '*Loopback*' } | Select-Object -First 1
    $ip = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.*' } | Select-Object -First 1).IPAddress
    if (-not $ip) { $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.*' } | Select-Object -First 1).IPAddress }
    $mac = $adapter.MacAddress -replace '-', ':'
    $regBody = @{ hostname = $Hostname; ip = $ip; mac = $mac } | ConvertTo-Json -Compress
    $result = Invoke-RestMethod -Uri "$ApiBase/pcs/register" -Method POST -Headers $Headers -Body $regBody -TimeoutSec 10
    Write-Log "Registered: $($result.hostname) ($ip) MAC=$mac in $($result.lab)"
} catch {
    Write-Log "Registration failed: $($_.Exception.Message)"
}

# Report initial login
$currentUser = Get-LoggedOnUser
if ($currentUser) {
    try {
        $body = @{ hostname = $Hostname; username = $currentUser; action = "login" } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "$ApiBase/sessions/report" -Method POST -Headers $Headers -Body $body -TimeoutSec 5 | Out-Null
        $script:LastUser = $currentUser
        Write-Log "Reported login: $currentUser"
    } catch {}
}

# Track shown announcements to avoid repeating
$script:ShownAnnouncements = @{}

# Main polling loop
while ($true) {
    try {
        # --- 1. Poll for pending messages ---
        try {
            $response = Invoke-RestMethod -Uri "$ApiBase/pcs/$Hostname/pending-messages" -Method GET -Headers $Headers -TimeoutSec 10
            if ($response.count -gt 0) {
                foreach ($msg in $response.messages) {
                    & msg.exe * /TIME:300 "From: $($msg.sender)`n$($msg.message)" 2>$null
                    Write-Log "Displayed message from $($msg.sender)"
                }
            }
        } catch { Write-Log "Message poll error: $($_.Exception.Message)" }

        # --- 2. Get full config (blocked sites, apps, exam mode, announcements, schedules) ---
        try {
            $config = Invoke-RestMethod -Uri "$ApiBase/pcs/$Hostname/config" -Method GET -Headers $Headers -TimeoutSec 10

            # --- 2a. Blocked websites → update hosts file ---
            $newSites = @($config.blockedSites)
            $sitesChanged = ($newSites -join ',') -ne ($script:LastBlockedSites -join ',')
            if ($sitesChanged) {
                Update-BlockedSites -Sites $newSites
                $script:LastBlockedSites = $newSites
                if ($newSites.Count -gt 0) { Write-Log "Blocked sites updated: $($newSites -join ', ')" }
                else { Write-Log "All sites unblocked" }
            }

            # --- 2b. Blocked apps → kill running instances ---
            if ($config.blockedApps -and $config.blockedApps.Count -gt 0) {
                Stop-BlockedApps -Apps $config.blockedApps
            }

            # --- 2c. Exam mode ---
            if ($config.examMode -and $config.examMode.enabled) {
                if (-not $script:ExamModeActive) {
                    Write-Log "Exam mode activating..."
                    if ($config.examMode.blockInternet) {
                        Enable-ExamFirewall -AllowedSites @($config.examMode.allowedSites)
                    }
                    if ($config.examMode.message) {
                        & msg.exe * /TIME:600 "EXAM MODE: $($config.examMode.message)" 2>$null
                    }
                    $script:ExamModeActive = $true
                }
                # Kill apps not in allowed list during exam
                if ($config.examMode.allowedApps -and $config.examMode.allowedApps.Count -gt 0) {
                    $allowed = @($config.examMode.allowedApps) + @("explorer", "svchost", "csrss", "winlogon", "dwm", "taskhostw", "sihost", "fontdrvhost", "lsass", "services", "smss", "wininit", "conhost", "RuntimeBroker", "SearchHost", "StartMenuExperienceHost", "ShellExperienceHost", "TextInputHost", "ctfmon", "dllhost", "spoolsv", "powershell", "cmd")
                    $userProcs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -gt 0 -and $_.MainWindowTitle -ne "" }
                    foreach ($proc in $userProcs) {
                        if ($proc.ProcessName -notin $allowed) {
                            try { $proc.Kill(); Write-Log "Exam: killed $($proc.ProcessName)" } catch {}
                        }
                    }
                }
            } else {
                if ($script:ExamModeActive) {
                    Disable-ExamFirewall
                    $script:ExamModeActive = $false
                    Write-Log "Exam mode deactivated"
                }
            }

            # --- 2d. Announcements ---
            if ($config.announcements -and $config.announcements.Count -gt 0) {
                foreach ($ann in $config.announcements) {
                    if (-not $script:ShownAnnouncements.ContainsKey($ann.id)) {
                        Show-Announcement -Title $ann.title -Message $ann.message -Priority $ann.priority
                        $script:ShownAnnouncements[$ann.id] = $true
                        Write-Log "Showed announcement: $($ann.title)"
                    }
                }
            }

            # --- 2e. Scheduled shutdown warning ---
            if ($config.schedule) {
                $now = Get-Date
                $shutdownTime = [datetime]::ParseExact($config.schedule.time, "HH:mm", $null)
                $dayName = $now.DayOfWeek.ToString()
                if ($config.schedule.days -contains $dayName) {
                    $minutesLeft = ($shutdownTime - $now).TotalMinutes
                    $warnMin = if ($config.schedule.warnMinutes) { $config.schedule.warnMinutes } else { 10 }
                    if ($minutesLeft -gt 0 -and $minutesLeft -le $warnMin) {
                        $mins = [math]::Ceiling($minutesLeft)
                        & msg.exe * /TIME:60 "WARNING: This PC will shut down in $mins minute(s)!" 2>$null
                    }
                    if ($minutesLeft -le 0 -and $minutesLeft -gt -1) {
                        Write-Log "Scheduled shutdown executing"
                        Stop-Computer -Force
                    }
                }
            }
        } catch { Write-Log "Config poll error: $($_.Exception.Message)" }

        # --- 3. Session tracking (login/logout/idle) ---
        try {
            $currentUser = Get-LoggedOnUser
            $idleMin = [IdleTime]::GetIdleMinutes()

            if ($currentUser -and -not $script:LastUser) {
                # New login
                $body = @{ hostname = $Hostname; username = $currentUser; action = "login" } | ConvertTo-Json -Compress
                Invoke-RestMethod -Uri "$ApiBase/sessions/report" -Method POST -Headers $Headers -Body $body -TimeoutSec 5 | Out-Null
                $script:LastUser = $currentUser
                Write-Log "Session: login $currentUser"
            } elseif (-not $currentUser -and $script:LastUser) {
                # Logout
                $body = @{ hostname = $Hostname; username = $script:LastUser; action = "logout" } | ConvertTo-Json -Compress
                Invoke-RestMethod -Uri "$ApiBase/sessions/report" -Method POST -Headers $Headers -Body $body -TimeoutSec 5 | Out-Null
                Write-Log "Session: logout $($script:LastUser)"
                $script:LastUser = $null
            } elseif ($currentUser -and $idleMin -ge 5) {
                # Idle report
                $body = @{ hostname = $Hostname; username = $currentUser; action = "idle"; idleMinutes = $idleMin } | ConvertTo-Json -Compress
                Invoke-RestMethod -Uri "$ApiBase/sessions/report" -Method POST -Headers $Headers -Body $body -TimeoutSec 5 | Out-Null
            } elseif ($currentUser) {
                # Active heartbeat (every 5 minutes only)
                $script:IdleTicks++
                if ($script:IdleTicks -ge 10) {
                    $body = @{ hostname = $Hostname; username = $currentUser; action = "active"; idleMinutes = $idleMin } | ConvertTo-Json -Compress
                    Invoke-RestMethod -Uri "$ApiBase/sessions/report" -Method POST -Headers $Headers -Body $body -TimeoutSec 5 | Out-Null
                    $script:IdleTicks = 0
                }
            }
        } catch { Write-Log "Session report error: $($_.Exception.Message)" }

    } catch {
        Write-Log "Main loop error: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds $PollInterval
}
