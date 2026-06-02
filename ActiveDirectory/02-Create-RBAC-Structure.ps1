# ================================================================
# Step 2: Create OU Structure and RBAC Security Groups
# Run AFTER server reboots from Step 1
# Run as Domain Admin on the Domain Controller
# ================================================================

Import-Module ActiveDirectory

$Domain = (Get-ADDomain).DistinguishedName
$DomainDNS = (Get-ADDomain).DNSRoot

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Creating RBAC Structure"
Write-Host " Domain: $DomainDNS"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# -
# STEP 1: Create Organizational Units (OUs)
# -
Write-Host "Creating Organizational Units..." -ForegroundColor Yellow

# Top-level OUs
$TopOUs = @(
    "EMIS Users",
    "EMIS Groups",
    "EMIS Computers",
    "Service Accounts",
    "Disabled Accounts"
)

foreach ($ou in $TopOUs) {
    try {
        New-ADOrganizationalUnit -Name $ou -Path $Domain -ProtectedFromAccidentalDeletion $true
        Write-Host "  Created OU: $ou" -ForegroundColor Green
    } catch {
        Write-Host "  OU already exists: $ou" -ForegroundColor DarkYellow
    }
}

# Department OUs (under EMIS Users)
$UserOU = "OU=EMIS Users,$Domain"
$Departments = @(
    "IT Department",
    "Administration",
    "Faculty",
    "Students",
    "Finance",
    "Human Resources",
    "Library",
    "Research",
    "Engineering",
    "Management"
)

foreach ($dept in $Departments) {
    try {
        New-ADOrganizationalUnit -Name $dept -Path $UserOU -ProtectedFromAccidentalDeletion $true
        Write-Host "  Created OU: EMIS Users/$dept" -ForegroundColor Green
    } catch {
        Write-Host "  OU already exists: $dept" -ForegroundColor DarkYellow
    }
}

# Sub-OUs under Students (by year/batch)
$StudentOU = "OU=Students,$UserOU"
$Batches = @("Batch-2080", "Batch-2081", "Batch-2082", "Batch-2083", "Batch-2084")

foreach ($batch in $Batches) {
    try {
        New-ADOrganizationalUnit -Name $batch -Path $StudentOU -ProtectedFromAccidentalDeletion $true
        Write-Host "  Created OU: Students/$batch" -ForegroundColor Green
    } catch {
        Write-Host "  OU already exists: $batch" -ForegroundColor DarkYellow
    }
}

# Sub-OUs under Faculty (by program)
$FacultyOU = "OU=Faculty,$UserOU"
$Programs = @("Computer Engineering", "Electronics Engineering", "Civil Engineering", "Electrical Engineering")

foreach ($prog in $Programs) {
    try {
        New-ADOrganizationalUnit -Name $prog -Path $FacultyOU -ProtectedFromAccidentalDeletion $true
        Write-Host "  Created OU: Faculty/$prog" -ForegroundColor Green
    } catch {
        Write-Host "  OU already exists: $prog" -ForegroundColor DarkYellow
    }
}

Write-Host ""

# -
# STEP 2: Create RBAC Security Groups
# -
Write-Host "Creating RBAC Security Groups..." -ForegroundColor Yellow

$GroupOU = "OU=EMIS Groups,$Domain"

# - Role-Based Groups (what permissions you get) -
$RoleGroups = @(
    @{ Name="Role-SuperAdmin";  Desc="Full domain administration - IT, Finance, HR, Management" },
    @{ Name="Role-Teacher";     Desc="Teaching and academic staff - Faculty, Library, Research, Engineering" },
    @{ Name="Role-Students";    Desc="Student access - labs, library, portal" }
)

foreach ($grp in $RoleGroups) {
    try {
        New-ADGroup -Name $grp.Name -GroupScope Global -GroupCategory Security `
            -Path $GroupOU -Description $grp.Desc
        Write-Host "  Created: $($grp.Name)" -ForegroundColor Green
    } catch {
        Write-Host "  Already exists: $($grp.Name)" -ForegroundColor DarkYellow
    }
}

# - Resource-Based Groups (what you can access) -
# NOTE: All roles get the same daily-use resources (files, printers, WiFi,
#       internet, email, LMS, lab PCs). Only infrastructure access
#       (ServerRoom, VPN, ERP) is limited to admin/staff roles.
$ResourceGroups = @(
    @{ Name="Access-FileServer-RW";       Desc="Read/Write to file server shares" },
    @{ Name="Access-PrinterColor";        Desc="Access to color printers" },
    @{ Name="Access-PrinterBW";           Desc="Access to B&W printers" },
    @{ Name="Access-WiFi";                Desc="Campus WiFi network access" },
    @{ Name="Access-VPN";                 Desc="VPN remote access" },
    @{ Name="Access-LabComputers";        Desc="Login to lab computers" },
    @{ Name="Access-ServerRoom";          Desc="Server room access control" },
    @{ Name="Access-ERP";                 Desc="ERP system access" },
    @{ Name="Access-LMS";                 Desc="Learning Management System access" },
    @{ Name="Access-Email";               Desc="Email system access" },
    @{ Name="Access-InternetFull";        Desc="Unrestricted internet access" }
)

foreach ($grp in $ResourceGroups) {
    try {
        New-ADGroup -Name $grp.Name -GroupScope DomainLocal -GroupCategory Security `
            -Path $GroupOU -Description $grp.Desc
        Write-Host "  Created: $($grp.Name)" -ForegroundColor Green
    } catch {
        Write-Host "  Already exists: $($grp.Name)" -ForegroundColor DarkYellow
    }
}

