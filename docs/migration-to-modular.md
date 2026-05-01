# Migration to Modular Structure

## Overview

This document outlines the migration plan from the current monolithic `nut-vm-setup.sh` (1,128 lines) to a modular, maintainable structure similar to the community-scripts ProxmoxVE project.

---

## Current State

### File Structure
```
nut-vm-setup/
├── nut-vm-setup.sh          # 1,128 lines - everything in one file
├── plan.md                  # Specification document
└── AGENTS.md                # Agent notes
```

### Problems with Current Structure

1. **Single File Bloat**: All functionality in 1,128 lines
2. **No Code Reuse**: Every function is embedded; can't be reused
3. **Hard to Test**: Can't test individual components in isolation
4. **Difficult to Navigate**: Finding specific functionality requires scrolling
5. **NUT Install Script as Heredoc**: 120 lines of shell embedded in a string (lines 776-898)
6. **Update Pain**: Any change requires editing the entire monolith

---

## Target State

### File Structure
```
nut-vm-setup/
├── nut-vm-setup.sh          # ~150 lines - main entry point
├── lib/
│   ├── build.func           # Core build functions (sourced)
│   ├── ui.sh                # UI helpers (colors, messages, spinners)
│   ├── prompts.sh           # Input prompts (password, yes/no, menus)
│   ├── proxmox.sh           # Proxmox-specific (VM creation, storage)
│   ├── ssh.sh               # SSH key management and remote execution
│   └── nut-config.sh        # NUT-specific configuration helpers
├── templates/
│   └── nut-install.sh       # NUT installation script template
├── config/
│   └── defaults.conf        # Default values and constants
├── json/
│   └── nut.json             # Application metadata for frontend integration
├── plan.md                  # Specification document
└── AGENTS.md                # Agent notes
```

---

## Detailed Migration Steps

### Phase 1: Create Core Library Structure

#### Step 1.1: Create `lib/build.func` (Core Framework)
**Source**: Lines from `nut-vm-setup.sh` - UI helpers, error handling, core flow

```bash
#!/usr/bin/env bash
# build.func - Core build functions for nut-vm-setup
# Adapted from community-scripts/ProxmoxVE pattern

set -euo pipefail

# Color definitions (from lines 54-59)
readonly C_INFO='\033[0;36m'
readonly C_OK='\033[0;32m'
readonly C_WARN='\033[0;33m'
readonly C_ERROR='\033[0;31m'
readonly C_RESET='\033[0m'
readonly C_BOLD='\033[1m'

# Message functions (lines 65-91)
msg_info() { echo -e "${C_INFO}[INFO]${C_RESET} $1"; }
msg_ok() { echo -e "${C_OK}[OK]${C_RESET} $1"; }
msg_error() { echo -e "${C_ERROR}[ERROR]${C_RESET} $1" >&2; exit 1; }
msg_warn() { echo -e "${C_WARN}[WARN]${C_RESET} $1"; }

# Error handling
catch_errors() { set -euo pipefail; trap 'msg_error "Error on line $LINENO"' ERR; }

# Core build functions
start() { header_info "$APP"; variables; color; catch_errors; }
build_container() { 
    # VM creation logic here
    download_cloud_image
    inject_ssh_key
    create_vm
    detect_ups
    setup_usb_passthrough
    start_vm
    get_vm_ip
    wait_ssh "$VM_IP" 22
    run_nut_install
}

description() { print_summary; }

# Variables function - sets defaults from config
variables() {
    local var_tags="${var_tags:-network;ups}"
    local var_cpu="${var_cpu:-1}"
    local var_ram="${var_ram:-1024}"
    local var_disk="${var_disk:-8}"
    local var_os="${var_os:-ubuntu}"
    local var_version="${var_version:-24.04}"
}

# Header display
header_info() {
    local title="$1 Setup"
    local width=60
    echo
    echo -e "${C_BOLD}╔$(printf '═%.0s' $(seq 1 $width))╗${C_RESET}"
    printf "${C_BOLD}║%$(( (width - ${#title}) / 2 ))s %s %$(( (width - ${#title}) / 2 ))s║${C_RESET}\n" "" "$title" ""
    echo -e "${C_BOLD}╚$(printf '═%.0s' $(seq 1 $width))╝${C_RESET}"
    echo
}

# Spinner functions (lines 93-118)
spinner_chars=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
SPINNER_PID=""
SPINNER_MSG=""

_spinner_task() {
    local i=0
    while true; do
        printf "\r${C_INFO}%s${C_RESET} %s" "${spinner_chars[$((i % 10))]}" "$SPINNER_MSG"
        i=$((i + 1))
        sleep 0.1
    done
}

spinner_start() {
    SPINNER_MSG="$1"
    _spinner_task &
    SPINNER_PID=$!
    disown $SPINNER_PID
}

spinner_stop() {
    if [[ -n "$SPINNER_PID" ]] && kill -0 $SPINNER_PID 2>/dev/null; then
        kill $SPINNER_PID 2>/dev/null
        wait $SPINNER_PID 2>/dev/null
        echo -e "\r\033[K"
    fi
    SPINNER_PID=""
}
```

