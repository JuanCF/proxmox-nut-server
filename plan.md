# Plan: Proxmox NUT Server VM Setup Script

## Context

Single bash script that creates an Ubuntu 24.04 VM on Proxmox, detects the USB UPS device, sets up USB passthrough, then installs and configures NUT (Network UPS Tools) in `netserver` mode inside the VM.

NUT cannot run reliably in LXC containers due to kernel driver detachment restrictions — a VM is required.

**Confirmed specs:**
- OS: Ubuntu 24.04 (Noble) cloud image
- NUT mode: `netserver`
- UPS connection: USB
- VM provisioning: cloud-init (automated)
- VM defaults: fixed but user can override interactively

---

## File Structure

Single deliverable:

```
nut-vm-setup.sh
```

The NUT install script is embedded as a heredoc inside the main script, SCP'd to the VM, and executed via SSH.

---

## Script Sections

```
nut-vm-setup.sh
├── Section 0:  Shebang, strict mode, constants
├── Section 1:  UI/output helper functions
├── Section 2:  Input/prompt helper functions
├── Section 3:  Prerequisite checks
├── Section 4:  VM configuration prompts
├── Section 5:  NUT configuration prompts
├── Section 6:  Cloud image download + VM creation
├── Section 7:  USB UPS detection and passthrough
├── Section 8:  VM boot + SSH readiness wait
├── Section 9:  NUT install heredoc + SCP + SSH execution
└── Section 10: Final summary output
```

---

## Constants

```bash
UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
UBUNTU_IMG_NAME="noble-server-cloudimg-amd64.img"
IMG_CACHE_DIR="/var/lib/vz/template/iso"
NUT_DEFAULT_PORT=3493
SSH_TIMEOUT=180
SSH_POLL_INTERVAL=5

declare -A UPS_VENDORS=(
  ["051d"]="APC"
  ["0764"]="CyberPower"
  ["0463"]="Eaton"
  ["09ae"]="Tripp Lite"
  ["10af"]="Liebert"
)
```

---

## Function List

### Section 1 — UI Helpers

| Function | Description |
|----------|-------------|
| `msg_info` | Cyan `[INFO]` prefix |
| `msg_ok` | Green `[OK]` prefix |
| `msg_error` | Red `[ERROR]` + exit 1 |
| `msg_warn` | Yellow `[WARN]` non-fatal |
| `msg_header` | Full-width box title banner |
| `spinner_start` / `spinner_stop` | Background spinner during long ops |

### Section 2 — Prompt Helpers

| Function | Signature | Notes |
|----------|-----------|-------|
| `prompt_default` | `VARNAME "text" "default"` | Enter = use default |
| `prompt_password` | `VARNAME "text"` | `read -s`, confirm twice |
| `prompt_yes_no` | `"question" default` | Returns 0=yes 1=no |
| `prompt_menu` | `VARNAME "title" items...` | Numbered list, validated |
| `prompt_integer` | `VARNAME "text" default min max` | Range-validated number |

### Section 3 — Prerequisite Checks

| Function | What it checks |
|----------|---------------|
| `check_root` | `$EUID -eq 0` |
| `check_proxmox` | `qm`, `pvesh`, `pveversion` exist |
| `check_dependencies` | `ssh`, `scp`, `wget`/`curl`, `lsusb` |
| `get_next_vmid` | `pvesh get /cluster/nextid` |
| `list_storage_pools` | `pvesm status --content images` |
| `validate_vmid` | Check ID not already in use |

### Section 4 — VM Config Prompts (`collect_vm_config`)

Globals: `VM_ID`, `VM_NAME`, `VM_STORAGE`, `VM_BRIDGE`, `VM_RAM`, `VM_CORES`, `VM_DISK_GB`, `VM_USER`, `VM_PASSWORD`

| Prompt | Default |
|--------|---------|
| VM ID | next available |
| VM hostname | `nut-server` |
| Storage pool | first available |
| Network bridge | `vmbr0` |
| RAM (MB) | `1024` |
| CPU cores | `1` |
| Disk size (GB) | `8` |
| VM username | `ubuntu` |
| VM password | (prompted, hidden) |

Shows confirmation table + `prompt_yes_no` before proceeding.

### Section 5 — NUT Config Prompts (`collect_nut_config`)

Globals: `NUT_UPS_NAME`, `NUT_UPS_DESC`, `NUT_DRIVER`, `NUT_ADMIN_USER`, `NUT_ADMIN_PASS`, `NUT_MONITOR_USER`, `NUT_MONITOR_PASS`, `NUT_LISTEN_ADDR`, `NUT_LISTEN_PORT`

