# EMIS - Educational Management Information System

**REST API for Active Directory User & Lab Management at TCIOE (Thapathali Campus, IOE)**

Built with [Pode](https://github.com/Badgerati/Pode) (PowerShell web framework) running on Windows Server Domain Controller.

---

## Architecture

```
┌──────────────┐     HTTPS (443)      ┌───────────────┐     HTTP (8080)     ┌──────────────────┐
│   Clients    │ ──────────────────▶  │  nginx proxy  │ ────────────────▶  │  Pode API Server │
│  (Browser /  │                      │  (DC:443)     │                     │  (DC:8080)       │
│   Postman)   │                      └───────────────┘                     │  + Active Dir.   │
└──────────────┘                                                            └────────┬─────────┘
                                                                                     │
                    ┌──────────────┐     Polls every 30s                              │
                    │  Lab PCs     │ ◀──── GET /pending-messages ─────────────────────┘
                    │  (Domain     │ ────▶ POST /pcs/register (on boot)
                    │   Joined)    │
                    └──────────────┘
```

- **Domain**: `emis.local`
- **Email Domain**: `@tcioe.edu.np`
- **DC**: `WIN-M732KGNLU8C` (10.10.100.3)
- **API URL**: `https://api-emis.tcioe.edu.np` (proxied via nginx)
- **Internal**: `http://localhost:8080`

---

## Quick Start (on DC)

```powershell
# 1. Install Pode
Install-Module -Name Pode -Scope CurrentUser -Force

# 2. Download the API script
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/sumanmhz/sumanmhz/main/ActiveDirectory/04-AD-User-API.ps1" -OutFile "C:\emis-api\04-AD-User-API.ps1"

# 3. Create required directories
New-Item -ItemType Directory -Path "C:\emis-api\photos" -Force

# 4. Run the API
powershell -File "C:\emis-api\04-AD-User-API.ps1"
```

---

## Authentication

All API requests require an `X-API-Key` header.

```
X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs
```

### Roles

| Role | Access |
|------|--------|
| `superadmin` | Full access — create/delete users, manage labs, install software |
| `teacher` | Monitor labs, reset student passwords |
| `student` | Change own password only |
| `polling-agent` | Used by lab PCs for auto-registration and message polling |

### API Key File

Located at `C:\emis-api\api-keys.json`:
```json
[
  {
    "Key": "Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs",
    "Role": "superadmin",
    "Owner": "admin",
    "Username": "Administrator"
  }
]
```

---

## TCIOE Schema

### Departments (6 Academic + 2 Admin)
| Code | Name |
|------|------|
| `DOAS` | Department of Applied Sciences |
| `DOA` | Department of Architecture |
| `DAME` | Department of Automobile & Mechanical Engineering |
| `DOCE` | Department of Civil Engineering |
| `DOECE` | Department of Electronics & Computer Engineering |
| `DOIE` | Department of Industrial Engineering |
| `Administration` | Campus Administration |
| `IT` | IT Department |

### Programs (7)
| Code | Department | Level |
|------|-----------|-------|
| `BCT` | DOECE | Bachelor — Computer Engineering |
| `BEI` | DOECE | Bachelor — Electronics & Information |
| `BCE` | DOCE | Bachelor — Civil Engineering |
| `BAR` | DOA | Bachelor — Architecture |
| `BME` | DAME | Bachelor — Mechanical Engineering |
| `BIE` | DOIE | Bachelor — Industrial Engineering |
| `MMDM` | DAME | Masters |

### Batches
`Batch-2080`, `Batch-2081`, `Batch-2082`, `Batch-2083`, `Batch-2084`

### OU Structure
```
DC=emis,DC=local
└── OU=EMIS Users
    ├── OU=Students
    │   ├── OU=BCE
    │   │   ├── OU=Batch-2080
    │   │   ├── OU=Batch-2081
    │   │   └── ...
    │   ├── OU=BEI
    │   └── ...
    └── OU=Staff
        ├── OU=DOECE
        ├── OU=DOCE
        ├── OU=Administration
        └── ...
```

### User Types

**Students** — username = THA + batch + program + serial (e.g., `THA080BCT002`)
```
Username:  THA080BCT002
Email:     THA080BCT002@tcioe.edu.np
OU:        OU=Batch-2080,OU=BCT,OU=Students,OU=EMIS Users,DC=emis,DC=local
```

**Staff/Teachers** — username = hajiri ID (employee ID, e.g., `10234`)
```
Username:  10234
Email:     10234@tcioe.edu.np (or custom)
OU:        OU=DOECE,OU=Staff,OU=EMIS Users,DC=emis,DC=local
```

---

## API Endpoints

### System

#### `GET /api/v1/health`
Health check.
```bash
curl -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" \
  http://localhost:8080/api/v1/health
```

---

### Auth

#### `POST /api/v1/auth/login`
Login with AD credentials.
```bash
curl -X POST http://localhost:8080/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"Administrator","password":"YourPassword"}'
```

#### `GET /api/v1/auth/me`
Get current user info (requires login session).

#### `GET /api/v1/dashboard`
Dashboard stats (user counts, lab status).

---

### Users

#### `GET /api/v1/users`
List/search users with pagination.

| Param | Description |
|-------|------------|
| `page` | Page number (default: 1) |
| `pageSize` | Results per page (default: 50, max: 200) |
| `search` | Search by name/username/email |
| `dept` | Filter by department |
| `batch` | Filter by batch |

```bash
curl -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" \
  "http://localhost:8080/api/v1/users?dept=DOECE&batch=Batch-2080&page=1"
```

#### `POST /api/v1/users`
Create a single user. All fields are explicit (no auto-parsing).

**Create Student:**
```bash
curl -X POST http://localhost:8080/api/v1/users \
  -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" \
  -H "Content-Type: application/json" \
  -d '{
    "userType": "student",
    "firstName": "Ram",
    "lastName": "Sharma",
    "username": "THA080BCT001",
    "email": "THA080BCT001@tcioe.edu.np",
    "department": "DOECE",
    "batch": "Batch-2080",
    "program": "BCT",
    "photo": "THA080BCT001.jpg"
  }'
```

**Create Staff/Teacher:**
```bash
curl -X POST http://localhost:8080/api/v1/users \
  -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" \
  -H "Content-Type: application/json" \
  -d '{
    "userType": "staff",
    "firstName": "Sita",
    "lastName": "Adhikari",
    "username": "10234",
    "email": "sita@tcioe.edu.np",
    "department": "DOECE",
    "title": "Assistant Professor"
  }'
```

| Field | Student | Staff | Description |
|-------|---------|-------|-------------|
| `userType` | `"student"` | `"staff"` | Required |
| `firstName` | Required | Required | |
| `lastName` | Required | Required | |
| `username` | Required (THA+roll) | Required (hajiri ID) | 2-20 chars |
| `email` | Required | Required | |
| `department` | Required | Required | Must be valid |
| `batch` | Required | — | e.g., `Batch-2080` |
| `program` | Required | — | e.g., `BCE` |
| `title` | Optional | Optional | Job title |
| `role` | — | Optional | Override auto-assigned role |
| `photo` | Optional | Optional | Filename from `/api/v1/photos/` |

**Response (201):**
```json
{
  "message": "User created",
  "username": "THA080BCT001",
  "email": "THA080BCT001@tcioe.edu.np",
  "userType": "student",
  "department": "DOECE",
  "batch": "Batch-2080",
  "program": "BCT",
  "role": "Role-Students",
  "tempPassword": "Emis@482910",
  "mustChange": true,
  "photo": "/api/v1/photos/THA080BCT001.jpg"
}
```

#### `POST /api/v1/users/bulk`
Create up to 500 users at once. Same field schema as single create.

```bash
curl -X POST http://localhost:8080/api/v1/users/bulk \
  -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" \
  -H "Content-Type: application/json" \
  -d '{
    "users": [
      {
        "userType": "student",
        "firstName": "Ram",
        "lastName": "Sharma",
        "username": "THA080BCT001",
        "email": "THA080BCT001@tcioe.edu.np",
        "department": "DOECE",
        "batch": "Batch-2080",
        "program": "BCT",
        "photo": "THA080BCT001.jpg"
      },
      {
        "userType": "student",
        "firstName": "Sita",
        "lastName": "KC",
        "username": "THA080BCT002",
        "email": "THA080BCT002@tcioe.edu.np",
        "department": "DOECE",
        "batch": "Batch-2080",
        "program": "BCT"
      }
    ]
  }'
```

**Response:**
```json
{
  "summary": { "total": 2, "created": 2, "skipped": 0, "failed": 0 },
  "created": [...],
  "skipped": [],
  "failed": []
}
```

#### `DELETE /api/v1/users/:username`
Disable a user and move to `OU=Disabled Accounts`.
```bash
curl -X DELETE -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" \
  http://localhost:8080/api/v1/users/THA080BCT001
```

#### `DELETE /api/v1/users/batch/:batch`
Disable all students in a batch (across all programs).
```bash
curl -X DELETE -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" \
  http://localhost:8080/api/v1/users/batch/Batch-2080
```

#### `DELETE /api/v1/users/staff/department/:department`
Disable all staff in a department.
```bash
curl -X DELETE -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" \
  http://localhost:8080/api/v1/users/staff/department/DOECE
```

---

### Photos

Photos are stored on the server at `C:\emis-api\photos\` and also set as AD `thumbnailPhoto` attribute when linked during user creation.

#### `POST /api/v1/photos/bulk`
Bulk upload photos as base64-encoded JSON.

```bash
curl -X POST http://localhost:8080/api/v1/photos/bulk \
  -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" \
  -H "Content-Type: application/json" \
  -d '{
    "photos": [
      { "filename": "THA080BCT001.jpg", "base64": "/9j/4AAQ..." },
      { "filename": "THA080BCT002.jpg", "base64": "/9j/4BBR..." }
    ]
  }'