#### Step 1.2: Create `lib/prompts.sh`
**Source**: Lines 124-248 from `nut-vm-setup.sh`

```bash
#!/usr/bin/env bash
# prompts.sh - Interactive user prompts

# Password generation
AUTO_GENERATE_PASSWORDS=false
GENERATED_PASSWORDS=()

generate_password() {
    local length="${1:-16}"
    local password
    password=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9!@#$%^&*' | head -c "$length")
    if [[ ${#password} -lt $length ]]; then
        password=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w "$length" | head -n 1)
    fi
    echo "$password"
}

prompt_autogenerate_passwords() {
    echo -e "\n${C_BOLD}Password Configuration:${C_RESET}"
    echo "  1. Enter passwords manually (default)"
    echo "  2. Auto-generate secure passwords"
    echo
    if prompt_yes_no "Auto-generate all passwords?" "n"; then
        AUTO_GENERATE_PASSWORDS=true
        msg_ok "Passwords will be auto-generated and shown at the end"
    fi
}

prompt_default() {
    local varname="$1"
    local prompt_text="$2"
    local default_value="$3"
    local input
    read -rp "${prompt_text} [${default_value}]: " input
    printf -v "$varname" '%s' "${input:-$default_value}"
}

prompt_password() {
    local varname="$1"
    local prompt_text="$2"
    local pass1 pass2

    if [[ "$AUTO_GENERATE_PASSWORDS" == "true" ]]; then
        pass1=$(generate_password 16)
        printf -v "$varname" '%s' "$pass1"
        GENERATED_PASSWORDS+=("$prompt_text: $pass1")
        return 0
    fi

    while true; do
        read -rsp "${prompt_text}: " pass1
        echo
        read -rsp "Confirm password: " pass2
        echo
        [[ "$pass1" == "$pass2" ]] && { printf -v "$varname" '%s' "$pass1"; return 0; }
        msg_warn "Passwords do not match. Please try again."
    done
}

prompt_yes_no() {
    local question="$1"
    local default="${2:-y}"
    local yn
    if [[ "$default" == "y" ]]; then
        read -rp "${question} [Y/n]: " yn
        yn="${yn:-Y}"
    else
        read -rp "${question} [y/N]: " yn
        yn="${yn:-N}"
    fi
    [[ "$yn" =~ ^[Yy]$ ]]
}

prompt_menu() {
    local varname="$1"
    local title="$2"
    shift 2
    local items=("$@")
    local choice
    echo -e "\n${C_BOLD}${title}${C_RESET}"
    for i in "${!items[@]}"; do
        echo "  $((i + 1)). ${items[$i]}"
    done
    while true; do
        read -rp "Select option (1-${#items[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#items[@]} )); then
            printf -v "$varname" '%s' "$((choice - 1))"
            return 0
        fi
        msg_warn "Invalid selection. Please enter a number between 1 and ${#items[@]}."
    done
}

prompt_integer() {
    local varname="$1"
    local prompt_text="$2"
    local default_value="$3"
    local min="$4"
    local max="$5"
    local input
    while true; do
        read -rp "${prompt_text} [${default_value}]: " input
        input="${input:-$default_value}"
        if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= min && input <= max )); then
            printf -v "$varname" '%s' "$input"
            return 0
        fi
        msg_warn "Please enter a number between $min and $max."
    done
}
```

