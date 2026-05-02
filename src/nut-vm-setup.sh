#!/usr/bin/env bash
#
# nut-vm-setup.sh - Proxmox NUT Server VM Setup Script
#
# Creates an Ubuntu 24.04 VM on Proxmox, configures USB passthrough for UPS,
# and installs/configures NUT (Network UPS Tools) in netserver mode.
#
# Must be run as root on a Proxmox host.

#===============================================================================
# Section 0: Constants
#===============================================================================

readonly UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
readonly UBUNTU_IMG_NAME="noble-server-cloudimg-amd64.img"
readonly IMG_CACHE_DIR="/var/lib/vz/template/iso"
readonly NUT_DEFAULT_PORT=3493
readonly SSH_TIMEOUT=300
readonly SSH_POLL_INTERVAL=5
readonly VM_START_DELAY=120
readonly SCRIPT_VERSION="1.0.0"

# UPS Vendor IDs
readonly -A UPS_VENDORS=(
    ["051d"]="APC"
    ["0764"]="CyberPower"
    ["0463"]="Eaton"
    ["09ae"]="Tripp Lite"
    ["10af"]="Liebert"
)

# Driver options
readonly -A UPS_DRIVERS=(
    [1]="usbhid-ups"
    [2]="blazer_usb"
    [3]="nutdrv_qx"
)

# Driver descriptions
readonly -A DRIVER_DESCS=(
    [1]="usbhid-ups - APC, Eaton, CyberPower (recommended)"
    [2]="blazer_usb - Generic Megatec/Q1 protocol"
    [3]="nutdrv_qx - Newer generic USB devices"
)

#===============================================================================
# Section 1: Colors, Symbols, and UI Helpers
#===============================================================================

YW=$(echo "\033[33m")
YWB=$(echo "\033[93m")
BL=$(echo "\033[36m")
RD=$(echo "\033[01;31m")
BGN=$(echo "\033[4;92m")
GN=$(echo "\033[1;92m")
DGN=$(echo "\033[32m")
BOLD=$(echo "\033[1m")
CL=$(echo "\033[m")

CM="  ✔️  ${CL}"
CROSS="  ✖️  ${CL}"
INFO="  💡  ${CL}"

BFR="\\r\\033[K"
HOLD=" "
TAB="  "

SPINNER_PID=""

