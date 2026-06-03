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
                    │  Lab PCs     │ ◀──── GET /pcs/:hostname/config ─────────────────┘
                    │  (EMIS Agent)│ ────▶ POST /pcs/register (on boot)
                    │  (Domain     │ ────▶ POST /sessions/report (login/idle/logout)
                    │   Joined)    │ ◀──── Blocked sites, apps, exam mode, announcements
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

### Programs (10)
| Code | Department | Level |
|------|-----------|-------|
| `BCT` | DOECE | Bachelor — Computer Engineering |
| `BEI` | DOECE | Bachelor — Electronics & Information |
| `BCE` | DOCE | Bachelor — Civil Engineering |
| `BAR` | DOA | Bachelor — Architecture |
| `BME` | DAME | Bachelor — Mechanical Engineering |
| `BIE` | DOIE | Bachelor — Industrial Engineering |
| `BAM` | DAME | Bachelor — Automobile Engineering |
| `MMDM` | DAME | M.Sc. — Mechanical Design & Manufacturing |
| `MEE` | DOCE | M.Sc. — Earthquake Engineering |
| `MIISE` | DOECE | M.Sc. — Informatics & Intelligent Systems Engineering |

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
Aggregate stats for the web dashboard. Teachers get lab/session/announcement data. Superadmins get everything including user breakdowns, blocking stats, audit activity, and photo counts.

**Response (superadmin):**
```json
{
  "totalLabs": 4,
  "totalPCs": 120,
  "onlinePCs": 87,
  "offlinePCs": 33,
  "labs": [
    { "name": "Lab-D101", "location": "D-Block 1st Floor", "total": 30, "online": 24, "offline": 6 },
    { "name": "Lab-D201", "location": "D-Block 2nd Floor", "total": 30, "online": 21, "offline": 9 }
  ],
  "sessions": {
    "active": 45,
    "idle": 8,
    "byLab": { "Lab-D101": 20, "Lab-D201": 15, "Lab-D301": 10 }
  },
  "users": {
    "total": 1250,
    "enabled": 1180,
    "disabled": 70,
    "students": 1100,
    "staff": 150,
    "byProgram": { "BCT": 240, "BEI": 210, "BCE": 200, "BAR": 96, "BME": 144, "BIE": 96, "BAM": 48, "MMDM": 24, "MEE": 24, "MIISE": 18 },
    "byBatch": { "Batch-2080": 220, "Batch-2081": 220, "Batch-2082": 220, "Batch-2083": 220, "Batch-2084": 220 },
    "byDepartment": { "DOECE": 40, "DOCE": 30, "DAME": 25, "DOA": 15, "DOIE": 10, "DOAS": 15, "Administration": 10, "IT": 5 }
  },
  "announcements": 3,
  "examModeLabs": ["Lab-D101"],
  "activeSchedules": 2,
  "blocking": { "sites": 5, "apps": 2 },
  "recentAuditEvents": 42,
  "photos": 980,
  "timestamp": "2026-06-03T14:30:00.000Z"
}
```

**Dashboard Graphs (what you can build from this data):**

| Graph | Type | Data Source |
|-------|------|-------------|
| Lab PC Status | Stacked bar or donut | `labs[].online` vs `labs[].offline` per lab |
| Overall PC Health | Donut/pie | `onlinePCs` vs `offlinePCs` |
| Active Sessions by Lab | Bar chart | `sessions.byLab` |
| Active vs Idle Users | Donut | `sessions.active - sessions.idle` vs `sessions.idle` |
| Students by Program | Horizontal bar | `users.byProgram` (BCT, BEI, BCE, etc.) |
| Students by Batch | Bar chart | `users.byBatch` (Batch-2080 through 2084) |
| Staff by Department | Horizontal bar | `users.byDepartment` |
| Enabled vs Disabled Users | Donut/pie | `users.enabled` vs `users.disabled` |
| Students vs Staff | Pie chart | `users.students` vs `users.staff` |
| Blocking Overview | Stat cards | `blocking.sites`, `blocking.apps` counts |
| System Activity | Stat card + sparkline | `recentAuditEvents` (24h trend from `/audit`) |
| Exam Mode Status | Status indicators | `examModeLabs` — which labs are locked down |
| Photo Coverage | Progress bar | `photos` vs `users.students` (% with photos) |
| Announcements & Schedules | Stat cards | `announcements`, `activeSchedules` counts |

