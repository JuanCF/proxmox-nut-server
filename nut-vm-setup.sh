#!/bin/bash
#
# nut-vm-setup.sh - Proxmox NUT Server VM Setup Script
#
# Creates an Ubuntu 24.04 VM on Proxmox, configures USB passthrough for UPS,
# and installs/configures NUT (Network UPS Tools) in netserver mode.
#
# Must be run as root on a Proxmox host.

set -euo pipefail
IFS=$'\n\t'

#===============================================================================
# Section 0: Constants
#===============================================================================

readonly UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
readonly UBUNTU_IMG_NAME="noble-server-cloudimg-amd64.img"
readonly IMG_CACHE_DIR="/var/lib/vz/template/iso"
readonly NUT_DEFAULT_PORT=3493
readonly SSH_TIMEOUT=180
readonly SSH_POLL_INTERVAL=5
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
# Section 1: UI/Output Helper Functions
#===============================================================================

# Colors
readonly C_INFO='\033[0;36m'    # Cyan
readonly C_OK='\033[0;32m'     # Green
readonly C_WARN='\033[0;33m'   # Yellow
readonly C_ERROR='\033[0;31m' # Red
readonly C_RESET='\033[0m'    # Reset
readonly C_BOLD='\033[1m'     # Bold

# Spinner variables
SPINNER_PID=""
SPINNER_MSG=""

msg_info() {
    echo -e "${C_INFO}[INFO]${C_RESET} $1"
}

msg_ok() {
    echo -e "${C_OK}[OK]${C_RESET} $1"
}

msg_error() {
    echo -e "${C_ERROR}[ERROR]${C_RESET} $1" >&2
    exit 1
}

msg_warn() {
    echo -e "${C_WARN}[WARN]${C_RESET} $1"
}

