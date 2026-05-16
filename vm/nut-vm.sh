#!/usr/bin/env bash
#
# vm/nut-vm.sh - Proxmox NUT Server VM Setup Script
#
# Creates an Ubuntu 24.04 VM on Proxmox, configures USB passthrough for UPS,
# and installs/configures NUT (Network UPS Tools) in netserver mode.
#
# Must be run as root on a Proxmox host.

# Consumed by build.func via source on line 18 — shellcheck can’t follow non-constant sources.
# shellcheck disable=SC2034
APP="NUT VM"
var_tags="nut;vm;ups;network"
var_cpu="1"
var_ram="1024"
var_disk="8"
var_os="ubuntu"
var_version="24.04"

# These functions are fetched at runtime; shellcheck cannot statically analyze them.
# shellcheck disable=SC1090
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVED/main/misc/build.func)
# shellcheck disable=SC1090
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVED/main/misc/cloud-init.func)

SPINNER_PID=""
SCRIPT_ERROR_LOG=()

# build.func's msg_error prints but does not call exit; override to add exit 1
# so that check_root, check_proxmox, and whiptail cancellations abort the script.
msg_error() {
  [[ -n "${SPINNER_PID:-}" ]] && ps -p "${SPINNER_PID:-}" &>/dev/null && kill "${SPINNER_PID:-}"
  printf "\e[?25h"
  echo -e "${BFR}${CROSS}${RD}${1}${CL}"
  SCRIPT_ERROR_LOG+=("[ERROR] $1")
  SPINNER_PID=""
  exit 1
}

msg_warn() {
  SCRIPT_ERROR_LOG+=("[WARN] $1")
  echo -e "${BFR}${YW}${1}${CL}"
}

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
# Constants
#===============================================================================

readonly UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64.img"
readonly UBUNTU_IMG_CHECKSUM_URL="https://cloud-images.ubuntu.com/minimal/releases/noble/release/SHA256SUMS"
readonly UBUNTU_IMG_NAME="ubuntu-24.04-minimal-cloudimg-amd64.img"
readonly IMG_CACHE_DIR="/var/lib/vz/template/iso"
readonly NUT_DEFAULT_PORT=3493
readonly SSH_TIMEOUT=300
readonly SSH_POLL_INTERVAL=5
readonly SCRIPT_VERSION="1.0.0"

# UPS Vendor IDs
# shellcheck disable=SC2034
# shellcheck disable=SC2080
readonly -A UPS_VENDORS=(
  ["051d"]="APC"
  ["0764"]="CyberPower"
  ["0463"]="Eaton"
  ["09ae"]="Tripp Lite"
  ["10af"]="Liebert"
)

readonly -A UPS_DRIVERS=(
  [1]="usbhid-ups"
  [2]="blazer_usb"
  [3]="nutdrv_qx"
)

readonly -A DRIVER_DESCS=(
  [1]="usbhid-ups - APC, Eaton, CyberPower (recommended)"
  [2]="blazer_usb - Generic Megatec/Q1 protocol"
  [3]="nutdrv_qx - Newer generic USB devices"
)

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
    password=$(tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "$length" | head -n 1)
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
    if [[ "$input" =~ ^[0-9]+$ ]] && ((input >= min && input <= max)); then
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

  for cmd in qm pvesh pveversion pvesm python3; do
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

  for cmd in ssh scp wget curl lsusb whiptail timeout openssl ssh-keygen ip sha256sum dpkg; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    msg_error "Missing required dependencies: ${missing[*]}"
  fi
  msg_ok "Dependencies satisfied"
}

check_architecture() {
  local arch
  arch=$(dpkg --print-architecture)
  if [[ "$arch" != "amd64" ]]; then
    echo -e "\n ${INFO}${YW}This script requires an amd64 Proxmox host (detected: ${arch})."
    echo -e " ${YW}The Ubuntu Noble cloud image ships amd64 only."
    sleep 2
    exit 1
  fi
  msg_ok "Architecture: amd64"
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

  NUT_DRIVER="usbhid-ups"

  prompt_default NUT_ADMIN_USER "NUT admin username" "admin" "NUT ADMIN USER"
  prompt_password NUT_ADMIN_PASS "NUT admin password"
  prompt_default NUT_MONITOR_USER "NUT monitor username" "monuser" "NUT MONITOR USER"
  prompt_password NUT_MONITOR_PASS "NUT monitor password"
  prompt_default NUT_LISTEN_ADDR "NUT listen address" "0.0.0.0" "NUT LISTEN ADDRESS"
  prompt_integer NUT_LISTEN_PORT "NUT listen port" "$NUT_DEFAULT_PORT" 1 65535
}

#===============================================================================
# Section 6: Storage Type Detection
#===============================================================================

determine_storage_type() {
  STORAGE_TYPE=$(pvesm status -storage "$VM_STORAGE" | awk 'NR>1 {print $2}')
  case $STORAGE_TYPE in
  nfs | dir | cifs)
    DISK_EXT=".qcow2"
    DISK_REF_PREFIX="${VM_ID}/"
    DISK_IMPORT=(--format qcow2)
    ;;
  btrfs)
    DISK_EXT=".raw"
    DISK_REF_PREFIX="${VM_ID}/"
    DISK_IMPORT=(--format raw)
    ;;
  *)
    DISK_EXT=""
    DISK_REF_PREFIX=""
    DISK_IMPORT=(--format raw)
    ;;
  esac
  DISK0="vm-${VM_ID}-disk-0${DISK_EXT}"
  DISK0_REF="${VM_STORAGE}:${DISK_REF_PREFIX}${DISK0}"
}