**Time-series graphs** (call `/api/v1/sessions/history` and `/api/v1/audit` periodically):

| Graph | Type | Data Source |
|-------|------|-------------|
| Login Activity Over Time | Line/area chart | `/sessions/history` — group by hour/day |
| Peak Lab Usage Hours | Heatmap | `/sessions/history` — hour × day-of-week |
| Audit Activity Timeline | Line chart | `/audit` — group by hour/day |
| Per-Lab Usage Trend | Multi-line chart | `/sessions/history?lab=X` — daily active users per lab |

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

#### `POST /api/v1/photos/upload`
Upload a photo file via multipart/form-data. *Role: superadmin*

```bash
# Upload with auto-detected filename
curl -X POST http://localhost:8080/api/v1/photos/upload \
  -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" \
  -F "photo=@THA080BCT001.jpg"

# Upload with custom username (renames file to username.ext)
curl -X POST http://localhost:8080/api/v1/photos/upload \
  -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" \
  -F "photo=@photo.jpg" \
  -F "username=THA080BCT001"
```

- Max 2MB per photo
- Supported: `.jpg`, `.jpeg`, `.png`
- Field name must be `photo`
- Optional `username` field to rename the saved file

**Response (201):**
```json
{
  "message": "Photo uploaded",
  "filename": "THA080BCT001.jpg",
  "size": 45230,
  "url": "/api/v1/photos/THA080BCT001.jpg"
}
```

#### `GET /api/v1/photos/:filename`
Serve a photo file. No auth required.
```bash
curl http://localhost:8080/api/v1/photos/THA080BCT001.jpg -o photo.jpg
```

**Workflow:**
1. Upload photo → `POST /api/v1/photos/upload` (with `username=THA080BCT001`)
2. Create user with `"photo": "THA080BCT001.jpg"` → sets AD `thumbnailPhoto` automatically
3. View any photo → `GET /api/v1/photos/THA080BCT001.jpg`

---

### Passwords

#### `PUT /api/v1/users/:username/password`
Change own password (students can only change their own).
```bash
curl -X PUT http://localhost:8080/api/v1/users/THA080BCT001/password \
  -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" \
  -H "Content-Type: application/json" \
  -d '{"currentPassword":"Emis@482910","newPassword":"MyNew@Pass1"}'
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
Auto-register a lab PC (called by startup script). Auto-detects lab from IP subnet. Includes MAC for WOL.
```json
{ "hostname": "DESKTOP-O8QKSH4", "ip": "10.10.30.89", "mac": "AA:BB:CC:DD:EE:FF" }
```

#### `GET /api/v1/pcs/registered`
List all registered lab PCs.

#### `GET /api/v1/pcs/:hostname/config`
Returns full config for a lab PC (used by polling agent). Returns blocked sites, blocked apps, exam mode, announcements, and shutdown schedule — all in one call.

**Response:**
```json
{
  "hostname": "DESKTOP-O8QKSH4",
  "blockedSites": ["facebook.com", "tiktok.com"],
  "blockedApps": ["chrome", "firefox"],
  "examMode": { "enabled": false },
  "announcements": [],
  "schedule": null
}
```

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

### Website Blocking

Block websites on lab PCs by adding entries to their hosts file (resolved to 127.0.0.1).

#### `GET /api/v1/websites/blocked`
List all blocked websites. *Roles: superadmin, teacher*

#### `POST /api/v1/websites/block`
Block a website. *Role: superadmin*
```bash
curl -X POST http://localhost:8080/api/v1/websites/block \
  -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" \
  -H "Content-Type: application/json" \
  -d '{"domain":"facebook.com","reason":"Social media","labs":["Lab1","Lab2"]}'
