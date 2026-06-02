# ================================================================
# Step 1: Install AD DS and Promote to Domain Controller
# Run this on Windows Server (2019/2022) as Administrator
# ================================================================
# CONFIGURATION — Edit these before running
$DomainName     = "tcioe.edu.np"
$NetBIOSName    = "TCIOE"
$SafeModePass   = (Read-Host "Enter DSRM (Safe Mode) password" -AsSecureString)
# ================================================================

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Active Directory Domain Services Setup"
Write-Host " Domain: $DomainName"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# ── Step 1: Install AD DS Role ───────────────────────────────────────
Write-Host "Step 1/3: Installing AD DS role and management tools..." -ForegroundColor Yellow

Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools -Verbose

# Also install DNS and GPMC
Install-WindowsFeature -Name DNS -IncludeManagementTools
Install-WindowsFeature -Name GPMC

Write-Host "AD DS role installed successfully." -ForegroundColor Green

# ── Step 2: Promote to Domain Controller ─────────────────────────────
Write-Host ""
Write-Host "Step 2/3: Promoting server to Domain Controller..." -ForegroundColor Yellow
Write-Host "  This will CREATE a new forest: $DomainName" -ForegroundColor White
Write-Host ""

Import-Module ADDSDeployment

Install-ADDSForest `
    -DomainName $DomainName `
    -DomainNetbiosName $NetBIOSName `
    -ForestMode "WinThreshold" `
    -DomainMode "WinThreshold" `
    -InstallDns:$true `
    -CreateDnsDelegation:$false `
    -DatabasePath "C:\Windows\NTDS" `
    -SysvolPath "C:\Windows\SYSVOL" `
    -LogPath "C:\Windows\NTDS" `
    -SafeModeAdministratorPassword $SafeModePass `
    -NoRebootOnCompletion:$false `
    -Force:$true

# Server will reboot automatically after promotion
# After reboot, run 02-Create-RBAC-Structure.ps1
