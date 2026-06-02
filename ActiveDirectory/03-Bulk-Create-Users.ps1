# ================================================================
# Step 3: Bulk Create 2000 Users from CSV
# Run AFTER Step 2 (RBAC structure must exist)
# Run as Domain Admin on the Domain Controller
# ================================================================
# USAGE:
#   .\03-Bulk-Create-Users.ps1                          # uses users.csv in same folder
#   .\03-Bulk-Create-Users.ps1 -CsvPath "C:\myusers.csv"
#   .\03-Bulk-Create-Users.ps1 -GenerateSample          # auto-generate 2000 sample users
# ================================================================

param(
    [string]$CsvPath = "$PSScriptRoot\users.csv",
    [switch]$GenerateSample
)

Import-Module ActiveDirectory

$Domain        = (Get-ADDomain).DistinguishedName
$DomainDNS     = (Get-ADDomain).DNSRoot
$DefaultPass   = (Read-Host "Enter default password for new users" -AsSecureString)

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Bulk User Creation"
Write-Host " Domain: $DomainDNS"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# ══════════════════════════════════════════════════════════════════════
# Generate sample CSV with 2000 users if requested
# ══════════════════════════════════════════════════════════════════════
if ($GenerateSample) {
    Write-Host "Generating 2000 sample users..." -ForegroundColor Yellow

    $FirstNames = @("Suman","Ram","Shyam","Hari","Gita","Sita","Anita","Binod","Prakash","Deepak",
                     "Sarita","Mina","Rajesh","Suresh","Mahesh","Kamala","Nirmala","Bikash","Sandesh","Prabha",
                     "Raju","Bimal","Anil","Sunita","Kumari","Laxmi","Krishna","Bishnu","Ganesh","Durga",
                     "Nabin","Kabita","Dipak","Puspa","Renuka","Saroj","Manish","Pawan","Yogesh","Rekha")

    $LastNames = @("Sharma","Adhikari","Bhandari","Poudel","Thapa","Gurung","Magar","Tamang","Rai","Limbu",
                    "Shrestha","Maharjan","Karki","Ghimire","Sapkota","Dhakal","Pandey","Joshi","Khadka","Basnet",
                    "Neupane","Subedi","Koirala","Bhattarai","Rijal","Dahal","Chhetri","Lama","KC","Regmi")

    $Departments = @(
        @{ Dept="IT Department";     Role="Role-SuperAdmin";  Title="IT Staff" },
        @{ Dept="Administration";    Role="Role-SuperAdmin";  Title="Admin Staff" },
        @{ Dept="Faculty";           Role="Role-Teacher";     Title="Lecturer" },
        @{ Dept="Students";          Role="Role-Students";    Title="Student" },
        @{ Dept="Finance";           Role="Role-SuperAdmin";  Title="Accountant" },
        @{ Dept="Human Resources";   Role="Role-SuperAdmin";  Title="HR Officer" },
        @{ Dept="Library";           Role="Role-Teacher";     Title="Librarian" },
        @{ Dept="Research";          Role="Role-Teacher";     Title="Researcher" },
        @{ Dept="Engineering";       Role="Role-Teacher";     Title="Lab Assistant" },
        @{ Dept="Management";        Role="Role-SuperAdmin";  Title="Manager" }
    )

    # Distribution: ~1400 students, ~600 staff across departments
    $Users = @()
    $usedNames = @{}

    for ($i = 1; $i -le 2000; $i++) {
        $first = $FirstNames | Get-Random
        $last  = $LastNames  | Get-Random

        # Pick department (70% students, 30% staff)
        if ($i -le 1400) {
            $deptInfo = $Departments | Where-Object { $_.Dept -eq "Students" }
        } else {
            $deptInfo = $Departments | Where-Object { $_.Dept -ne "Students" } | Get-Random
        }

        # Ensure unique username
        $baseUser = ("$($first.ToLower()).$($last.ToLower())")
        $username = $baseUser
        $counter = 1
        while ($usedNames.ContainsKey($username)) {
            $username = "$baseUser$counter"
            $counter++
        }
        $usedNames[$username] = $true

        $Users += [PSCustomObject]@{
            FirstName   = $first
            LastName    = $last
            Username    = $username
            Email       = "$username@$DomainDNS"
            Department  = $deptInfo.Dept
            Title       = $deptInfo.Title
            Role        = $deptInfo.Role
            Phone       = "977-56-" + (Get-Random -Minimum 100000 -Maximum 999999)
        }
    }

    $Users | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "  Generated $($Users.Count) users in: $CsvPath" -ForegroundColor Green
    Write-Host ""
}