| Prompt | Default |
|--------|---------|
| UPS name | `ups` |
| UPS description | `My UPS` |
| Driver (menu) | `usbhid-ups` |
| Admin username | `admin` |
| Admin password | (prompted, hidden) |
| Monitor username | `monuser` |
| Monitor password | (prompted, hidden) |
| Listen address | `0.0.0.0` |
| Listen port | `3493` |

Driver menu:
1. `usbhid-ups` — APC, Eaton, CyberPower (recommended)
2. `blazer_usb` — Generic Megatec/Q1 protocol
3. `nutdrv_qx` — Newer generic USB devices

### Section 6 — Cloud Image + VM Creation

| Function | Description |
|----------|-------------|
| `download_cloud_image` | wget/curl with resume; skip if cached |
| `inject_ssh_key` | Generate temp ed25519 keypair in `/tmp/`; register `trap EXIT` cleanup |
| `create_vm` | Full `qm create` + `importdisk` + `set` + `resize` + cloudinit sequence |

`create_vm` command sequence:
```bash
qm create $VM_ID --name $VM_NAME --memory $VM_RAM --cores $VM_CORES \
  --net0 virtio,bridge=$VM_BRIDGE --ostype l26 --agent enabled=1 \
  --serial0 socket --vga serial0

qm importdisk $VM_ID $IMG_CACHE_DIR/$UBUNTU_IMG_NAME $VM_STORAGE

qm set $VM_ID --scsihw virtio-scsi-pci --scsi0 $VM_STORAGE:vm-$VM_ID-disk-0
qm resize $VM_ID scsi0 ${VM_DISK_GB}G
qm set $VM_ID --ide2 $VM_STORAGE:cloudinit --boot c --bootdisk scsi0
qm set $VM_ID --ipconfig0 ip=dhcp --ciuser $VM_USER \
  --cipassword $VM_PASSWORD --sshkeys /tmp/nut-setup-key.pub
```

### Section 7 — USB Detection + Passthrough

| Function | Description |
|----------|-------------|
| `detect_ups` | Parse `lsusb`, cross-ref `UPS_VENDORS`, interactive selection |
| `setup_usb_passthrough` | `qm set $VM_ID --usb0 host=VENDOR:PRODUCT` |

Fallback paths:
- 0 matches → warn + offer manual `VENDOR:PRODUCT` entry or skip
- 1 match → confirm and auto-select
- Multiple matches → `prompt_menu`
- Duplicate `VENDOR:PRODUCT` → use bus-port notation `host=4-1` to disambiguate

### Section 8 — VM Boot + SSH Wait

| Function | Description |
|----------|-------------|
| `start_vm` | `qm start $VM_ID` |
| `wait_ssh HOST PORT TIMEOUT` | Poll `nc -z` with spinner; exit 1 on timeout |
| `get_vm_ip` | `qm guest exec` with retry up to 2 min; fall back to manual entry |

SSH options used throughout: `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`

### Section 9 — NUT Install (Remote Script)

| Function | Description |
|----------|-------------|
| `build_nut_install_script` | Expand NUT vars into heredoc, store in variable |
| `deploy_nut_script` | SCP to VM + `ssh sudo bash` execution |
| `run_nut_install` | Orchestrate build + deploy with spinner |

Remote script steps:
1. `apt-get update && apt-get install -y nut-server nut-client usbutils`
2. Poll `lsusb` for UPS vendor ID (up to 12 × 5s retries)
3. Write all 5 NUT config files
4. `chown root:nut /etc/nut/*.conf && chmod 640 /etc/nut/*.conf`
5. `mkdir -p /var/run/nut && chown nut:nut /var/run/nut`
6. `systemctl enable nut-server nut-monitor && systemctl restart nut-server nut-monitor`
7. `sleep 5 && upsc $UPS_NAME@localhost` → print `NUT_TEST_OK` or `NUT_TEST_FAIL`

---

## NUT Config File Templates

### `/etc/nut/nut.conf`
```
MODE=netserver
```

### `/etc/nut/ups.conf`
```
[$NUT_UPS_NAME]
  driver = $NUT_DRIVER
  port = auto
  desc = "$NUT_UPS_DESC"
  pollinterval = 2
```

### `/etc/nut/upsd.conf`
```
LISTEN $NUT_LISTEN_ADDR $NUT_LISTEN_PORT
MAXAGE 15
STATEPATH /var/run/nut
```

### `/etc/nut/upsd.users`
```
[$NUT_ADMIN_USER]
  password = $NUT_ADMIN_PASS
  actions = SET
  instcmds = ALL

[$NUT_MONITOR_USER]
  password = $NUT_MONITOR_PASS
  upsmon master
```
> **Permissions required:** `chmod 640`, `chown root:nut` — NUT refuses to start otherwise.