```

- Max 500 photos per request
- Max 1MB per photo
- Supported: `.jpg`, `.jpeg`, `.png`

**Response:**
```json
{
  "summary": { "total": 2, "saved": 2, "failed": 0 },
  "saved": [
    { "filename": "THA080BCT001.jpg", "size": 45230, "url": "/api/v1/photos/THA080BCT001.jpg" }
  ],
  "failed": []
}
```

#### `GET /api/v1/photos/:filename`
Serve a photo file.
```bash
curl http://localhost:8080/api/v1/photos/THA080BCT001.jpg -o photo.jpg
```

**Workflow:**
1. Upload photos in bulk → `POST /api/v1/photos/bulk`
2. Create users with `"photo": "THA080BCT001.jpg"` → sets AD `thumbnailPhoto` automatically
3. View any photo → `GET /api/v1/photos/THA080BCT001.jpg`

---

### Passwords

#### `PUT /api/v1/users/:username/password`
Change own password (students can only change their own).
```bash
curl -X PUT http://localhost:8080/api/v1/users/THA080BCT001/password \
  -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" \
  -H "Content-Type: application/json" \
  -d '{"oldPassword":"Emis@482910","newPassword":"MyNew@Pass1"}'
```

#### `POST /api/v1/users/:username/reset`
Admin/teacher reset password (generates new temp password).
```bash
curl -X POST -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" \
  http://localhost:8080/api/v1/users/THA080BCT001/reset
