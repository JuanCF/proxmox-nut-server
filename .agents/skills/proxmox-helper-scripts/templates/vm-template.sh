#!/usr/bin/env bash
# Replace YOUR_USERNAME with your GitHub username while developing.
# BEFORE OPENING A PR: change both URLs back to community-scripts/ProxmoxVE
source <(curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/ProxmoxVED/main/misc/build.func)
source <(curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/ProxmoxVED/main/misc/cloud-init.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: YOUR_USERNAME
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/UPSTREAM_USER/UPSTREAM_REPO

# ---- Application metadata ----
APP="AppName"                          # TODO: Set application name
var_tags="${var_tags:-vm;linux}"       # TODO: Update tags (semicolon-separated, max 4)
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-10}"
var_os="${var_os:-debian}"             # TODO: Set base OS (debian, ubuntu, …)
var_version="${var_version:-12}"       # TODO: Set OS version

NSAPP="${NSAPP:-appname-vm}"           # TODO: Lowercase hyphenated name for API telemetry

# ---- Initialization (in this exact order) ----
header_info "$APP"
variables    # populates VMID, STORAGE, HN, CORE_COUNT, RAM_SIZE, DISK_SIZE, BRG, MAC, etc.
color
catch_errors

# ---- VM-specific helpers ----
function get_valid_nextid() {
  local try_id
  try_id=$(pvesh get /cluster/nextid)
  while true; do
    if [ -f "/etc/pve/qemu-server/${try_id}.conf" ] || [ -f "/etc/pve/lxc/${try_id}.conf" ]; then
      try_id=$((try_id + 1)); continue
    fi
    if lvs --noheadings -o lv_name | grep -qE "(^|[-_])${try_id}($|[-_])"; then
      try_id=$((try_id + 1)); continue
    fi
    break
  done
  echo "$try_id"
}

function cleanup_vmid() {
  if qm status $VMID &>/dev/null; then
    qm stop $VMID &>/dev/null
    qm destroy $VMID &>/dev/null
  fi
}

function arch_check() {
  ARCH=$(dpkg --print-architecture)
}

arch_check

