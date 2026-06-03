# ============================================================================
#  EMIS Lab PC Lockdown - GPO Configuration
#  Run on DC (WIN-M732KGNLU8C) as Administrator
#  Applies to existing GPO: "Lab PC Security"
# ============================================================================

Import-Module GroupPolicy

$GPOName = "Lab PC Security"
$Domain  = "emis.local"

# Verify GPO exists
$gpo = Get-GPO -Name $GPOName -Domain $Domain -ErrorAction SilentlyContinue
if (-not $gpo) {
    Write-Host "[ERROR] GPO '$GPOName' not found!" -ForegroundColor Red
    exit 1
}
Write-Host "Configuring GPO: $GPOName (ID: $($gpo.Id))" -ForegroundColor Cyan

# ============================================================================
#  1. WALLPAPER - Set TCIOE wallpaper, prevent changes
# ============================================================================
Write-Host "`n[1/4] Setting wallpaper policy..." -ForegroundColor Yellow

# Create wallpaper directory in SYSVOL (accessible to all domain PCs)
$wallpaperDir = "\\$Domain\SYSVOL\$Domain\wallpaper"
if (-not (Test-Path $wallpaperDir)) {
    New-Item -ItemType Directory -Path $wallpaperDir -Force | Out-Null
    Write-Host "  Created: $wallpaperDir"
}

# Check if wallpaper image exists, download if not
$wallpaperPath = "$wallpaperDir\tcioe-wallpaper.jpg"
if (-not (Test-Path $wallpaperPath)) {
    Write-Host "  Downloading TCIOE campus wallpaper..." -ForegroundColor Cyan
    try {
        Invoke-WebRequest -Uri "https://tcioe.edu.np/data/campus.jpg" -OutFile $wallpaperPath -UseBasicParsing
        Write-Host "  Downloaded: $wallpaperPath" -ForegroundColor Green
    } catch {
        Write-Host "  [!] Download failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "      Manually place wallpaper at: $wallpaperPath" -ForegroundColor Red
    }
} else {
    Write-Host "  Wallpaper already exists: $wallpaperPath" -ForegroundColor Green
}

# Set wallpaper path (User Configuration)
# User Config > Admin Templates > Desktop > Desktop Wallpaper
Set-GPRegistryValue -Name $GPOName -Domain $Domain `
    -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" `
    -ValueName "Wallpaper" -Type String `
    -Value "\\$Domain\SYSVOL\$Domain\wallpaper\tcioe-wallpaper.jpg"

# Wallpaper style: 2 = Stretch, 0 = Center, 6 = Fit, 10 = Fill
Set-GPRegistryValue -Name $GPOName -Domain $Domain `
    -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" `
    -ValueName "WallpaperStyle" -Type String -Value "10"

# Prevent users from changing wallpaper
# User Config > Admin Templates > Control Panel > Personalization > Prevent changing desktop background
Set-GPRegistryValue -Name $GPOName -Domain $Domain `
    -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" `
    -ValueName "NoChangingWallPaper" -Type DWord -Value 1

# Also disable Active Desktop
Set-GPRegistryValue -Name $GPOName -Domain $Domain `
    -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" `
    -ValueName "NoActiveDesktop" -Type DWord -Value 1

Write-Host "  Wallpaper: SET (Fill mode, changes disabled)" -ForegroundColor Green

# ============================================================================
#  2. DISABLE USER ACCOUNT PHOTO CHANGE
# ============================================================================
Write-Host "`n[2/4] Disabling user account photo change..." -ForegroundColor Yellow

# Force default account picture for all users (they can't change it)
# Only the API/admin can set thumbnailPhoto in AD
# Computer Config > Admin Templates > Control Panel > User Accounts
Set-GPRegistryValue -Name $GPOName -Domain $Domain `
    -Key "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" `
    -ValueName "UseDefaultTile" -Type DWord -Value 1

# Block access to "Your Info" page in Settings where photo is changed
# This hides the account picture change option in Settings > Accounts
Set-GPRegistryValue -Name $GPOName -Domain $Domain `
    -Key "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" `
    -ValueName "NoChangeAccountPicture" -Type DWord -Value 1