#===============================================================================
# Section 7: Cloud Image Download + SSH Key + Cloud-Init Snippet
#===============================================================================

download_cloud_image() {
  local img_path="$IMG_CACHE_DIR/$UBUNTU_IMG_NAME"

  if [[ -f "$img_path" ]]; then
    msg_info "Verifying cached Ubuntu 24.04 cloud image"
    local expected_sha
    expected_sha=$(curl -fsSL "$UBUNTU_IMG_CHECKSUM_URL" | grep " \*\?${UBUNTU_IMG_NAME}$" | awk '{print $1}')
    if [[ -n "$expected_sha" ]] && echo "${expected_sha}  ${img_path}" | sha256sum -c --status 2>/dev/null; then
      msg_ok "Using cached Ubuntu 24.04 cloud image (checksum verified)"
      return 0
    fi
    msg_info "Cached image checksum mismatch — re-downloading"
    rm -f "$img_path"
  fi

  msg_info "Downloading Ubuntu 24.04 cloud image"
  mkdir -p "$IMG_CACHE_DIR"

  if ! wget -q -c -O "${img_path}.tmp" "$UBUNTU_IMG_URL" 2>/dev/null; then
    msg_error "Failed to download cloud image"
  fi

  mv "${img_path}.tmp" "$img_path"

  msg_info "Verifying SHA-256 checksum"
  local expected_sha
  expected_sha=$(curl -fsSL "$UBUNTU_IMG_CHECKSUM_URL" | grep " \*\?${UBUNTU_IMG_NAME}$" | awk '{print $1}')
  if [[ -z "$expected_sha" ]]; then
    msg_error "Could not fetch checksum for $UBUNTU_IMG_NAME"
  fi
  if ! echo "${expected_sha}  ${img_path}" | sha256sum -c --status; then
    rm -f "$img_path"
    msg_error "SHA-256 checksum verification failed — image may be corrupt"
  fi

  msg_ok "Downloaded and verified Ubuntu 24.04 cloud image"
}

inject_ssh_key() {
  TEMP_KEY_DIR="/tmp/nut-setup-$$"
  mkdir -p "$TEMP_KEY_DIR"

  $STD ssh-keygen -t ed25519 -f "$TEMP_KEY_DIR/nut-setup-key" -N "" -C "nut-setup-temp"

  TEMP_SSH_KEY="$TEMP_KEY_DIR/nut-setup-key"
  TEMP_SSH_PUB="$TEMP_KEY_DIR/nut-setup-key.pub"

  cleanup_temp_keys() {
    [[ -d "$TEMP_KEY_DIR" ]] && rm -rf "$TEMP_KEY_DIR"
  }
  trap cleanup_temp_keys EXIT

  msg_ok "Generated temporary SSH keys"
}

generate_cloudinit_snippet() {
  local snippet_path="/var/lib/vz/snippets/nut-vm-${VM_ID}-cloudinit.yaml"
  CLOUDINIT_SNIPPET=""

  local cfg_content
  cfg_content=$(awk '$1 == "dir:" && $2 == "local" {f=1} f && /content/{print $2; exit}' /etc/pve/storage.cfg 2>/dev/null || echo "")
  if [[ "$cfg_content" != *snippets* ]]; then
    if [[ -n "$cfg_content" ]]; then
      pvesm set local --content "${cfg_content},snippets" 2>/dev/null || true
    else
      pvesm set local --content "vztmpl,iso,backup,snippets" 2>/dev/null || true
    fi
    # Re-read config to confirm the update took effect
    cfg_content=$(awk '$1 == "dir:" && $2 == "local" {f=1} f && /content/{print $2; exit}' /etc/pve/storage.cfg 2>/dev/null || echo "")
    if [[ "$cfg_content" != *snippets* ]]; then
      msg_warn "Could not enable snippets on local storage — vendor cloud-init snippet will be skipped"
      msg_warn "VM IP detection will fall back to manual entry after boot"
      return 0
    fi
  fi

  mkdir -p "/var/lib/vz/snippets"

  # Embed the user-supplied password into the vendor snippet so it never
  # appears on a Proxmox command line.  Residual risk: password at rest in
  # /var/lib/vz/snippets until the file is manually removed.
  python3 -c "
import sys
with open(sys.argv[1], 'w') as f:
    f.write('#cloud-config\n')
    f.write('chpasswd:\n')
    f.write('  list: |\n')
    f.write('    ' + sys.argv[2] + ':' + sys.argv[3] + '\n')
    f.write('  expire: False\n')
    f.write('ssh_pwauth: True\n')
    f.write('package_update: true\n')
    f.write('packages:\n')
    f.write('  - qemu-guest-agent\n')
    f.write('runcmd:\n')
    f.write('  - systemctl enable --now qemu-guest-agent\n')
" "$snippet_path" "$VM_USER" "$VM_PASSWORD"
  chmod 600 "$snippet_path"

  CLOUDINIT_SNIPPET="$snippet_path"
  msg_ok "Generated cloud-init snippet"
}

#===============================================================================
# Section 8: VM Creation
#===============================================================================

