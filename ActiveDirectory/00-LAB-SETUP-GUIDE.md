# Active Directory Lab Setup â€” Complete Guide (From Zero)

> **Goal:** Set up a Windows Server Domain Controller with 2000 users and RBAC  
> **Domain:** emis.local  
> **Environment:** VMware ESXi â†’ Windows Server 2019 VM

---

## Part 1: Hardware Requirements

### Minimum Hardware for ESXi Host

| Component    | Minimum          | Recommended         |
|-------------|------------------|---------------------|
| CPU         | 64-bit, 2 cores  | 4+ cores (Intel VT-x/AMD-V **must** be enabled in BIOS) |
| RAM         | 8 GB             | 16 GB or more       |
| Storage     | 100 GB           | 256 GB+ (SSD preferred) |
| NIC         | 1 Gigabit NIC    | 1 Gigabit NIC (Intel NICs have best ESXi support) |
| USB         | 8 GB USB drive   | For ESXi installer boot |

### VM Sizing for Windows Server (Domain Controller)

| Resource     | Value           |
|-------------|-----------------|
| vCPUs       | 2               |
| RAM         | 4 GB (8 GB if handling 2000 users actively) |
| Disk        | 60 GB thin provisioned |
| Network     | 1 vNIC (VM Network) |
| Guest OS    | Windows Server 2019 Standard |

---

## Part 2: Download Everything First

### 1. Download VMware ESXi

- Go to: https://www.vmware.com/products/vsphere/esxi-and-vcenter.html
- **Free version:** VMware vSphere Hypervisor (ESXi) â€” free license
- Or use **Broadcom** portal (VMware is now Broadcom):
  - https://support.broadcom.com/
  - Create account â†’ Downloads â†’ VMware vSphere Hypervisor
- Download the **ESXi ISO** (VMware-VMvisor-Installer-8.x.x.iso)

### 2. Download Windows Server 2019

- **Evaluation (free 180 days):**
  - https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2019
  - Choose **ISO** download â†’ 64-bit edition
  - ~5.5 GB file

### 3. Download Rufus (to make bootable USB)

- https://rufus.ie/
- Portable version is fine

---

## Part 3: Install VMware ESXi on Physical Server

### Step 1: Create Bootable USB

1. Insert **8 GB+ USB drive** into your PC
2. Open **Rufus**
3. Select the USB drive
4. Click **SELECT** â†’ choose the ESXi ISO
5. Partition scheme: **GPT**
6. Target system: **UEFI**
7. Click **START** â†’ wait for completion

### Step 2: Enable Virtualization in BIOS

1. Restart the server/PC where you'll install ESXi
2. Enter BIOS (press **F2**, **DEL**, or **F10** during boot â€” depends on hardware)
3. Find **CPU Configuration** or **Advanced Settings**
4. Enable:
   - **Intel VT-x** (Intel) or **AMD-V / SVM Mode** (AMD)
   - **Intel VT-d** (if available)
5. Save and exit BIOS

### Step 3: Boot from USB and Install ESXi

1. Insert the bootable USB
2. Boot from USB (press **F12** or **F11** for boot menu)
3. ESXi installer loads â†’ Press **Enter** to continue

```
â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚  VMware ESXi 8.0 Installation        â”‚
â”‚                                      â”‚
â”‚  Press Enter to continue             â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
```