msg_header() {
    local title="$1"
    local width=60
    local padding=$(( (width - ${#title} - 2) / 2 ))
    echo
    echo -e "${C_BOLD}╔$(printf '═%.0s' $(seq 1 $width))╗${C_RESET}"
    printf "${C_BOLD}║%${padding}s %s %${padding}s║${C_RESET}\n" "" "$title" ""
    echo -e "${C_BOLD}╚$(printf '═%.0s' $(seq 1 $width))╝${C_RESET}"
    echo
}

spinner_chars=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")

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

#===============================================================================
# Section 2: Input/Prompt Helper Functions
#===============================================================================

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

    while true; do
        read -rsp "${prompt_text}: " pass1
        echo
        read -rsp "Confirm password: " pass2
        echo
        if [[ "$pass1" == "$pass2" ]]; then
            printf -v "$varname" '%s' "$pass1"
            return 0
        else
            msg_warn "Passwords do not match. Please try again."
        fi
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

    echo
    echo -e "${C_BOLD}${title}${C_RESET}"
    for i in "${!items[@]}"; do
        echo "  $((i + 1)). ${items[$i]}"
    done

    while true; do
        read -rp "Select option (1-${#items[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#items[@]} )); then
            printf -v "$varname" '%s' "$((choice - 1))"
            return 0
        else
            msg_warn "Invalid selection. Please enter a number between 1 and ${#items[@]}."
        fi
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
        else
            msg_warn "Please enter a number between $min and $max."
        fi
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

    for cmd in ssh scp wget lsusb nc; do
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

    # Get next available VM ID
    VM_ID=$(get_next_vmid)
    prompt_integer VM_ID "VM ID" "$VM_ID" 100 999999999

    while ! validate_vmid "$VM_ID"; do
        msg_warn "VM ID $VM_ID is already in use"
        prompt_integer VM_ID "VM ID" "$((VM_ID + 1))" 100 999999999
    done

    # VM Name
    prompt_default VM_NAME "VM Hostname" "nut-server"

    # Storage pool
    mapfile -t storage_pools < <(list_storage_pools)
    storage_count=${#storage_pools[@]}

    if [[ $storage_count -eq 0 ]]; then
        msg_error "No storage pools found with 'images' content type"
    elif [[ $storage_count -eq 1 ]]; then
        VM_STORAGE="${storage_pools[0]}"
        msg_info "Using storage pool: $VM_STORAGE"
    else
        echo
        echo "Available storage pools:"
        local i
        for i in "${!storage_pools[@]}"; do
            echo "  $((i + 1)). ${storage_pools[$i]}"
        done
        local storage_idx
        prompt_menu storage_idx "Select storage pool:" "${storage_pools[@]}"
        VM_STORAGE="${storage_pools[$storage_idx]}"
    fi

    # Network bridge
    VM_BRIDGE="vmbr0"
    prompt_default VM_BRIDGE "Network bridge" "$VM_BRIDGE"

    while ! validate_bridge "$VM_BRIDGE"; do
        msg_warn "Bridge '$VM_BRIDGE' does not exist"
        prompt_default VM_BRIDGE "Network bridge" "vmbr0"
    done

    # RAM
    prompt_integer VM_RAM "RAM (MB)" "1024" 256 131072

    # CPU cores
    prompt_integer VM_CORES "CPU cores" "1" 1 128

    # Disk size
    prompt_integer VM_DISK_GB "Disk size (GB)" "8" 4 10240

    # VM user
    prompt_default VM_USER "VM username" "ubuntu"

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
# Section 5: NUT Configuration Prompts
#===============================================================================

collect_nut_config() {
    # UPS name and description
    prompt_default NUT_UPS_NAME "UPS name (identifier)" "ups"
    prompt_default NUT_UPS_DESC "UPS description" "My UPS"

    # Driver selection
    echo
    echo "Select NUT driver:"
    local sorted_keys=($(echo "${!UPS_DRIVERS[@]}" | tr ' ' '\n' | sort -n))
    for key in "${sorted_keys[@]}"; do
        echo "  $key. ${DRIVER_DESCS[$key]}"
    done

    local driver_choice
    prompt_menu driver_choice "Select driver:" "${DRIVER_DESCS[1]}" "${DRIVER_DESCS[2]}" "${DRIVER_DESCS[3]}"
    NUT_DRIVER="${UPS_DRIVERS[$((driver_choice + 1))]}"

    # Admin user
    prompt_default NUT_ADMIN_USER "NUT admin username" "admin"
    prompt_password NUT_ADMIN_PASS "NUT admin password"

    # Monitor user
    prompt_default NUT_MONITOR_USER "NUT monitor username" "monuser"
    prompt_password NUT_MONITOR_PASS "NUT monitor password"

    # Listen address and port
    prompt_default NUT_LISTEN_ADDR "NUT listen address" "0.0.0.0"
    prompt_integer NUT_LISTEN_PORT "NUT listen port" "3493" 1 65535
}

#===============================================================================
# Section 6: Cloud Image Download + VM Creation
#===============================================================================

download_cloud_image() {
    local img_path="$IMG_CACHE_DIR/$UBUNTU_IMG_NAME"

    if [[ -f "$img_path" ]]; then
        msg_info "Cloud image already exists, using cached version"
        return 0
    fi

    msg_info "Downloading Ubuntu 24.04 cloud image..."
    mkdir -p "$IMG_CACHE_DIR"

    spinner_start "Downloading Ubuntu 24.04 cloud image..."

    if command -v wget &>/dev/null; then
        if ! wget -q -c -O "$img_path.tmp" "$UBUNTU_IMG_URL" 2>/dev/null; then
            spinner_stop
            msg_error "Failed to download cloud image"
        fi
    elif command -v curl &>/dev/null; then
        if ! curl -sL --continue-at - -o "$img_path.tmp" "$UBUNTU_IMG_URL" 2>/dev/null; then
            spinner_stop
            msg_error "Failed to download cloud image"
        fi
    else
        spinner_stop
        msg_error "Neither wget nor curl is available"
    fi

    spinner_stop
    mv "$img_path.tmp" "$img_path"
    msg_ok "Cloud image downloaded"
}

inject_ssh_key() {
    TEMP_KEY_DIR="/tmp/nut-setup-$$"
    mkdir -p "$TEMP_KEY_DIR"

    # Generate temp SSH keypair
    ssh-keygen -t ed25519 -f "$TEMP_KEY_DIR/nut-setup-key" -N "" -C "nut-setup-temp" &>/dev/null

    TEMP_SSH_KEY="$TEMP_KEY_DIR/nut-setup-key"
    TEMP_SSH_PUB="$TEMP_KEY_DIR/nut-setup-key.pub"

    # Register cleanup trap
    cleanup_temp_keys() {
        if [[ -d "$TEMP_KEY_DIR" ]]; then
            rm -rf "$TEMP_KEY_DIR"
        fi
    }
    trap cleanup_temp_keys EXIT

    msg_ok "Generated temporary SSH keys"
}

create_vm() {
    local img_path="$IMG_CACHE_DIR/$UBUNTU_IMG_NAME"

    msg_info "Creating VM $VM_ID..."
    spinner_start "Creating VM..."

    # Create VM
    if ! qm create "$VM_ID" \
        --name "$VM_NAME" \
        --memory "$VM_RAM" \
        --cores "$VM_CORES" \
        --net0 "virtio,bridge=$VM_BRIDGE" \
        --ostype l26 \
        --agent "enabled=1" \
        --serial0 socket \
        --vga serial0 &>/dev/null; then
        spinner_stop
        msg_error "Failed to create VM"
    fi

    spinner_stop
    msg_ok "VM created"

    # Import disk
    msg_info "Importing disk..."
    spinner_start "Importing disk..."

    if ! qm importdisk "$VM_ID" "$img_path" "$VM_STORAGE" &>/dev/null; then
        spinner_stop
        msg_error "Failed to import disk"
    fi

    spinner_stop
    msg_ok "Disk imported"

    # Configure VM
    msg_info "Configuring VM..."

    qm set "$VM_ID" --scsihw virtio-scsi-pci &>/dev/null
    qm set "$VM_ID" --scsi0 "${VM_STORAGE}:vm-${VM_ID}-disk-0" &>/dev/null
    qm resize "$VM_ID" scsi0 "${VM_DISK_GB}G" &>/dev/null
    qm set "$VM_ID" --ide2 "${VM_STORAGE}:cloudinit" &>/dev/null
    qm set "$VM_ID" --boot c --bootdisk scsi0 &>/dev/null
    qm set "$VM_ID" --ipconfig0 "ip=dhcp" &>/dev/null
    qm set "$VM_ID" --ciuser "$VM_USER" &>/dev/null
    qm set "$VM_ID" --cipassword "$VM_PASSWORD" &>/dev/null
    qm set "$VM_ID" --sshkeys "$TEMP_SSH_PUB" &>/dev/null

    VM_CREATED=true
    msg_ok "VM configured"
}

#===============================================================================
# Section 7: USB Detection + Passthrough
#===============================================================================

detect_ups() {
    msg_info "Detecting USB UPS devices..."

    local usb_devices=()
    local device_info=()
    local i=0

    # Parse lsusb output
    while IFS= read -r line; do
        if [[ "$line" =~ Bus[[:space:]]([0-9]+)[[:space:]]Device[[:space:]]([0-9]+).+ID[[:space:]]([0-9a-f]{4}):([0-9a-f]{4})[[:space:]]*(.*) ]]; then
            local bus="${BASH_REMATCH[1]}"
            local device="${BASH_REMATCH[2]}"
            local vendor="${BASH_REMATCH[3]}"
            local product="${BASH_REMATCH[4]}"
            local name="${BASH_REMATCH[5]}"

            # Check if vendor is in our known list
            local vendor_name="${UPS_VENDORS[$vendor]:-Unknown}"

            # Add to list if it's a known UPS vendor or has UPS-like name
            if [[ -n "${UPS_VENDORS[$vendor]:-}" ]] || [[ "$name" =~ [Uu][Pp][Ss] ]]; then
                usb_devices+=("$vendor:$product")
                device_info+=("Bus $bus Device $device - $vendor_name ($vendor:$product) - $name")
                ((i++))
            fi
        fi
    done < <(lsusb 2>/dev/null)

    UPS_DEVICE_COUNT=$i

    if [[ $UPS_DEVICE_COUNT -eq 0 ]]; then
        msg_warn "No USB UPS devices detected"
        if prompt_yes_no "Enter UPS vendor:product manually?" "n"; then
            read -rp "Enter UPS vendor:product (e.g., 051d:0002): " UPS_VENDOR_PRODUCT
        fi
        return
    elif [[ $UPS_DEVICE_COUNT -eq 1 ]]; then
        msg_info "Found 1 UPS device: ${device_info[0]}"
        if prompt_yes_no "Use this device?" "y"; then
            UPS_VENDOR_PRODUCT="${usb_devices[0]}"
            UPS_BUS_PORT=""
        fi
    else
        echo
        echo "Multiple UPS devices found:"
        local idx
        for idx in "${!device_info[@]}"; do
            echo "  $((idx + 1)). ${device_info[$idx]}"
        done

        local choice
        prompt_menu choice "Select UPS device:" "${device_info[@]}"
        UPS_VENDOR_PRODUCT="${usb_devices[$choice]}"

        # Check for duplicates
        local duplicates=0
        local dev
        for dev in "${usb_devices[@]}"; do
            if [[ "$dev" == "$UPS_VENDOR_PRODUCT" ]]; then
                ((duplicates++))
            fi
        done

        if [[ $duplicates -gt 1 ]]; then
            msg_warn "Multiple devices with same ID detected, using bus-port notation"
            # Extract bus from selected device info
            if [[ "${device_info[$choice]}" =~ Bus[[:space:]]([0-9]+) ]]; then
                local bus="${BASH_REMATCH[1]}"
                UPS_BUS_PORT="$bus-1"
            fi
        fi
    fi
}

setup_usb_passthrough() {
    if [[ -z "${UPS_VENDOR_PRODUCT:-}" ]]; then
        msg_warn "No UPS device selected, skipping USB passthrough"
        return
    fi

    msg_info "Setting up USB passthrough for $UPS_VENDOR_PRODUCT..."

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
    msg_info "Starting VM $VM_ID..."

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

    msg_info "Waiting for SSH on $host:$port..."
    spinner_start "Waiting for SSH..."

    while [[ $elapsed -lt $timeout ]]; do
        if nc -z -w 2 "$host" "$port" 2>/dev/null; then
            spinner_stop
            msg_ok "SSH is available"
            return 0
        fi
        sleep "$SSH_POLL_INTERVAL"
        elapsed=$((elapsed + SSH_POLL_INTERVAL))
    done

    spinner_stop
    msg_error "SSH connection timed out after ${timeout}s"
}

get_vm_ip() {
    msg_info "Getting VM IP address..."
    spinner_start "Waiting for guest agent..."

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
            spinner_stop
            VM_IP="$ip"
            msg_ok "VM IP address: $VM_IP"
            return 0
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    spinner_stop
    msg_warn "Could not get IP from guest agent"
    read -rp "Enter VM IP address manually: " VM_IP

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

# Export variables for config file generation
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
NUT_SCRIPT
)

    # Substitute variables
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

    msg_info "Deploying NUT install script to VM..."
    spinner_start "Copying install script..."

    # Wait a bit for cloud-init to finish
    sleep 10

    # Copy script to VM
    local retry_count=0
    local max_retries=5

    while [[ $retry_count -lt $max_retries ]]; do
        if echo "$NUT_INSTALL_SCRIPT" | ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -i "$TEMP_SSH_KEY" \
            "${VM_USER}@${VM_IP}" \
            "cat > $remote_script_path" 2>/dev/null; then
            break
        fi
        sleep 10
        ((retry_count++))
    done

    if [[ $retry_count -eq $max_retries ]]; then
        spinner_stop
        msg_error "Failed to copy install script to VM"
    fi

    spinner_stop
    msg_ok "Install script copied"

    # Execute script
    msg_info "Running NUT install script on VM (this may take a few minutes)..."
    spinner_start "Installing NUT..."

    NUT_INSTALL_OUTPUT=$(ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ServerAliveInterval=30 \
        -i "$TEMP_SSH_KEY" \
        "${VM_USER}@${VM_IP}" \
        "sudo bash $remote_script_path" 2>&1) || true

    spinner_stop

    # Check for test result
    if echo "$NUT_INSTALL_OUTPUT" | grep -q "NUT_TEST_OK"; then
        NUT_TEST_RESULT="OK"
        msg_ok "NUT installation and test successful"
    else
        NUT_TEST_RESULT="FAIL"
        msg_warn "NUT test failed (check driver compatibility)"
    fi

    # Cleanup remote script
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -i "$TEMP_SSH_KEY" \
        "${VM_USER}@${VM_IP}" \
        "rm -f $remote_script_path" 2>/dev/null || true
}

run_nut_install() {
    build_nut_install_script
    deploy_nut_script
}

#===============================================================================
# Section 10: Final Summary Output
#===============================================================================

print_summary() {
    local width=60

    echo
    echo -e "${C_BOLD}╔$(printf '═%.0s' $(seq 1 $width))╗${C_RESET}"
    printf "${C_BOLD}║%$(( (width - 25) / 2 ))s%s%$(( (width - 25) / 2 ))s║${C_RESET}\n" "" "NUT VM Setup - Complete!" ""
    echo -e "${C_BOLD}╠$(printf '═%.0s' $(seq 1 $width))╣${C_RESET}"
    printf "${C_BOLD}║${C_RESET}  VM ID:          %-42s${C_BOLD}║${C_RESET}\n" "$VM_ID"
    printf "${C_BOLD}║${C_RESET}  VM Name:        %-42s${C_BOLD}║${C_RESET}\n" "$VM_NAME"
    printf "${C_BOLD}║${C_RESET}  VM IP:          %-42s${C_BOLD}║${C_RESET}\n" "$VM_IP"
    echo -e "${C_BOLD}║%-${width}s║${C_RESET}" ""
    printf "${C_BOLD}║${C_RESET}  NUT Server:     %-42s${C_BOLD}║${C_RESET}\n" "${VM_IP}:${NUT_LISTEN_PORT}"
    printf "${C_BOLD}║${C_RESET}  UPS Name:       %-42s${C_BOLD}║${C_RESET}\n" "$NUT_UPS_NAME"
    echo -e "${C_BOLD}║%-${width}s║${C_RESET}" ""
    printf "${C_BOLD}║${C_RESET}  Test command:                             ${C_BOLD}║${C_RESET}\n"
    printf "${C_BOLD}║${C_RESET}    upsc %s@${VM_IP}                ${C_BOLD}║${C_RESET}\n" "$NUT_UPS_NAME"
    echo -e "${C_BOLD}╠$(printf '═%.0s' $(seq 1 $width))╣${C_RESET}"
    printf "${C_BOLD}║${C_RESET}  Client upsmon.conf snippet:               ${C_BOLD}║${C_RESET}\n"
    printf "${C_BOLD}║${C_RESET}  MONITOR %s@%s:${NUT_LISTEN_PORT} 1 %s PASS slave  ${C_BOLD}║${C_RESET}\n" "$NUT_UPS_NAME" "$VM_IP" "$NUT_MONITOR_USER"

    if [[ "$NUT_TEST_RESULT" == "FAIL" ]]; then
        echo -e "${C_BOLD}╠$(printf '═%.0s' $(seq 1 $width))╣${C_RESET}"
        printf "${C_BOLD}║${C_RESET}  ${C_WARN}NOTE: NUT test failed - check driver selection${C_RESET}           ${C_BOLD}║${C_RESET}\n"
        printf "${C_BOLD}║${C_RESET}  ${C_INFO}Try: upsc %s@%s to troubleshoot${C_RESET}             ${C_BOLD}║${C_RESET}\n" "$NUT_UPS_NAME" "$VM_IP"
    fi

    echo -e "${C_BOLD}╚$(printf '═%.0s' $(seq 1 $width))╝${C_RESET}"
    echo
}

#===============================================================================
# Main
#===============================================================================

main() {
    # Parse CLI flags
    case "${1:-}" in
        --help|-h)
            echo "Usage: $0 [--version|--help]"
            echo
            echo "Creates an Ubuntu 24.04 VM on Proxmox and configures NUT netserver."
            echo
            echo "Options:"
            echo "  --help, -h      Show this help message"
            echo "  --version       Show version"
            exit 0
            ;;
        --version)
            echo "nut-vm-setup v${SCRIPT_VERSION}"
            exit 0
            ;;
    esac

    msg_header "Proxmox NUT Server VM Setup"

    # Prerequisite checks
    check_root
    check_proxmox
    check_dependencies

    # Generate SSH keys early for cleanup trap
    inject_ssh_key

    # Collect configuration
    collect_vm_config
    collect_nut_config

    # Print summary before proceeding
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

    # Download cloud image
    download_cloud_image

    # Create VM
    create_vm

    # Detect and setup USB passthrough
    detect_ups
    setup_usb_passthrough

    # Start VM
    start_vm

    # Get VM IP (must happen before wait_ssh)
    get_vm_ip

    # Wait for SSH
    wait_ssh "$VM_IP" 22

    # Install NUT
    run_nut_install

    # Print final summary
    print_summary
}

# Handle interrupts
trap 'msg_error "Interrupted by user"' INT TERM

main "$@"