create_vm() {
  local img_path="$IMG_CACHE_DIR/$UBUNTU_IMG_NAME"

  generate_cloudinit_snippet
  determine_storage_type

  msg_info "Creating VM $VM_ID"
  $STD qm create "$VM_ID" \
    --name "$VM_NAME" \
    --memory "$VM_RAM" \
    --cores "$VM_CORES" \
    --net0 "virtio,bridge=$VM_BRIDGE" \
    --ostype l26 \
    --agent enabled=1 \
    --serial0 socket \
    --vga serial0 \
    --onboot 1 \
    --tags 'community-script;nut;network;ups'
  msg_ok "Created VM $VM_ID"

  msg_info "Importing disk image"
  [[ "${VERBOSE:-}" == "yes" ]] && set -x
  if ! $STD qm importdisk "$VM_ID" "$img_path" "$VM_STORAGE" "${DISK_IMPORT[@]}"; then
    msg_error "Failed to import disk"
  fi
  [[ "${VERBOSE:-}" == "yes" ]] && set +x
  msg_ok "Imported disk image"

  msg_info "Configuring VM"
  $STD qm set "$VM_ID" --scsihw virtio-scsi-pci
  $STD qm set "$VM_ID" --scsi0 "${DISK0_REF}"
  $STD qm resize "$VM_ID" scsi0 "${VM_DISK_GB}G"
  $STD qm set "$VM_ID" --boot c --bootdisk scsi0

  # setup_cloud_init generates a random password; the real password is injected
  # via the vendor cloud-init snippet (see generate_cloudinit_snippet) so it
  # never appears on a Proxmox command line.
  # CLOUDINIT_SSH_KEYS is read by cloud-init.func (sourced on line 19); shellcheck
  # can’t track usage across non-constant source directives.
  # shellcheck disable=SC2034
  CLOUDINIT_SSH_KEYS="$TEMP_SSH_PUB"
  setup_cloud_init "$VM_ID" "$VM_STORAGE" "$VM_NAME" "yes" "$VM_USER"
  # Vendor snippet installs qemu-guest-agent and sets the user password on first
  # boot (required for get_vm_ip and for SSH login).
  if [[ -n "${CLOUDINIT_SNIPPET:-}" ]]; then
    $STD qm set "$VM_ID" --cicustom "vendor=local:snippets/nut-vm-${VM_ID}-cloudinit.yaml"
  fi

  msg_ok "VM configured"
}