4. Press **F11** to accept the license
5. Select the **disk** where ESXi will be installed (your server's internal disk, NOT the USB)
6. Choose keyboard layout â†’ **US Default**
7. Set a **root password** (remember this!)
8. Press **F11** to confirm and install
9. Remove USB â†’ Reboot

### Step 4: Configure ESXi Network

After reboot, ESXi shows a yellow/gray screen (DCUI):

```
â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚  VMware ESXi 8.0.0                          â”‚
â”‚                                             â”‚
â”‚  Download tools: https://192.168.x.x        â”‚
â”‚                                             â”‚
â”‚  To manage: https://192.168.x.x/ui          â”‚
â”‚                                             â”‚
â”‚  F2: Customize System/View Logs             â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
```

1. Press **F2** â†’ enter root password
2. Go to **Configure Management Network**
3. Select **IPv4 Configuration**
4. Change to **Set static IPv4 address**:
   ```
   IP Address:     192.168.1.100    (or your lab network)
   Subnet Mask:    255.255.255.0
   Default Gateway: 192.168.1.1
   ```
5. Go to **DNS Configuration**:
   ```
   Primary DNS:    8.8.8.8
   Hostname:       esxi01
   ```
6. Press **Esc** â†’ **Y** to apply and restart management network

### Step 5: Access ESXi Web UI

1. On another computer on the same network, open browser
2. Go to: **https://192.168.1.100/ui** (your ESXi IP)
3. Accept the SSL warning
4. Login: **root** / (your password)

You're now in the **ESXi Host Client** web interface!

---

## Part 4: Upload Windows Server ISO to ESXi

### Step 1: Create a Datastore (if needed)

- In ESXi web UI â†’ **Storage** â†’ **Datastores**
- You should see **datastore1** (auto-created during install)
- If not, click **New datastore** â†’ VMFS â†’ select disk â†’ finish

### Step 2: Upload the ISO

1. Go to **Storage** â†’ **Datastore browser**
2. Click **Create directory** â†’ name it `ISOs`
3. Click **Upload** â†’ select your **Windows Server 2019 ISO**
4. Wait for upload to complete (5.5 GB)

---

## Part 5: Create Windows Server VM

### Step 1: Create New Virtual Machine

1. In ESXi web UI â†’ **Virtual Machines** â†’ **Create / Register VM**
2. Select **Create a new virtual machine** â†’ Next

### Step 2: Name and Guest OS

```
Name:              WinServer-DC
Compatibility:     ESXi 8.0 (or your version)
Guest OS family:   Windows
Guest OS version:  Microsoft Windows Server 2019 (64-bit)
```

### Step 3: Select Storage

- Choose **datastore1** â†’ Next

### Step 4: Customize Settings

| Setting              | Value                          |
|---------------------|--------------------------------|
| CPU                 | **2**                          |
| Memory              | **4096 MB** (4 GB)             |
| Hard disk 1         | **60 GB** (Thin Provisioned)   |
| Network Adapter 1   | VM Network, Adapter: **VMXNET3** |
| CD/DVD Drive 1      | **Datastore ISO file** â†’ browse to your Windows Server ISO |

**IMPORTANT:** Check the box **"Connect at power on"** for the CD/DVD drive!

### Step 5: Click Finish â†’ VM is Created

---

## Part 6: Install Windows Server 2019

### Step 1: Power On the VM

1. **Virtual Machines** â†’ select **WinServer-DC** â†’ **Power on**
2. Click the **VM console thumbnail** (or click **Console** â†’ **Open browser console**)

### Step 2: Boot from ISO

- VM boots from the CD/DVD drive automatically
- If it says "Press any key to boot from CD/DVD" â†’ press a key quickly!

### Step 3: Windows Setup

```
Language:              English (United States)
Time and currency:     your preference
Keyboard:              US
```
Click **Next** â†’ **Install now**

### Step 4: Select Edition

```
Windows Server 2019 Standard (Desktop Experience)   â† SELECT THIS ONE
```

> **Desktop Experience** = has GUI. Do NOT pick "Server Core" unless you're comfortable with command-line only.

### Step 5: License Terms

- Accept â†’ Next

### Step 6: Installation Type

- Select **Custom: Install Windows only (advanced)**

### Step 7: Select Disk

- Select **Drive 0 Unallocated Space** (60 GB)
- Click **Next**
- Wait for installation (10-20 minutes)
- VM reboots automatically

### Step 8: Set Administrator Password

After reboot:
```
Username:  Administrator
Password:  (set a strong password, e.g., P@ssw0rd2024!)
```

> Remember this password! You need it for everything.

### Step 9: Login

Press **Ctrl+Alt+Delete** (in VM console: use the **Send Ctrl+Alt+Del** button in toolbar)

---

## Part 7: Configure Windows Server Networking

### Step 1: Set Static IP

1. Right-click **Network icon** in taskbar â†’ **Open Network & Internet settings**
2. Click **Change adapter options** (or **Ethernet** â†’ **Change adapter options**)
3. Right-click **Ethernet0** â†’ **Properties**
4. Select **Internet Protocol Version 4 (TCP/IPv4)** â†’ **Properties**

```
IP address:         192.168.1.10
Subnet mask:        255.255.255.0
Default gateway:    192.168.1.1
Preferred DNS:      127.0.0.1       â† points to itself (will be DNS server)
Alternate DNS:      8.8.8.8
```

Click **OK** â†’ **Close**

### Step 2: Set Computer Name

1. Open **PowerShell as Administrator**
2. Run:

```powershell
Rename-Computer -NewName "DC01" -Restart
```

Server reboots. Login again after reboot.

### Step 3: Verify Networking

```powershell
# Check IP
ipconfig /all

# Test internet
ping 8.8.8.8

# Check hostname
hostname
```

---

## Part 8: Install Active Directory (Run the Scripts!)

### Step 1: Copy Scripts to the Server

**Option A â€” USB/Shared folder:**
- Copy the `ActiveDirectory` folder to `C:\Scripts\` on the server

**Option B â€” Download from GitHub (if server has internet):**
Open PowerShell as Administrator:

```powershell
# Allow script execution
Set-ExecutionPolicy RemoteSigned -Force

# Create scripts folder
New-Item -Path "C:\Scripts" -ItemType Directory -Force

# Download from GitHub (replace with your repo URL)
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/sumanmhz/sumanmhz/main/ActiveDirectory/01-Install-AD-DS.ps1" -OutFile "C:\Scripts\01-Install-AD-DS.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/sumanmhz/sumanmhz/main/ActiveDirectory/02-Create-RBAC-Structure.ps1" -OutFile "C:\Scripts\02-Create-RBAC-Structure.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/sumanmhz/sumanmhz/main/ActiveDirectory/03-Bulk-Create-Users.ps1" -OutFile "C:\Scripts\03-Bulk-Create-Users.ps1"
```

### Step 2: Run Script 1 â€” Install AD DS

```powershell
cd C:\Scripts
.\01-Install-AD-DS.ps1
```

What happens:
- Installs AD-DS, DNS, and GPMC roles
- Promotes server to Domain Controller for **emis.local**
- **Server reboots automatically** (wait 2-3 minutes)

### Step 3: Login After Reboot

After reboot, the login screen now shows:

```
EMIS\Administrator
```

Login with your Administrator password.

### Step 4: Run Script 2 â€” Create RBAC Structure

```powershell
cd C:\Scripts
.\02-Create-RBAC-Structure.ps1
```

What happens:
- Creates all OUs (departments, student batches, faculty programs)
- Creates 3 Role groups + 11 Resource groups
- Maps roles to resources (RBAC)
- Creates and links 4 GPOs
- Sets password policy

### Step 5: Run Script 3 â€” Create 2000 Users

```powershell
cd C:\Scripts
.\03-Bulk-Create-Users.ps1 -GenerateSample
```

- Enter a default password when prompted (e.g., `Welcome@123`)
- Generates 2000 users (1400 students + 600 staff)
- Creates all accounts and assigns RBAC roles
- Takes about 5-10 minutes

---

## Part 9: Verify Everything Works

### Check Users Were Created

```powershell
# Total users
Get-ADUser -Filter * | Measure-Object

# Users in Students OU
Get-ADUser -Filter * -SearchBase "OU=Students,OU=EMIS Users,DC=emis,DC=local" | Measure-Object

# List first 10 users
Get-ADUser -Filter * -SearchBase "OU=EMIS Users,DC=emis,DC=local" -Properties Department |
    Select-Object -First 10 Name, SamAccountName, Department |
    Format-Table -AutoSize
```

### Check Groups

```powershell
# List all role groups
Get-ADGroup -Filter 'Name -like "Role-*"' | Select Name

# Check members of a role
Get-ADGroupMember "Role-Students" | Measure-Object
Get-ADGroupMember "Role-Faculty" | Measure-Object
```

### Check OUs

```powershell
Get-ADOrganizationalUnit -Filter * | Select Name, DistinguishedName | Format-Table -AutoSize
```

### Open Active Directory Users and Computers (GUI)

```powershell
dsa.msc
```

This opens the GUI tool where you can browse the OU tree and see all users.

---

## Part 10: Join a Client PC to the Domain (Optional)

If you want to test with a Windows 10/11 client VM:

### Step 1: Create Another VM in ESXi

| Setting    | Value                    |
|-----------|--------------------------|
| Name      | Client-PC01              |
| OS        | Windows 10/11 64-bit     |
| CPU       | 2                        |
| RAM       | 2048 MB                  |
| Disk      | 40 GB                    |

Install Windows 10/11 on this VM.

### Step 2: Configure Client Networking

Set the DNS server to point to your Domain Controller:

```
IP:          192.168.1.20
Subnet:      255.255.255.0
Gateway:     192.168.1.1
DNS:         192.168.1.10    â† DC's IP address!
```

### Step 3: Join Domain

```powershell
Add-Computer -DomainName "emis.local" -Restart
```

Enter domain admin credentials when prompted. PC reboots.

### Step 4: Login as a Domain User

On the login screen, click **Other user** and enter:
```
Username: EMIS\suman.sharma    (or any created user)
Password: Welcome@123           (default password)
```

It will force a password change on first login.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| ESXi installer doesn't detect NIC | Download the ESXi customized ISO with your NIC drivers from VMware Flings |
| VM can't boot from ISO | Check CD/DVD drive is connected and "Connect at power on" is checked |
| Can't access ESXi web UI | Verify you're on the same network, try `ping 192.168.1.100` |
| Script says "not recognized" | Run `Set-ExecutionPolicy RemoteSigned -Force` first |
| AD DS promotion fails | Make sure static IP and DNS (127.0.0.1) are set, and server can ping the gateway |
| Users can't login from client | Client's DNS MUST point to the DC's IP (192.168.1.10), not 8.8.8.8 |
| "Access Denied" running scripts | Right-click PowerShell â†’ "Run as Administrator" |
| DVMT not enough / VM won't start | Reduce video memory in VM settings to 8 MB |

---

## Network Diagram

```
â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚                   Physical Server                    â”‚
â”‚                   (ESXi Host)                        â”‚
â”‚                  192.168.1.100                       â”‚
â”‚                                                     â”‚
â”‚  â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”    â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”       â”‚
â”‚  â”‚  WinServer-DC    â”‚    â”‚  Client-PC01     â”‚       â”‚
â”‚  â”‚  192.168.1.10    â”‚    â”‚  192.168.1.20    â”‚       â”‚
â”‚  â”‚                  â”‚    â”‚                  â”‚       â”‚
â”‚  â”‚  AD DS + DNS     â”‚    â”‚  Windows 10/11   â”‚       â”‚
â”‚  â”‚  tcioe.edu.np    â”‚    â”‚  Joined to       â”‚       â”‚
â”‚  â”‚  Domain Controllerâ”‚   â”‚  tcioe.edu.np    â”‚       â”‚
â”‚  â”‚  2000 Users      â”‚    â”‚                  â”‚       â”‚
â”‚  â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜    â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜       â”‚
â”‚                                                     â”‚
â”‚              VM Network (vSwitch0)                   â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
                     â”‚
              â”Œâ”€â”€â”€â”€â”€â”€â”´â”€â”€â”€â”€â”€â”€â”
              â”‚   Router    â”‚
              â”‚ 192.168.1.1 â”‚
              â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
```

---

## Execution Order Summary

```
1. Install ESXi on physical server
2. Access ESXi web UI (https://192.168.1.100/ui)
3. Upload Windows Server 2019 ISO
4. Create VM â†’ Install Windows Server 2019
5. Set static IP (192.168.1.10) and hostname (DC01)
6. Run 01-Install-AD-DS.ps1        â†’ server reboots
7. Run 02-Create-RBAC-Structure.ps1 â†’ OUs, groups, GPOs
8. Run 03-Bulk-Create-Users.ps1 -GenerateSample â†’ 2000 users
9. Verify with dsa.msc (GUI) or PowerShell queries
10. (Optional) Join a client PC to the domain and test login
```