```
- `labs` is optional — if omitted, blocks on ALL labs.

#### `DELETE /api/v1/websites/block/:domain`
Unblock a website. *Role: superadmin*
```bash
curl -X DELETE -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" \
  http://localhost:8080/api/v1/websites/block/facebook.com
```

---

### App Blocking

Block applications on lab PCs by killing their processes.

#### `GET /api/v1/apps/blocked`
List all blocked apps. *Roles: superadmin, teacher*

#### `POST /api/v1/apps/block`
Block an application. *Role: superadmin*
```bash
curl -X POST http://localhost:8080/api/v1/apps/block \
  -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" \
  -H "Content-Type: application/json" \
  -d '{"processName":"chrome","displayName":"Google Chrome","labs":["Lab1"]}'
```

#### `DELETE /api/v1/apps/block/:appname`
Unblock an application. *Role: superadmin*

---

### Exam Mode

Lock down a lab for exams — block internet (except whitelisted sites), restrict apps, show exam message.

#### `GET /api/v1/labs/:lab/exam-mode`
Get exam mode status. *Roles: superadmin, teacher*

#### `POST /api/v1/labs/:lab/exam-mode`
Enable exam mode. *Role: superadmin*
```bash
curl -X POST http://localhost:8080/api/v1/labs/Lab1/exam-mode \
  -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" \
  -H "Content-Type: application/json" \
  -d '{
    "blockInternet": true,
    "allowedSites": ["10.10.100.3", "moodle.tcioe.edu.np"],
    "allowedApps": ["notepad", "devenv"],
    "blockUSB": true,
    "message": "DBMS Lab Exam in progress"
  }'
```

**How it works on lab PCs:**
- Windows Firewall blocks all outbound traffic
- Only whitelisted IPs (resolved from `allowedSites`) are allowed
- DC traffic (10.10.100.0/24) and DNS are always allowed
- Non-allowed apps with visible windows are killed
- Exam message is displayed via `msg.exe`

#### `DELETE /api/v1/labs/:lab/exam-mode`
Disable exam mode. *Role: superadmin*

---

### Session Tracking

Track user logins, logouts, and idle time on lab PCs.

#### `POST /api/v1/sessions/report`
Report a session event (used by polling agent). *Role: polling-agent*
```json
{ "hostname": "DESKTOP-O8QKSH4", "username": "THA080BCT001", "action": "login" }
```
Actions: `login`, `logout`, `idle`, `active`. Idle reports include `idleMinutes`.

#### `GET /api/v1/sessions/active`
List currently active sessions. *Roles: superadmin, teacher*
```bash
curl -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" \
  "http://localhost:8080/api/v1/sessions/active?lab=Lab1"
```

#### `GET /api/v1/sessions/history`
Session history with pagination. *Role: superadmin*

| Param | Description |
|-------|------------|
| `page` | Page number (default: 1) |
| `pageSize` | Results per page (default: 50) |
| `hostname` | Filter by PC |
| `username` | Filter by user |
| `lab` | Filter by lab |

#### `GET /api/v1/labs/:lab/idle`
List idle users in a lab (idle >= 5 minutes). *Roles: superadmin, teacher*

---

### Announcements

Broadcast announcements to lab PCs. Shown via `msg.exe`, auto-expires.

#### `GET /api/v1/announcements`
List active announcements. *Any authenticated role + polling-agent*

#### `POST /api/v1/announcements`
Create an announcement. *Roles: superadmin, teacher*
```bash
curl -X POST http://localhost:8080/api/v1/announcements \
  -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Maintenance Notice",
    "message": "Labs will be closed for maintenance on Saturday.",
    "priority": "high",
    "labs": ["Lab1", "Lab2"],
    "expiresAt": "2026-06-05T18:00:00"
  }'
```
- `priority`: `normal` (default) or `high`
- `labs`: optional — if omitted, shows on ALL labs
- `expiresAt`: optional — auto-removes after this time

#### `DELETE /api/v1/announcements/:id`
Delete an announcement. *Role: superadmin*

---

### Wake-on-LAN

Wake powered-off lab PCs remotely using UDP magic packets. Requires MAC address in pc-registry.

#### `POST /api/v1/pcs/:hostname/wake`
Wake a single PC. *Role: superadmin*
```bash
curl -X POST -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" \
  http://localhost:8080/api/v1/pcs/DESKTOP-O8QKSH4/wake
