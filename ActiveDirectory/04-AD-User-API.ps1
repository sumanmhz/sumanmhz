# ================================================================
# Step 4: Lab & User Management REST API
# Controls AD users + Lab PCs via WinRM (PowerShell Remoting)
# Requires: Pode module, ActiveDirectory module, WinRM enabled on lab PCs
# Run as Domain Admin on the Domain Controller
# ================================================================
# USAGE:
#   .\04-AD-User-API.ps1                            # start on port 8443 (HTTPS)
#   .\04-AD-User-API.ps1 -Port 9443                 # custom port
#   .\04-AD-User-API.ps1 -GenerateKey                # generate a new service key
#   .\04-AD-User-API.ps1 -HttpOnly -Port 8080        # HTTP (dev only)
# ================================================================
# ROLES (3 only):
#   superadmin - Full control: users, PCs, software, all labs
#   teacher    - Monitor ANY lab, view students, reset student passwords
#   student    - Change own password only
# ================================================================
# ENDPOINTS:
#   --- Health ---
#   GET    /api/v1/health
#
#   --- Auth ---
#   POST   /api/v1/auth/login                     - AD login - returns API key + role
#   GET    /api/v1/auth/me                         - Who am I (from key)
#
#   --- Dashboard ---
#   GET    /api/v1/dashboard                       - Aggregate stats (users, labs, PCs)
#
#   --- Users (superadmin) ---
#   GET    /api/v1/users                          - List/search users
#   POST   /api/v1/users                          - Create user (explicit: username, email, batch, program, department)
#   POST   /api/v1/users/bulk                     - Bulk create users
#   DELETE /api/v1/users/:username                 - Disable user
#   DELETE /api/v1/users/batch/:batch              - Disable entire batch (across all programs)
#   DELETE /api/v1/users/staff/department/:dept    - Disable entire department staff
#
#   --- Photos ---
#   POST   /api/v1/photos/bulk                     - Bulk upload photos (base64 JSON array)
#   GET    /api/v1/photos/:filename                - Get a photo
#
#   --- Password ---
#   PUT    /api/v1/users/:username/password        - Change password (student: own only)
#   POST   /api/v1/users/:username/reset           - Admin/teacher reset password
#
#   --- Labs (superadmin + teacher) ---
#   GET    /api/v1/labs                            - List all labs
#   GET    /api/v1/labs/:lab                       - Lab detail + PC status
#   GET    /api/v1/labs/:lab/monitor               - Live: who's logged in, processes
#
#   --- PC Management (superadmin) ---
#   POST   /api/v1/pcs/:hostname/shutdown          - Shutdown a PC
#   POST   /api/v1/pcs/:hostname/restart           - Restart a PC
#   POST   /api/v1/pcs/:hostname/logoff            - Force logoff
#   POST   /api/v1/pcs/:hostname/message           - Send popup message
#   POST   /api/v1/labs/:lab/shutdown-all           - Shutdown all PCs in a lab
#   POST   /api/v1/labs/:lab/restart-all            - Restart all PCs in a lab
#   POST   /api/v1/labs/:lab/message-all            - Message all PCs in a lab
#
#   --- Software (superadmin) ---
#   POST   /api/v1/pcs/:hostname/install            - Install software on a PC
#   POST   /api/v1/labs/:lab/install                 - Install software on all PCs in lab
#   GET    /api/v1/pcs/:hostname/software            - List installed software
#
#   --- Web Dashboard ---
#   GET    /                                        - Redirects to /web/
#   GET    /web/*                                   - Serves static dashboard files
# ================================================================

param(
    [int]$Port = 8443,
    [switch]$GenerateKey,
    [switch]$HttpOnly,
    [int]$Threads = 16
)

# - Install Pode if missing -
if (-not (Get-Module -ListAvailable -Name Pode)) {
    Write-Host "Installing Pode module..." -ForegroundColor Yellow
    Install-Module -Name Pode -Force -AllowClobber -Scope CurrentUser
}

Import-Module Pode
Import-Module ActiveDirectory

$ConfigDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $ConfigDir) { $ConfigDir = "C:\emis-api" }
$KeyFile   = Join-Path $ConfigDir "api-keys.json"
$LabFile   = Join-Path $ConfigDir "labs.json"

# - Generate Service Key -
function New-ServiceKey {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return [Convert]::ToBase64String($bytes) -replace '[+/=]', ''
}

if ($GenerateKey) {
    $newKey = New-ServiceKey

    Write-Host ""
    Write-Host "Select role:" -ForegroundColor Yellow
    Write-Host "  1) superadmin - Full control"
    Write-Host "  2) teacher    - Monitor any lab, reset student passwords"
    Write-Host "  3) student    - Change own password only"
    $roleChoice = Read-Host "Role (1/2/3)"
    $role = switch ($roleChoice) {
        "1" { "superadmin" }
        "2" { "teacher" }
        "3" { "student" }
        default { Write-Host "Invalid choice" -ForegroundColor Red; exit 1 }
    }

    $name = Read-Host "Service/user name (e.g., portal, ram.sharma, lab-monitor)"

    $keyEntry = @{
        Name    = $name
        Key     = $newKey
        Role    = $role
        Created = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }

    # For student, ask username
    if ($role -eq "student") {
        $username = Read-Host "AD username this key belongs to"
        $keyEntry.Username = $username
    }

    $keys = @()
    if (Test-Path $KeyFile) {
        $keys = @(Get-Content $KeyFile -Raw | ConvertFrom-Json)
    }
    $keys += $keyEntry
    $keys | ConvertTo-Json -Depth 5 | Set-Content $KeyFile -Encoding UTF8

    Write-Host ""
    Write-Host "Service Key Generated" -ForegroundColor Green
    Write-Host "  Name:  $name"
    Write-Host "  Role:  $role" -ForegroundColor Cyan
    Write-Host "  Key:   $newKey" -ForegroundColor Cyan
    if ($keyEntry.Lab)      { Write-Host "  Lab:   $($keyEntry.Lab)" }
    if ($keyEntry.Username) { Write-Host "  User:  $($keyEntry.Username)" }
    Write-Host ""
    Write-Host "  Header: X-Api-Key: $newKey" -ForegroundColor Yellow
    Write-Host "  IMPORTANT: Copy this key now." -ForegroundColor Red
    exit 0
}

# - Verify configs exist -
if (-not (Test-Path $KeyFile)) {
    Write-Host "ERROR: No API keys configured." -ForegroundColor Red
    Write-Host "  Run: .\04-AD-User-API.ps1 -GenerateKey" -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path $LabFile)) {
    Write-Host "WARNING: No labs.json found. Creating template..." -ForegroundColor Yellow
    $template = @()
    $labInfo = @(
        @{ Num=1; Loc="Block A, Room 101" },
        @{ Num=2; Loc="Block A, Room 102" },
        @{ Num=3; Loc="Block B, Room 201" },
        @{ Num=4; Loc="Block B, Room 202" },
        @{ Num=5; Loc="Block B, Room 203" }
    )
    foreach ($lab in $labInfo) {
        $n = $lab.Num
        $pcs = @()
        for ($p = 1; $p -le 24; $p++) {
            $pcs += @{ Hostname = "LAB$n-PC$($p.ToString('D2'))"; IP = "10.10.$n.$($p + 10)" }
        }
        $template += @{
            Name     = "Lab-$n"
            Location = $lab.Loc
            Switch   = "10.10.$n.1"
            Subnet   = "10.10.$n.0/24"
            Gateway  = "10.10.$n.1"
            PCs      = $pcs
        }
    }
    $template | ConvertTo-Json -Depth 5 | Set-Content $LabFile -Encoding UTF8
    Write-Host "  Created: $LabFile (5 labs, 24 PCs each = 120 total)" -ForegroundColor Green
    Write-Host "  Edit this file to match your actual lab layout." -ForegroundColor Yellow
    Write-Host ""
}