#### Step 1.3: Create `lib/proxmox.sh`
**Source**: Lines 251-311 from `nut-vm-setup.sh`

```bash
#!/usr/bin/env bash
# proxmox.sh - Proxmox-specific operations

# Constants (will be sourced from config/defaults.conf)
readonly IMG_CACHE_DIR="${IMG_CACHE_DIR:-/var/lib/vz/template/iso}"
readonly UBUNTU_IMG_URL="${UBUNTU_IMG_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
readonly UBUNTU_IMG_NAME="${UBUNTU_IMG_NAME:-noble-server-cloudimg-amd64.img}"

check_root() {
    if [[ $EUID -ne 0 ]]; then
        msg_error "This script must be run as root"
    fi
    msg_ok "Running as root"
}

check_proxmox() {
    local missing=()
    for cmd in qm pvesh pveversion; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    [[ ${#missing[@]} -gt 0 ]] && msg_error "Missing Proxmox commands: ${missing[*]}"
    msg_ok "Proxmox VE environment detected"
}

check_dependencies() {
    local missing=()
    for cmd in ssh scp wget lsusb nc; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    [[ ${#missing[@]} -gt 0 ]] && msg_error "Missing required dependencies: ${missing[*]}"
    msg_ok "Dependencies satisfied"
}

get_next_vmid() {
    pvesh get /cluster/nextid 2>/dev/null || echo "100"
}

list_storage_pools() {
    pvesm status --content images 2>/dev/null | awk 'NR>1 {print $1}' | head -20
}

validate_vmid() {
    local vmid="$1"
    if qm list 2>/dev/null | grep -q "^[[:space:]]*${vmid}[[:space:]]"; then
        return 1
    fi
    return 0
}

validate_bridge() {
    local bridge="$1"
    ip link show "$bridge" &>/dev/null
}
```

#### Step 1.4: Create `lib/ssh.sh`
**Source**: Lines 466-489 from `nut-vm-setup.sh`

```bash
#!/usr/bin/env bash
# ssh.sh - SSH key management and remote execution

TEMP_KEY_DIR=""
TEMP_SSH_KEY=""
TEMP_SSH_PUB=""
CLOUDINIT_SNIPPET=""

inject_ssh_key() {
    TEMP_KEY_DIR="/tmp/nut-setup-$$"
    mkdir -p "$TEMP_KEY_DIR"

    ssh-keygen -t ed25519 -f "$TEMP_KEY_DIR/nut-setup-key" -N "" -C "nut-setup-temp" &>/dev/null

    TEMP_SSH_KEY="$TEMP_KEY_DIR/nut-setup-key"
    TEMP_SSH_PUB="$TEMP_KEY_DIR/nut-setup-key.pub"

    cleanup_temp_keys() {
        [[ -d "$TEMP_KEY_DIR" ]] && rm -rf "$TEMP_KEY_DIR"
        [[ -n "${CLOUDINIT_SNIPPET:-}" && -f "$CLOUDINIT_SNIPPET" ]] && rm -f "$CLOUDINIT_SNIPPET"
    }
    trap cleanup_temp_keys EXIT

    msg_ok "Generated temporary SSH keys"
}

run_remote_script() {
    local host="$1"
    local user="$2"
    local script_content="$3"
    local remote_path="${4:-/tmp/remote-script.sh}"

    # Copy script
    echo "$script_content" | ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        -o GSSAPIAuthentication=no \
        -o PasswordAuthentication=no \
        -i "$TEMP_SSH_KEY" \
        "${user}@${host}" "cat > $remote_path" 2>/dev/null

    # Execute script
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        -o GSSAPIAuthentication=no \
        -o PasswordAuthentication=no \
        -i "$TEMP_SSH_KEY" \
        "${user}@${host}" "sudo bash $remote_path" 2>&1
}

wait_for_ssh() {
    local host="$1"
    local port="${2:-22}"
    local timeout="${3:-300}"
    local elapsed=0

    msg_info "Waiting for SSH on $host:$port..."
    spinner_start "Waiting for SSH..."

    while [[ $elapsed -lt $timeout ]]; do
        if nc -z -w 2 "$host" "$port" 2>/dev/null; then
            spinner_stop
            msg_ok "SSH is available"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    spinner_stop
    msg_error "SSH connection timed out after ${timeout}s"
}

get_vm_ip() {
    local vmid="$1"
    local max_wait="${2:-120}"

    msg_info "Getting VM IP address..."
    spinner_start "Waiting for guest agent..."

    local elapsed=0
    local ip=""
    local node
    node=$(hostname)

    while [[ $elapsed -lt $max_wait ]]; do
        ip=$(pvesh get "/nodes/${node}/qemu/${vmid}/agent/network-get-interfaces" \
            --output-format json 2>/dev/null | jq -r '
            .result[] | select(.name != "lo") | .["ip-addresses"][] |
            select(.["ip-address-type"] == "ipv4") | .["ip-address"]
            ' | grep -v '^127\|^169\.254' | head -1)

        if [[ -n "$ip" ]]; then
            spinner_stop
            msg_ok "VM IP address: $ip"
            echo "$ip"
            return 0
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    spinner_stop
    msg_warn "Could not get IP from guest agent"
    return 1
}
```