### `/etc/nut/upsmon.conf`
```
MONITOR $NUT_UPS_NAME@localhost:$NUT_LISTEN_PORT 1 $NUT_MONITOR_USER $NUT_MONITOR_PASS master

MINSUPPLIES 1
SHUTDOWNCMD "/sbin/shutdown -h +0"
POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 15
POWERDOWNFLAG /etc/killpower

NOTIFYMSG ONLINE    "UPS %s on line power"
NOTIFYMSG ONBATT    "UPS %s on battery"
NOTIFYMSG LOWBATT   "UPS %s battery is low"
NOTIFYMSG COMMOK    "Communications with UPS %s established"
NOTIFYMSG COMMBAD   "Communications with UPS %s lost"
NOTIFYMSG SHUTDOWN  "UPS %s forcing system shutdown"

NOTIFYFLAG ONLINE   SYSLOG+WALL
NOTIFYFLAG ONBATT   SYSLOG+WALL
NOTIFYFLAG LOWBATT  SYSLOG+WALL
RBWARNTIME 43200
NOCOMMWARNTIME 300
FINALDELAY 5
```

---

## Order of Operations

1. Parse CLI flags (`--help`, `--version`, `--dry-run`)
2. Print header banner
3. `check_root` → `check_proxmox` → `check_dependencies`
4. `get_next_vmid` + `list_storage_pools`
5. `inject_ssh_key` — generate temp keypair, register `trap EXIT` cleanup
6. `collect_vm_config` — interactive VM prompts + confirmation loop
7. `collect_nut_config` — interactive NUT prompts
8. Print confirmed settings summary
9. `download_cloud_image` (with cache check)
10. `create_vm` — full qm sequence
11. `detect_ups` → `setup_usb_passthrough` (or skip)
12. `start_vm`
13. `wait_ssh` (with spinner)
14. `get_vm_ip` (guest agent with retry)
15. `build_nut_install_script` + `deploy_nut_script`
16. Parse `NUT_TEST_OK` / `NUT_TEST_FAIL` from SSH output
17. `print_summary`
18. `trap EXIT` fires: remove temp keys + install script

---

## Final Summary Output Format

```
╔═══════════════════════════════════════════════════════════╗
║              NUT VM Setup - Complete!                     ║
╠═══════════════════════════════════════════════════════════╣
║  VM ID:          100                                      ║
║  VM Name:        nut-server                               ║
║  VM IP:          192.168.1.50                             ║
║                                                           ║
║  NUT Server:     192.168.1.50:3493                        ║
║  UPS Name:       ups                                      ║
║                                                           ║
║  Test command:                                            ║
║    upsc ups@192.168.1.50                                  ║
╠═══════════════════════════════════════════════════════════╣
║  Client upsmon.conf snippet:                              ║
║  MONITOR ups@192.168.1.50:3493 1 monuser PASS slave       ║
╚═══════════════════════════════════════════════════════════╝
```

---

## Key Edge Cases

| Scenario | Handling |
|----------|----------|
| VMID claimed between detection and creation | Catch `qm create` exit, prompt for new ID |
| Storage type (dir vs lvm-thin) affects disk name | Parse `qm config` after import to get actual disk identifier |
| Image partial download | Use `wget -c` (resume) or check size vs Content-Length |
| `vmbr0` doesn't exist | Validate bridge with `ip link show` before VM creation |
| Two identical UPS models on same host | Use bus-port notation `host=4-1` instead of `vendor:product` |
| UPS not plugged in yet | Offer: re-scan / manual entry / skip passthrough |
| DHCP slow to assign IP | Retry `qm guest exec` for up to 2 min before fallback to manual |
| Cloud-init not done when SSH opens | 10s extra wait after SSH ready; retry SCP loop |
| NUT driver mismatch | Print `upsc` output regardless; include driver change instructions in summary |
| Password with special chars (`$`, `` ` ``) | Export vars at top of remote script; use single-quoted heredoc delimiters for config file writes |
| Script interrupted mid-run | `trap ERR` → prompt to `qm destroy $VM_ID --purge` if `VM_CREATED=true` |
| Running on Proxmox cluster | Note: VM created on local node only |

---

## Verification

1. Run on Proxmox host: `bash nut-vm-setup.sh`
2. Walk through all prompts — confirm defaults work (just press Enter)
3. Verify VM created: `qm list`
4. Verify USB passthrough: `qm config <vmid> | grep usb`
5. Run test command from summary: `upsc ups@<VM_IP>`
6. From another machine: `upsc ups@<VM_IP>:3493` — confirms netserver is accessible
7. Check services inside VM: `ssh ubuntu@<VM_IP> systemctl status nut-server nut-monitor`