# ══════════════════════════════════════════════════════════════════════
# Import users from CSV
# ══════════════════════════════════════════════════════════════════════
if (-not (Test-Path $CsvPath)) {
    Write-Host "ERROR: CSV not found at $CsvPath" -ForegroundColor Red
    Write-Host "  Run with -GenerateSample to create a sample CSV" -ForegroundColor Yellow
    exit 1
}

$Users = Import-Csv -Path $CsvPath
$Total = $Users.Count
$Created = 0
$Skipped = 0
$Failed = 0

Write-Host "Importing $Total users from $CsvPath..." -ForegroundColor Yellow
Write-Host ""

foreach ($user in $Users) {
    $i = $Users.IndexOf($user) + 1

    # Show progress every 100 users
    if ($i % 100 -eq 0 -or $i -eq 1) {
        Write-Progress -Activity "Creating users" -Status "$i of $Total" -PercentComplete (($i / $Total) * 100)
    }

    # Determine target OU based on department
    $TargetOU = "OU=$($user.Department),OU=TCIOE Users,$Domain"

    # Handle student batches (put in sub-OU)
    if ($user.Department -eq "Students") {
        $batches = @("Batch-2080", "Batch-2081", "Batch-2082", "Batch-2083", "Batch-2084")
        $batch = $batches | Get-Random
        $TargetOU = "OU=$batch,OU=Students,OU=TCIOE Users,$Domain"
    }

    # Handle faculty sub-OUs
    if ($user.Department -eq "Faculty") {
        $programs = @("Computer Engineering", "Electronics Engineering", "Civil Engineering", "Electrical Engineering")
        $program = $programs | Get-Random
        $TargetOU = "OU=$program,OU=Faculty,OU=TCIOE Users,$Domain"
    }

    try {
        # Check if user already exists
        if (Get-ADUser -Filter "SamAccountName -eq '$($user.Username)'" -ErrorAction SilentlyContinue) {
            $Skipped++
            continue
        }

        # Create user
        New-ADUser `
            -SamAccountName $user.Username `
            -UserPrincipalName "$($user.Username)@$DomainDNS" `
            -Name "$($user.FirstName) $($user.LastName)" `
            -GivenName $user.FirstName `
            -Surname $user.LastName `
            -DisplayName "$($user.FirstName) $($user.LastName)" `
            -EmailAddress $user.Email `
            -Title $user.Title `
            -Department $user.Department `
            -Office "TCIOE Campus" `
            -OfficePhone $user.Phone `
            -Path $TargetOU `
            -AccountPassword $DefaultPass `
            -ChangePasswordAtLogon $true `
            -Enabled $true

        # Add user to their RBAC role group
        if ($user.Role) {
            Add-ADGroupMember -Identity $user.Role -Members $user.Username
        }

        $Created++
    }
    catch {
        $Failed++
        Write-Host "  FAILED: $($user.Username) - $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Progress -Activity "Creating users" -Completed

# ── Summary ──────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Bulk User Import Complete!"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host " Total in CSV:  $Total"
Write-Host " Created:       $Created" -ForegroundColor Green
Write-Host " Skipped:       $Skipped" -ForegroundColor Yellow
Write-Host " Failed:        $Failed" -ForegroundColor $(if ($Failed -gt 0) { "Red" } else { "Green" })
Write-Host ""
Write-Host " Users per role:"

$RoleCounts = $Users | Group-Object Role | Sort-Object Count -Descending
foreach ($rc in $RoleCounts) {
    Write-Host "   $($rc.Name): $($rc.Count)"
}

Write-Host ""
Write-Host " Verify with:"
Write-Host '   Get-ADUser -Filter * -SearchBase "OU=TCIOE Users,$Domain" | Measure-Object'
Write-Host '   Get-ADGroupMember "Role-Students" | Measure-Object'
Write-Host '   Get-ADUser -Filter {Department -eq "Faculty"} | Select Name,Department'
