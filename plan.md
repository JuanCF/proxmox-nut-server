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
vm/nut-vm.sh
```

The NUT install script is embedded as a heredoc inside the main script, SCP'd to the VM, and executed via SSH.

---

## Script Sections

```
vm/nut-vm.sh
├── Section 2:  Input/prompt helper functions (whiptail)
├── Section 3:  Prerequisite checks
├── Section 4:  VM configuration prompts
├── Section 5:  NUT configuration prompts
├── Section 6:  Storage type detection
├── Section 7:  Cloud image download + SSH key + cloud-init snippet
├── Section 8:  VM creation
├── Section 9:  USB UPS detection and passthrough
├── Section 10: VM boot + SSH readiness wait
├── Section 11: NUT install heredoc + SCP + SSH execution
└── Section 12: Final summary output
```

---

## Constants

```bash
UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64.img"
UBUNTU_IMG_CHECKSUM_URL="https://cloud-images.ubuntu.com/minimal/releases/noble/release/SHA256SUMS"
UBUNTU_IMG_NAME="ubuntu-24.04-minimal-cloudimg-amd64.img"
IMG_CACHE_DIR="/var/lib/vz/template/iso"
NUT_DEFAULT_PORT=3493
SSH_TIMEOUT=300
SSH_POLL_INTERVAL=5
SCRIPT_VERSION="1.0.0"

AUTO_GENERATE_PASSWORDS=false
```

---

## Function List

### Section 2 — Prompt Helpers

| Function | Signature | Notes |
|----------|-----------|-------|
| `generate_password` | `length` | openssl rand + urandom fallback |
| `prompt_autogenerate_passwords` | — | whiptail yes/no; sets `AUTO_GENERATE_PASSWORDS` |
| `prompt_default` | `VARNAME "text" "default"` | Enter = use default |
| `prompt_password` | `VARNAME "text"` | `read -s`, confirm twice; auto-generates if enabled |
| `prompt_yes_no` | `"question" default` | Returns 0=yes 1=no |
| `prompt_menu` | `VARNAME "title" items...` | Numbered list, validated |
| `prompt_integer` | `VARNAME "text" default min max` | Range-validated number |

### Section 3 — Prerequisite Checks

| Function | What it checks |
|----------|---------------|
| `check_root` | `$EUID -eq 0` |
| `check_proxmox` | `qm`, `pvesh`, `pveversion`, `pvesm`, `python3` exist |
| `check_dependencies` | `ssh`, `scp`, `wget`/`curl`, `lsusb`, `whiptail`, `timeout`, `openssl`, `ssh-keygen`, `ip`, `sha256sum`, `dpkg` |
| `check_architecture` | `dpkg --print-architecture` is `amd64` |
| `get_next_vmid` | `pvesh get /cluster/nextid` |
| `list_storage_pools` | `pvesm status --content images` |
| `validate_vmid` | Check ID not already in use |
| `validate_bridge` | `ip link show` bridge exists |

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
| VM password | (prompted, hidden or auto-generated) |

Shows confirmation table + `prompt_yes_no` before proceeding.

### Section 5 — NUT Config Prompts (`collect_nut_config`)

Globals: `NUT_UPS_NAME`, `NUT_UPS_DESC`, `NUT_DRIVER`, `NUT_ADMIN_USER`, `NUT_ADMIN_PASS`, `NUT_MONITOR_USER`, `NUT_MONITOR_PASS`, `NUT_LISTEN_ADDR`, `NUT_LISTEN_PORT`

| Prompt | Default |
|--------|---------|
| UPS name | `ups` |
| UPS description | `My UPS` |
| Driver | `usbhid-ups` (hardcoded) |
| Admin username | `admin` |
| Admin password | (prompted, hidden or auto-generated) |
| Monitor username | `monuser` |
| Monitor password | (prompted, hidden or auto-generated) |
| Listen address | `0.0.0.0` |
| Listen port | `3493` |

### Section 6 — Storage Type Detection

| Function | Description |
|----------|-------------|
| `determine_storage_type` | Parses `pvesm status` to set `DISK_EXT`, `DISK_REF_PREFIX`, `DISK_IMPORT` based on storage backend (nfs/dir/cifs/btrfs vs lvm-thin/zfs) |

### Section 7 — Cloud Image Download + SSH Key + Cloud-Init Snippet

| Function | Description |
|----------|-------------|
| `download_cloud_image` | wget with resume; skip if cached and SHA-256 checksum verifies |
| `inject_ssh_key` | Generate temp ed25519 keypair in `/tmp/nut-setup-$$/`; register `trap EXIT` cleanup |
| `generate_cloudinit_snippet` | Creates vendor cloud-init YAML in `/var/lib/vz/snippets/` that installs `qemu-guest-agent` and sets the VM user password via `chpasswd` |

### Section 8 — VM Creation

| Function | Description |
|----------|-------------|
| `create_vm` | Full `qm create` + `importdisk` + `set` + `resize` + `setup_cloud_init` (from `cloud-init.func`) + vendor snippet sequence |

`create_vm` command sequence:
```bash
qm create $VM_ID --name $VM_NAME --memory $VM_RAM --cores $VM_CORES \
  --net0 virtio,bridge=$VM_BRIDGE --ostype l26 --agent enabled=1 \
  --serial0 socket --vga serial0 --onboot 1 --tags 'community-script;nut;network;ups'