```

---

### Labs

#### `GET /api/v1/labs`
List all configured labs.

#### `GET /api/v1/labs/:lab`
Lab details with PC list and online/offline status.

#### `GET /api/v1/labs/:lab/monitor`
Live monitoring — who's logged in, running processes.

---

### PC Management

#### `POST /api/v1/pcs/:hostname/shutdown`
```bash
curl -X POST -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" \
  http://localhost:8080/api/v1/pcs/DESKTOP-O8QKSH4/shutdown
```

#### `POST /api/v1/pcs/:hostname/restart`
Restart a lab PC.

#### `POST /api/v1/pcs/:hostname/logoff`
Force logoff all sessions.

#### `POST /api/v1/pcs/:hostname/message`
Queue a popup message (delivered via polling agent).
```bash
curl -X POST http://localhost:8080/api/v1/pcs/DESKTOP-O8QKSH4/message \
  -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" \
  -H "Content-Type: application/json" \
  -d '{"message":"Lab closing in 10 minutes!","from":"Admin"}'
```

#### `GET /api/v1/pcs/:hostname/pending-messages`
Used by polling agent to fetch queued messages. Requires `polling-agent` key.

#### `POST /api/v1/pcs/register`
Auto-register a lab PC (called by startup script). Auto-detects lab from IP subnet.
```json
{ "hostname": "DESKTOP-O8QKSH4", "ip": "10.10.30.89" }
```

#### `GET /api/v1/pcs/registered`
List all registered lab PCs.

---

### Bulk Lab Operations

#### `POST /api/v1/labs/:lab/shutdown-all`
Shutdown all PCs in a lab.

#### `POST /api/v1/labs/:lab/restart-all`
Restart all PCs in a lab.

#### `POST /api/v1/labs/:lab/message-all`
Send a message to all PCs in a lab.

---

### Software Management

#### `GET /api/v1/pcs/:hostname/software`
List installed software on a PC.

#### `POST /api/v1/pcs/:hostname/install`
Install software on a single PC.
```json
{ "wingetId": "Mozilla.Firefox" }
```

#### `POST /api/v1/labs/:lab/install`
Install software on all PCs in a lab.

---

## Lab PC Polling System

Lab PCs can't be reached from the DC (router blocks inter-VLAN). Instead, PCs poll the API.

**Startup Script** (`poll-messages.ps1`):
- Deployed via GPO as a startup script
- Auto-registers PC hostname + IP on boot
- Polls `GET /pending-messages` every 30 seconds
- Displays messages via `msg.exe` + balloon notification

**GPO**: "Lab PC Security" — includes startup script, firewall rules, and lockdown policies.

---

## GPO Lockdown Policies

Run `05-GPO-LabLockdown.ps1` on the DC to apply:

| Policy | Effect |
|--------|--------|
| TCIOE Wallpaper | Forced campus wallpaper, can't be changed |
| No Account Photo Change | Only API/admin can set user photos |
| No Registry Editor | `regedit` blocked for all users |
| No Domain Change | Can't unjoin/rejoin domain |
| No Network Changes | Can't modify IP/DNS/adapter settings |

---

## Config Files

All stored in `C:\emis-api\`:

| File | Purpose |
|------|---------|
| `api-keys.json` | API key → role mapping |
| `labs.json` | Lab definitions (PCs, IPs) |
| `lab-subnets.json` | Subnet → lab name mapping |
| `pc-registry.json` | Auto-registered PCs |
| `message-queue.json` | Pending messages for lab PCs |
| `photos/` | User photos directory |

---

## PowerShell Testing Examples

```powershell
# Set headers once
$h = @{ "X-API-Key" = "Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs"; "Content-Type" = "application/json" }