Write-Host ""

# -
# STEP 3: Map Roles - Resource Access (RBAC nesting)
# -
Write-Host "Mapping RBAC role-to-resource permissions..." -ForegroundColor Yellow

$RoleMappings = @{
    "Role-SuperAdmin" = @(
        "Access-FileServer-RW", "Access-PrinterColor", "Access-PrinterBW",
        "Access-WiFi", "Access-VPN", "Access-ServerRoom",
        "Access-ERP", "Access-LMS", "Access-Email", "Access-InternetFull",
        "Access-LabComputers"
    )
    "Role-Teacher" = @(
        "Access-FileServer-RW", "Access-PrinterColor", "Access-PrinterBW",
        "Access-WiFi", "Access-LMS",
        "Access-Email", "Access-InternetFull", "Access-LabComputers"
    )
    "Role-Students" = @(
        "Access-FileServer-RW", "Access-PrinterColor", "Access-PrinterBW",
        "Access-WiFi", "Access-LMS",
        "Access-Email", "Access-InternetFull", "Access-LabComputers"
    )
}

foreach ($role in $RoleMappings.Keys) {
    foreach ($resource in $RoleMappings[$role]) {
        try {
            Add-ADGroupMember -Identity $resource -Members $role
            Write-Host "  $role --> $resource" -ForegroundColor DarkGray
        } catch {
            Write-Host "  Already mapped: $role --> $resource" -ForegroundColor DarkYellow
        }
    }
}

# Add Role-SuperAdmin to built-in Domain Admins
try {
    Add-ADGroupMember -Identity "Domain Admins" -Members "Role-SuperAdmin"
    Write-Host "  Role-SuperAdmin --> Domain Admins" -ForegroundColor Green
} catch {
    Write-Host "  Already mapped: Role-SuperAdmin --> Domain Admins" -ForegroundColor DarkYellow
}

Write-Host ""

# -
# STEP 4: Create Group Policy Objects (GPOs) for RBAC
# -
Write-Host "Creating Group Policy Objects..." -ForegroundColor Yellow

$GPOs = @(
    @{ Name="GPO-PasswordPolicy";       Desc="Domain password complexity and lockout" },
    @{ Name="GPO-DesktopConfig";         Desc="Desktop configuration and drive mappings for all users" },
    @{ Name="GPO-LabComputers";          Desc="Lab computer WinRM, auto-logoff, power settings" },
    @{ Name="GPO-AuditPolicy";           Desc="Enable logon/logoff and object access auditing" }
)

foreach ($gpo in $GPOs) {
    try {
        New-GPO -Name $gpo.Name -Comment $gpo.Desc | Out-Null
        Write-Host "  Created GPO: $($gpo.Name)" -ForegroundColor Green
    } catch {
        Write-Host "  GPO already exists: $($gpo.Name)" -ForegroundColor DarkYellow
    }
}

# Link GPOs to OUs
$GPOLinks = @(
    @{ GPO="GPO-DesktopConfig";       OU="OU=EMIS Users,$Domain" },
    @{ GPO="GPO-LabComputers";        OU="OU=EMIS Computers,$Domain" },
    @{ GPO="GPO-AuditPolicy";         OU=$Domain }
)

foreach ($link in $GPOLinks) {
    try {
        New-GPLink -Name $link.GPO -Target $link.OU -LinkEnabled Yes | Out-Null
        Write-Host "  Linked $($link.GPO) --> $($link.OU)" -ForegroundColor Green
    } catch {
        Write-Host "  Already linked: $($link.GPO)" -ForegroundColor DarkYellow
    }
}

Write-Host ""

# -
# STEP 5: Set Password Policy
# -
Write-Host "Configuring domain password policy..." -ForegroundColor Yellow

Set-ADDefaultDomainPasswordPolicy -Identity $DomainDNS `
    -MinPasswordLength 8 `
    -PasswordHistoryCount 12 `
    -MaxPasswordAge (New-TimeSpan -Days 90) `
    -MinPasswordAge (New-TimeSpan -Days 1) `
    -ComplexityEnabled $true `
    -LockoutThreshold 5 `
    -LockoutDuration (New-TimeSpan -Minutes 30) `
    -LockoutObservationWindow (New-TimeSpan -Minutes 30)

Write-Host "  Password policy applied." -ForegroundColor Green

# - Summary -
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " RBAC Structure Created Successfully!"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host " OUs:              $($TopOUs.Count) top-level + $($Departments.Count) departments"
Write-Host " Role Groups:      $($RoleGroups.Count) (Global scope)"
Write-Host " Resource Groups:  $($ResourceGroups.Count) (DomainLocal scope)"
Write-Host " GPOs:             $($GPOs.Count) created and linked"
Write-Host ""
Write-Host " RBAC Model:"
Write-Host "   User --> Role Group --> Resource Group --> Actual Permission"
Write-Host ""
Write-Host " Example:"
Write-Host '   jdoe --> Role-Teacher --> Access-WiFi --> WiFi access'
Write-Host ""
Write-Host " Next: Run 03-Bulk-Create-Users.ps1 to import 2000 users"