#===============================================================================
# Section 9: USB Detection + Passthrough
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
  done <<<"$lsusb_output"

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
      if [[ "${device_info[$choice]}" =~ Bus[[:space:]]([0-9]+)[[:space:]]Device[[:space:]]([0-9]+) ]]; then
        local bus="${BASH_REMATCH[1]}"
        local devnum="${BASH_REMATCH[2]}"
        local port="1"
        local sysdev
        for sysdev in /sys/bus/usb/devices/*/; do
          local dev_bus dev_num devpath
          dev_bus=$(cat "${sysdev}busnum" 2>/dev/null) || continue
          dev_num=$(cat "${sysdev}devnum" 2>/dev/null) || continue
          if [[ "$((10#$dev_bus))" == "$((10#$bus))" && "$((10#$dev_num))" == "$((10#$devnum))" ]]; then
            devpath=$(basename "$sysdev")
            if [[ "$devpath" =~ ^[0-9]+-([0-9]+) ]]; then
              port="${BASH_REMATCH[1]}"
            fi
            break
          fi
        done
        UPS_BUS_PORT="${bus}-${port}"
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

  if $STD qm set "$VM_ID" --usb0 "$usb_param"; then
    msg_ok "USB passthrough configured"
  else
    msg_warn "Failed to set USB passthrough (continuing anyway)"
  fi
}

#===============================================================================
# Section 10: VM Boot + SSH Readiness Wait
#===============================================================================

start_vm() {
  msg_info "Starting VM $VM_ID"

  if ! $STD qm start "$VM_ID"; then
    msg_error "Failed to start VM"
  fi

  msg_ok "VM started"
}

wait_ssh() {
  local host="$1"
  local port="${2:-22}"
  local timeout="${3:-$SSH_TIMEOUT}"
  local start=$SECONDS
  local last_report=0

  msg_info "Waiting for SSH on $host:$port"

  while ((SECONDS - start < timeout)); do
    if timeout 2 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null; then
      msg_ok "SSH is available on $host"
      return 0
    fi
    local elapsed=$((SECONDS - start))
    if ((elapsed - last_report >= 30)); then
      msg_info "Still waiting for SSH on $host:$port (${elapsed}s elapsed)"
      last_report=$elapsed
    fi
    sleep "$SSH_POLL_INTERVAL"
  done

  msg_error "SSH connection timed out after ${timeout}s — verify the VM has network access and SSH is running"
}

get_vm_ip() {
  # Wait for the qemu-guest-agent installed by the cloud-init snippet.
  # Once cloud-init finishes (~3-5 min on first boot), the agent reports IPs directly.
  msg_info "Waiting for VM guest agent (cloud-init installs it on first boot, ~3-5 min)"

  local ip="" node elapsed=0 max_wait=120
  node=$(hostname)

  while [[ $elapsed -lt $max_wait ]]; do
    ip=$(pvesh get "/nodes/${node}/qemu/${VM_ID}/agent/network-get-interfaces" \
      --output-format json 2>/dev/null | python3 -c "
import sys, json
try:
    for iface in json.load(sys.stdin).get('result', []):
        for a in iface.get('ip-addresses', []):
            addr = a.get('ip-address', '')
            if (a.get('ip-address-type') == 'ipv4'
                    and not addr.startswith('127.')
                    and not addr.startswith('169.254.')):
                print(addr)
                sys.exit(0)
except Exception:
    pass
" 2>/dev/null) || true

    if [[ -n "$ip" ]]; then
      VM_IP="$ip"
      msg_ok "VM IP address: $VM_IP"
      return 0
    fi

    sleep 15
    elapsed=$((elapsed + 15))
    [[ $((elapsed % 60)) -eq 0 ]] && msg_info "Still waiting for guest agent (${elapsed}s elapsed)"
  done

  msg_warn "Guest agent did not respond after ${max_wait}s"
  VM_IP=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
    --title "VM IP ADDRESS" \
    --inputbox "Enter VM IP address manually:" \
    8 58 "" 3>&1 1>&2 2>&3) || msg_error "No IP address provided"
  [[ -z "$VM_IP" ]] && msg_error "No IP address provided"
}

#===============================================================================
# Section 11: NUT Install & NUT Admin Deploy
#===============================================================================

build_nut_install_script() {
  local nut_conf_b64 ups_conf_b64 upsd_conf_b64 upsd_users_b64 upsmon_conf_b64

  nut_conf_b64=$(printf '%s\n' 'MODE=netserver' | base64 -w0)
  ups_conf_b64=$(printf '[%s]\n  driver = %s\n  port = auto\n  desc = "%s"\n  pollinterval = 2\n' "$NUT_UPS_NAME" "$NUT_DRIVER" "$NUT_UPS_DESC" | base64 -w0)
  upsd_conf_b64=$(printf 'LISTEN %s %s\nMAXAGE 15\nSTATEPATH /var/run/nut\n' "$NUT_LISTEN_ADDR" "$NUT_LISTEN_PORT" | base64 -w0)
  upsd_users_b64=$(printf '[%s]\n  password = %s\n  actions = SET\n  instcmds = ALL\n\n[%s]\n  password = %s\n  upsmon master\n' "$NUT_ADMIN_USER" "$NUT_ADMIN_PASS" "$NUT_MONITOR_USER" "$NUT_MONITOR_PASS" | base64 -w0)
  upsmon_conf_b64=$(
    printf '%s\n' \
      "MONITOR ${NUT_UPS_NAME}@localhost:${NUT_LISTEN_PORT} 1 ${NUT_MONITOR_USER} ${NUT_MONITOR_PASS} master" \
      "" \
      "MINSUPPLIES 1" \
      'SHUTDOWNCMD "/sbin/shutdown -h +0"' \
      "POLLFREQ 5" \
      "POLLFREQALERT 5" \
      "HOSTSYNC 15" \
      "DEADTIME 15" \
      "POWERDOWNFLAG /etc/killpower" \
      "" \
      'NOTIFYMSG ONLINE    "UPS %s on line power"' \
      'NOTIFYMSG ONBATT    "UPS %s on battery"' \
      'NOTIFYMSG LOWBATT   "UPS %s battery is low"' \
      'NOTIFYMSG COMMOK    "Communications with UPS %s established"' \
      'NOTIFYMSG COMMBAD   "Communications with UPS %s lost"' \
      'NOTIFYMSG SHUTDOWN  "UPS %s forcing system shutdown"' \
      "" \
      "NOTIFYFLAG ONLINE   SYSLOG+WALL" \
      "NOTIFYFLAG ONBATT   SYSLOG+WALL" \
      "NOTIFYFLAG LOWBATT  SYSLOG+WALL" \
      "RBWARNTIME 43200" \
      "NOCOMMWARNTIME 300" \
      "FINALDELAY 5" |
      base64 -w0
  )

  NUT_INSTALL_SCRIPT=$(
    cat <<'NUT_SCRIPT'
#!/usr/bin/env bash
set -e

UPS_NAME="__UPS_NAME__"
UPS_DESC="__UPS_DESC__"
DRIVER="__DRIVER__"
ADMIN_USER="__ADMIN_USER__"
MONITOR_USER="__MONITOR_USER__"
LISTEN_ADDR="__LISTEN_ADDR__"
LISTEN_PORT="__LISTEN_PORT__"

echo "[NUT-INSTALL] Waiting for cloud-init to finish..."
cloud-init status --wait >/dev/null 2>&1 || true

echo "[NUT-INSTALL] Waiting for apt lock..."
APT_LOCK_MAX=30
APT_LOCK_WAIT=0
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
  if [[ $APT_LOCK_WAIT -ge $APT_LOCK_MAX ]]; then
    echo "[NUT-INSTALL-ERROR] apt lock is still held after $((APT_LOCK_MAX * 2)) seconds, aborting."
    exit 1
  fi
  sleep 2
  ((APT_LOCK_WAIT++))
done

echo "[NUT-INSTALL] Updating packages..."
apt-get update -qq >/dev/null 2>&1

echo "[NUT-INSTALL] Installing NUT packages..."
apt-get install -y -qq nut-server nut-client usbutils libusb-1.0-0 libsnmp40 libneon27-gnutls libavahi-client3 libfreeipmi17 libupsclient6 >/dev/null 2>&1

echo "[NUT-INSTALL] Creating library symlinks for nut-scanner..."
ln -sf /usr/lib/x86_64-linux-gnu/libusb-1.0.so.0 /usr/lib/x86_64-linux-gnu/libusb-1.0.so 2>/dev/null || true
ln -sf /usr/lib/x86_64-linux-gnu/libnetsnmp.so.40 /usr/lib/x86_64-linux-gnu/libnetsnmp.so 2>/dev/null || true
ln -sf /usr/lib/x86_64-linux-gnu/libneon-gnutls.so.27 /usr/lib/x86_64-linux-gnu/libneon.so 2>/dev/null || true
ln -sf /usr/lib/x86_64-linux-gnu/libavahi-client.so.3 /usr/lib/x86_64-linux-gnu/libavahi-client.so 2>/dev/null || true
ln -sf /usr/lib/x86_64-linux-gnu/libfreeipmi.so.17 /usr/lib/x86_64-linux-gnu/libfreeipmi.so 2>/dev/null || true
ln -sf /usr/lib/x86_64-linux-gnu/libupsclient.so.6 /usr/lib/x86_64-linux-gnu/libupsclient.so 2>/dev/null || true

echo "[NUT-INSTALL] Waiting for UPS device..."
for i in {1..12}; do
    if lsusb 2>/dev/null | grep -qiE "(apc|cyberpower|eaton|tripplite|liebert|ups)"; then
        echo "[NUT-INSTALL] UPS device detected"
        break
    fi
    if [[ $i -eq 12 ]]; then
        echo "[NUT-INSTALL-WARN] UPS device not detected after 60 seconds"
    fi
    sleep 5
done

echo "[NUT-INSTALL] Configuring NUT..."

echo '__NUT_CONF_B64__' | base64 -d > /etc/nut/nut.conf

echo "[NUT-INSTALL] Detecting UPS driver with nut-scanner..."
NUT_SCANNER_OUTPUT=$(nut-scanner -U 2>/dev/null || true)

if [[ -n "$NUT_SCANNER_OUTPUT" ]] && echo "$NUT_SCANNER_OUTPUT" | grep -q "driver"; then
    echo "[NUT-INSTALL] UPS auto-detected by nut-scanner"
    DETECTED_DRIVER=$(echo "$NUT_SCANNER_OUTPUT" | awk -F'"' '/driver[[:space:]]*=/ {print $2; exit}')
    DETECTED_PORT=$(echo "$NUT_SCANNER_OUTPUT" | awk -F'"' '/^[[:space:]]+port[[:space:]]*=/ {print $2; exit}')
    DETECTED_VENDORID=$(echo "$NUT_SCANNER_OUTPUT" | awk -F'"' '/vendorid[[:space:]]*=/ {print $2; exit}')
    DETECTED_PRODUCTID=$(echo "$NUT_SCANNER_OUTPUT" | awk -F'"' '/productid[[:space:]]*=/ {print $2; exit}')

    {
        printf '[%s]\n' "$UPS_NAME"
        printf '  driver = %s\n' "${DETECTED_DRIVER:-$DRIVER}"
        printf '  port = %s\n' "${DETECTED_PORT:-auto}"
        [[ -n "$DETECTED_VENDORID" ]] && printf '  vendorid = %s\n' "$DETECTED_VENDORID"
        [[ -n "$DETECTED_PRODUCTID" ]] && printf '  productid = %s\n' "$DETECTED_PRODUCTID"
        printf '  desc = "%s"\n' "$UPS_DESC"
        printf '  pollinterval = 2\n'
    } > /etc/nut/ups.conf
else
    echo "[NUT-INSTALL] nut-scanner did not detect UPS, using fallback driver: $DRIVER"
    echo '__UPS_CONF_B64__' | base64 -d > /etc/nut/ups.conf
fi

echo '__UPSD_CONF_B64__' | base64 -d > /etc/nut/upsd.conf
echo '__UPSD_USERS_B64__' | base64 -d > /etc/nut/upsd.users
echo '__UPSMON_CONF_B64__' | base64 -d > /etc/nut/upsmon.conf

echo "[NUT-INSTALL] Setting permissions..."
chown root:nut /etc/nut/*.conf
chmod 640 /etc/nut/*.conf

mkdir -p /var/run/nut
chown nut:nut /var/run/nut

echo "[NUT-INSTALL] Starting NUT services..."
set +e

if systemctl list-unit-files 'nut-driver-enumerator.service' >/dev/null 2>&1; then
  systemctl daemon-reload
  if ! systemctl enable nut-server nut-monitor nut-driver-enumerator.service nut-driver-enumerator.path nut-driver.target >/dev/null 2>&1; then
    echo "[NUT-INSTALL-WARN] Failed to enable NUT services"
  fi
  if ! systemctl restart nut-driver-enumerator.service >/dev/null 2>&1; then
    echo "[NUT-INSTALL-WARN] nut-driver-enumerator restart failed"
  fi
elif systemctl list-unit-files 'nut-driver@.service' >/dev/null 2>&1; then
  systemctl daemon-reload
  if ! systemctl enable "nut-driver@${UPS_NAME}" nut-server nut-monitor >/dev/null 2>&1; then
    echo "[NUT-INSTALL-WARN] Failed to enable NUT services"
  fi
  if ! systemctl restart "nut-driver@${UPS_NAME}" >/dev/null 2>&1; then
    echo "[NUT-INSTALL-WARN] nut-driver@${UPS_NAME} restart failed"
  fi
else
  if ! systemctl enable nut-driver nut-server nut-monitor >/dev/null 2>&1; then
    echo "[NUT-INSTALL-WARN] Failed to enable NUT services"
  fi
  if ! systemctl restart nut-driver >/dev/null 2>&1; then
    echo "[NUT-INSTALL-WARN] nut-driver restart failed"
  fi
fi

sleep 3
if ! systemctl restart nut-server nut-monitor >/dev/null 2>&1; then
  echo "[NUT-INSTALL-WARN] nut-server/nut-monitor restart failed"
fi
set -e

echo "[NUT-INSTALL] Complete!"
NUT_SCRIPT
  )

  NUT_INSTALL_SCRIPT=$(
    export PY_NUT_UPS_NAME="$NUT_UPS_NAME"
    export PY_NUT_UPS_DESC="$NUT_UPS_DESC"
    export PY_NUT_DRIVER="$NUT_DRIVER"
    export PY_NUT_ADMIN_USER="$NUT_ADMIN_USER"
    export PY_NUT_MONITOR_USER="$NUT_MONITOR_USER"
    export PY_NUT_LISTEN_ADDR="$NUT_LISTEN_ADDR"
    export PY_NUT_LISTEN_PORT="$NUT_LISTEN_PORT"
    export PY_NUT_CONF_B64="$nut_conf_b64"
    export PY_UPS_CONF_B64="$ups_conf_b64"
    export PY_UPSD_CONF_B64="$upsd_conf_b64"
    export PY_UPSD_USERS_B64="$upsd_users_b64"
    export PY_UPSMON_CONF_B64="$upsmon_conf_b64"
    python3 -c "
import os, sys
script = sys.stdin.read()
script = script.replace('__UPS_NAME__', os.environ['PY_NUT_UPS_NAME'])
script = script.replace('__UPS_DESC__', os.environ['PY_NUT_UPS_DESC'])
script = script.replace('__DRIVER__', os.environ['PY_NUT_DRIVER'])
script = script.replace('__ADMIN_USER__', os.environ['PY_NUT_ADMIN_USER'])
script = script.replace('__MONITOR_USER__', os.environ['PY_NUT_MONITOR_USER'])
script = script.replace('__LISTEN_ADDR__', os.environ['PY_NUT_LISTEN_ADDR'])
script = script.replace('__LISTEN_PORT__', os.environ['PY_NUT_LISTEN_PORT'])
script = script.replace('__NUT_CONF_B64__', os.environ['PY_NUT_CONF_B64'])
script = script.replace('__UPS_CONF_B64__', os.environ['PY_UPS_CONF_B64'])
script = script.replace('__UPSD_CONF_B64__', os.environ['PY_UPSD_CONF_B64'])
script = script.replace('__UPSD_USERS_B64__', os.environ['PY_UPSD_USERS_B64'])
script = script.replace('__UPSMON_CONF_B64__', os.environ['PY_UPSMON_CONF_B64'])
print(script, end='')
" <<<"$NUT_INSTALL_SCRIPT"
  )
}

build_nut_admin_script() {
  local nut_admin_url_prefix
  nut_admin_url_prefix="${NUT_ADMIN_URL_PREFIX:-https://raw.githubusercontent.com/JuanCF/proxmox-nut-server/main}"

  NUT_ADMIN_SCRIPT=$(
    cat <<'NUT_ADMIN_HEREDOC'
#!/usr/bin/env bash
NUT_ADMIN_URL="__NUT_ADMIN_URL_PREFIX__"
NUT_ADMIN_FAIL=0
NUT_ADMIN_ERROR_LOG=""

echo "[NUT-ADMIN] Installing NUT Admin web interface..."

echo "[NUT-ADMIN] Installing dependencies..."
if ! apt-get update -qq >/dev/null 2>&1; then
  NUT_ADMIN_ERROR_LOG+="[NUT-ADMIN-ERROR] apt-get update failed\n"
  NUT_ADMIN_FAIL=1
fi

if [[ $NUT_ADMIN_FAIL -eq 0 ]] && ! apt-get install -y -qq python3-venv python3-pip curl >/dev/null 2>&1; then
  NUT_ADMIN_ERROR_LOG+="[NUT-ADMIN-ERROR] apt-get install failed\n"
  NUT_ADMIN_FAIL=1
fi

if [[ $NUT_ADMIN_FAIL -eq 0 ]]; then
  echo "[NUT-ADMIN] Creating application directory..."
  mkdir -p /opt/nut-admin/static

  echo "[NUT-ADMIN] Downloading admin files..."
  if ! curl -fsSL "${NUT_ADMIN_URL}/src/nut-admin/app.py" -o /opt/nut-admin/app.py; then
    NUT_ADMIN_ERROR_LOG+="[NUT-ADMIN-ERROR] Failed to download app.py\n"
    NUT_ADMIN_FAIL=1
  fi
  if ! curl -fsSL "${NUT_ADMIN_URL}/src/nut-admin/static/index.html" -o /opt/nut-admin/static/index.html; then
    NUT_ADMIN_ERROR_LOG+="[NUT-ADMIN-ERROR] Failed to download index.html\n"
    NUT_ADMIN_FAIL=1
  fi
  if ! curl -fsSL "${NUT_ADMIN_URL}/src/nut-admin/nut-admin.service" -o /etc/systemd/system/nut-admin.service; then
    NUT_ADMIN_ERROR_LOG+="[NUT-ADMIN-ERROR] Failed to download nut-admin.service\n"
    NUT_ADMIN_FAIL=1
  fi
fi

if [[ $NUT_ADMIN_FAIL -eq 0 ]]; then
  echo "[NUT-ADMIN] Setting up Python virtual environment..."
  if ! python3 -m venv /opt/nut-admin/venv >/dev/null 2>&1; then
    NUT_ADMIN_ERROR_LOG+="[NUT-ADMIN-ERROR] python3 -m venv failed\n"
    NUT_ADMIN_FAIL=1
  elif ! /opt/nut-admin/venv/bin/pip install --quiet flask >/dev/null 2>&1; then
    NUT_ADMIN_ERROR_LOG+="[NUT-ADMIN-ERROR] pip install flask failed\n"
    NUT_ADMIN_FAIL=1
  fi
fi

if [[ $NUT_ADMIN_FAIL -eq 0 ]]; then
  echo "[NUT-ADMIN] Enabling systemd service..."
  systemctl daemon-reload
  systemctl enable nut-admin

  echo "[NUT-ADMIN] Starting service..."
  if systemctl restart nut-admin; then
    VM_IP="$(hostname -I | awk '{print $1}')"
    echo ""
    echo "NUT Admin web interface installed and running."
    echo "URL: http://${VM_IP}:8081"
    echo "NUT_ADMIN_OK"
  else
    NUT_ADMIN_ERROR_LOG+="[NUT-ADMIN-ERROR] systemctl restart nut-admin failed\n"
    NUT_ADMIN_FAIL=1
  fi
fi

if [[ $NUT_ADMIN_FAIL -ne 0 ]]; then
  echo "NUT_ADMIN_FAIL"
  echo "NUT_ADMIN_ERROR_LOG_START"
  echo -e "$NUT_ADMIN_ERROR_LOG"
  echo "NUT_ADMIN_ERROR_LOG_END"
fi
NUT_ADMIN_HEREDOC
  )

  NUT_ADMIN_SCRIPT=$(
    export PY_NUT_ADMIN_URL_PREFIX="$nut_admin_url_prefix"
    python3 -c "
import os, sys
script = sys.stdin.read()
script = script.replace('__NUT_ADMIN_URL_PREFIX__', os.environ['PY_NUT_ADMIN_URL_PREFIX'])
print(script, end='')
" <<<"$NUT_ADMIN_SCRIPT"
  )
}

deploy_nut_script() {
  local remote_script_path="/tmp/nut-install.sh"

  msg_info "Deploying NUT install script to VM"

  sleep 20

  local retry_count=0
  local max_retries=5
  local local_script
  local_script=$(mktemp /tmp/nut-install-XXXXXX.sh)
  chmod 600 "$local_script"
  printf '%s\n' "$NUT_INSTALL_SCRIPT" >"$local_script"

  while [[ $retry_count -lt $max_retries ]]; do
    if scp -q -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 \
      -o GSSAPIAuthentication=no \
      -o PasswordAuthentication=no \
      -i "$TEMP_SSH_KEY" \
      "$local_script" \
      "${VM_USER}@${VM_IP}:$remote_script_path" 2>/dev/null; then
      break
    fi
    sleep 10
    ((retry_count++))
  done

  rm -f "$local_script"

  if [[ $retry_count -eq $max_retries ]]; then
    msg_error "Failed to copy install script to VM"
  fi

  ssh -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    -o GSSAPIAuthentication=no \
    -o PasswordAuthentication=no \
    -i "$TEMP_SSH_KEY" \
    "${VM_USER}@${VM_IP}" \
    "chmod +x $remote_script_path" 2>/dev/null || true

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

  while IFS= read -r line; do
    [[ "$line" =~ \[NUT-INSTALL-(WARN|ERROR)\] ]] && SCRIPT_ERROR_LOG+=("$line")
  done <<<"$NUT_INSTALL_OUTPUT"

  msg_ok "NUT install script completed"

  ssh -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o GSSAPIAuthentication=no \
    -o PasswordAuthentication=no \
    -i "$TEMP_SSH_KEY" \
    "${VM_USER}@${VM_IP}" \
    "rm -f $remote_script_path" 2>/dev/null || true
}

deploy_nut_admin_script() {
  local remote_script_path="/tmp/nut-admin-install.sh"

  msg_info "Deploying NUT Admin install script to VM"

  local local_script
  local_script=$(mktemp /tmp/nut-admin-install-XXXXXX.sh)
  chmod 600 "$local_script"
  printf '%s\n' "$NUT_ADMIN_SCRIPT" >"$local_script"

  local retry_count=0
  local max_retries=5
  while [[ $retry_count -lt $max_retries ]]; do
    if scp -q -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 \
      -o GSSAPIAuthentication=no \
      -o PasswordAuthentication=no \
      -i "$TEMP_SSH_KEY" \
      "$local_script" \
      "${VM_USER}@${VM_IP}:$remote_script_path" 2>/dev/null; then
      break
    fi
    sleep 5
    ((retry_count++))
  done

  rm -f "$local_script"

  if [[ $retry_count -eq $max_retries ]]; then
    msg_error "Failed to copy NUT Admin install script to VM"
  fi

  ssh -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    -o GSSAPIAuthentication=no \
    -o PasswordAuthentication=no \
    -i "$TEMP_SSH_KEY" \
    "${VM_USER}@${VM_IP}" \
    "chmod +x $remote_script_path" 2>/dev/null || true

  msg_ok "NUT Admin install script deployed"

  msg_info "Running NUT Admin installer on VM"

  NUT_ADMIN_OUTPUT=$(ssh -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    -o ServerAliveInterval=30 \
    -o GSSAPIAuthentication=no \
    -o PasswordAuthentication=no \
    -i "$TEMP_SSH_KEY" \
    "${VM_USER}@${VM_IP}" \
    "sudo bash $remote_script_path" 2>&1) || true

  if echo "$NUT_ADMIN_OUTPUT" | grep -q "NUT_ADMIN_OK"; then
    msg_ok "NUT Admin web interface installed"
  elif echo "$NUT_ADMIN_OUTPUT" | grep -q "NUT_ADMIN_FAIL"; then
    msg_warn "NUT Admin web interface failed"
  else
    msg_warn "NUT Admin web interface status unknown"
  fi

  while IFS= read -r line; do
    [[ "$line" =~ \[NUT-ADMIN-(WARN|ERROR)\] ]] && SCRIPT_ERROR_LOG+=("$line")
  done <<<"$NUT_ADMIN_OUTPUT"

  ssh -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o GSSAPIAuthentication=no \
    -o PasswordAuthentication=no \
    -i "$TEMP_SSH_KEY" \
    "${VM_USER}@${VM_IP}" \
    "rm -f $remote_script_path" 2>/dev/null || true
}

run_nut_install() {
  build_nut_install_script
  deploy_nut_script
}

run_nut_admin_install() {
  build_nut_admin_script
  deploy_nut_admin_script
}

verify_nut_post_reboot() {
  local retries=0 max_retries=18
  msg_info "Verifying NUT server after reboot"
  while ((retries < max_retries)); do
    local output
    output=$(ssh -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 \
      -o GSSAPIAuthentication=no \
      -o PasswordAuthentication=no \
      -i "$TEMP_SSH_KEY" \
      "${VM_USER}@${VM_IP}" \
      "upsc '${NUT_UPS_NAME}@localhost' 2>/dev/null || true" 2>/dev/null) || true
    if [[ -n "$output" ]]; then
      NUT_TEST_RESULT="OK"
      msg_ok "NUT server responding after reboot"
      return 0
    fi
    sleep 5
    retries=$((retries + 1))
  done
  NUT_TEST_RESULT="FAIL"
  msg_warn "NUT server not responding after reboot — check driver/USB passthrough"
}

#===============================================================================
# Section 12: Final Summary Output
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

  if [[ "${VERBOSE:-}" == "yes" && ${#SCRIPT_ERROR_LOG[@]} -gt 0 ]]; then
    echo
    echo -e "${YW}Debug - Script error/warning log:${CL}"
    for entry in "${SCRIPT_ERROR_LOG[@]}"; do
      echo -e "  ${entry}"
    done
  fi
  echo
}

#===============================================================================
# Main
#===============================================================================

main() {
  case "${1:-}" in
  --help | -h)
    echo "Usage: $0 [--debug|--version|--help]"
    echo
    echo "Creates an Ubuntu 24.04 VM on Proxmox and configures NUT netserver."
    echo
    echo "Options:"
    echo "  --help, -h      Show this help message"
    echo "  --version       Show version"
    echo "  --debug, -d     Enable debug tracing (set -x) and show all command output"
    echo
    echo "Environment:"
    echo "  VERBOSE=yes     Show full command output"
    exit 0
    ;;
  --version)
    echo "nut-vm.sh v${SCRIPT_VERSION}"
    exit 0
    ;;
  --debug | -d)
    VERBOSE=yes
    set -x
    ;;
  esac

  header_info
  color
  variables
  catch_errors

  if [[ "${VERBOSE:-}" == "yes" ]]; then
    STD=""
    set -x
  fi

  echo -e "${BOLD}  v${SCRIPT_VERSION}${CL}\n"

  check_root
  check_proxmox
  check_dependencies
  check_architecture

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

  get_vm_ip
  wait_ssh "$VM_IP" 22
  run_nut_install
  run_nut_admin_install

  msg_info "Rebooting VM ${VM_ID} to apply NUT configuration"
  qm reboot "$VM_ID" 2>/dev/null || qm reset "$VM_ID" 2>/dev/null || true
  msg_ok "VM rebooted"

  local reboot_wait=0 reboot_max=90
  msg_info "Waiting for VM to finish rebooting"
  while ((reboot_wait < reboot_max)); do
    if timeout 2 bash -c "echo >/dev/tcp/${VM_IP}/22" 2>/dev/null; then
      msg_ok "VM is reachable after reboot"
      break
    fi
    sleep 5
    reboot_wait=$((reboot_wait + 5))
  done
  if ((reboot_wait >= reboot_max)); then
    msg_warn "VM is still rebooting — upsc command may not be immediately available"
  fi

  if ((reboot_wait < reboot_max)); then
    verify_nut_post_reboot
  fi

  print_summary
}

trap '[[ -n "${SPINNER_PID:-}" ]] && kill "${SPINNER_PID:-}" 2>/dev/null; printf "\e[?25h"; echo -e "\n${RD}Interrupted${CL}"; exit 130' INT TERM

main "$@"