#### Step 1.5: Create `templates/nut-install.sh`
**Source**: Lines 776-898 from `nut-vm-setup.sh` (the heredoc)

```bash
#!/bin/bash
# NUT Installation Script Template
# Variables are substituted before deployment

set -e

UPS_NAME="{{UPS_NAME}}"
UPS_DESC="{{UPS_DESC}}"
DRIVER="{{DRIVER}}"
ADMIN_USER="{{ADMIN_USER}}"
ADMIN_PASS="{{ADMIN_PASS}}"
MONITOR_USER="{{MONITOR_USER}}"
MONITOR_PASS="{{MONITOR_PASS}}"
LISTEN_ADDR="{{LISTEN_ADDR}}"
LISTEN_PORT="{{LISTEN_PORT}}"

echo "[NUT-INSTALL] Updating packages..."
apt-get update -qq

echo "[NUT-INSTALL] Installing NUT packages..."
apt-get install -y -qq nut-server nut-client usbutils

echo "[NUT-INSTALL] Waiting for UPS device..."
for i in {1..12}; do
    if lsusb 2>/dev/null | grep -qiE "(apc|cyberpower|eaton|tripplite|liebert|ups)"; then
        echo "[NUT-INSTALL] UPS device detected"
        break
    fi
    if [[ $i -eq 12 ]]; then
        echo "[NUT-INSTALL] Warning: UPS device not detected after 60 seconds"
    fi
    sleep 5
done

echo "[NUT-INSTALL] Configuring NUT..."

# nut.conf
cat > /etc/nut/nut.conf <<EOF
MODE=netserver
EOF

# ups.conf
cat > /etc/nut/ups.conf <<EOF
[${UPS_NAME}]
  driver = ${DRIVER}
  port = auto
  desc = "${UPS_DESC}"
  pollinterval = 2
EOF

# upsd.conf
cat > /etc/nut/upsd.conf <<EOF
LISTEN ${LISTEN_ADDR} ${LISTEN_PORT}
MAXAGE 15
STATEPATH /var/run/nut
EOF

# upsd.users
cat > /etc/nut/upsd.users <<EOF
[${ADMIN_USER}]
  password = ${ADMIN_PASS}
  actions = SET
  instcmds = ALL

[${MONITOR_USER}]
  password = ${MONITOR_PASS}
  upsmon master
EOF

# upsmon.conf
cat > /etc/nut/upsmon.conf <<EOF
MONITOR ${UPS_NAME}@localhost:${LISTEN_PORT} 1 ${MONITOR_USER} ${MONITOR_PASS} master

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
EOF

# Set permissions
echo "[NUT-INSTALL] Setting permissions..."
chown root:nut /etc/nut/*.conf
chmod 640 /etc/nut/*.conf

# Create state directory
mkdir -p /var/run/nut
chown nut:nut /var/run/nut

# Enable and start services
echo "[NUT-INSTALL] Starting NUT services..."
systemctl enable nut-server nut-monitor
systemctl restart nut-server nut-monitor

# Wait for services
sleep 5

# Test NUT
echo "[NUT-INSTALL] Testing NUT connection..."
if upsc "${UPS_NAME}@localhost" &>/dev/null; then
    echo "NUT_TEST_OK"
else
    echo "NUT_TEST_FAIL"
fi

echo "[NUT-INSTALL] Complete!"
```