spinner() {
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local spin_i=0
    printf "\e[?25l"
    while true; do
        printf "\r ${YWB}%s${CL}" "${frames[spin_i]}"
        spin_i=$(( (spin_i + 1) % ${#frames[@]} ))
        sleep 0.1
    done
}

msg_info() {
    local msg="$1"
    echo -ne "${TAB}${YW}${HOLD}${msg}${HOLD}"
    spinner &
    SPINNER_PID=$!
}

msg_ok() {
    [[ -n "$SPINNER_PID" ]] && ps -p "$SPINNER_PID" &>/dev/null && kill "$SPINNER_PID"
    printf "\e[?25h"
    local msg="$1"
    echo -e "${BFR}${CM}${GN}${msg}${CL}"
    SPINNER_PID=""
}

msg_error() {
    [[ -n "$SPINNER_PID" ]] && ps -p "$SPINNER_PID" &>/dev/null && kill "$SPINNER_PID"
    printf "\e[?25h"
    local msg="$1"
    echo -e "${BFR}${CROSS}${RD}${msg}${CL}"
    SPINNER_PID=""
    exit 1
}

msg_warn() {
    [[ -n "$SPINNER_PID" ]] && ps -p "$SPINNER_PID" &>/dev/null && kill "$SPINNER_PID" && printf "\e[?25h"
    SPINNER_PID=""
    local msg="$1"
    echo -e "${TAB}${YW}⚠${CL} ${msg}"
}

error_handler() {
    [[ -n "$SPINNER_PID" ]] && ps -p "$SPINNER_PID" &>/dev/null && kill "$SPINNER_PID"
    printf "\e[?25h"
    local line_number="$1"
    local command="$2"
    local exit_code="$?"
    echo -e "\n${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: while executing command ${YW}$command${CL}\n"
}

catch_errors() {
    set -Eeuo pipefail
    trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
}

# VERBOSE=yes to see full command output; default suppresses it
VERBOSE="${VERBOSE:-no}"
if [[ "$VERBOSE" == "yes" ]]; then
    STD=""
else
    STD=">/dev/null 2>&1"
fi

header_info() {
    clear
    cat <<"EOF"
    _   _ _   _ _____
   | \ | | | | |_   _|
   |  \| | | | | | |
   | |\  | |_| | | |
   |_| \_|\___/  |_|

   Proxmox NUT Server VM Setup
EOF
}

#===============================================================================
# Section 2: Input/Prompt Helper Functions (whiptail)
#===============================================================================

AUTO_GENERATE_PASSWORDS=false
GENERATED_PASSWORDS=()

generate_password() {
    local length="${1:-16}"
    local password
    password=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9!@#$%^&*' | head -c "$length")
    if [[ ${#password} -lt $length ]]; then
        password=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w "$length" | head -n 1)
    fi
    echo "$password"
}

prompt_autogenerate_passwords() {
    if whiptail --backtitle "Proxmox VE Helper Scripts" \
                --title "PASSWORD CONFIGURATION" \
                --yesno "Auto-generate all passwords?\n\nYes = generate secure passwords automatically.\nNo  = enter them manually." \
                12 58; then
        AUTO_GENERATE_PASSWORDS=true
        msg_ok "Passwords will be auto-generated"
    fi
}

prompt_default() {
    local varname="$1"
    local prompt_text="$2"
    local default_value="$3"
    local title="${4:-INPUT}"
    local result

    result=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
                      --title "$title" \
                      --inputbox "$prompt_text" \
                      8 58 "$default_value" \
                      3>&1 1>&2 2>&3) || msg_error "Cancelled by user"

    printf -v "$varname" '%s' "${result:-$default_value}"
}

prompt_password() {
    local varname="$1"
    local prompt_text="$2"

    if [[ "$AUTO_GENERATE_PASSWORDS" == "true" ]]; then
        local pass
        pass=$(generate_password 16)
        printf -v "$varname" '%s' "$pass"
        GENERATED_PASSWORDS+=("$prompt_text: $pass")
        return 0
    fi

    local pass1 pass2
    while true; do
        pass1=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
                         --title "PASSWORD" \
                         --passwordbox "$prompt_text" \
                         8 58 \
                         3>&1 1>&2 2>&3) || msg_error "Cancelled by user"

        pass2=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
                         --title "PASSWORD" \
                         --passwordbox "Confirm: $prompt_text" \
                         8 58 \
                         3>&1 1>&2 2>&3) || msg_error "Cancelled by user"

        if [[ "$pass1" == "$pass2" ]]; then
            printf -v "$varname" '%s' "$pass1"
            return 0
        fi
        whiptail --backtitle "Proxmox VE Helper Scripts" \
                 --title "MISMATCH" \
                 --msgbox "Passwords do not match. Please try again." 8 58
    done
}

prompt_yes_no() {
    local question="$1"
    local default="${2:-y}"
    local title="${3:-CONFIRM}"
    local args=(--backtitle "Proxmox VE Helper Scripts" --title "$title" --yesno "$question" 12 62)

    [[ "$default" == "n" ]] && args+=(--defaultno)
    whiptail "${args[@]}"
}

prompt_menu() {
    local varname="$1"
    local title="$2"
    shift 2
    local items=("$@")
    local menu_items=()
    local i
    for i in "${!items[@]}"; do
        menu_items+=("$((i + 1))" "${items[$i]}")
    done

    local choice
    choice=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
                      --title "$title" \
                      --menu "Select an option:" 16 70 "${#items[@]}" \
                      "${menu_items[@]}" \
                      3>&1 1>&2 2>&3) || msg_error "Cancelled by user"

    printf -v "$varname" '%s' "$((choice - 1))"
}

prompt_integer() {
    local varname="$1"
    local prompt_text="$2"
    local default_value="$3"
    local min="$4"
    local max="$5"
    local input

    while true; do
        input=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
                         --title "INPUT" \
                         --inputbox "$prompt_text (${min}-${max}):" \
                         8 58 "$default_value" \
                         3>&1 1>&2 2>&3) || msg_error "Cancelled by user"

        input="${input:-$default_value}"
        if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= min && input <= max )); then
            printf -v "$varname" '%s' "$input"
            return 0
        fi
        whiptail --backtitle "Proxmox VE Helper Scripts" \
                 --title "INVALID INPUT" \
                 --msgbox "Please enter a number between $min and $max." 8 58
    done
}