# -
# START PODE SERVER
# -
Start-PodeServer -Threads $Threads {

    # - Server Config -
    if ($HttpOnly) {
        Add-PodeEndpoint -Address * -Port $Port -Protocol Http
    } else {
        Add-PodeEndpoint -Address * -Port $Port -Protocol Https -SelfSigned
    }

    New-PodeLoggingMethod -Terminal | Enable-PodeRequestLogging
    New-PodeLoggingMethod -Terminal | Enable-PodeErrorLogging

    # - Serve static dashboard files -
    $webDir = Join-Path $ConfigDir "web"
    if (Test-Path $webDir) {
        Add-PodeStaticRoute -Path '/web' -Source $webDir -Defaults @('index.html')
    }

    # - Photos directory -
    $photosDir = "C:\emis-api\photos"
    if (-not (Test-Path $photosDir)) { New-Item -ItemType Directory -Path $photosDir -Force | Out-Null }

    # - Root redirect to dashboard -
    Add-PodeRoute -Method Get -Path '/' -ScriptBlock {
        Move-PodeResponseUrl -Url '/web/'
    }

    # Rate limit: 100 req/min per IP
    Add-PodeLimitRule -Type IP -Values * -Limit 100 -Seconds 60

    # - Load Config -
    $script:ADDomain    = (Get-ADDomain).DistinguishedName
    $script:ADDomainDNS = (Get-ADDomain).DNSRoot
    $script:KeyFilePath = $KeyFile
    $script:LabFilePath = $LabFile
    $script:MsgQueueFile = Join-Path $ConfigDir "message-queue.json"
    if (-not (Test-Path $script:MsgQueueFile)) { '[]' | Set-Content $script:MsgQueueFile -Encoding UTF8 }
    $pcRegistryFile = "C:\emis-api\pc-registry.json"
    if (-not (Test-Path $pcRegistryFile)) { '[]' | Set-Content $pcRegistryFile -Encoding UTF8 }

    $script:ValidBatches     = @("Batch-2080", "Batch-2081", "Batch-2082", "Batch-2083", "Batch-2084")
    $script:ValidPrograms    = @("BCE", "BEI", "BAR", "BAE", "BME", "BCiE", "BIE", "MSc-IIS", "MSc-EQ", "PhD-ME", "BAS")
    $script:ValidDepartments = @("DOAS", "DOA", "DAME", "DOCE", "DOECE", "DOIE", "Administration", "IT")
    $script:ProgramToDept    = @{ BCE="DOECE"; BEI="DOECE"; BAR="DOA"; BAE="DAME"; BME="DAME"; BCiE="DOCE"; BIE="DOIE"; "MSc-IIS"="DOECE"; "MSc-EQ"="DOCE"; "PhD-ME"="DAME"; BAS="DOAS" }
    $script:EmailDomain      = "tcioe.edu.np"

    # Lab-to-subnet mapping
    $labSubnetsFile = "C:\emis-api\lab-subnets.json"
    if (-not (Test-Path $labSubnetsFile)) {
        @(
            @{ Name = "Lab-D101"; Subnet = "10.10.30.0/24"; Location = "D101"; Gateway = "10.10.30.1" }
        ) | ConvertTo-Json -Depth 3 | Set-Content $labSubnetsFile -Encoding UTF8
    }

    $script:RoleMap = @{
        "DOAS"           = "Role-Teacher"
        "DOA"            = "Role-Teacher"
        "DAME"           = "Role-Teacher"
        "DOCE"           = "Role-Teacher"
        "DOECE"          = "Role-Teacher"
        "DOIE"           = "Role-Teacher"
        "Administration" = "Role-SuperAdmin"
        "IT"             = "Role-SuperAdmin"
    }

    # - Helper: Load labs from JSON -
    function Get-Labs {
        @(Get-Content "C:\emis-api\labs.json" -Raw | ConvertFrom-Json)
    }

    function Get-Lab {
        param([string]$Name)
        $labs = Get-Labs
        $labs | Where-Object { $_.Name -eq $Name }
    }

    # - Helper: Resolve target OU -
    # Students: OU=Batch,OU=Program,OU=Students,OU=EMIS Users,DC=emis,DC=local
    # Staff:    OU=Department,OU=Staff,OU=EMIS Users,DC=emis,DC=local
    function Get-UserOU {
        param([string]$Department, [string]$Batch, [string]$Program, [string]$UserType)
        $base = "OU=EMIS Users,DC=emis,DC=local"
        if ($UserType -eq "student" -and $Program -and $Batch) {
            return "OU=$Batch,OU=$Program,OU=Students,$base"
        }
        if ($Department) { return "OU=$Department,OU=Staff,$base" }
        return $base
    }

    # - Helper: Parse roll number → batch, program, serial -
    function Parse-RollNumber {
        param([string]$RollNo)
        if ($RollNo -match '^(\d{3})([A-Za-z]+-?[A-Za-z]*)(\d+)$') {
            $batchNum = $Matches[1]
            $prog = $Matches[2]
            $serial = $Matches[3]
            # Validate program
            if ($prog -in @("BCE","BEI","BAR","BAE","BME","BCiE","BIE","BAS")) {
                return @{ Batch = "Batch-20$batchNum"; Program = $prog; Serial = $serial; Valid = $true }
            }
        }
        # Try MSc/PhD patterns
        if ($RollNo -match '^(\d{3})(MSc-IIS|MSc-EQ|PhD-ME)(\d+)$') {
            return @{ Batch = "Batch-20$($Matches[1])"; Program = $Matches[2]; Serial = $Matches[3]; Valid = $true }
        }
        return @{ Valid = $false }
    }

    # - Helper: Resolve lab from IP subnet -
    function Get-LabFromIP {
        param([string]$IP)
        $labSubnetsFile = "C:\emis-api\lab-subnets.json"
        if (-not (Test-Path $labSubnetsFile)) { return $null }
        $labSubnets = @(Get-Content $labSubnetsFile -Raw -Encoding UTF8 | ConvertFrom-Json)
        $ipSubnet = ($IP -replace '\.\d+$', '.0/24')
        $match = $labSubnets | Where-Object { $_.Subnet -eq $ipSubnet }
        if ($match) { return $match.Name }
        return $null
    }

    # -
    # MIDDLEWARE: API Key Auth + Role Check
    # -
    Add-PodeMiddleware -Name 'ApiKeyAuth' -ScriptBlock {
        if ($WebEvent.Path -eq '/api/v1/health') { return $true }
        if ($WebEvent.Path -eq '/api/v1/auth/login') { return $true }
        if ($WebEvent.Path -notlike '/api/*') { return $true }

        $apiKey = $WebEvent.Request.Headers['X-Api-Key']
        if ([string]::IsNullOrWhiteSpace($apiKey)) {
            Set-PodeResponseStatus -Code 401
            Write-PodeJsonResponse -Value @{ error = "Unauthorized"; message = "Missing X-Api-Key header" }
            return $false
        }

        $keys = @(Get-Content "C:\emis-api\api-keys.json" -Raw | ConvertFrom-Json)
        $matched = $keys | Where-Object { $_.Key -eq $apiKey }

        if (-not $matched) {
            Set-PodeResponseStatus -Code 403
            Write-PodeJsonResponse -Value @{ error = "Forbidden"; message = "Invalid API key" }
            return $false
        }

        # Attach caller identity to request
        if ($null -eq $WebEvent.Data) {
            $WebEvent.Data = @{}
        } elseif ($WebEvent.Data -isnot [hashtable]) {
            # Convert PSObject to hashtable preserving body data
            $ht = @{}
            $WebEvent.Data.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
            $WebEvent.Data = $ht
        }
        $WebEvent.Data['_role']     = $matched.Role
        $WebEvent.Data['_name']     = $matched.Name
        $WebEvent.Data['_username'] = $matched.Username   # student's AD username
        return $true
    }

    # - Role check helper -
    function Assert-Role {
        param([string[]]$Allowed)
        $role = $WebEvent.Data['_role']
        if ($role -in $Allowed) { return $true }
        Set-PodeResponseStatus -Code 403
        Write-PodeJsonResponse -Value @{
            error   = "Forbidden"
            message = "Role '$role' cannot access this. Required: $($Allowed -join ' or ')"
        }
        return $false
    }

    # -
    #                         HEALTH CHECK
    # -
    Add-PodeRoute -Method Get -Path '/api/v1/health' -ScriptBlock {
        try {
            $dc = Get-ADDomainController -Discover
            $labs = Get-Labs
            Write-PodeJsonResponse -Value @{
                status    = "healthy"
                domain    = "emis.local"
                dc        = $dc.HostName[0]
                labs      = $labs.Count
                timestamp = (Get-Date -Format "o")
            }
        } catch {
            Set-PodeResponseStatus -Code 503
            Write-PodeJsonResponse -Value @{ status = "unhealthy"; error = $_.Exception.Message }
        }
    }

    # -
    #                    AUTH & DASHBOARD
    # -

    # - POST /api/v1/auth/login - AD credential login -
    Add-PodeRoute -Method Post -Path '/api/v1/auth/login' -ScriptBlock {
        $body = $WebEvent.Data
        if ([string]::IsNullOrWhiteSpace($body.username) -or [string]::IsNullOrWhiteSpace($body.password)) {
            Set-PodeResponseStatus -Code 400
            Write-PodeJsonResponse -Value @{ error = "ValidationError"; message = "'username' and 'password' required" }
            return
        }

        $safeUser = $body.username -replace '[^a-zA-Z0-9._-]', ''

        try {
            $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext([System.DirectoryServices.AccountManagement.ContextType]::Domain)
            $valid = $ctx.ValidateCredentials("$safeUser@emis.local", $body.password)
            $ctx.Dispose()
        } catch { $valid = $false }

        if (-not $valid) {
            Set-PodeResponseStatus -Code 401
            Write-PodeJsonResponse -Value @{ error = "AuthenticationFailed"; message = "Invalid username or password" }
            return
        }

        # Determine role from AD groups
        try {
            $adUser = Get-ADUser -Identity $safeUser -Properties MemberOf, Department, DisplayName -ErrorAction Stop
            $groups = @($adUser.MemberOf | ForEach-Object { (Get-ADGroup $_).Name })

            $role = 'student'
            if ($groups -contains 'Role-DomainAdmins' -or $groups -contains 'Role-ITAdmins' -or $groups -contains 'Domain Admins') {
                $role = 'superadmin'
            } elseif ($groups -contains 'Role-Faculty' -or $groups -contains 'Role-LabAssistants' -or $groups -contains 'Role-HelpDesk') {
                $role = 'teacher'
            }

            # Find or create a session key for this user
            $keys = @(Get-Content "C:\emis-api\api-keys.json" -Raw | ConvertFrom-Json)
            $existing = $keys | Where-Object { $_.Name -eq "session:$safeUser" -and $_.Role -eq $role }

            if ($existing) {
                $sessionKey = $existing.Key
            } else {
                $bytes = New-Object byte[] 32
                [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
                $sessionKey = [Convert]::ToBase64String($bytes) -replace '[+/=]', ''
                $keys += @{
                    Name     = "session:$safeUser"
                    Key      = $sessionKey
                    Role     = $role
                    Username = $safeUser
                    Created  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                }
                $keys | ConvertTo-Json -Depth 5 | Set-Content "C:\emis-api\api-keys.json" -Encoding UTF8
            }

            Write-PodeJsonResponse -Value @{
                message     = "Login successful"
                username    = $safeUser
                displayName = $adUser.DisplayName
                department  = $adUser.Department
                role        = $role
                apiKey      = $sessionKey
            }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ error = "ServerError"; message = $_.Exception.Message }
        }
    }

    # - GET /api/v1/auth/me - Who am I -
    Add-PodeRoute -Method Get -Path '/api/v1/auth/me' -ScriptBlock {
        if (-not (Assert-Role @("superadmin", "teacher", "student"))) { return }
        Write-PodeJsonResponse -Value @{
            name     = $WebEvent.Data['_name']
            role     = $WebEvent.Data['_role']
            username = $WebEvent.Data['_username']
        }
    }

    # - GET /api/v1/dashboard - Aggregate stats -
    Add-PodeRoute -Method Get -Path '/api/v1/dashboard' -ScriptBlock {
        if (-not (Assert-Role @("superadmin", "teacher"))) { return }

        try {
            $labs = Get-Labs
            $labStats = @($labs | ForEach-Object {
                $onlineCount = 0
                foreach ($pc in $_.PCs) {
                    if (Test-Connection -ComputerName $pc.IP -Count 1 -Quiet -TimeoutSeconds 1) { $onlineCount++ }
                }
                @{
                    name     = $_.Name
                    location = $_.Location
                    total    = $_.PCs.Count
                    online   = $onlineCount
                    offline  = $_.PCs.Count - $onlineCount
                }
            })

            $totalPCs = ($labStats | Measure-Object -Property total -Sum).Sum
            $onlinePCs = ($labStats | Measure-Object -Property online -Sum).Sum

            $result = @{
                labs      = $labStats
                totalPCs  = $totalPCs
                onlinePCs = $onlinePCs
                timestamp = (Get-Date -Format "o")
            }

            # Superadmin gets user counts too
            if ($WebEvent.Data['_role'] -eq 'superadmin') {
                $base = "OU=EMIS Users,DC=emis,DC=local"
                $totalUsers = (Get-ADUser -SearchBase $base -Filter * | Measure-Object).Count
                $enabledUsers = (Get-ADUser -SearchBase $base -Filter 'Enabled -eq $true' | Measure-Object).Count
                $students = (Get-ADUser -SearchBase "OU=Students,$base" -Filter * | Measure-Object).Count
                $faculty = (Get-ADUser -SearchBase "OU=Faculty,$base" -Filter * -ErrorAction SilentlyContinue | Measure-Object).Count
                $result.totalUsers   = $totalUsers
                $result.enabledUsers = $enabledUsers
                $result.students     = $students
                $result.faculty      = $faculty
            }

            Write-PodeJsonResponse -Value $result
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ error = "ServerError"; message = $_.Exception.Message }
        }
    }

    # -
    #              USER MANAGEMENT (superadmin only)
    # -

    # - GET /api/v1/users -
    Add-PodeRoute -Method Get -Path '/api/v1/users' -ScriptBlock {
        if (-not (Assert-Role @("superadmin", "teacher"))) { return }

        $dept     = $WebEvent.Query['department']
        $batch    = $WebEvent.Query['batch']
        $program  = $WebEvent.Query['program']
        $search   = $WebEvent.Query['search']
        $page     = if ($WebEvent.Query['page'])     { [int]$WebEvent.Query['page'] }     else { 1 }
        $pageSize = if ($WebEvent.Query['pageSize']) { [int]$WebEvent.Query['pageSize'] } else { 50 }
        if ($pageSize -gt 200) { $pageSize = 200 }
        if ($page -lt 1) { $page = 1 }

        # Teachers can only list students
        if ($WebEvent.Data['_role'] -eq 'teacher') { $dept = "Students" }

        try {
            $searchBase = "OU=EMIS Users,DC=emis,DC=local"
            if ($dept -eq "Students" -and $batch) {
                $searchBase = "OU=$batch,OU=Students,$searchBase"
            } elseif ($dept -eq "Faculty" -and $program) {
                $searchBase = "OU=$program,OU=Faculty,$searchBase"
            } elseif ($dept) {
                $searchBase = "OU=$dept,$searchBase"
            }

            $filter = "*"
            if ($search) {
                $filter = "Name -like '*$search*' -or SamAccountName -like '*$search*' -or EmailAddress -like '*$search*'"
            }

            $allUsers = Get-ADUser -SearchBase $searchBase -Filter $filter `
                -Properties DisplayName, EmailAddress, Department, Title, Enabled, WhenCreated, DistinguishedName |
                Select-Object SamAccountName, DisplayName, EmailAddress, Department, Title, Enabled, WhenCreated, DistinguishedName

            $total = $allUsers.Count
            $users = $allUsers | Select-Object -Skip (($page - 1) * $pageSize) -First $pageSize

            $results = @($users | ForEach-Object {
                $dn = $_.DistinguishedName
                $ouMatch = [regex]::Match($dn, 'OU=(Batch-\d+)')
                $progMatch = [regex]::Match($dn, 'OU=(BCE|BEI|BAR|BAE|BME|BCiE|BIE|BAS|MSc-IIS|MSc-EQ|PhD-ME)')
                $deptMatch = [regex]::Match($dn, 'OU=(DOAS|DOA|DAME|DOCE|DOECE|DOIE|Administration|IT)')
                @{
                    username    = $_.SamAccountName
                    displayName = $_.DisplayName
                    email       = $_.EmailAddress
                    department  = if ($_.Department) { $_.Department } elseif ($deptMatch.Success) { $deptMatch.Groups[1].Value } else { $null }
                    title       = $_.Title
                    enabled     = $_.Enabled
                    created     = $_.WhenCreated.ToString("yyyy-MM-dd")
                    batch       = if ($ouMatch.Success) { $ouMatch.Groups[1].Value } else { $null }
                    program     = if ($progMatch.Success) { $progMatch.Groups[1].Value } else { $null }
                }
            })

            Write-PodeJsonResponse -Value @{
                total = $total; page = $page; pageSize = $pageSize
                pages = [math]::Ceiling($total / $pageSize); users = $results
            }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ error = "ServerError"; message = $_.Exception.Message }
        }
    }

    # - POST /api/v1/users -
    # All fields must be provided explicitly by the caller
    # Students: { "userType":"student", "firstName":"...", "lastName":"...", "username":"080BCE001", "email":"...", "batch":"Batch-2080", "program":"BCE", "department":"DOECE" }
    # Staff:    { "userType":"staff", "firstName":"...", "lastName":"...", "username":"12345", "email":"...", "department":"DOECE" }
    Add-PodeRoute -Method Post -Path '/api/v1/users' -ScriptBlock {
        if (-not (Assert-Role @("superadmin"))) { return }
        $body = $WebEvent.Data

        $userType = if ($body['userType']) { $body['userType'] } else { "staff" }

        # Common required fields
        $required = @("firstName", "lastName", "username", "email", "department")
        $missing = $required | Where-Object { [string]::IsNullOrWhiteSpace($body[$_]) }

        if ($userType -eq "student") {
            # Students also require batch and program
            if (-not $body['batch']) { $missing += "batch" }
            if (-not $body['program']) { $missing += "program" }
        }

        if ($missing) {
            Set-PodeResponseStatus -Code 400
            Write-PodeJsonResponse -Value @{ error = "ValidationError"; message = "Missing: $($missing -join ', ')" }
            return
        }

        $safeUsername = $body['username'] -replace '[^a-zA-Z0-9._-]', ''
        if ($safeUsername -ne $body['username'] -or $safeUsername.Length -lt 2 -or $safeUsername.Length -gt 20) {
            Set-PodeResponseStatus -Code 400
            Write-PodeJsonResponse -Value @{ error = "ValidationError"; message = "Username: 2-20 chars, alphanumeric/dot/hyphen/underscore" }
            return
        }

        $department = $body['department']
        if ($department -notin $script:ValidDepartments) {
            Set-PodeResponseStatus -Code 400
            Write-PodeJsonResponse -Value @{ error = "ValidationError"; message = "Invalid department. Valid: $($script:ValidDepartments -join ', ')" }
            return
        }

        $batch = $body['batch']; $program = $body['program']; $email = $body['email']

        if ($userType -eq "student") {
            if ($batch -notin $script:ValidBatches) {
                Set-PodeResponseStatus -Code 400
                Write-PodeJsonResponse -Value @{ error = "ValidationError"; message = "Invalid batch. Valid: $($script:ValidBatches -join ', ')" }
                return
            }
            if ($program -notin $script:ValidPrograms) {
                Set-PodeResponseStatus -Code 400
                Write-PodeJsonResponse -Value @{ error = "ValidationError"; message = "Invalid program. Valid: $($script:ValidPrograms -join ', ')" }
                return
            }
            $targetOU = Get-UserOU -UserType "student" -Program $program -Batch $batch
            $role = "Role-Students"
        } else {
            $targetOU = Get-UserOU -UserType "staff" -Department $department
            $role = if ($body['role']) { $body['role'] } elseif ($script:RoleMap.ContainsKey($department)) { $script:RoleMap[$department] } else { "Role-Teacher" }
        }

        try {
            if (Get-ADUser -Filter "SamAccountName -eq '$safeUsername'" -ErrorAction SilentlyContinue) {
                Set-PodeResponseStatus -Code 409
                Write-PodeJsonResponse -Value @{ error = "Conflict"; message = "User '$safeUsername' already exists" }
                return
            }

            $tempPass   = "Emis@" + (Get-Random -Minimum 100000 -Maximum 999999)
            $securePass = ConvertTo-SecureString $tempPass -AsPlainText -Force

            New-ADUser -SamAccountName $safeUsername -UserPrincipalName "$safeUsername@tcioe.edu.np" `
                -Name "$($body['firstName']) $($body['lastName'])" -GivenName $body['firstName'] -Surname $body['lastName'] `
                -DisplayName "$($body['firstName']) $($body['lastName'])" -EmailAddress $email `
                -Title $body['title'] -Department $department -Office "TCIOE" `
                -Path $targetOU -AccountPassword $securePass -ChangePasswordAtLogon $true -Enabled $true

            if ($role) { Add-ADGroupMember -Identity $role -Members $safeUsername }

            # Set photo if provided (filename like 080BCE002.jpg)
            $photoUrl = $null
            if ($body['photo']) {
                $safePhoto = $body['photo'] -replace '[^a-zA-Z0-9._-]', ''
                $photoPath = Join-Path "C:\emis-api\photos" $safePhoto
                if (Test-Path $photoPath) {
                    $photoBytes = [IO.File]::ReadAllBytes($photoPath)
                    Set-ADUser -Identity $safeUsername -Replace @{ thumbnailPhoto = $photoBytes }
                    $photoUrl = "/api/v1/photos/$safePhoto"
                }
            }

            Write-PodeJsonResponse -StatusCode 201 -Value @{
                message = "User created"; username = $safeUsername; email = $email; userType = $userType
                department = $department; batch = $batch; program = $program
                role = $role; tempPassword = $tempPass; mustChange = $true; photo = $photoUrl
            }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ error = "ServerError"; message = $_.Exception.Message }
        }
    }

    # - POST /api/v1/users/bulk -
    # All fields explicit per user, same schema as POST /api/v1/users
    Add-PodeRoute -Method Post -Path '/api/v1/users/bulk' -ScriptBlock {
        if (-not (Assert-Role @("superadmin"))) { return }
        $userList = $WebEvent.Data.users

        if (-not $userList -or $userList.Count -eq 0) {
            Set-PodeResponseStatus -Code 400
            Write-PodeJsonResponse -Value @{ error = "ValidationError"; message = "Body must contain 'users' array" }
            return
        }
        if ($userList.Count -gt 500) {
            Set-PodeResponseStatus -Code 400
            Write-PodeJsonResponse -Value @{ error = "ValidationError"; message = "Max 500 users per request" }
            return
        }

        $results = @{ created = @(); skipped = @(); failed = @() }

        foreach ($u in $userList) {
            # Convert PSObject to hashtable if needed
            if ($u -isnot [hashtable]) {
                $uh = @{}; $u.PSObject.Properties | ForEach-Object { $uh[$_.Name] = $_.Value }; $u = $uh
            }
            $userType = if ($u['userType']) { $u['userType'] } else { "staff" }

            # Validate required fields
            $required = @("firstName", "lastName", "username", "email", "department")
            if ($userType -eq "student") { $required += @("batch", "program") }
            $missing = $required | Where-Object { [string]::IsNullOrWhiteSpace($u[$_]) }
            if ($missing) { $results.failed += @{ username = $u['username']; reason = "Missing: $($missing -join ', ')" }; continue }

            $safe = $u['username'] -replace '[^a-zA-Z0-9._-]', ''
            if ($safe.Length -lt 2) { $results.failed += @{ username = $u['username']; reason = "Invalid username" }; continue }

            $department = $u['department']
            if ($department -notin $script:ValidDepartments) { $results.failed += @{ username = $safe; reason = "Invalid department" }; continue }

            $batch = $u['batch']; $program = $u['program']; $email = $u['email']

            if ($userType -eq "student") {
                if ($batch -notin $script:ValidBatches) { $results.failed += @{ username = $safe; reason = "Invalid batch" }; continue }
                if ($program -notin $script:ValidPrograms) { $results.failed += @{ username = $safe; reason = "Invalid program" }; continue }
                $targetOU = Get-UserOU -UserType "student" -Program $program -Batch $batch
                $role = "Role-Students"
            } else {
                $targetOU = Get-UserOU -UserType "staff" -Department $department
                $role = if ($u['role']) { $u['role'] } elseif ($script:RoleMap.ContainsKey($department)) { $script:RoleMap[$department] } else { "Role-Teacher" }
            }

            try {
                if (Get-ADUser -Filter "SamAccountName -eq '$safe'" -ErrorAction SilentlyContinue) {
                    $results.skipped += @{ username = $safe; reason = "Already exists" }; continue
                }

                $tempPass   = "Emis@" + (Get-Random -Minimum 100000 -Maximum 999999)
                $securePass = ConvertTo-SecureString $tempPass -AsPlainText -Force

                New-ADUser -SamAccountName $safe -UserPrincipalName "$safe@tcioe.edu.np" `
                    -Name "$($u['firstName']) $($u['lastName'])" -GivenName $u['firstName'] -Surname $u['lastName'] `
                    -DisplayName "$($u['firstName']) $($u['lastName'])" -EmailAddress $email `
                    -Title $u['title'] -Department $department -Office "TCIOE" `
                    -Path $targetOU -AccountPassword $securePass -ChangePasswordAtLogon $true -Enabled $true

                if ($role) { Add-ADGroupMember -Identity $role -Members $safe }

                # Set photo if provided
                $photoUrl = $null
                if ($u['photo']) {
                    $safePhoto = $u['photo'] -replace '[^a-zA-Z0-9._-]', ''
                    $photoPath = Join-Path "C:\emis-api\photos" $safePhoto
                    if (Test-Path $photoPath) {
                        $photoBytes = [IO.File]::ReadAllBytes($photoPath)
                        Set-ADUser -Identity $safe -Replace @{ thumbnailPhoto = $photoBytes }
                        $photoUrl = "/api/v1/photos/$safePhoto"
                    }
                }

                $results.created += @{ username = $safe; userType = $userType; department = $department; batch = $batch; program = $program; tempPassword = $tempPass; photo = $photoUrl }
            } catch {
                $results.failed += @{ username = $safe; reason = $_.Exception.Message }
            }
        }

        Write-PodeJsonResponse -Value @{
            summary = @{ total = $userList.Count; created = $results.created.Count; skipped = $results.skipped.Count; failed = $results.failed.Count }
            created = $results.created; skipped = $results.skipped; failed = $results.failed
        }
    }

    # - DELETE /api/v1/users/:username -
    Add-PodeRoute -Method Delete -Path '/api/v1/users/:username' -ScriptBlock {
        if (-not (Assert-Role @("superadmin"))) { return }
        $username = $WebEvent.Parameters['username']

        try {
            $user = Get-ADUser -Identity $username -Properties MemberOf -ErrorAction Stop
            $disabledOU = "OU=Disabled Accounts,DC=emis,DC=local"
            foreach ($group in $user.MemberOf) {
                $gn = (Get-ADGroup $group).Name
                if ($gn -ne "Domain Users") { Remove-ADGroupMember -Identity $group -Members $username -Confirm:$false }
            }
            Disable-ADAccount -Identity $username
            Move-ADObject -Identity $user.DistinguishedName -TargetPath $disabledOU
            Write-PodeJsonResponse -Value @{ message = "User disabled and moved to Disabled Accounts"; username = $username }
        } catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
            Set-PodeResponseStatus -Code 404
            Write-PodeJsonResponse -Value @{ error = "NotFound"; message = "User '$username' not found" }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ error = "ServerError"; message = $_.Exception.Message }
        }
    }

    # - DELETE /api/v1/users/batch/:batch -
    # Searches ALL programs for the given batch
    Add-PodeRoute -Method Delete -Path '/api/v1/users/batch/:batch' -ScriptBlock {
        if (-not (Assert-Role @("superadmin"))) { return }
        $batch = $WebEvent.Parameters['batch']
        if ($batch -notin $script:ValidBatches) {
            Set-PodeResponseStatus -Code 400
            Write-PodeJsonResponse -Value @{ error = "ValidationError"; message = "Invalid batch. Valid: $($script:ValidBatches -join ', ')" }
            return
        }
        try {
            $searchBase = "OU=Students,OU=EMIS Users,DC=emis,DC=local"
            $disabledOU = "OU=Disabled Accounts,DC=emis,DC=local"
            # Search across all programs for this batch (OU=Batch-20XX,OU=Program,OU=Students,...)
            $users = Get-ADUser -SearchBase $searchBase -Filter * -Properties MemberOf,DistinguishedName |
                Where-Object { $_.DistinguishedName -match "OU=$batch," }
            $disabled = 0; $errors = @()
            foreach ($user in $users) {
                try {
                    foreach ($group in $user.MemberOf) {
                        $gn = (Get-ADGroup $group).Name
                        if ($gn -ne "Domain Users") { Remove-ADGroupMember -Identity $group -Members $user.SamAccountName -Confirm:$false }
                    }
                    Disable-ADAccount -Identity $user.SamAccountName
                    Move-ADObject -Identity $user.DistinguishedName -TargetPath $disabledOU
                    $disabled++
                } catch { $errors += @{ username = $user.SamAccountName; reason = $_.Exception.Message } }
            }
            Write-PodeJsonResponse -Value @{ message = "Batch removal complete"; batch = $batch; total = @($users).Count; disabled = $disabled; errors = $errors }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ error = "ServerError"; message = $_.Exception.Message }
        }
    }

    # - DELETE /api/v1/users/staff/department/:department -
    # Renamed: was faculty/:program, now targets staff by department
    Add-PodeRoute -Method Delete -Path '/api/v1/users/staff/department/:department' -ScriptBlock {
        if (-not (Assert-Role @("superadmin"))) { return }
        $department = $WebEvent.Parameters['department']
        if ($department -notin $script:ValidDepartments) {
            Set-PodeResponseStatus -Code 400
            Write-PodeJsonResponse -Value @{ error = "ValidationError"; message = "Invalid department. Valid: $($script:ValidDepartments -join ', ')" }
            return
        }
        try {
            $searchBase = "OU=$department,OU=Staff,OU=EMIS Users,DC=emis,DC=local"
            $disabledOU = "OU=Disabled Accounts,DC=emis,DC=local"
            $users = Get-ADUser -SearchBase $searchBase -Filter * -Properties MemberOf
            $disabled = 0; $errors = @()
            foreach ($user in $users) {
                try {
                    foreach ($group in $user.MemberOf) {
                        $gn = (Get-ADGroup $group).Name
                        if ($gn -ne "Domain Users") { Remove-ADGroupMember -Identity $group -Members $user.SamAccountName -Confirm:$false }
                    }
                    Disable-ADAccount -Identity $user.SamAccountName
                    Move-ADObject -Identity $user.DistinguishedName -TargetPath $disabledOU
                    $disabled++
                } catch { $errors += @{ username = $user.SamAccountName; reason = $_.Exception.Message } }
            }
            Write-PodeJsonResponse -Value @{ message = "Staff department removal complete"; department = $department; total = $users.Count; disabled = $disabled; errors = $errors }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ error = "ServerError"; message = $_.Exception.Message }
        }
    }

    # -
    #                    PHOTO MANAGEMENT
    # -

    # - POST /api/v1/photos/bulk - Bulk upload photos as base64 -
    # Body: { "photos": [ { "filename": "080BCE002.jpg", "base64": "/9j/4AAQ..." }, ... ] }
    Add-PodeRoute -Method Post -Path '/api/v1/photos/bulk' -ScriptBlock {
        if (-not (Assert-Role @("superadmin"))) { return }
        $body = $WebEvent.Data
        $photoList = $body.photos
        if (-not $photoList -or $photoList.Count -eq 0) {
            Set-PodeResponseStatus -Code 400
            Write-PodeJsonResponse -Value @{ error = "ValidationError"; message = "Body must contain 'photos' array" }
            return
        }
        if ($photoList.Count -gt 500) {
            Set-PodeResponseStatus -Code 400
            Write-PodeJsonResponse -Value @{ error = "ValidationError"; message = "Max 500 photos per request" }
            return
        }

        $photosDir = "C:\emis-api\photos"
        if (-not (Test-Path $photosDir)) { New-Item -ItemType Directory -Path $photosDir -Force | Out-Null }

        $saved = @(); $failed = @()
        foreach ($p in $photoList) {
            if ($p -isnot [hashtable]) {
                $ph = @{}; $p.PSObject.Properties | ForEach-Object { $ph[$_.Name] = $_.Value }; $p = $ph
            }
            $filename = $p['filename']
            $b64 = $p['base64']
            if (-not $filename -or -not $b64) { $failed += @{ filename = $filename; reason = "Missing filename or base64" }; continue }
            # Sanitize filename - only allow alphanumeric, dash, underscore, dot
            $safeFile = $filename -replace '[^a-zA-Z0-9._-]', ''
            if ($safeFile -notmatch '\.(jpg|jpeg|png)$') { $failed += @{ filename = $filename; reason = "Must be .jpg, .jpeg, or .png" }; continue }
            try {
                $bytes = [Convert]::FromBase64String($b64)
                if ($bytes.Length -gt 1MB) { $failed += @{ filename = $safeFile; reason = "File too large (max 1MB)" }; continue }
                [IO.File]::WriteAllBytes((Join-Path $photosDir $safeFile), $bytes)
                $saved += @{ filename = $safeFile; size = $bytes.Length; url = "/api/v1/photos/$safeFile" }
            } catch {
                $failed += @{ filename = $safeFile; reason = $_.Exception.Message }
            }
        }

        Write-PodeJsonResponse -Value @{
            summary = @{ total = $photoList.Count; saved = $saved.Count; failed = $failed.Count }
            saved = $saved; failed = $failed
        }
    }

    # - GET /api/v1/photos/:filename - Serve a photo -
    Add-PodeRoute -Method Get -Path '/api/v1/photos/:filename' -ScriptBlock {
        $filename = $WebEvent.Parameters['filename']
        $safeFile = $filename -replace '[^a-zA-Z0-9._-]', ''
        $filePath = Join-Path "C:\emis-api\photos" $safeFile
        if (-not (Test-Path $filePath)) {
            Set-PodeResponseStatus -Code 404
            Write-PodeJsonResponse -Value @{ error = "NotFound"; message = "Photo not found" }
            return
        }
        $ext = [IO.Path]::GetExtension($safeFile).ToLower()
        $contentType = switch ($ext) { '.jpg' { 'image/jpeg' } '.jpeg' { 'image/jpeg' } '.png' { 'image/png' } default { 'application/octet-stream' } }
        Set-PodeHeader -Name 'Content-Type' -Value $contentType
        Set-PodeHeader -Name 'Cache-Control' -Value 'public, max-age=86400'
        Write-PodeFileResponse -Path $filePath -ContentType $contentType
    }

    # -
    #                    PASSWORD MANAGEMENT
    # -

    # - PUT /api/v1/users/:username/password - Change own password -
    Add-PodeRoute -Method Put -Path '/api/v1/users/:username/password' -ScriptBlock {
        if (-not (Assert-Role @("superadmin", "teacher", "student"))) { return }

        $username = $WebEvent.Parameters['username']
        $body     = $WebEvent.Data

        # Students can only change their OWN password
        if ($WebEvent.Data['_role'] -eq 'student' -and $WebEvent.Data['_username'] -ne $username) {
            Set-PodeResponseStatus -Code 403
            Write-PodeJsonResponse -Value @{ error = "Forbidden"; message = "Students can only change their own password" }
            return
        }

        if ([string]::IsNullOrWhiteSpace($body.currentPassword) -or [string]::IsNullOrWhiteSpace($body.newPassword)) {
            Set-PodeResponseStatus -Code 400
            Write-PodeJsonResponse -Value @{ error = "ValidationError"; message = "Both 'currentPassword' and 'newPassword' required" }
            return
        }

        $newPwd = $body.newPassword
        if ($newPwd.Length -lt 8) {
            Set-PodeResponseStatus -Code 400
            Write-PodeJsonResponse -Value @{ error = "ValidationError"; message = "Password must be at least 8 characters" }
            return
        }
        $complexity = 0
        if ($newPwd -cmatch '[A-Z]') { $complexity++ }
        if ($newPwd -cmatch '[a-z]') { $complexity++ }
        if ($newPwd -match '\d')     { $complexity++ }
        if ($newPwd -match '[^a-zA-Z0-9]') { $complexity++ }
        if ($complexity -lt 3) {
            Set-PodeResponseStatus -Code 400
            Write-PodeJsonResponse -Value @{ error = "ValidationError"; message = "Need 3 of: uppercase, lowercase, digit, special char" }
            return
        }

        try {
            $user = Get-ADUser -Identity $username -ErrorAction Stop

            # Validate current password
            $valid = $false
            try {
                $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext([System.DirectoryServices.AccountManagement.ContextType]::Domain)
                $valid = $ctx.ValidateCredentials($user.UserPrincipalName, $body.currentPassword)
                $ctx.Dispose()
            } catch { $valid = $false }

            if (-not $valid) {
                Set-PodeResponseStatus -Code 401
                Write-PodeJsonResponse -Value @{ error = "AuthenticationFailed"; message = "Current password is incorrect" }
                return
            }

            $newSecure = ConvertTo-SecureString $body.newPassword -AsPlainText -Force
            Set-ADAccountPassword -Identity $username -NewPassword $newSecure -Reset
            Set-ADUser -Identity $username -ChangePasswordAtLogon $false

            Write-PodeJsonResponse -Value @{ message = "Password changed successfully"; username = $username }
        } catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
            Set-PodeResponseStatus -Code 404
            Write-PodeJsonResponse -Value @{ error = "NotFound"; message = "User '$username' not found" }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ error = "ServerError"; message = $_.Exception.Message }
        }
    }

    # - POST /api/v1/users/:username/reset - Admin/teacher reset -
    Add-PodeRoute -Method Post -Path '/api/v1/users/:username/reset' -ScriptBlock {
        if (-not (Assert-Role @("superadmin", "teacher"))) { return }

        $username = $WebEvent.Parameters['username']

        # Teachers can only reset student passwords
        if ($WebEvent.Data['_role'] -eq 'teacher') {
            try {
                $targetUser = Get-ADUser -Identity $username -Properties Department -ErrorAction Stop
                if ($targetUser.Department -ne "Students") {
                    Set-PodeResponseStatus -Code 403
                    Write-PodeJsonResponse -Value @{ error = "Forbidden"; message = "Teachers can only reset student passwords" }
                    return
                }
            } catch {
                Set-PodeResponseStatus -Code 404
                Write-PodeJsonResponse -Value @{ error = "NotFound"; message = "User '$username' not found" }
                return
            }
        }

        try {
            Get-ADUser -Identity $username -ErrorAction Stop
            $tempPass   = "Emis@" + (Get-Random -Minimum 100000 -Maximum 999999)
            $securePass = ConvertTo-SecureString $tempPass -AsPlainText -Force
            Set-ADAccountPassword -Identity $username -NewPassword $securePass -Reset
            Set-ADUser -Identity $username -ChangePasswordAtLogon $true
            Unlock-ADAccount -Identity $username -ErrorAction SilentlyContinue

            Write-PodeJsonResponse -Value @{ message = "Password reset"; username = $username; tempPassword = $tempPass; mustChange = $true }
        } catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
            Set-PodeResponseStatus -Code 404
            Write-PodeJsonResponse -Value @{ error = "NotFound"; message = "User '$username' not found" }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ error = "ServerError"; message = $_.Exception.Message }
        }
    }

    # -
    #                    LAB MANAGEMENT
    # -

    # - GET /api/v1/labs - List all labs -
    Add-PodeRoute -Method Get -Path '/api/v1/labs' -ScriptBlock {
        if (-not (Assert-Role @("superadmin", "teacher"))) { return }

        $labs = Get-Labs

        $results = @($labs | ForEach-Object {
            @{ name = $_.Name; location = $_.Location; switch = $_.Switch; subnet = $_.Subnet; pcCount = $_.PCs.Count }
        })

        Write-PodeJsonResponse -Value @{ labs = $results }
    }

    # - GET /api/v1/labs/:lab - Lab detail with PC online status -
    Add-PodeRoute -Method Get -Path '/api/v1/labs/:lab' -ScriptBlock {
        if (-not (Assert-Role @("superadmin", "teacher"))) { return }

        $labName = $WebEvent.Parameters['lab']

        $lab = Get-Lab -Name $labName
        if (-not $lab) {
            Set-PodeResponseStatus -Code 404
            Write-PodeJsonResponse -Value @{ error = "NotFound"; message = "Lab '$labName' not found" }
            return
        }

        # Ping all PCs
        $pcStatus = @($lab.PCs | ForEach-Object {
            $online = Test-Connection -ComputerName $_.IP -Count 1 -Quiet -TimeoutSeconds 2
            @{ hostname = $_.Hostname; ip = $_.IP; online = $online }
        })

        $onlineCount = ($pcStatus | Where-Object { $_.online }).Count

        Write-PodeJsonResponse -Value @{
            name = $lab.Name; location = $lab.Location; switch = $lab.Switch
            subnet = $lab.Subnet; gateway = $lab.Gateway
            total = $lab.PCs.Count; online = $onlineCount; offline = $lab.PCs.Count - $onlineCount
            pcs = $pcStatus
        }
    }

    # - GET /api/v1/labs/:lab/monitor - Who's logged in, CPU, RAM -
    Add-PodeRoute -Method Get -Path '/api/v1/labs/:lab/monitor' -ScriptBlock {
        if (-not (Assert-Role @("superadmin", "teacher"))) { return }

        $labName = $WebEvent.Parameters['lab']

        $lab = Get-Lab -Name $labName
        if (-not $lab) {
            Set-PodeResponseStatus -Code 404
            Write-PodeJsonResponse -Value @{ error = "NotFound"; message = "Lab '$labName' not found" }
            return
        }

        $pcData = @($lab.PCs | ForEach-Object {
            $pc = $_
            try {
                $session = New-PSSession -ComputerName $pc.Hostname -ErrorAction Stop

                $info = Invoke-Command -Session $session -ScriptBlock {
                    $loggedOn = (Get-CimInstance Win32_ComputerSystem).UserName
                    $uptime   = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
                    $cpu      = [math]::Round((Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average, 1)
                    $mem      = Get-CimInstance Win32_OperatingSystem
                    $memPct   = [math]::Round((($mem.TotalVisibleMemorySize - $mem.FreePhysicalMemory) / $mem.TotalVisibleMemorySize) * 100, 1)
                    $disk     = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
                    $diskPct  = [math]::Round((($disk.Size - $disk.FreeSpace) / $disk.Size) * 100, 1)
                    $procs    = Get-Process | Where-Object { $_.MainWindowTitle -ne "" } |
                                Select-Object -First 10 ProcessName, @{N='MemoryMB';E={[math]::Round($_.WorkingSet64/1MB,1)}}, MainWindowTitle

                    @{
                        loggedOnUser = $loggedOn
                        uptime       = $uptime.ToString("yyyy-MM-dd HH:mm")
                        cpuPercent   = $cpu
                        memPercent   = $memPct
                        diskPercent  = $diskPct
                        processes    = @($procs)
                    }
                } -ErrorAction Stop

                Remove-PSSession $session

                @{
                    hostname     = $pc.Hostname; ip = $pc.IP; online = $true
                    loggedOnUser = $info.loggedOnUser; uptime = $info.uptime
                    cpuPercent   = $info.cpuPercent; memPercent = $info.memPercent
                    diskPercent  = $info.diskPercent; processes = $info.processes
                }
            } catch {
                @{ hostname = $pc.Hostname; ip = $pc.IP; online = $false; error = $_.Exception.Message }
            }
        })

        $onlineCount = ($pcData | Where-Object { $_.online }).Count

        Write-PodeJsonResponse -Value @{
            lab = $labName; total = $lab.PCs.Count
            online = $onlineCount; offline = $lab.PCs.Count - $onlineCount
            pcs = $pcData
        }
    }

    # -
    #              PC MANAGEMENT (superadmin only)
    # -

    # - Helper: find PC across all labs + registry -
    function Find-PC {
        param([string]$Hostname)
        # Check labs.json
        $labs = Get-Labs
        foreach ($lab in $labs) {
            $pc = $lab.PCs | Where-Object { $_.Hostname -eq $Hostname }
            if ($pc) { return @{ Lab = $lab; PC = $pc } }
        }
        # Check pc-registry.json
        $regFile = "C:\emis-api\pc-registry.json"
        if (Test-Path $regFile) {
            $registry = @(Get-Content $regFile -Raw -Encoding UTF8 | ConvertFrom-Json)
            $found = $registry | Where-Object { $_.Hostname -eq $Hostname }
            if ($found) { return @{ Lab = @{ Name = $found.Lab }; PC = $found } }
        }
        return $null
    }

    # - POST /api/v1/pcs/:hostname/shutdown -
    Add-PodeRoute -Method Post -Path '/api/v1/pcs/:hostname/shutdown' -ScriptBlock {
        if (-not (Assert-Role @("superadmin"))) { return }
        $hostname = $WebEvent.Parameters['hostname']
        $pcInfo = Find-PC -Hostname $hostname
        if (-not $pcInfo) {
            Set-PodeResponseStatus -Code 404
            Write-PodeJsonResponse -Value @{ error = "NotFound"; message = "PC '$hostname' not in any lab" }
            return
        }
        try {
            Stop-Computer -ComputerName $hostname -Force -ErrorAction Stop
            Write-PodeJsonResponse -Value @{ message = "Shutdown sent"; hostname = $hostname; lab = $pcInfo.Lab.Name }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ error = "ServerError"; message = $_.Exception.Message }
        }
    }

    # - POST /api/v1/pcs/:hostname/restart -
    Add-PodeRoute -Method Post -Path '/api/v1/pcs/:hostname/restart' -ScriptBlock {
        if (-not (Assert-Role @("superadmin"))) { return }
        $hostname = $WebEvent.Parameters['hostname']
        $pcInfo = Find-PC -Hostname $hostname
        if (-not $pcInfo) {
            Set-PodeResponseStatus -Code 404
            Write-PodeJsonResponse -Value @{ error = "NotFound"; message = "PC '$hostname' not found" }
            return
        }
        try {
            Restart-Computer -ComputerName $hostname -Force -ErrorAction Stop
            Write-PodeJsonResponse -Value @{ message = "Restart sent"; hostname = $hostname; lab = $pcInfo.Lab.Name }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ error = "ServerError"; message = $_.Exception.Message }
        }
    }

    # - POST /api/v1/pcs/:hostname/logoff -
    Add-PodeRoute -Method Post -Path '/api/v1/pcs/:hostname/logoff' -ScriptBlock {
        if (-not (Assert-Role @("superadmin"))) { return }
        $hostname = $WebEvent.Parameters['hostname']
        $pcInfo = Find-PC -Hostname $hostname
        if (-not $pcInfo) {
            Set-PodeResponseStatus -Code 404
            Write-PodeJsonResponse -Value @{ error = "NotFound"; message = "PC '$hostname' not found" }
            return
        }
        try {
            Invoke-Command -ComputerName $hostname -ScriptBlock {
                $sessions = query user 2>$null | Select-Object -Skip 1
                foreach ($s in $sessions) {
                    $id = ($s.Trim() -split '\s+')[2]
                    logoff $id /server:localhost
                }
            } -ErrorAction Stop
            Write-PodeJsonResponse -Value @{ message = "Logoff sent"; hostname = $hostname }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ error = "ServerError"; message = $_.Exception.Message }
        }
    }

    # - POST /api/v1/pcs/register - (lab PCs auto-register on boot)
    Add-PodeRoute -Method Post -Path '/api/v1/pcs/register' -ScriptBlock {
        $apiKey = $WebEvent.Request.Headers['X-API-Key']
        if ($apiKey -ne 'polling-agent') {
            if (-not (Assert-Role @("superadmin"))) { return }
        }
        $body = $WebEvent.Data
        if ($body -isnot [hashtable]) {
            $ht = @{}; $body.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }; $body = $ht
        }
        $hostname = $body['hostname']
        $ip = $body['ip']
        if (-not $hostname -or -not $ip) {
            Set-PodeResponseStatus -Code 400
            Write-PodeJsonResponse -Value @{ error = "ValidationError"; message = "Body must contain 'hostname' and 'ip'" }
            return
        }
        try {
            $regFile = "C:\emis-api\pc-registry.json"
            $registry = @()
            if (Test-Path $regFile) {
                $raw = Get-Content $regFile -Raw -Encoding UTF8
                if ($raw -and $raw.Trim().Length -gt 2) { $registry = @($raw | ConvertFrom-Json) }
            }
            # Determine lab from subnet (auto-detect)
            $subnet = ($ip -replace '\.\d+$', '.0/24')
            $labName = Get-LabFromIP -IP $ip
            if (-not $labName) { $labName = if ($body['lab']) { $body['lab'] } else { "Unknown-$($ip -replace '\.\d+$', '')" } }
            # Update or add
            $existing = $registry | Where-Object { $_.Hostname -eq $hostname.ToUpper() }
            if ($existing) {
                $existing.IP = $ip
                $existing.Subnet = $subnet
                $existing.Lab = $labName
                $existing.LastSeen = (Get-Date).ToString('o')
                $existing.Online = $true
            } else {
                $registry += @{
                    Hostname  = $hostname.ToUpper()
                    IP        = $ip
                    Subnet    = $subnet
                    Lab       = $labName
                    FirstSeen = (Get-Date).ToString('o')
                    LastSeen  = (Get-Date).ToString('o')
                    Online    = $true
                }
            }
            $registry | ConvertTo-Json -Depth 5 | Set-Content $regFile -Encoding UTF8
            Write-PodeJsonResponse -Value @{ message = "PC registered"; hostname = $hostname.ToUpper(); lab = $labName; ip = $ip }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ error = "ServerError"; message = $_.Exception.Message }
        }
    }

    # - GET /api/v1/pcs/registered - (list all registered PCs)
    Add-PodeRoute -Method Get -Path '/api/v1/pcs/registered' -ScriptBlock {
        if (-not (Assert-Role @("superadmin", "teacher"))) { return }
        $regFile = "C:\emis-api\pc-registry.json"
        $registry = @()
        if (Test-Path $regFile) {
            $raw = Get-Content $regFile -Raw -Encoding UTF8
            if ($raw -and $raw.Trim().Length -gt 2) { $registry = @($raw | ConvertFrom-Json) }
        }
        Write-PodeJsonResponse -Value @{ count = $registry.Count; pcs = $registry }
    }

    # - POST /api/v1/pcs/:hostname/message - (queues message for polling)
    Add-PodeRoute -Method Post -Path '/api/v1/pcs/:hostname/message' -ScriptBlock {
        if (-not (Assert-Role @("superadmin"))) { return }
        $hostname = $WebEvent.Parameters['hostname']
        $body = $WebEvent.Data
        $msgText = $null
        if ($body -is [hashtable]) { $msgText = $body['message'] }
        elseif ($body) { $msgText = $body.message }
        if ([string]::IsNullOrWhiteSpace($msgText)) {
            Set-PodeResponseStatus -Code 400
            Write-PodeJsonResponse -Value @{ error = "ValidationError"; message = "Body must contain 'message'"; debug_type = $body.GetType().Name; debug_keys = "$($body.Keys -join ',')" }
            return
        }
        $pcInfo = Find-PC -Hostname $hostname
        if (-not $pcInfo) {
            Set-PodeResponseStatus -Code 404
            Write-PodeJsonResponse -Value @{ error = "NotFound"; message = "PC '$hostname' not found" }
            return
        }
        try {
            $safeMsg = $body.message -replace '[^a-zA-Z0-9 .,!?@#$%&()\-]', ''
            $mqFile = "C:\emis-api\message-queue.json"
            $queue = @()
            if (Test-Path $mqFile) {
                $raw = Get-Content $mqFile -Raw -Encoding UTF8
                if ($raw -and $raw.Trim().Length -gt 2) { $queue = @($raw | ConvertFrom-Json) }
            }
            $senderName = 'admin'
            if ($WebEvent.Auth -and $WebEvent.Auth.User) { $senderName = $WebEvent.Auth.User.Username }
            $queue += @{
                id        = [guid]::NewGuid().ToString()
                hostname  = $hostname.ToUpper()
                message   = $safeMsg
                sender    = $senderName
                timestamp = (Get-Date).ToString('o')
                delivered = $false
            }
            $queue | ConvertTo-Json -Depth 5 | Set-Content $mqFile -Encoding UTF8
            Write-PodeJsonResponse -Value @{ message = "Message queued"; hostname = $hostname; text = $safeMsg }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ error = "ServerError"; message = $_.Exception.Message }
        }
    }

    # - GET /api/v1/pcs/:hostname/pending-messages - (lab PCs poll this)
    Add-PodeRoute -Method Get -Path '/api/v1/pcs/:hostname/pending-messages' -ScriptBlock {
        $hostname = $WebEvent.Parameters['hostname'].ToUpper()
        $apiKey = $WebEvent.Request.Headers['X-API-Key']
        if ($apiKey -ne 'polling-agent') {
            if (-not (Assert-Role @("superadmin"))) { return }
        }
        try {
            $pending = @()
            $mqFile = "C:\emis-api\message-queue.json"
            $queue = @()
            if (Test-Path $mqFile) {
                $raw = Get-Content $mqFile -Raw -Encoding UTF8
                if ($raw -and $raw.Trim().Length -gt 2) { $queue = @($raw | ConvertFrom-Json) }
            }
            $pending = @($queue | Where-Object { $_.hostname -eq $hostname -and -not $_.delivered })
            foreach ($msg in $queue) {
                if ($msg.hostname -eq $hostname -and -not $msg.delivered) {
                    $msg.delivered = $true
                }
            }
            $queue | ConvertTo-Json -Depth 5 | Set-Content $mqFile -Encoding UTF8
            Write-PodeJsonResponse -Value @{ hostname = $hostname; count = $pending.Count; messages = $pending }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ error = "ServerError"; message = $_.Exception.Message }
        }
    }

    # - POST /api/v1/labs/:lab/shutdown-all -
    Add-PodeRoute -Method Post -Path '/api/v1/labs/:lab/shutdown-all' -ScriptBlock {
        if (-not (Assert-Role @("superadmin"))) { return }
        $lab = Get-Lab -Name $WebEvent.Parameters['lab']
        if (-not $lab) {
            Set-PodeResponseStatus -Code 404
            Write-PodeJsonResponse -Value @{ error = "NotFound"; message = "Lab not found" }
            return
        }
        $ok = @(); $fail = @()
        foreach ($pc in $lab.PCs) {
            try { Stop-Computer -ComputerName $pc.Hostname -Force -ErrorAction Stop; $ok += $pc.Hostname }
            catch { $fail += @{ hostname = $pc.Hostname; reason = $_.Exception.Message } }
        }
        Write-PodeJsonResponse -Value @{ message = "Shutdown all"; lab = $lab.Name; success = $ok.Count; failed = $fail.Count; details = @{ success = $ok; failed = $fail } }
    }

    # - POST /api/v1/labs/:lab/restart-all -
    Add-PodeRoute -Method Post -Path '/api/v1/labs/:lab/restart-all' -ScriptBlock {
        if (-not (Assert-Role @("superadmin"))) { return }
        $lab = Get-Lab -Name $WebEvent.Parameters['lab']
        if (-not $lab) {
            Set-PodeResponseStatus -Code 404
            Write-PodeJsonResponse -Value @{ error = "NotFound"; message = "Lab not found" }
            return
        }
        $ok = @(); $fail = @()
        foreach ($pc in $lab.PCs) {
            try { Restart-Computer -ComputerName $pc.Hostname -Force -ErrorAction Stop; $ok += $pc.Hostname }
            catch { $fail += @{ hostname = $pc.Hostname; reason = $_.Exception.Message } }
        }
        Write-PodeJsonResponse -Value @{ message = "Restart all"; lab = $lab.Name; success = $ok.Count; failed = $fail.Count; details = @{ success = $ok; failed = $fail } }
    }

    # - POST /api/v1/labs/:lab/message-all -
    Add-PodeRoute -Method Post -Path '/api/v1/labs/:lab/message-all' -ScriptBlock {
        if (-not (Assert-Role @("superadmin"))) { return }
        $body = $WebEvent.Data
        if ([string]::IsNullOrWhiteSpace($body.message)) {
            Set-PodeResponseStatus -Code 400
            Write-PodeJsonResponse -Value @{ error = "ValidationError"; message = "Body must contain 'message'" }
            return
        }
        $lab = Get-Lab -Name $WebEvent.Parameters['lab']
        if (-not $lab) {
            Set-PodeResponseStatus -Code 404
            Write-PodeJsonResponse -Value @{ error = "NotFound"; message = "Lab not found" }
            return
        }
        $safeMsg = $body.message -replace '[^a-zA-Z0-9 .,!?@#$%&()\-]', ''
        $ok = @(); $fail = @()
        foreach ($pc in $lab.PCs) {
            try { Invoke-Command -ComputerName $pc.Hostname -ScriptBlock { param($m); msg * $m } -ArgumentList $safeMsg -ErrorAction Stop; $ok += $pc.Hostname }
            catch { $fail += @{ hostname = $pc.Hostname; reason = $_.Exception.Message } }
        }
        Write-PodeJsonResponse -Value @{ message = "Broadcast sent"; lab = $lab.Name; text = $safeMsg; success = $ok.Count; failed = $fail.Count }
    }

    # -
    #              SOFTWARE MANAGEMENT (superadmin only)
    # -

    # - GET /api/v1/pcs/:hostname/software -
    Add-PodeRoute -Method Get -Path '/api/v1/pcs/:hostname/software' -ScriptBlock {
        if (-not (Assert-Role @("superadmin"))) { return }
        $hostname = $WebEvent.Parameters['hostname']
        $pcInfo = Find-PC -Hostname $hostname
        if (-not $pcInfo) {
            Set-PodeResponseStatus -Code 404
            Write-PodeJsonResponse -Value @{ error = "NotFound"; message = "PC '$hostname' not found" }
            return
        }
        try {
            $software = Invoke-Command -ComputerName $hostname -ScriptBlock {
                Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*,
                                 HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName } |
                Select-Object DisplayName, DisplayVersion, Publisher, InstallDate |
                Sort-Object DisplayName
            } -ErrorAction Stop

            Write-PodeJsonResponse -Value @{ hostname = $hostname; lab = $pcInfo.Lab.Name; count = $software.Count; software = @($software) }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ error = "ServerError"; message = $_.Exception.Message }
        }
    }

    # - POST /api/v1/pcs/:hostname/install -
    # Body: { wingetId: "Mozilla.Firefox" }
    # OR:   { installer: "\\server\share\setup.msi", args: "/qn", type: "msi|exe" }
    Add-PodeRoute -Method Post -Path '/api/v1/pcs/:hostname/install' -ScriptBlock {
        if (-not (Assert-Role @("superadmin"))) { return }
        $hostname = $WebEvent.Parameters['hostname']
        $body = $WebEvent.Data
        $pcInfo = Find-PC -Hostname $hostname
        if (-not $pcInfo) {
            Set-PodeResponseStatus -Code 404
            Write-PodeJsonResponse -Value @{ error = "NotFound"; message = "PC '$hostname' not found" }
            return
        }

        try {
            if ($body.wingetId) {
                $safeId = $body.wingetId -replace '[^a-zA-Z0-9._-]', ''
                $result = Invoke-Command -ComputerName $hostname -ScriptBlock {
                    param($id)
                    $out = winget install --id $id --accept-package-agreements --accept-source-agreements --silent 2>&1
                    @{ output = ($out | Out-String); exitCode = $LASTEXITCODE }
                } -ArgumentList $safeId -ErrorAction Stop
                Write-PodeJsonResponse -Value @{ message = "Winget install done"; hostname = $hostname; package = $safeId; exitCode = $result.exitCode; output = $result.output }
            }
            elseif ($body.installer) {
                $type = if ($body.type) { $body.type } else { "msi" }
                $iargs = if ($body.args) { $body.args } else { "/qn /norestart" }
                $result = Invoke-Command -ComputerName $hostname -ScriptBlock {
                    param($inst, $t, $a)
                    if ($t -eq "msi") {
                        $p = Start-Process msiexec.exe -ArgumentList "/i `"$inst`" $a" -Wait -PassThru -NoNewWindow
                    } else {
                        $p = Start-Process $inst -ArgumentList $a -Wait -PassThru -NoNewWindow
                    }
                    @{ exitCode = $p.ExitCode }
                } -ArgumentList $body.installer, $type, $iargs -ErrorAction Stop
                Write-PodeJsonResponse -Value @{ message = "Install done"; hostname = $hostname; installer = $body.installer; exitCode = $result.exitCode }
            }
            else {
                Set-PodeResponseStatus -Code 400
                Write-PodeJsonResponse -Value @{ error = "ValidationError"; message = "Provide 'wingetId' or 'installer'" }
            }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ error = "ServerError"; message = $_.Exception.Message }
        }
    }

    # - POST /api/v1/labs/:lab/install - Install on all PCs -
    Add-PodeRoute -Method Post -Path '/api/v1/labs/:lab/install' -ScriptBlock {
        if (-not (Assert-Role @("superadmin"))) { return }
        $body = $WebEvent.Data
        $lab = Get-Lab -Name $WebEvent.Parameters['lab']
        if (-not $lab) {
            Set-PodeResponseStatus -Code 404
            Write-PodeJsonResponse -Value @{ error = "NotFound"; message = "Lab not found" }
            return
        }
        if (-not $body.wingetId -and -not $body.installer) {
            Set-PodeResponseStatus -Code 400
            Write-PodeJsonResponse -Value @{ error = "ValidationError"; message = "Provide 'wingetId' or 'installer'" }
            return
        }

        $ok = @(); $fail = @()
        foreach ($pc in $lab.PCs) {
            try {
                if ($body.wingetId) {
                    $safeId = $body.wingetId -replace '[^a-zA-Z0-9._-]', ''
                    $r = Invoke-Command -ComputerName $pc.Hostname -ScriptBlock {
                        param($id); winget install --id $id --accept-package-agreements --accept-source-agreements --silent 2>&1 | Out-Null; $LASTEXITCODE
                    } -ArgumentList $safeId -ErrorAction Stop
                    $ok += @{ hostname = $pc.Hostname; exitCode = $r }
                } else {
                    $type = if ($body.type) { $body.type } else { "msi" }
                    $iargs = if ($body.args) { $body.args } else { "/qn /norestart" }
                    $r = Invoke-Command -ComputerName $pc.Hostname -ScriptBlock {
                        param($inst, $t, $a)
                        if ($t -eq "msi") { $p = Start-Process msiexec.exe -ArgumentList "/i `"$inst`" $a" -Wait -PassThru -NoNewWindow }
                        else { $p = Start-Process $inst -ArgumentList $a -Wait -PassThru -NoNewWindow }
                        $p.ExitCode
                    } -ArgumentList $body.installer, $type, $iargs -ErrorAction Stop
                    $ok += @{ hostname = $pc.Hostname; exitCode = $r }
                }
            } catch {
                $fail += @{ hostname = $pc.Hostname; reason = $_.Exception.Message }
            }
        }

        Write-PodeJsonResponse -Value @{
            message = "Lab-wide install complete"; lab = $lab.Name
            package = if ($body.wingetId) { $body.wingetId } else { $body.installer }
            success = $ok.Count; failed = $fail.Count
            details = @{ success = $ok; failed = $fail }
        }
    }

    # -
    #                       STARTUP BANNER
    # -
    $labs = Get-Labs
    $totalPCs = ($labs | ForEach-Object { $_.PCs.Count } | Measure-Object -Sum).Sum

    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host " EMIS Lab & User Management API" -ForegroundColor White
    Write-Host " Domain:  $($script:ADDomainDNS)"
    Write-Host " Port:    $Port"
    Write-Host " Threads: $Threads"
    Write-Host " Labs:    $($labs.Count) ($totalPCs PCs)"
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host " 3 Roles:" -ForegroundColor Yellow
    Write-Host "   superadmin - Full control (users + PCs + software)"
    Write-Host "   teacher    - Monitor any lab, reset student passwords"
    Write-Host "   student    - Change own password only"
    Write-Host ""
    Write-Host " Dashboard:" -ForegroundColor Yellow
    Write-Host "   Open browser: https://localhost:$Port/"
    Write-Host ""
    Write-Host " Auth Endpoints:" -ForegroundColor Yellow
    Write-Host "   POST  /api/v1/auth/login"
    Write-Host "   GET   /api/v1/auth/me"
    Write-Host "   GET   /api/v1/dashboard"
    Write-Host ""
    Write-Host " User Endpoints:" -ForegroundColor Yellow
    Write-Host "   GET    /api/v1/users"
    Write-Host "   POST   /api/v1/users"
    Write-Host "   POST   /api/v1/users/bulk"
    Write-Host "   PUT    /api/v1/users/{u}/password"
    Write-Host "   POST   /api/v1/users/{u}/reset"
    Write-Host "   DELETE /api/v1/users/{u}"
    Write-Host "   DELETE /api/v1/users/batch/{batch}"
    Write-Host "   DELETE /api/v1/users/staff/department/{dept}"
    Write-Host ""
    Write-Host " Photo Endpoints:" -ForegroundColor Yellow
    Write-Host "   POST   /api/v1/photos/bulk                (base64 JSON array)"
    Write-Host "   GET    /api/v1/photos/{filename}"
    Write-Host ""
    Write-Host " Lab Endpoints:" -ForegroundColor Yellow
    Write-Host "   GET    /api/v1/labs"
    Write-Host "   GET    /api/v1/labs/{lab}"
    Write-Host "   GET    /api/v1/labs/{lab}/monitor"
    Write-Host ""
    Write-Host " PC Endpoints:" -ForegroundColor Yellow
    Write-Host "   POST   /api/v1/pcs/{pc}/shutdown"
    Write-Host "   POST   /api/v1/pcs/{pc}/restart"
    Write-Host "   POST   /api/v1/pcs/{pc}/logoff"
    Write-Host "   POST   /api/v1/pcs/{pc}/message"
    Write-Host "   POST   /api/v1/labs/{lab}/shutdown-all"
    Write-Host "   POST   /api/v1/labs/{lab}/restart-all"
    Write-Host "   POST   /api/v1/labs/{lab}/message-all"
    Write-Host ""
    Write-Host " Software Endpoints:" -ForegroundColor Yellow
    Write-Host "   GET    /api/v1/pcs/{pc}/software"
    Write-Host "   POST   /api/v1/pcs/{pc}/install"
    Write-Host "   POST   /api/v1/labs/{lab}/install"
    Write-Host ""
}