# Health
Invoke-RestMethod -Uri "http://localhost:8080/api/v1/health"

# Create student
Invoke-RestMethod -Method Post -Uri "http://localhost:8080/api/v1/users" -Headers $h -Body (@{
    userType="student"; firstName="Ram"; lastName="Sharma"; username="THA080BCT001"
    email="THA080BCT001@tcioe.edu.np"; department="DOECE"; batch="Batch-2080"; program="BCT"
} | ConvertTo-Json)

# Create teacher
Invoke-RestMethod -Method Post -Uri "http://localhost:8080/api/v1/users" -Headers $h -Body (@{
    userType="staff"; firstName="Sita"; lastName="Adhikari"; username="10234"
    email="sita@tcioe.edu.np"; department="DOECE"
} | ConvertTo-Json)

# List users
Invoke-RestMethod -Uri "http://localhost:8080/api/v1/users?dept=DOECE" -Headers $h

# Upload photo
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\to\photo.jpg"))
Invoke-RestMethod -Method Post -Uri "http://localhost:8080/api/v1/photos/bulk" -Headers $h -Body (@{
    photos = @(@{ filename="THA080BCT001.jpg"; base64=$b64 })
} | ConvertTo-Json -Depth 3)

# Send message
Invoke-RestMethod -Method Post -Uri "http://localhost:8080/api/v1/pcs/DESKTOP-O8QKSH4/message" -Headers $h -Body (@{
    message="Lab closing soon!"; from="Admin"
} | ConvertTo-Json)

# Delete user
Invoke-RestMethod -Method Delete -Uri "http://localhost:8080/api/v1/users/THA080BCT001" -Headers $h
```

---

## Error Responses

All errors return JSON:
```json
{
  "error": "ValidationError",
  "message": "Missing: firstName, lastName"
}
```

| Code | Error | Meaning |
|------|-------|---------|
| 400 | ValidationError | Invalid/missing fields |
| 401 | Unauthorized | Missing or invalid API key |
| 403 | Forbidden | Insufficient role |
| 404 | NotFound | User/lab/PC not found |
| 409 | Conflict | User already exists |
| 500 | ServerError | Internal error |

---

## Tech Stack

- **Pode v2.13.3** — PowerShell REST framework
- **ActiveDirectory module** — AD user/group management
- **nginx** — HTTPS reverse proxy
- **Windows Server** — Domain Controller
- **GPO** — Lab PC policy enforcement

---

## License

MIT — See [LICENSE](../LICENSE)