# Disable Settings > Accounts page entirely for extra safety
# User Config > Admin Templates > Control Panel > Settings Page Visibility
Set-GPRegistryValue -Name $GPOName -Domain $Domain `
    -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" `
    -ValueName "SettingsPageVisibility" -Type String `
    -Value "hide:yourinfo"

Write-Host "  Account photo change: DISABLED" -ForegroundColor Green
Write-Host "  (Photos can still be set via API -> AD thumbnailPhoto)" -ForegroundColor DarkGray

# ============================================================================
#  3. DISABLE REGISTRY EDITOR
# ============================================================================
Write-Host "`n[3/4] Disabling Registry Editor..." -ForegroundColor Yellow

# User Config > Admin Templates > System > Prevent access to registry editing tools
# Value: 1 = Disable regedit (including silent mode)
Set-GPRegistryValue -Name $GPOName -Domain $Domain `
    -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" `
    -ValueName "DisableRegistryTools" -Type DWord -Value 1

Write-Host "  Registry Editor (regedit): DISABLED" -ForegroundColor Green

# ============================================================================
#  4. PREVENT DOMAIN/WORKGROUP CHANGES
# ============================================================================
Write-Host "`n[4/4] Preventing domain/workgroup changes..." -ForegroundColor Yellow

# Disable System Properties > Computer Name tab (where domain is changed)
# User Config > Admin Templates > System > Prevent access to system properties
Set-GPRegistryValue -Name $GPOName -Domain $Domain `
    -Key "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" `
    -ValueName "NoPropertiesMyComputer" -Type DWord -Value 1

# Also hide "Network ID" and "Change" buttons specifically
# Computer Config > Admin Templates > System > Disable changing computer name
Set-GPRegistryValue -Name $GPOName -Domain $Domain `
    -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\CurrentVersion\Winlogon" `
    -ValueName "DisableChangeComputerName" -Type DWord -Value 1

# Block domain join/unjoin UI
# Computer Config > Windows Settings > Security Settings
Set-GPRegistryValue -Name $GPOName -Domain $Domain `
    -Key "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
    -ValueName "NoMachineDomainJoin" -Type DWord -Value 1

# Disable Network Connections settings (so they can't change adapter/DNS)
Set-GPRegistryValue -Name $GPOName -Domain $Domain `
    -Key "HKCU\Software\Policies\Microsoft\Windows\Network Connections" `
    -ValueName "NC_LanProperties" -Type DWord -Value 0

Write-Host "  Domain/Computer name change: DISABLED" -ForegroundColor Green
Write-Host "  Network adapter settings: DISABLED" -ForegroundColor Green

# ============================================================================
#  SUMMARY
# ============================================================================
Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host " GPO Configuration Complete!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host " GPO: $GPOName" -ForegroundColor White
Write-Host " Applied policies:" -ForegroundColor White
Write-Host "   [x] Wallpaper set to TCIOE branding (Fill mode)" -ForegroundColor Green
Write-Host "   [x] Wallpaper change disabled" -ForegroundColor Green
Write-Host "   [x] User account photo change disabled" -ForegroundColor Green
Write-Host "   [x] Registry Editor (regedit) disabled" -ForegroundColor Green
Write-Host "   [x] Domain/computer name change disabled" -ForegroundColor Green
Write-Host "   [x] Network adapter settings disabled" -ForegroundColor Green
Write-Host ""
Write-Host " IMPORTANT:" -ForegroundColor Yellow
Write-Host "   1. Wallpaper auto-downloaded from tcioe.edu.np to SYSVOL" -ForegroundColor Yellow
Write-Host ""
Write-Host "   2. Force GPO update on lab PCs:" -ForegroundColor Yellow
Write-Host "      gpupdate /force" -ForegroundColor White
Write-Host ""
Write-Host "   3. These apply to ALL users on lab PCs." -ForegroundColor Yellow
Write-Host "      Admins logging in locally will also be affected." -ForegroundColor Yellow
Write-Host "      To exempt admins, use Security Filtering or WMI filter." -ForegroundColor Yellow
Write-Host ""