#### Step 1.6: Create `config/defaults.conf`

```bash
# NUT VM Setup - Default Configuration
# Source this file to set default values

# Script metadata
SCRIPT_VERSION="1.0.0"

# Ubuntu Cloud Image Settings
UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
UBUNTU_IMG_NAME="noble-server-cloudimg-amd64.img"
IMG_CACHE_DIR="/var/lib/vz/template/iso"

# NUT Settings
NUT_DEFAULT_PORT=3493
NUT_LISTEN_ADDR="0.0.0.0"

# VM Settings
VM_DEFAULT_ID="100"
VM_DEFAULT_NAME="nut-server"
VM_DEFAULT_STORAGE="local"
VM_DEFAULT_BRIDGE="vmbr0"
VM_DEFAULT_RAM="1024"
VM_DEFAULT_CPU="1"
VM_DEFAULT_DISK="8"
VM_DEFAULT_USER="ubuntu"

# SSH Settings
SSH_TIMEOUT=300
SSH_POLL_INTERVAL=5
VM_START_DELAY=120

# UPS Vendor IDs
declare -A UPS_VENDORS=(
    ["051d"]="APC"
    ["0764"]="CyberPower"
    ["0463"]="Eaton"
    ["09ae"]="Tripp Lite"
    ["10af"]="Liebert"
)

# UPS Drivers
declare -A UPS_DRIVERS=(
    [1]="usbhid-ups"
    [2]="blazer_usb"
    [3]="nutdrv_qx"
)

# Driver Descriptions
declare -A DRIVER_DESCS=(
    [1]="usbhid-ups - APC, Eaton, CyberPower (recommended)"
    [2]="blazer_usb - Generic Megatec/Q1 protocol"
    [3]="nutdrv_qx - Newer generic USB devices"
)
```

### Phase 2: Refactor Main Script

#### Step 2.1: Refactor `nut-vm-setup.sh`