#===============================================================================
# Section 3: Prerequisite Checks
#===============================================================================

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

    if [[ ${#missing[@]} -gt 0 ]]; then
        msg_error "Missing Proxmox commands: ${missing[*]}"
    fi
    msg_ok "Proxmox VE environment detected"
}

check_dependencies() {
    local missing=()

    for cmd in ssh scp wget lsusb nc whiptail; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        msg_error "Missing required dependencies: ${missing[*]}"
    fi
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

#===============================================================================
# Section 4: VM Configuration Prompts
#===============================================================================

collect_vm_config() {
    local storage_pools=()
    local storage_count=0

    VM_ID=$(get_next_vmid)
    prompt_integer VM_ID "VM ID" "$VM_ID" 100 999999999

    while ! validate_vmid "$VM_ID"; do
        whiptail --backtitle "Proxmox VE Helper Scripts" \
                 --title "VM ID IN USE" \
                 --msgbox "VM ID $VM_ID is already in use. Please choose another." 8 58
        prompt_integer VM_ID "VM ID" "$((VM_ID + 1))" 100 999999999
    done

    prompt_default VM_NAME "VM Hostname" "nut-server" "VM HOSTNAME"

    mapfile -t storage_pools < <(list_storage_pools)
    storage_count=${#storage_pools[@]}

    if [[ $storage_count -eq 0 ]]; then
        msg_error "No storage pools found with 'images' content type"
    elif [[ $storage_count -eq 1 ]]; then
        VM_STORAGE="${storage_pools[0]}"
        msg_ok "Using storage pool: $VM_STORAGE"
    else
        local storage_idx
        prompt_menu storage_idx "SELECT STORAGE POOL" "${storage_pools[@]}"
        VM_STORAGE="${storage_pools[$storage_idx]}"
    fi

    VM_BRIDGE="vmbr0"
    prompt_default VM_BRIDGE "Network bridge" "$VM_BRIDGE" "NETWORK BRIDGE"

    while ! validate_bridge "$VM_BRIDGE"; do
        whiptail --backtitle "Proxmox VE Helper Scripts" \
                 --title "INVALID BRIDGE" \
                 --msgbox "Bridge '$VM_BRIDGE' does not exist. Please try again." 8 58
        prompt_default VM_BRIDGE "Network bridge" "vmbr0" "NETWORK BRIDGE"
    done

    prompt_integer VM_RAM "RAM (MB)" "1024" 256 131072
    prompt_integer VM_CORES "CPU cores" "1" 1 128
    prompt_integer VM_DISK_GB "Disk size (GB)" "8" 4 10240
    prompt_default VM_USER "VM username" "ubuntu" "VM USER"
    prompt_password VM_PASSWORD "VM password"

    if ! prompt_yes_no "VM Configuration:\n\n  VM ID:     $VM_ID\n  Hostname:  $VM_NAME\n  Storage:   $VM_STORAGE\n  Bridge:    $VM_BRIDGE\n  RAM:       ${VM_RAM} MB\n  Cores:     $VM_CORES\n  Disk:      ${VM_DISK_GB} GB\n  Username:  $VM_USER\n\nProceed with VM creation?" "y" "VM CONFIGURATION SUMMARY"; then
        msg_error "Aborted by user"
    fi
}

#===============================================================================
# Section 5: NUT Configuration Prompts
#===============================================================================

collect_nut_config() {
    prompt_default NUT_UPS_NAME "UPS name (identifier)" "ups" "UPS NAME"
    prompt_default NUT_UPS_DESC "UPS description" "My UPS" "UPS DESCRIPTION"

    local driver_choice
    prompt_menu driver_choice "SELECT NUT DRIVER" "${DRIVER_DESCS[1]}" "${DRIVER_DESCS[2]}" "${DRIVER_DESCS[3]}"
    NUT_DRIVER="${UPS_DRIVERS[$((driver_choice + 1))]}"

    prompt_default NUT_ADMIN_USER "NUT admin username" "admin" "NUT ADMIN USER"
    prompt_password NUT_ADMIN_PASS "NUT admin password"
    prompt_default NUT_MONITOR_USER "NUT monitor username" "monuser" "NUT MONITOR USER"
    prompt_password NUT_MONITOR_PASS "NUT monitor password"
    prompt_default NUT_LISTEN_ADDR "NUT listen address" "0.0.0.0" "NUT LISTEN ADDRESS"
    prompt_integer NUT_LISTEN_PORT "NUT listen port" "3493" 1 65535
}

#===============================================================================
# Section 6: Cloud Image Download + VM Creation
#===============================================================================

download_cloud_image() {
    local img_path="$IMG_CACHE_DIR/$UBUNTU_IMG_NAME"

    if [[ -f "$img_path" ]]; then
        msg_ok "Using cached Ubuntu 24.04 cloud image"
        return 0
    fi

    msg_info "Downloading Ubuntu 24.04 cloud image"
    mkdir -p "$IMG_CACHE_DIR"

    if command -v wget &>/dev/null; then
        if ! wget -q -c -O "$img_path.tmp" "$UBUNTU_IMG_URL" 2>/dev/null; then
            msg_error "Failed to download cloud image"
        fi
    elif command -v curl &>/dev/null; then
        if ! curl -sL --continue-at - -o "$img_path.tmp" "$UBUNTU_IMG_URL" 2>/dev/null; then
            msg_error "Failed to download cloud image"
        fi
    else
        msg_error "Neither wget nor curl is available"
    fi

    mv "$img_path.tmp" "$img_path"
    msg_ok "Downloaded Ubuntu 24.04 cloud image"
}

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

generate_cloudinit_snippet() {
    local snippet_path="/var/lib/vz/snippets/nut-vm-${VM_ID}-cloudinit.yaml"

    # Proxmox requires 'snippets' content type on the storage or it rejects the
    # volume reference at VM start with "volume does not exist".
    local cfg_content
    cfg_content=$(awk '/^dir: local/{f=1} f && /content/{print $2; exit}' /etc/pve/storage.cfg 2>/dev/null || echo "")
    if [[ "$cfg_content" != *snippets* ]]; then
        if [[ -n "$cfg_content" ]]; then
            pvesm set local --content "${cfg_content},snippets" &>/dev/null || true
        else
            pvesm set local --content "vztmpl,iso,backup,snippets" &>/dev/null || true
        fi
    fi

    mkdir -p "/var/lib/vz/snippets"

    cat > "$snippet_path" << 'EOF'
#cloud-config
package_update: true
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable --now qemu-guest-agent
EOF

    CLOUDINIT_SNIPPET="$snippet_path"
    msg_ok "Generated cloud-init snippet"
}

create_vm() {
    local img_path="$IMG_CACHE_DIR/$UBUNTU_IMG_NAME"

    generate_cloudinit_snippet

    msg_info "Creating VM $VM_ID"

    if ! qm create "$VM_ID" \
        --name "$VM_NAME" \
        --memory "$VM_RAM" \
        --cores "$VM_CORES" \
        --net0 "virtio,bridge=$VM_BRIDGE" \
        --ostype l26 \
        --agent "enabled=1" \
        --serial0 socket \
        --vga serial0 &>/dev/null; then
        msg_error "Failed to create VM"
    fi

    msg_ok "Created VM $VM_ID"

    msg_info "Importing disk image"

    if ! qm importdisk "$VM_ID" "$img_path" "$VM_STORAGE" &>/dev/null; then
        msg_error "Failed to import disk"
    fi

    msg_ok "Imported disk image"

    msg_info "Configuring VM"

    qm set "$VM_ID" --scsihw virtio-scsi-pci &>/dev/null
    qm set "$VM_ID" --scsi0 "${VM_STORAGE}:vm-${VM_ID}-disk-0" &>/dev/null
    qm resize "$VM_ID" scsi0 "${VM_DISK_GB}G" &>/dev/null
    qm set "$VM_ID" --ide2 "${VM_STORAGE}:cloudinit" &>/dev/null
    qm set "$VM_ID" --boot c --bootdisk scsi0 &>/dev/null
    qm set "$VM_ID" --ipconfig0 "ip=dhcp" &>/dev/null
    qm set "$VM_ID" --ciuser "$VM_USER" &>/dev/null
    qm set "$VM_ID" --cipassword "$VM_PASSWORD" &>/dev/null
    qm set "$VM_ID" --sshkeys "$TEMP_SSH_PUB" &>/dev/null
    qm set "$VM_ID" --cicustom "vendor=local:snippets/nut-vm-${VM_ID}-cloudinit.yaml" &>/dev/null

    VM_CREATED=true
    msg_ok "VM configured"
}

#===============================================================================
# Section 7: USB Detection + Passthrough
#===============================================================================

detect_ups() {
    if ! command -v lsusb &>/dev/null; then
        msg_warn "lsusb not found — USB detection unavailable"
        if whiptail --backtitle "Proxmox VE Helper Scripts" \
                    --title "USB DETECTION" \
                    --yesno "lsusb not available. Enter UPS vendor:product manually?" 8 58; then
            UPS_VENDOR_PRODUCT=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
                                          --title "UPS DEVICE" \
                                          --inputbox "Enter UPS vendor:product (e.g. 051d:0002):" \
                                          8 58 "" 3>&1 1>&2 2>&3) || true
        fi
        return
    fi

    msg_info "Scanning for USB UPS devices"

    local lsusb_output
    lsusb_output=$(timeout 10 lsusb 2>/dev/null) || {
        msg_warn "USB device detection timed out"
        if whiptail --backtitle "Proxmox VE Helper Scripts" \
                    --title "USB TIMEOUT" \
                    --yesno "lsusb timed out. Enter UPS vendor:product manually?" 8 58; then
            UPS_VENDOR_PRODUCT=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
                                          --title "UPS DEVICE" \
                                          --inputbox "Enter UPS vendor:product (e.g. 051d:0002):" \
                                          8 58 "" 3>&1 1>&2 2>&3) || true
        fi
        return
    }

    msg_ok "USB scan complete"

    local usb_devices=()
    local device_info=()
    local i=0

    while IFS= read -r line; do
        if [[ "$line" =~ Bus[[:space:]]([0-9]+)[[:space:]]Device[[:space:]]([0-9]+).+ID[[:space:]]([0-9a-f]{4}):([0-9a-f]{4})[[:space:]]*(.*) ]]; then
            local bus="${BASH_REMATCH[1]}"
            local device="${BASH_REMATCH[2]}"
            local vendor="${BASH_REMATCH[3]}"
            local product="${BASH_REMATCH[4]}"
            local name="${BASH_REMATCH[5]}"
            local vendor_name="${UPS_VENDORS[$vendor]:-Unknown}"

            if [[ -n "${UPS_VENDORS[$vendor]:-}" ]] || [[ "$name" =~ [Uu][Pp][Ss] ]]; then
                usb_devices+=("$vendor:$product")
                device_info+=("Bus $bus Device $device - $vendor_name ($vendor:$product) - $name")
                ((++i))
            fi
        fi
    done <<< "$lsusb_output"

    UPS_DEVICE_COUNT=$i

    if [[ $UPS_DEVICE_COUNT -eq 0 ]]; then
        msg_warn "No USB UPS devices detected"
        if whiptail --backtitle "Proxmox VE Helper Scripts" \
                    --title "NO UPS FOUND" \
                    --yesno "No UPS devices found. Enter vendor:product manually?" 8 58; then
            UPS_VENDOR_PRODUCT=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
                                          --title "UPS DEVICE" \
                                          --inputbox "Enter UPS vendor:product (e.g. 051d:0002):" \
                                          8 58 "" 3>&1 1>&2 2>&3) || true
        fi
        return
    elif [[ $UPS_DEVICE_COUNT -eq 1 ]]; then
        if whiptail --backtitle "Proxmox VE Helper Scripts" \
                    --title "UPS DETECTED" \
                    --yesno "Use this device?\n\n${device_info[0]}" 10 70; then
            UPS_VENDOR_PRODUCT="${usb_devices[0]}"
            UPS_BUS_PORT=""
        fi
    else
        local choice
        prompt_menu choice "SELECT UPS DEVICE" "${device_info[@]}"
        UPS_VENDOR_PRODUCT="${usb_devices[$choice]}"

        local duplicates=0
        local dev
        for dev in "${usb_devices[@]}"; do
            [[ "$dev" == "$UPS_VENDOR_PRODUCT" ]] && ((++duplicates))
        done

        if [[ $duplicates -gt 1 ]]; then
            msg_warn "Multiple devices with same ID — using bus-port notation"
            if [[ "${device_info[$choice]}" =~ Bus[[:space:]]([0-9]+) ]]; then
                UPS_BUS_PORT="${BASH_REMATCH[1]}-1"
            fi
        fi
    fi
}

setup_usb_passthrough() {
    if [[ -z "${UPS_VENDOR_PRODUCT:-}" ]]; then
        msg_warn "No UPS device selected, skipping USB passthrough"
        return
    fi

    msg_info "Setting up USB passthrough for $UPS_VENDOR_PRODUCT"

    local usb_param
    if [[ -n "${UPS_BUS_PORT:-}" ]]; then
        usb_param="host=${UPS_BUS_PORT}"
    else
        usb_param="host=${UPS_VENDOR_PRODUCT}"
    fi

    if qm set "$VM_ID" --usb0 "$usb_param" &>/dev/null; then
        msg_ok "USB passthrough configured"
    else
        msg_warn "Failed to set USB passthrough (continuing anyway)"
    fi
}

#===============================================================================
# Section 8: VM Boot + SSH Readiness Wait
#===============================================================================

start_vm() {
    msg_info "Starting VM $VM_ID"

    if ! qm start "$VM_ID" &>/dev/null; then
        msg_error "Failed to start VM"
    fi

    msg_ok "VM started"
}

wait_ssh() {
    local host="$1"
    local port="${2:-22}"
    local timeout="${3:-$SSH_TIMEOUT}"
    local elapsed=0

    msg_info "Waiting for SSH on $host:$port"

    while [[ $elapsed -lt $timeout ]]; do
        if nc -z -w 2 "$host" "$port" 2>/dev/null; then
            msg_ok "SSH is available on $host"
            return 0
        fi
        sleep "$SSH_POLL_INTERVAL"
        elapsed=$((elapsed + SSH_POLL_INTERVAL))
    done

    msg_error "SSH connection timed out after ${timeout}s"
}

get_vm_ip() {
    msg_info "Waiting for guest agent to report VM IP"

    local elapsed=0
    local max_wait=120
    local ip=""
    local node
    node=$(hostname)

    while [[ $elapsed -lt $max_wait ]]; do
        ip=$(pvesh get "/nodes/${node}/qemu/${VM_ID}/agent/network-get-interfaces" \
            --output-format json 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for iface in data.get('result', []):
        for addr in iface.get('ip-addresses', []):
            a = addr.get('ip-address', '')
            if addr.get('ip-address-type') == 'ipv4' and not a.startswith('127.') and not a.startswith('169.254.'):
                print(a)
                sys.exit(0)
except:
    pass
" 2>/dev/null || true)

        if [[ -n "$ip" ]]; then
            VM_IP="$ip"
            msg_ok "VM IP address: $VM_IP"
            return 0
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    msg_warn "Could not get IP from guest agent"
    VM_IP=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
                     --title "VM IP ADDRESS" \
                     --inputbox "Enter VM IP address manually:" \
                     8 58 "" 3>&1 1>&2 2>&3) || msg_error "No IP address provided"

    if [[ -z "$VM_IP" ]]; then
        msg_error "No IP address provided"
    fi
}

#===============================================================================
# Section 9: NUT Install Heredoc + SCP + SSH Execution
#===============================================================================

build_nut_install_script() {
    NUT_INSTALL_SCRIPT=$(cat <<'NUT_SCRIPT'
#!/bin/bash
set -e

UPS_NAME="__UPS_NAME__"
UPS_DESC="__UPS_DESC__"
DRIVER="__DRIVER__"
ADMIN_USER="__ADMIN_USER__"
ADMIN_PASS="__ADMIN_PASS__"
MONITOR_USER="__MONITOR_USER__"
MONITOR_PASS="__MONITOR_PASS__"
LISTEN_ADDR="__LISTEN_ADDR__"
LISTEN_PORT="__LISTEN_PORT__"

echo "[NUT-INSTALL] Updating packages..."
apt-get update -qq >/dev/null 2>&1

echo "[NUT-INSTALL] Installing NUT packages..."
apt-get install -y -qq nut-server nut-client usbutils >/dev/null 2>&1

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

cat > /etc/nut/nut.conf <<EOF
MODE=netserver
EOF

cat > /etc/nut/ups.conf <<EOF
[${UPS_NAME}]
  driver = ${DRIVER}
  port = auto
  desc = "${UPS_DESC}"
  pollinterval = 2
EOF

cat > /etc/nut/upsd.conf <<EOF
LISTEN ${LISTEN_ADDR} ${LISTEN_PORT}
MAXAGE 15
STATEPATH /var/run/nut
EOF

cat > /etc/nut/upsd.users <<EOF
[${ADMIN_USER}]
  password = ${ADMIN_PASS}
  actions = SET
  instcmds = ALL

[${MONITOR_USER}]
  password = ${MONITOR_PASS}
  upsmon master
EOF

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

echo "[NUT-INSTALL] Setting permissions..."
chown root:nut /etc/nut/*.conf
chmod 640 /etc/nut/*.conf

mkdir -p /var/run/nut
chown nut:nut /var/run/nut

echo "[NUT-INSTALL] Starting NUT services..."
systemctl enable nut-server nut-monitor >/dev/null 2>&1
systemctl restart nut-server nut-monitor >/dev/null 2>&1

sleep 5

echo "[NUT-INSTALL] Testing NUT connection..."
if upsc "${UPS_NAME}@localhost" &>/dev/null; then
    echo "NUT_TEST_OK"
else
    echo "NUT_TEST_FAIL"
fi

echo "[NUT-INSTALL] Complete!"
NUT_SCRIPT
)

    NUT_INSTALL_SCRIPT="${NUT_INSTALL_SCRIPT//__UPS_NAME__/$NUT_UPS_NAME}"
    NUT_INSTALL_SCRIPT="${NUT_INSTALL_SCRIPT//__UPS_DESC__/$NUT_UPS_DESC}"
    NUT_INSTALL_SCRIPT="${NUT_INSTALL_SCRIPT//__DRIVER__/$NUT_DRIVER}"
    NUT_INSTALL_SCRIPT="${NUT_INSTALL_SCRIPT//__ADMIN_USER__/$NUT_ADMIN_USER}"
    NUT_INSTALL_SCRIPT="${NUT_INSTALL_SCRIPT//__ADMIN_PASS__/$NUT_ADMIN_PASS}"
    NUT_INSTALL_SCRIPT="${NUT_INSTALL_SCRIPT//__MONITOR_USER__/$NUT_MONITOR_USER}"
    NUT_INSTALL_SCRIPT="${NUT_INSTALL_SCRIPT//__MONITOR_PASS__/$NUT_MONITOR_PASS}"
    NUT_INSTALL_SCRIPT="${NUT_INSTALL_SCRIPT//__LISTEN_ADDR__/$NUT_LISTEN_ADDR}"
    NUT_INSTALL_SCRIPT="${NUT_INSTALL_SCRIPT//__LISTEN_PORT__/$NUT_LISTEN_PORT}"
}

deploy_nut_script() {
    local remote_script_path="/tmp/nut-install.sh"

    msg_info "Deploying NUT install script to VM"

    sleep 20

    local retry_count=0
    local max_retries=5

    while [[ $retry_count -lt $max_retries ]]; do
        if echo "$NUT_INSTALL_SCRIPT" | ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 \
            -o GSSAPIAuthentication=no \
            -o PasswordAuthentication=no \
            -i "$TEMP_SSH_KEY" \
            "${VM_USER}@${VM_IP}" \
            "cat > $remote_script_path" 2>/dev/null; then
            break
        fi
        sleep 10
        ((retry_count++))
    done

    if [[ $retry_count -eq $max_retries ]]; then
        msg_error "Failed to copy install script to VM"
    fi

    msg_ok "Install script deployed"

    msg_info "Running NUT installer on VM (this may take a few minutes)"

    NUT_INSTALL_OUTPUT=$(ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        -o ServerAliveInterval=30 \
        -o GSSAPIAuthentication=no \
        -o PasswordAuthentication=no \
        -i "$TEMP_SSH_KEY" \
        "${VM_USER}@${VM_IP}" \
        "sudo bash $remote_script_path" 2>&1) || true

    if echo "$NUT_INSTALL_OUTPUT" | grep -q "NUT_TEST_OK"; then
        NUT_TEST_RESULT="OK"
        msg_ok "NUT installed and tested successfully"
    else
        NUT_TEST_RESULT="FAIL"
        msg_warn "NUT test failed (check driver compatibility)"
    fi

    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o GSSAPIAuthentication=no \
        -o PasswordAuthentication=no \
        -i "$TEMP_SSH_KEY" \
        "${VM_USER}@${VM_IP}" \
        "rm -f $remote_script_path" 2>/dev/null || true

    msg_ok "NUT installation complete"
}

run_nut_install() {
    build_nut_install_script
    deploy_nut_script
}

#===============================================================================
# Section 10: Final Summary Output
#===============================================================================

print_summary() {
    local summary_text
    summary_text="NUT VM Setup Complete!\n\n"
    summary_text+="  VM ID:      $VM_ID\n"
    summary_text+="  VM Name:    $VM_NAME\n"
    summary_text+="  VM IP:      $VM_IP\n\n"
    summary_text+="  NUT Server: ${VM_IP}:${NUT_LISTEN_PORT}\n"
    summary_text+="  UPS Name:   $NUT_UPS_NAME\n\n"
    summary_text+="  Test command:\n"
    summary_text+="    upsc ${NUT_UPS_NAME}@${VM_IP}\n\n"
    summary_text+="  Client upsmon.conf:\n"
    summary_text+="    MONITOR ${NUT_UPS_NAME}@${VM_IP}:${NUT_LISTEN_PORT} 1 ${NUT_MONITOR_USER} PASS slave"

    if [[ "$NUT_TEST_RESULT" == "FAIL" ]]; then
        summary_text+="\n\n⚠ NUT test failed — check driver selection\n"
        summary_text+="  Try: upsc ${NUT_UPS_NAME}@${VM_IP}"
    fi

    if [[ "$AUTO_GENERATE_PASSWORDS" == "true" && ${#GENERATED_PASSWORDS[@]} -gt 0 ]]; then
        summary_text+="\n\n⚠ AUTO-GENERATED PASSWORDS (save these!):\n"
        for pwd_entry in "${GENERATED_PASSWORDS[@]}"; do
            summary_text+="  $pwd_entry\n"
        done
    fi

    whiptail --backtitle "Proxmox VE Helper Scripts" \
             --title "SETUP COMPLETE" \
             --msgbox "$summary_text" 24 72

    echo
    echo -e "${GN}${CM}NUT VM setup completed successfully!${CL}"
    echo -e "${INFO}${YW}VM IP:      ${BGN}${VM_IP}${CL}"
    echo -e "${INFO}${YW}NUT Server: ${BGN}${VM_IP}:${NUT_LISTEN_PORT}${CL}"
    echo -e "${INFO}${YW}Test with:  ${BGN}upsc ${NUT_UPS_NAME}@${VM_IP}${CL}"

    if [[ "$AUTO_GENERATE_PASSWORDS" == "true" && ${#GENERATED_PASSWORDS[@]} -gt 0 ]]; then
        echo
        echo -e "${YW}⚠ Auto-generated passwords:${CL}"
        for pwd_entry in "${GENERATED_PASSWORDS[@]}"; do
            echo -e "  ${DGN}${pwd_entry}${CL}"
        done
    fi
    echo
}

#===============================================================================
# Main
#===============================================================================

main() {
    case "${1:-}" in
        --help|-h)
            echo "Usage: $0 [--version|--help]"
            echo
            echo "Creates an Ubuntu 24.04 VM on Proxmox and configures NUT netserver."
            echo
            echo "Options:"
            echo "  --help, -h      Show this help message"
            echo "  --version       Show version"
            echo
            echo "Environment:"
            echo "  VERBOSE=yes     Show full command output"
            exit 0
            ;;
        --version)
            echo "nut-vm-setup v${SCRIPT_VERSION}"
            exit 0
            ;;
    esac

    catch_errors

    header_info
    echo -e "${BOLD}  v${SCRIPT_VERSION}${CL}\n"

    check_root
    check_proxmox
    check_dependencies

    inject_ssh_key

    prompt_autogenerate_passwords
    collect_vm_config
    collect_nut_config

    if ! prompt_yes_no "NUT Configuration:\n\n  UPS Name:     $NUT_UPS_NAME\n  UPS Desc:     $NUT_UPS_DESC\n  Driver:       $NUT_DRIVER\n  Admin User:   $NUT_ADMIN_USER\n  Monitor User: $NUT_MONITOR_USER\n  Listen:       $NUT_LISTEN_ADDR:$NUT_LISTEN_PORT\n\nProceed with VM and NUT setup?" "y" "NUT CONFIGURATION SUMMARY"; then
        msg_error "Aborted by user"
    fi

    download_cloud_image
    create_vm
    detect_ups
    setup_usb_passthrough
    start_vm

    msg_info "Waiting ${VM_START_DELAY}s for VM to initialize"
    local remaining="$VM_START_DELAY"
    while [[ $remaining -gt 0 ]]; do
        printf "\r${YW}  ⏳${CL} %2d seconds remaining..." "$remaining"
        sleep 1
        ((remaining--))
    done
    echo
    msg_ok "VM initialization wait complete"

    get_vm_ip
    wait_ssh "$VM_IP" 22
    run_nut_install
    print_summary
}

trap '[[ -n "$SPINNER_PID" ]] && kill "$SPINNER_PID" 2>/dev/null; printf "\e[?25h"; echo -e "\n${RD}Interrupted${CL}"; exit 130' INT TERM

main "$@"