qm importdisk $VM_ID $IMG_CACHE_DIR/$UBUNTU_IMG_NAME $VM_STORAGE --format <qcow2|raw>

qm set $VM_ID --scsihw virtio-scsi-pci --scsi0 ${DISK0_REF}
qm resize $VM_ID scsi0 ${VM_DISK_GB}G
qm set $VM_ID --boot c --bootdisk scsi0

setup_cloud_init "$VM_ID" "$VM_STORAGE" "$VM_NAME" "yes" "$VM_USER"
qm set $VM_ID --cicustom "vendor=local:snippets/nut-vm-${VM_ID}-cloudinit.yaml"
```

### Section 9 — USB Detection + Passthrough

| Function | Description |
|----------|-------------|
| `detect_ups` | Parse `lsusb`, cross-ref `UPS_VENDORS`, interactive selection; falls back to manual entry or skip |
| `setup_usb_passthrough` | `qm set $VM_ID --usb0 host=VENDOR:PRODUCT` or `host=BUS-PORT` |

### Section 10 — VM Boot + SSH Readiness Wait

| Function | Description |
|----------|-------------|
| `start_vm` | `qm start $VM_ID` |
| `get_vm_ip` | `pvesh get /nodes/{node}/qemu/{VM_ID}/agent/network-get-interfaces` with retry up to 2 min; falls back to manual entry |
| `wait_ssh` | Poll `/dev/tcp/HOST/PORT` with spinner; exit 1 on timeout |

### Section 11 — NUT Install (Remote Script)

| Function | Description |
|----------|-------------|
| `build_nut_install_script` | Base64-encode all 5 NUT config files, build heredoc, then use Python to safely substitute variables (handles special chars in passwords) |
| `deploy_nut_script` | SCP to VM with retry loop + `ssh sudo bash` execution; parses `NUT_TEST_OK` / `NUT_TEST_FAIL` |
| `run_nut_install` | Orchestrate build + deploy |
| `verify_nut_post_reboot` | SSH `upsc` retry loop after VM reboot to confirm NUT server is responding |

Remote script steps:
1. Wait for `cloud-init status --wait`
2. Wait for apt lock (up to 60s)
3. `apt-get update && apt-get install -y nut-server nut-client usbutils`
4. Poll `lsusb` for UPS vendor ID (up to 12 × 5s retries)
5. Run `nut-scanner -U` for auto-detection; if successful, write `ups.conf` with detected driver/port/vendorid/productid
6. If `nut-scanner` fails, decode and write fallback `ups.conf` from base64
7. Decode and write remaining NUT config files (`nut.conf`, `upsd.conf`, `upsd.users`, `upsmon.conf`) from base64
8. `chown root:nut /etc/nut/*.conf && chmod 640 /etc/nut/*.conf`
9. `mkdir -p /var/run/nut && chown nut:nut /var/run/nut`
10. `systemctl enable nut-driver nut-server nut-monitor && systemctl restart ...`
11. Poll `upsc $UPS_NAME@localhost` (up to 12 × 5s retries) → print `NUT_TEST_OK` or `NUT_TEST_FAIL`

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

1. Parse CLI flags (`--help`, `--version`, `--debug`)
2. Print header banner (`header_info`)
3. Source `build.func` + `cloud-init.func` from `community-scripts/ProxmoxVED` via curl
4. `check_root` → `check_proxmox` → `check_dependencies` → `check_architecture`
5. `inject_ssh_key` — generate temp keypair, register `trap EXIT` cleanup
6. `prompt_autogenerate_passwords` — optional auto-generation
7. `collect_vm_config` — interactive VM prompts + confirmation loop
8. `collect_nut_config` — interactive NUT prompts
9. Print confirmed NUT settings summary + confirmation
10. `download_cloud_image` (with SHA-256 checksum verification)
11. `create_vm` — full qm sequence + `setup_cloud_init` + vendor snippet
12. `detect_ups` → `setup_usb_passthrough` (or skip)
13. `start_vm`
14. `get_vm_ip` (guest agent with retry)
15. `wait_ssh`
16. `build_nut_install_script` + `deploy_nut_script`
17. Parse `NUT_TEST_OK` / `NUT_TEST_FAIL` from SSH output
18. Reboot VM (`qm reboot`) and wait for SSH to come back
19. `verify_nut_post_reboot` — confirm `upsc` responds
20. `print_summary`
21. `trap EXIT` fires: remove temp keys

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
| VMID claimed between detection and creation | `validate_vmid` loops until an unused ID is chosen |
| Storage type (dir vs lvm-thin vs nfs vs btrfs) affects disk name | `determine_storage_type` sets `DISK_EXT`, `DISK_REF_PREFIX`, and `DISK_IMPORT` flags before import |
| Image partial download | Use `wget -c` (resume); verify SHA-256 checksum after download |
| Cached image checksum mismatch | Re-download if `sha256sum -c` fails |
| `vmbr0` doesn't exist | Validate bridge with `ip link show` before VM creation |
| Two identical UPS models on same host | Use bus-port notation `host=4-1` instead of `vendor:product` |
| UPS not plugged in yet | Offer: manual entry or skip passthrough |
| DHCP / guest agent slow to report IP | Retry `pvesh get /nodes/.../network-get-interfaces` for up to 2 min; fallback to manual whiptail prompt |
| Cloud-init not done when SSH opens | `wait_ssh` polls until port 22 is open; remote script waits for `cloud-init status --wait` |
| Apt lock held on first boot | Remote script polls `/var/lib/dpkg/lock-frontend` up to 60s before proceeding |
| NUT driver mismatch | Remote script runs `nut-scanner -U` and overrides driver if detected; fallback to user-selected driver; post-reboot `verify_nut_post_reboot` confirms |
| Password with special chars (`$`, `` ` ``, backslash, etc.) | Base64-encode all config files in the heredoc, then decode on the VM; variable substitution done via Python `str.replace` to avoid shell escaping issues |
| Script interrupted mid-run | `trap INT TERM` kills spinner and prints interrupt message; `trap EXIT` cleans up temp SSH keys |
| Running on Proxmox cluster | Note: VM created on local node only |
| Non-amd64 architecture | `check_architecture` aborts with warning (Ubuntu cloud image is amd64-only) |
| Auto-generated passwords | `generate_password` uses openssl rand with fallback to `/dev/urandom`; passwords displayed in final summary whiptail + console output |

---

## Verification

1. Run on Proxmox host: `bash vm/nut-vm.sh`
2. Walk through all prompts — confirm defaults work (just press Enter)
3. Verify VM created: `qm list`
4. Verify USB passthrough: `qm config <vmid> | grep usb`
5. Run test command from summary: `upsc ups@<VM_IP>`
6. From another machine: `upsc ups@<VM_IP>:3493` — confirms netserver is accessible
7. Check services inside VM: `ssh ubuntu@<VM_IP> systemctl status nut-driver nut-server nut-monitor`