```bash
#!/usr/bin/env bash
#
# nut-vm-setup.sh - Proxmox NUT Server VM Setup Script
#
# Creates an Ubuntu 24.04 VM on Proxmox, configures USB passthrough for UPS,
# and installs/configures NUT (Network UPS Tools) in netserver mode.
#
# Must be run as root on a Proxmox host.
#
# REFACTORED: Now sources modular libraries from lib/

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source configuration and libraries
source "$SCRIPT_DIR/config/defaults.conf"
source "$SCRIPT_DIR/lib/build.func"
source "$SCRIPT_DIR/lib/prompts.sh"
source "$SCRIPT_DIR/lib/proxmox.sh"
source "$SCRIPT_DIR/lib/ssh.sh"

# Application metadata
APP="NUT Server"
var_tags="${var_tags:-network;ups}"
var_cpu="${var_cpu:-1}"
var_ram="${var_ram:-1024}"
var_disk="${var_disk:-8}"
var_os="${var_os:-ubuntu}"
var_version="${var_version:-24.04}"

#===============================================================================
# VM Configuration Collection (App-specific)
#===============================================================================

collect_vm_config() {
    local storage_pools=()
    local storage_count=0

    # Get next available VM ID
    VM_ID=$(get_next_vmid)
    prompt_integer VM_ID "VM ID" "$VM_ID" 100 999999999

    while ! validate_vmid "$VM_ID"; do
        msg_warn "VM ID $VM_ID is already in use"
        prompt_integer VM_ID "VM ID" "$((VM_ID + 1))" 100 999999999
    done

    # VM Name
    prompt_default VM_NAME "VM Hostname" "$VM_DEFAULT_NAME"

    # Storage pool
    mapfile -t storage_pools < <(list_storage_pools)
    storage_count=${#storage_pools[@]}

    if [[ $storage_count -eq 0 ]]; then
        msg_error "No storage pools found with 'images' content type"
    elif [[ $storage_count -eq 1 ]]; then
        VM_STORAGE="${storage_pools[0]}"
        msg_info "Using storage pool: $VM_STORAGE"
    else
        local i
        echo -e "\nAvailable storage pools:"
        for i in "${!storage_pools[@]}"; do
            echo "  $((i + 1)). ${storage_pools[$i]}"
        done
        local storage_idx
        prompt_menu storage_idx "Select storage pool:" "${storage_pools[@]}"
        VM_STORAGE="${storage_pools[$storage_idx]}"
    fi

    # Network bridge
    VM_BRIDGE="$VM_DEFAULT_BRIDGE"
    prompt_default VM_BRIDGE "Network bridge" "$VM_BRIDGE"

    while ! validate_bridge "$VM_BRIDGE"; do
        msg_warn "Bridge '$VM_BRIDGE' does not exist"
        prompt_default VM_BRIDGE "Network bridge" "$VM_DEFAULT_BRIDGE"
    done

    # RAM
    prompt_integer VM_RAM "RAM (MB)" "$VM_DEFAULT_RAM" 256 131072

    # CPU cores
    prompt_integer VM_CORES "CPU cores" "$VM_DEFAULT_CPU" 1 128

    # Disk size
    prompt_integer VM_DISK_GB "Disk size (GB)" "$VM_DEFAULT_DISK" 4 10240

    # VM user
    prompt_default VM_USER "VM username" "$VM_DEFAULT_USER"

    # VM password
    prompt_password VM_PASSWORD "VM password"

    # Confirmation
    echo
    echo -e "${C_BOLD}VM Configuration Summary:${C_RESET}"
    echo "  VM ID:        $VM_ID"
    echo "  Hostname:     $VM_NAME"
    echo "  Storage:      $VM_STORAGE"
    echo "  Bridge:       $VM_BRIDGE"
    echo "  RAM:          ${VM_RAM} MB"
    echo "  CPU cores:    $VM_CORES"
    echo "  Disk size:    ${VM_DISK_GB} GB"
    echo "  Username:     $VM_USER"
    echo

    if ! prompt_yes_no "Proceed with VM creation?" "y"; then
        msg_error "Aborted by user"
    fi
}

#===============================================================================
# NUT Configuration (App-specific)
#===============================================================================

collect_nut_config() {
    prompt_default NUT_UPS_NAME "UPS name (identifier)" "ups"
    prompt_default NUT_UPS_DESC "UPS description" "My UPS"

    echo
    echo "Select NUT driver:"
    local sorted_keys=($(echo "${!UPS_DRIVERS[@]}" | tr ' ' '\n' | sort -n))
    for key in "${sorted_keys[@]}"; do
        echo "  $key. ${DRIVER_DESCS[$key]}"
    done

    local driver_choice
    prompt_menu driver_choice "Select driver:" "${DRIVER_DESCS[1]}" "${DRIVER_DESCS[2]}" "${DRIVER_DESCS[3]}"
    NUT_DRIVER="${UPS_DRIVERS[$((driver_choice + 1))]}"

    prompt_default NUT_ADMIN_USER "NUT admin username" "admin"
    prompt_password NUT_ADMIN_PASS "NUT admin password"

    prompt_default NUT_MONITOR_USER "NUT monitor username" "monuser"
    prompt_password NUT_MONITOR_PASS "NUT monitor password"

    prompt_default NUT_LISTEN_ADDR "NUT listen address" "0.0.0.0"
    prompt_integer NUT_LISTEN_PORT "NUT listen port" "3493" 1 65535
}

#===============================================================================
# Main Entry Point
#===============================================================================

main() {
    # Parse CLI flags
    case "${1:-}" in
        --help|-h)
            cat <<EOF
Usage: $0 [--version|--help]

Creates an Ubuntu 24.04 VM on Proxmox and configures NUT netserver.

Options:
  --help, -h      Show this help message
  --version       Show version
EOF
            exit 0
            ;;
        --version)
            echo "nut-vm-setup v${SCRIPT_VERSION}"
            exit 0
            ;;
    esac

    # Initialize
    header_info "$APP"
    check_root
    check_proxmox
    check_dependencies

    inject_ssh_key
    prompt_autogenerate_passwords
    collect_vm_config
    collect_nut_config

    # Pre-proceeding confirmation
    echo
    echo -e "${C_BOLD}NUT Configuration Summary:${C_RESET}"
    echo "  UPS Name:        $NUT_UPS_NAME"
    echo "  UPS Description: $NUT_UPS_DESC"
    echo "  Driver:          $NUT_DRIVER"
    echo "  Admin User:      $NUT_ADMIN_USER"
    echo "  Monitor User:    $NUT_MONITOR_USER"
    echo "  Listen Address:  $NUT_LISTEN_ADDR:$NUT_LISTEN_PORT"
    echo

    if ! prompt_yes_no "Proceed with VM and NUT setup?" "y"; then
        msg_error "Aborted by user"
    fi

    # Execute
    download_cloud_image
    create_vm
    detect_ups
    setup_usb_passthrough
    start_vm

    msg_info "Waiting ${VM_START_DELAY}s for VM to initialize..."
    sleep "$VM_START_DELAY"

    VM_IP=$(get_vm_ip "$VM_ID")
    wait_for_ssh "$VM_IP" 22

    run_nut_install
    print_summary
}

main "$@"
```