```

#### `POST /api/v1/labs/:lab/wake-all`
Wake all PCs in a lab. *Role: superadmin*
```bash
curl -X POST -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" \
  http://localhost:8080/api/v1/labs/Lab1/wake-all
```

---

### Scheduled Shutdown

Schedule automatic shutdown for lab PCs with user warnings.

#### `GET /api/v1/schedules`
List all shutdown schedules. *Role: superadmin*

#### `POST /api/v1/labs/:lab/schedule-shutdown`
Create a scheduled shutdown. *Role: superadmin*
```bash
curl -X POST http://localhost:8080/api/v1/labs/Lab1/schedule-shutdown \
  -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" \
  -H "Content-Type: application/json" \
  -d '{"time":"17:00","days":["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday"],"warnMinutes":10}'
```
- `time`: shutdown time in HH:MM format
- `days`: array of day names
- `warnMinutes`: warn users N minutes before (default: 10)

#### `DELETE /api/v1/schedules/:id`
Remove a shutdown schedule. *Role: superadmin*

---

### Audit Log

All admin actions are logged with actor, action, target, and timestamp.

#### `GET /api/v1/audit`
View audit log with pagination. *Role: superadmin*
```bash
curl -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" \
  "http://localhost:8080/api/v1/audit?page=1&pageSize=50&action=block-website"
```

| Param | Description |
|-------|------------|
| `page` | Page number (default: 1) |
| `pageSize` | Results per page (default: 50) |
| `action` | Filter by action type |

**Example audit entry:**
```json
{
  "timestamp": "2026-06-03T14:30:00.000Z",
  "actor": "Administrator",
  "action": "block-website",
  "target": "facebook.com",
  "details": "Reason: Social media, Labs: Lab1, Lab2"
}
```

---

## Lab PC Polling System

Lab PCs can't be reached from the DC (router blocks inter-VLAN). Instead, PCs poll the API.

**EMIS Agent** (`poll-messages.ps1`):
- Deployed via GPO as a startup script (runs as SYSTEM)
- Auto-registers PC hostname, IP, and MAC address on boot
- Polls every 30 seconds for:
  - Pending messages → displayed via `msg.exe`
  - Full config via `GET /pcs/:hostname/config` (single call)
- **Website blocking**: updates Windows `hosts` file with blocked domains (→ 127.0.0.1), flushes DNS
- **App blocking**: kills processes matching blocked app names
- **Exam mode**: enables Windows Firewall rules (block all outbound, whitelist allowed IPs), kills unauthorized apps
- **Session tracking**: reports login/logout/idle/active events to `POST /sessions/report`
- **Idle detection**: uses Win32 `GetLastInputInfo` API — reports when idle >= 5 minutes
- **Announcements**: shows via `msg.exe`, tracks shown IDs to avoid repeats
- **Scheduled shutdown**: warns users N minutes before, executes `Stop-Computer` at scheduled time
- **Heartbeat**: sends active report every 5 minutes (10 poll cycles)
- **Log rotation**: keeps log file under 1MB

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
| `blocked-sites.json` | Blocked website domains |
| `blocked-apps.json` | Blocked application process names |
| `exam-mode.json` | Exam mode config per lab |
| `announcements.json` | Active announcements |
| `sessions.json` | Active/historical session data |
| `schedules.json` | Scheduled shutdown configs |
| `audit-log.json` | Admin action audit trail (max 10,000 entries) |
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

# Upload photo (PowerShell 7+)
curl.exe -X POST "http://localhost:8080/api/v1/photos/upload" `
  -H "X-API-Key: Moa6YPNPgtx9HPgueNTKCN6n1JaHJWuvoUF2BiX3cs" `
  -F "photo=@C:\path\to\photo.jpg" `
  -F "username=THA080BCT001"

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