# ---- Storage validation ----
msg_info "Validating Storage"
while read -r line; do
  TAG=$(echo $line | awk '{print $1}')
  TYPE=$(echo $line | awk '{printf "%-10s", $2}')
  FREE=$(echo $line | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf( "%9sB", $6)}')
  ITEM="  Type: $TYPE Free: $FREE "
  OFFSET=2
  if [[ $((${#ITEM} + $OFFSET)) -gt ${MSG_MAX_LENGTH:-} ]]; then MSG_MAX_LENGTH=$((${#ITEM} + $OFFSET)); fi
  STORAGE_MENU+=("$TAG" "$ITEM" "OFF")
done < <(pvesm status -content images | awk 'NR>1')
VALID=$(pvesm status -content images | awk 'NR>1')
if [ -z "$VALID" ]; then
  msg_error "Unable to detect a valid storage location."; exit
elif [ $((${#STORAGE_MENU[@]} / 3)) -eq 1 ]; then
  STORAGE=${STORAGE_MENU[0]}
else
  STORAGE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Storage Pools" --radiolist \
    "Which storage pool would you like to use for ${HN}?\nTo make a selection, use the Spacebar.\n" \
    16 $(($MSG_MAX_LENGTH + 23)) 6 "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3)
fi
msg_ok "Using ${CL}${BL}$STORAGE${CL} ${GN}for Storage Location."
msg_ok "Virtual Machine ID is ${CL}${BL}$VMID${CL}."

# ---- Disk naming by storage type ----
STORAGE_TYPE=$(pvesm status -storage "$STORAGE" | awk 'NR>1 {print $2}')
case $STORAGE_TYPE in
  nfs | dir | cifs) DISK_EXT=".qcow2"; DISK_REF="$VMID/"; DISK_IMPORT="-format qcow2"; THIN="";;
  btrfs)            DISK_EXT=".raw";   DISK_REF="$VMID/"; DISK_IMPORT="-format raw";   THIN="";;
  *)                DISK_EXT="";       DISK_REF="";        DISK_IMPORT="-format raw";;
esac
for i in {0,1}; do
  disk="DISK$i"
  eval DISK${i}=vm-${VMID}-disk-${i}${DISK_EXT:-}
  eval DISK${i}_REF=${STORAGE}:${DISK_REF:-}${!disk}
done

# ---- Download image ----
# TODO: Choose A (pre-built image) or B (cloud image with dynamic version) then delete the other.

# Option A — Pre-built image with fixed or parsed URL
# msg_info "Retrieving latest ${APP} image"
# URL="https://example.com/TODO_APP.img"         # TODO: Set image URL
# EXPECTED_SHA256="abc123..."                     # TODO: Set expected checksum (or remove check)
# curl -fSL -o "$(basename "$URL")" "$URL"
# echo "${EXPECTED_SHA256}  $(basename "$URL")" | sha256sum -c
# msg_ok "Downloaded $(basename "$URL")"

# Option B — Cloud image with version from GitHub releases API
msg_info "Retrieving latest ${APP} image"
RELEASE_JSON=$(curl -fsSL https://api.github.com/repos/TODO_USER/TODO_REPO/releases/latest)
RELEASE=$(echo "$RELEASE_JSON" | grep "tag_name" \
          | awk '{print substr($2, 3, length($2)-4)}')
# TODO: Adjust URL patterns for each architecture to match the upstream release asset naming
case "$ARCH" in
  amd64) URL="https://github.com/TODO_USER/TODO_REPO/releases/download/${RELEASE}/TODO_APP-${RELEASE}-amd64.img" ;;
  arm64) URL="https://github.com/TODO_USER/TODO_REPO/releases/download/${RELEASE}/TODO_APP-${RELEASE}-arm64.img" ;;
  *)     msg_error "Unsupported architecture: ${ARCH}"; exit 1 ;;
esac
curl -fSL -o "$(basename "$URL")" "$URL"
FILE=$(basename "$URL")
CHECKSUM_URL=$(echo "$RELEASE_JSON" \
  | grep "browser_download_url" \
  | grep -iE "sha256|checksum|shasums" \
  | head -1 \
  | awk -F '"' '{print $4}')
if [ -z "$CHECKSUM_URL" ]; then
  msg_error "No checksum asset found for ${APP} ${RELEASE} — cannot verify download"
  exit 1
fi
msg_info "Verifying ${FILE}"
curl -fSL -o "$(basename "$CHECKSUM_URL")" "$CHECKSUM_URL"
sha256sum -c <(grep "$FILE" "$(basename "$CHECKSUM_URL")") \
  || { msg_error "Checksum verification failed for ${FILE}"; rm -f "$FILE" "$(basename "$CHECKSUM_URL")"; exit 1; }
rm -f "$(basename "$CHECKSUM_URL")"
msg_ok "Downloaded ${CL}${BL}${FILE}${CL}"

# TODO: If the image is compressed, decompress it:
# xz -t "$FILE" && xz -dc "$FILE" | pv -N "Extracting" > "${FILE%.xz}" && FILE="${FILE%.xz}"
# gunzip "$FILE" && FILE="${FILE%.gz}"

# ---- Create VM ----
msg_info "Creating ${APP} VM"
qm create $VMID \
  -agent 1 \
  -bios ovmf \
  -machine q35 \
  -cores $CORE_COUNT \
  -memory $RAM_SIZE \
  -name $HN \
  -tags community-script \
  -net0 "virtio,bridge=$BRG,macaddr=$MAC$VLAN$MTU" \
  -onboot 1 \
  -ostype l26 \
  -scsihw virtio-scsi-pci >/dev/null
# TODO: For SeaBIOS (i440fx), replace with: -bios seabios (no efidisk0 needed)
msg_ok "Created VM shell"

# ---- Import disk ----
msg_info "Importing disk"
pvesm alloc $STORAGE $VMID $DISK0 4M 1>&/dev/null
qm importdisk $VMID "$FILE" $STORAGE ${DISK_IMPORT:-} 1>&/dev/null
qm set $VMID \
  -efidisk0 ${DISK0_REF},efitype=4m \
  -scsi0 "${DISK1_REF},${DISK_CACHE:-}${THIN}size=${DISK_SIZE}" \
  -boot order=scsi0 \
  -serial0 socket >/dev/null
# TODO: Remove -efidisk0 line if using SeaBIOS instead of OVMF
rm -f "$FILE"
msg_ok "Imported disk"

if [ -n "${DISK_SIZE}" ]; then
  msg_info "Resizing disk to ${DISK_SIZE}"
  qm resize $VMID scsi0 ${DISK_SIZE} >/dev/null
  msg_ok "Resized disk"
fi

# ---- Cloud-init ----
# TODO: Uncomment ONE of the modes below; comment or delete the others.

# Mode A — DHCP, default user (simplest; good for generic OS VMs)
setup_cloud_init "$VMID" "$STORAGE" "$HN" "yes"

# Mode B — Interactive wizard (lets the user configure user/network at script runtime)
# configure_cloud_init_interactive "root"
# setup_cloud_init "$VMID" "$STORAGE" "$HN" "$CLOUDINIT_ENABLE" "$CLOUDINIT_USER"

# Mode C — Static IP, fully specified at script level
# setup_cloud_init "$VMID" "$STORAGE" "$HN" "yes" "root" \
#                  "static" "192.168.1.100/24" "192.168.1.1" "1.1.1.1 8.8.8.8"

# Mode D — No cloud-init (pre-built images like HAOS that manage themselves)
# setup_cloud_init "$VMID" "$STORAGE" "$HN" "no"

# ---- Start VM ----
if [ "${START_VM:-yes}" == "yes" ]; then
  msg_info "Starting ${APP} VM"
  qm start $VMID
  msg_ok "Started ${APP} VM"
fi

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} VM created!${CL}"
echo -e "${INFO}${YW} VM ID: ${BGN}${VMID}${CL}"
# TODO: Add access instructions relevant to this app, for example:
# echo -e "${INFO}${YW} Access it via the Proxmox console or:${CL}"
# echo -e "${TAB}${GATEWAY}${BGN}http://<VM-IP>:PORT${CL}"