### Phase 3: Create Configuration Files

#### Step 3.1: Create `json/nut.json`

```json
{
  "name": "NUT Server",
  "description": "Network UPS Tools server in netserver mode",
  "type": "vm",
  "category": "network",
  "tags": ["network", "ups", "monitoring"],
  "defaults": {
    "cpu": 1,
    "ram": 1024,
    "disk": 8,
    "os": "ubuntu",
    "version": "24.04"
  },
  "ports": {
    "nut": 3493
  },
  "source": "https://networkupstools.org/",
  "documentation": "https://networkupstools.org/documentation.html"
}
```

---

## Migration Checklist

### Phase 1: Foundation (Library Structure)

- [ ] Create `lib/` directory
- [ ] Extract `lib/build.func` from lines 49-118, 120-248, 992-1034
- [ ] Extract `lib/ui.sh` (message functions, colors, spinners)
- [ ] Extract `lib/prompts.sh` (input collection functions)
- [ ] Extract `lib/proxmox.sh` (Proxmox-specific operations)
- [ ] Extract `lib/ssh.sh` (SSH key management and remote execution)
- [ ] Create `config/defaults.conf` with all constants

### Phase 2: Templates

- [ ] Create `templates/` directory
- [ ] Extract `templates/nut-install.sh` from heredoc (lines 776-898)
- [ ] Replace variable substitution with template placeholders
- [ ] Create `json/nut.json` for metadata

### Phase 3: Main Script Refactor

- [ ] Refactor `nut-vm-setup.sh` to ~150 lines
- [ ] Add library sourcing at top
- [ ] Move app-specific logic to functions
- [ ] Test that all paths work correctly
- [ ] Update `AGENTS.md` with new structure

### Phase 4: Documentation & Testing

- [ ] Update `AGENTS.md` with new file structure
- [ ] Update `plan.md` to reflect modular design
- [ ] Test each library function independently
- [ ] Test full installation flow
- [ ] Verify cleanup works correctly

---

## Comparison: Before vs After

| Metric | Before | After |
|--------|--------|-------|
| Main script lines | 1,128 | ~150 |
| Number of files | 3 | 10+ |
| Reusable library | None | `lib/` with 6+ modules |
| Testability | Manual only | Unit testable per module |
| NUT install script | Heredoc (lines 776-898) | `templates/nut-install.sh` |
| Configuration | Hardcoded | `config/defaults.conf` |
| Updates to common code | Edit 1,128-line file | Edit specific library file |

---

## Migration Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Breaking changes during refactor | High | Keep original script until new structure is fully tested |
| Path issues with sourcing | Medium | Use `$(dirname "$0")` for relative paths; test on clean system |
| Variable scope changes | Medium | Document all global variables; use `declare -g` where needed |
| Template substitution bugs | Medium | Unit test substitution function with various inputs |
| Lost functionality | High | Create comprehensive checklist; test each feature after migration |

---

## Next Steps

1. **Review this migration plan** - Ensure all requirements are captured
2. **Create branch** `refactor/modular-structure` (done)
3. **Start Phase 1** - Create library files one by one
4. **Test each library** independently before proceeding
5. **Keep original script** as `nut-vm-setup.sh.legacy` until migration complete
6. **Update documentation** after each phase

---

## References

- **Community Scripts Pattern**: https://github.com/community-scripts/ProxmoxVE/blob/main/misc/build.func
- **Current Script**: `nut-vm-setup.sh` (main branch, 1,128 lines)
- **Specification**: `plan.md`
