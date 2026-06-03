# ================================================================
# EMIS Lab PC Message Poller
# Deployed via GPO Startup Script - runs as SYSTEM
# Polls the API every 30 seconds for pending messages
# ================================================================

$ApiUrl = "http://10.10.100.3:8080/api/v1/pcs"
$PollInterval = 30  # seconds
$Hostname = $env:COMPUTERNAME

# Log file for troubleshooting
$LogFile = "C:\Windows\Temp\emis-poller.log"
function Write-Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts - $msg" | Out-File -Append -FilePath $LogFile -Encoding UTF8
}

Write-Log "Message poller started for $Hostname"

# Wait for network to be ready
$retries = 0
while ($retries -lt 10) {
    try {
        $null = Invoke-RestMethod -Uri "http://10.10.100.3:8080/api/v1/health" -TimeoutSec 5
        Write-Log "API reachable"
        break
    } catch {
        $retries++
        Write-Log "Waiting for API... attempt $retries"
        Start-Sleep -Seconds 10
    }
}

# Main polling loop
while ($true) {
    try {
        $response = Invoke-RestMethod -Uri "$ApiUrl/$Hostname/pending-messages" -Method GET -Headers @{ "X-API-Key" = "polling-agent" } -TimeoutSec 10

        if ($response.count -gt 0) {
            foreach ($msg in $response.messages) {
                $text = $msg.message
                $sender = $msg.sender
                $displayMsg = "From: $sender`n$text"
                
                # Show message using msg.exe (works for all logged-in users)
                & msg.exe * /TIME:300 $displayMsg 2>$null

                # Fallback: also show as a toast notification via PowerShell
                try {
                    Add-Type -AssemblyName System.Windows.Forms
                    $balloon = New-Object System.Windows.Forms.NotifyIcon
                    $balloon.Icon = [System.Drawing.SystemIcons]::Information
                    $balloon.BalloonTipTitle = "EMIS Admin Message"
                    $balloon.BalloonTipText = "$text`n- $sender"
                    $balloon.BalloonTipIcon = "Info"
                    $balloon.Visible = $true
                    $balloon.ShowBalloonTip(30000)
                    Start-Sleep -Seconds 2
                    $balloon.Dispose()
                } catch {}

                Write-Log "Displayed message from $sender : $text"
            }
        }
    } catch {
        Write-Log "Poll error: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds $PollInterval
}
