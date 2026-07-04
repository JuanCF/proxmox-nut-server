#!/usr/bin/env bash
# scripts/setup.sh — Standalone NUT + NutWatch installer & updater for Debian/Ubuntu/Raspbian
#
# Installs and configures NUT (Network UPS Tools) in netserver mode
# and the NutWatch web UI directly on the host machine.
#
# Usage:
#   sudo bash scripts/setup.sh                     # interactive full install
#   sudo bash scripts/setup.sh --update            # update NutWatch code only (e.g. inside a VM)
#   sudo bash scripts/setup.sh --install-only      # NutWatch only (NUT already configured)
#   AUTO=1 bash scripts/setup.sh                   # non-interactive, defaults/auto-generated passwords
#
# Shared environment variables:
#   NUTWATCH_REF        — NutWatch release tag (default: v1.2.0)
#   NUTWATCH_URL_PREFIX — override tarball URL for local testing
#
# NutWatch is fully open (no login) until an admin account is created, either
# from the dashboard's first-run Setup page or via:
#   /opt/nutwatch/venv/bin/python /opt/nutwatch/manage.py create-admin <username>
#
# Fresh install environment variables:
#   AUTO                — set to 1 for non-interactive mode
#   NUT_UPS_NAME        — UPS identifier (default: ups)
#   NUT_UPS_DESC        — UPS description (default: My UPS)
#   NUT_DRIVER          — NUT driver (default: usbhid-ups)
#   NUT_ADMIN_USER      — NUT admin username (default: admin)
#   NUT_ADMIN_PASS      — NUT admin password
#   NUT_MONITOR_USER    — NUT monitor username (default: monuser)
#   NUT_MONITOR_PASS    — NUT monitor password
#   NUT_LISTEN_ADDR     — NUT listen address (default: 0.0.0.0)
#   NUT_LISTEN_PORT     — NUT listen port (default: 3493)

set -euo pipefail

#===============================================================================
# Constants
#===============================================================================

NUTWATCH_REF="${NUTWATCH_REF:-v1.2.0}"
NUTWATCH_RELEASES_URL="https://github.com/JuanCF/nutwatch/releases/download/${NUTWATCH_REF}"
NUTWATCH_TARBALL_URL="${NUTWATCH_URL_PREFIX:-${NUTWATCH_RELEASES_URL}}/nutwatch.tar.gz"

NUT_DEFAULT_PORT=3493
NUT_DIR="/etc/nut"
NUTWATCH_DIR="/opt/nutwatch"

declare -A UPS_VENDORS=(
  ["051d"]="APC"
  ["0764"]="CyberPower"
  ["0463"]="Eaton"
  ["09ae"]="Tripp Lite"
  ["10af"]="Liebert"
)

#===============================================================================
# Helper functions
#===============================================================================

GENERATED_PASSWORDS=()

info() { echo -e "  [INFO]  $*"; }
ok() { echo -e "  [OK]    $*"; }
warn() { echo -e "  [WARN]  $*"; }
err() { echo -e "  [ERROR] $*" >&2; }

generate_password() {
  local length="${1:-16}"
  local password
  password=$(openssl rand -base64 48 2>/dev/null | tr -dc 'a-zA-Z0-9!@#$%^&*' | head -c "$length")
  if [[ ${#password} -lt $length ]]; then
    password=$(tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | fold -w "$length" | head -n 1)
  fi
  echo "$password"
}

prompt() {
  local varname="$1" prompt_text="$2" default_value="$3"
  local result
  if [[ -n "${!varname:-}" ]]; then
    return 0
  fi
  read -r -p "$prompt_text [$default_value]: " result
  printf -v "$varname" '%s' "${result:-$default_value}"
}

prompt_password() {
  local varname="$1" prompt_text="$2"
  if [[ -n "${!varname:-}" ]]; then
    return 0
  fi
  if [[ "${AUTO:-}" == "1" ]]; then
    local pass
    pass=$(generate_password 16)
    printf -v "$varname" '%s' "$pass"
    GENERATED_PASSWORDS+=("$prompt_text: $pass")
    return 0
  fi
  local pass1 pass2
  while true; do
    read -r -s -p "$prompt_text: " pass1
    echo
    if [[ -z "$pass1" ]]; then
      echo "  Password cannot be empty. Try again."
      continue
    fi
    read -r -s -p "Confirm $prompt_text: " pass2
    echo
    if [[ "$pass1" == "$pass2" ]]; then
      printf -v "$varname" '%s' "$pass1"
      return 0
    fi
    echo "  Passwords do not match. Try again."
  done
}

prompt_yes_no() {
  local prompt_text="$1" default="${2:-y}"
  if [[ "${AUTO:-}" == "1" ]]; then
    return 0
  fi
  local yn
  read -r -p "$prompt_text [${default}]: " yn
  yn="${yn:-$default}"
  [[ "$yn" =~ ^[yY] ]]
}

#===============================================================================
# Prerequisite checks
#===============================================================================

check_root() {
  if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (sudo)."
    exit 1
  fi
}

check_distro() {
  if ! command -v apt-get &>/dev/null; then
    err "This script requires apt-get (Debian/Ubuntu/Raspbian)."
    exit 1
  fi
}

check_dependencies() {
  local missing=()
  for cmd in curl openssl hostname rsync; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    info "Installing missing dependencies: ${missing[*]}"
    apt-get install -y -qq "${missing[@]}" 2>/dev/null || {
      err "Failed to install dependencies: ${missing[*]}"
      exit 1
    }
  fi
}

#===============================================================================
# USB UPS detection
#===============================================================================

detect_ups_usb() {
  info "Scanning for USB UPS devices..."

  local lsusb_output
  lsusb_output=$(lsusb 2>/dev/null) || {
    warn "lsusb not available — USB detection skipped"
    return 1
  }

  local devices=()
  while IFS= read -r line; do
    if [[ "$line" =~ ID[[:space:]]([0-9a-f]{4}):([0-9a-f]{4})[[:space:]]*(.*) ]]; then
      local vendor="${BASH_REMATCH[1]}"
      local product="${BASH_REMATCH[2]}"
      local name="${BASH_REMATCH[3]}"
      local vendor_name="${UPS_VENDORS[$vendor]:-Unknown}"

      if [[ -n "${UPS_VENDORS[$vendor]:-}" ]] || [[ "$name" =~ [Uu][Pp][Ss] ]]; then
        devices+=("$vendor:$product — $vendor_name ($name)")
      fi
    fi
  done <<<"$lsusb_output"

  if [[ ${#devices[@]} -eq 0 ]]; then
    warn "No known UPS devices detected via USB."
    warn "You can configure the driver manually, or skip and run nut-scanner later."
    return 1
  fi

  echo "  Detected UPS devices:"
  local i
  for i in "${!devices[@]}"; do
    echo "    $((i + 1)). ${devices[$i]}"
  done

  if [[ ${#devices[@]} -eq 1 ]]; then
    echo "  Using device: ${devices[0]}"
    return 0
  fi

  echo "  Using first detected device: ${devices[0]}"
  return 0
}

#===============================================================================
# NUT installation
#===============================================================================

install_nut() {
  info "Installing NUT packages..."
  apt-get update -qq
  apt-get install -y -qq nut-server nut-client usbutils
  ok "NUT packages installed"
}

#===============================================================================
# NUT configuration
#===============================================================================

write_nut_configs() {
  local ups_name="$1" ups_desc="$2" driver="$3"
  local admin_user="$4" admin_pass="$5"
  local mon_user="$6" mon_pass="$7"
  local listen_addr="$8" listen_port="$9"

  mkdir -p "$NUT_DIR"

  echo 'MODE=netserver' >"$NUT_DIR/nut.conf"
  ok "Wrote nut.conf (netserver mode)"

  cat >"$NUT_DIR/upsd.conf" <<UPSD_EOF
LISTEN $listen_addr $listen_port
MAXAGE 15
STATEPATH /var/run/nut
UPSD_EOF
  ok "Wrote upsd.conf"

  cat >"$NUT_DIR/upsd.users" <<UPSDUSERS_EOF
[$admin_user]
  password = $admin_pass
  actions = SET
  instcmds = ALL

[$mon_user]
  password = $mon_pass
  upsmon master
UPSDUSERS_EOF
  ok "Wrote upsd.users"

  cat >"$NUT_DIR/ups.conf" <<UPSCONF_EOF
[$ups_name]
  driver = $driver
  port = auto
  desc = "$ups_desc"
  pollinterval = 5
UPSCONF_EOF
  ok "Wrote ups.conf"

  cat >"$NUT_DIR/upsmon.conf" <<UPSMON_EOF
MONITOR ${ups_name}@localhost:${listen_port} 1 ${mon_user} ${mon_pass} master

MINSUPPLIES 1
SHUTDOWNCMD "/sbin/shutdown -h +0"
NOTIFYCMD "/etc/nut/notifycmd.sh"
POWERDOWNFLAG /etc/killpower

POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 15
RBWARNTIME 43200
NOCOMMWARNTIME 300
FINALDELAY 5

NOTIFYMSG ONLINE    "UPS %s on line power"
NOTIFYMSG ONBATT    "UPS %s on battery"
NOTIFYMSG LOWBATT   "UPS %s battery is low"
NOTIFYMSG COMMOK    "Communications with UPS %s established"
NOTIFYMSG COMMBAD   "Communications with UPS %s lost"
NOTIFYMSG SHUTDOWN  "UPS %s forcing system shutdown"

NOTIFYFLAG ONLINE   SYSLOG+WALL+EXEC
NOTIFYFLAG ONBATT   SYSLOG+WALL+EXEC
NOTIFYFLAG LOWBATT  SYSLOG+WALL+EXEC
NOTIFYFLAG COMMOK   SYSLOG+WALL+EXEC
NOTIFYFLAG COMMBAD  SYSLOG+WALL+EXEC
NOTIFYFLAG SHUTDOWN SYSLOG+WALL+EXEC
NOTIFYFLAG REPLBATT SYSLOG+WALL+EXEC
NOTIFYFLAG NOCOMM   SYSLOG+WALL+EXEC
NOTIFYFLAG NOPARENT SYSLOG+WALL+EXEC
UPSMON_EOF
  ok "Wrote upsmon.conf"

  cat >"$NUT_DIR/notifycmd.sh" <<'NOTIFY_EOF'
#!/bin/bash
LOGFILE="/var/log/nut/notifycmd.log"
HOOKDIR="/etc/nut/notify.d"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
UPSNAME_BARE="${UPSNAME%%@*}"
echo "[$TIMESTAMP] UPS=$UPSNAME EVENT=$NOTIFYTYPE" >>"$LOGFILE"
[[ -x "$HOOKDIR/${UPSNAME_BARE}_${NOTIFYTYPE}.sh" ]] && "$HOOKDIR/${UPSNAME_BARE}_${NOTIFYTYPE}.sh" >>"$LOGFILE" 2>&1
[[ -x "/usr/local/bin/nutwatch-wol-dispatch" ]] && "/usr/local/bin/nutwatch-wol-dispatch" "$UPSNAME_BARE" "$NOTIFYTYPE" >>"$LOGFILE" 2>&1
NOTIFY_EOF
  chmod 750 "$NUT_DIR/notifycmd.sh"
  ok "Wrote notifycmd.sh"

  mkdir -p "$NUT_DIR/notify.d" /var/log/nut

  chown root:nut "$NUT_DIR"/*.conf 2>/dev/null || true
  chmod 640 "$NUT_DIR"/*.conf
  chown root:nut "$NUT_DIR/notifycmd.sh"
  chown root:nut "$NUT_DIR/notify.d"
  chmod 750 "$NUT_DIR/notify.d"
  chown nut:nut /var/log/nut
  mkdir -p /var/run/nut
  chown nut:nut /var/run/nut

  ok "NUT permissions set"
}

#===============================================================================
# NutWatch update
#===============================================================================

update_nutwatch() {
  local backup_dir

  if [[ ! -d "$NUTWATCH_DIR" ]]; then
    err "NutWatch is not installed at $NUTWATCH_DIR — nothing to update."
    err "Run without --update for a fresh install."
    exit 1
  fi

  backup_dir=$(mktemp -d)
  info "Backing up current NutWatch to $backup_dir..."
  cp -a "$NUTWATCH_DIR" "$backup_dir/nutwatch"
  ok "Backed up"

  info "Downloading NutWatch ${NUTWATCH_REF} from ${NUTWATCH_TARBALL_URL}..."
  curl -fsSL "${NUTWATCH_TARBALL_URL}" -o /tmp/nutwatch.tar.gz || {
    err "Failed to download NutWatch tarball."
    err "Update aborted — existing installation is unchanged."
    exit 1
  }

  info "Extracting new version..."
  rm -rf /tmp/nutwatch-extract
  mkdir -p /tmp/nutwatch-extract
  tar -xzf /tmp/nutwatch.tar.gz -C /tmp/nutwatch-extract/
  rm -f /tmp/nutwatch.tar.gz

  info "Replacing NutWatch application files (preserving venv, config, and hooks)..."
  rsync -a --delete \
    --exclude='venv' \
    --exclude='__pycache__' \
    --exclude='.pytest_cache' \
    --exclude='tests' \
    /tmp/nutwatch-extract/ "$NUTWATCH_DIR/"
  rm -rf /tmp/nutwatch-extract

  info "Updating Python dependencies..."
  "$NUTWATCH_DIR/venv/bin/pip" install --quiet --upgrade pip
  "$NUTWATCH_DIR/venv/bin/pip" install --quiet -r "$NUTWATCH_DIR/requirements.txt"

  # Update WOL dispatch helper
  if [[ -f "$NUTWATCH_DIR/scripts/nutwatch-wol-dispatch" ]]; then
    cp "$NUTWATCH_DIR/scripts/nutwatch-wol-dispatch" /usr/local/bin/nutwatch-wol-dispatch
    chmod 755 /usr/local/bin/nutwatch-wol-dispatch
  fi

  # Deploy updated notifycmd.sh
  if [[ -f "$NUTWATCH_DIR/scripts/notifycmd.sh" ]]; then
    cp "$NUTWATCH_DIR/scripts/notifycmd.sh" /etc/nut/notifycmd.sh
    chmod 750 /etc/nut/notifycmd.sh
    chown root:nut /etc/nut/notifycmd.sh
  fi

  systemctl daemon-reload
  systemctl enable nutwatch 2>/dev/null || true

  info "Restarting NutWatch service..."
  systemctl restart nutwatch
  ok "NutWatch updated to ${NUTWATCH_REF} and restarted"
  echo ""
  echo "  Previous installation backed up to: $backup_dir/nutwatch"
  echo "  Remove it with: rm -rf $backup_dir"
}

install_nutwatch() {
  if [[ -d "$NUTWATCH_DIR" ]]; then
    info "NutWatch already installed at $NUTWATCH_DIR"
    if prompt_yes_no "Update NutWatch to the latest version?" "y"; then
      update_nutwatch
      return $?
    fi
    info "Skipping NutWatch install."
    return 0
  fi

  info "Installing NutWatch dependencies..."
  apt-get install -y -qq python3-venv python3-pip

  info "Downloading NutWatch from ${NUTWATCH_TARBALL_URL}..."

  mkdir -p "$NUTWATCH_DIR"

  curl -fsSL "${NUTWATCH_TARBALL_URL}" -o /tmp/nutwatch.tar.gz || {
    warn "Failed to download NutWatch tarball — skipping NutWatch install"
    warn "You can install it later with: sudo bash scripts/setup.sh --install-only"
    NUTWATCH_SKIP=true
  }

  if [[ "${NUTWATCH_SKIP:-}" == "true" ]]; then
    rmdir "$NUTWATCH_DIR" 2>/dev/null || true
    return 0
  fi

  tar -xzf /tmp/nutwatch.tar.gz -C "$NUTWATCH_DIR/"
  rm -f /tmp/nutwatch.tar.gz

  info "Installing notifycmd script and creating log directories..."
  mkdir -p /etc/nut
  if [[ -f "$NUTWATCH_DIR/scripts/notifycmd.sh" ]]; then
    cp "$NUTWATCH_DIR/scripts/notifycmd.sh" /etc/nut/notifycmd.sh
    chmod 750 /etc/nut/notifycmd.sh
    chown root:nut /etc/nut/notifycmd.sh
  fi
  mkdir -p /etc/nut/notify.d /var/log/nut
  chown root:nut /etc/nut/notify.d && chmod 750 /etc/nut/notify.d
  chown nut:nut /var/log/nut

  info "Setting up Python virtual environment..."
  python3 -m venv "$NUTWATCH_DIR/venv"
  "$NUTWATCH_DIR/venv/bin/pip" install --quiet -r "$NUTWATCH_DIR/requirements.txt"

  # Install WOL dispatch helper (after venv so shebang is valid)
  if [[ -f "$NUTWATCH_DIR/scripts/nutwatch-wol-dispatch" ]]; then
    cp "$NUTWATCH_DIR/scripts/nutwatch-wol-dispatch" /usr/local/bin/nutwatch-wol-dispatch
    chmod 755 /usr/local/bin/nutwatch-wol-dispatch
  fi

  cp "$NUTWATCH_DIR/nutwatch.service" /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable nutwatch
  systemctl restart nutwatch

  configure_firewall

  local host_ip
  host_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  host_ip="${host_ip:-$(hostname)}"
  echo ""
  echo "  NutWatch web interface installed and running."
  echo "  URL: http://${host_ip}:8081"
  echo ""

  ok "NutWatch installed and enabled"
}

#===============================================================================
# Service management
#===============================================================================

enable_nut_services() {
  info "Enabling NUT services..."

  systemctl daemon-reload 2>/dev/null || true
  systemctl enable nut-server 2>/dev/null || true
  systemctl enable nut-monitor 2>/dev/null || true

  if [[ -f /lib/systemd/system/nut-driver-enumerator.service ]]; then
    systemctl enable nut-driver-enumerator.service 2>/dev/null || true
    systemctl enable nut-driver-enumerator.path 2>/dev/null || true
    systemctl enable nut-driver-target 2>/dev/null || true
  elif [[ -f /lib/systemd/system/nut-driver@.service ]]; then
    systemctl enable "nut-driver@${1}" 2>/dev/null || true
  else
    systemctl enable nut-driver 2>/dev/null || true
  fi

  ok "NUT services enabled"
}

start_nut_services() {
  info "Starting NUT services..."
  systemctl restart nut-server nut-monitor 2>/dev/null || true
  ok "NUT services restarted"
}

configure_firewall() {
  if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    info "Configuring firewall..."
    ufw allow "${NUT_LISTEN_PORT:-$NUT_DEFAULT_PORT}"/tcp comment "NUT"
    ufw allow 8081/tcp comment "NutWatch"
    ok "Firewall rules added"
  fi
}

install_nut_detect_service() {
  local ups_name="$1" ups_desc="$2"
  local escaped_ups_name escaped_ups_desc

  escaped_ups_name="${ups_name//\\/\\\\}"
  escaped_ups_name="${escaped_ups_name//\$/\\\$}"
  escaped_ups_name="${escaped_ups_name//\"/\\\"}"
  escaped_ups_name="${escaped_ups_name//\`/\\\`}"

  escaped_ups_desc="${ups_desc//\\/\\\\}"
  escaped_ups_desc="${escaped_ups_desc//\$/\\\$}"
  escaped_ups_desc="${escaped_ups_desc//\"/\\\"}"
  escaped_ups_desc="${escaped_ups_desc//\`/\\\`}"

  cat >/usr/local/bin/nut-detect.sh <<DETECT_EOF
#!/bin/bash
nut-scanner -U > /tmp/nut-scan.txt
DRIVER=\$(awk -F'"' '/driver/ {print \$2; exit}' /tmp/nut-scan.txt)
PORT=\$(awk -F'"' '/port/ {print \$2; exit}' /tmp/nut-scan.txt)
VENDORID=\$(awk -F'"' '/vendorid/ {print \$2; exit}' /tmp/nut-scan.txt)
PRODUCTID=\$(awk -F'"' '/productid/ {print \$2; exit}' /tmp/nut-scan.txt)

{
  printf "[%s]\n" "$escaped_ups_name"
  printf "  driver = %s\n" "\${DRIVER:-usbhid-ups}"
  printf "  port = %s\n" "\${PORT:-auto}"
  [[ -n "\$VENDORID" ]] && printf "  vendorid = %s\n" "\$VENDORID"
  [[ -n "\$PRODUCTID" ]] && printf "  productid = %s\n" "\$PRODUCTID"
  printf "  desc = \"%s\"\n" "$escaped_ups_desc"
  printf "  pollinterval = 5\n"
} > /etc/nut/ups.conf

chown root:nut /etc/nut/ups.conf
chmod 640 /etc/nut/ups.conf
systemctl restart nut-driver nut-server nut-monitor 2>/dev/null || true
touch /var/lib/nut/driver-detected
DETECT_EOF
  chmod +x /usr/local/bin/nut-detect.sh

  cat >/etc/systemd/system/nut-detect.service <<SERVICE_EOF
[Unit]
Description=Auto-detect UPS driver on boot
After=multi-user.target
ConditionPathExists=!/var/lib/nut/driver-detected

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nut-detect.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE_EOF

  systemctl daemon-reload
  systemctl enable nut-detect 2>/dev/null || true
  ok "nut-detect oneshot service installed (runs once on next boot)"
}

#===============================================================================
# Summary
#===============================================================================

print_summary() {
  local host_ip
  host_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  host_ip="${host_ip:-$(hostname)}"

  echo ""
  echo "============================================"
  echo "  NUT + NutWatch Setup Complete!"
  echo "============================================"
  echo ""
  echo "  NUT Server:   ${host_ip}:${NUT_LISTEN_PORT:-$NUT_DEFAULT_PORT}"
  echo "  UPS Name:     ${NUT_UPS_NAME:-ups}"
  echo ""
  echo "  Test command:"
  echo "    upsc ${NUT_UPS_NAME:-ups}@localhost"
  echo ""
  echo "  NutWatch URL: http://${host_ip}:8081"
  echo ""
  echo "  Client upsmon.conf:"
  echo "    MONITOR ${NUT_UPS_NAME:-ups}@${host_ip}:${NUT_LISTEN_PORT:-$NUT_DEFAULT_PORT} 1 ${NUT_MONITOR_USER:-monuser} PASS slave"
  echo ""

  if [[ ${#GENERATED_PASSWORDS[@]} -gt 0 ]]; then
    echo "  Auto-generated passwords (save these!):"
    for entry in "${GENERATED_PASSWORDS[@]}"; do
      echo "    $entry"
    done
    echo ""
  fi

  echo "  Hook scripts go in: /etc/nut/notify.d/<UPSNAME>_<EVENT>.sh"
  echo ""
}

#===============================================================================
# Fresh install
#===============================================================================

do_fresh_install() {
  echo ""
  echo "  NutWatch — NUT + Web UI Setup (direct Linux install)"
  echo ""

  check_root
  check_distro
  check_dependencies

  if [[ -z "${NUT_UPS_NAME:-}" ]]; then
    prompt NUT_UPS_NAME "UPS name" "ups"
  fi
  if [[ -z "${NUT_UPS_DESC:-}" ]]; then
    prompt NUT_UPS_DESC "UPS description" "My UPS"
  fi
  if [[ -z "${NUT_DRIVER:-}" ]]; then
    NUT_DRIVER="usbhid-ups"
    if [[ "${AUTO:-}" != "1" ]]; then
      prompt NUT_DRIVER "NUT driver" "usbhid-ups"
    fi
  fi
  if [[ -z "${NUT_ADMIN_USER:-}" ]]; then
    prompt NUT_ADMIN_USER "NUT admin username" "admin"
  fi
  prompt_password NUT_ADMIN_PASS "NUT admin password"
  if [[ -z "${NUT_MONITOR_USER:-}" ]]; then
    prompt NUT_MONITOR_USER "NUT monitor username" "monuser"
  fi
  prompt_password NUT_MONITOR_PASS "NUT monitor password"
  if [[ -z "${NUT_LISTEN_ADDR:-}" ]]; then
    prompt NUT_LISTEN_ADDR "NUT listen address" "0.0.0.0"
  fi
  if [[ -z "${NUT_LISTEN_PORT:-}" ]]; then
    prompt NUT_LISTEN_PORT "NUT listen port" "$NUT_DEFAULT_PORT"
  fi

  echo ""

  if ! prompt_yes_no "Proceed with installation?" "y"; then
    echo "Aborted."
    exit 1
  fi

  detect_ups_usb || true

  install_nut
  write_nut_configs \
    "$NUT_UPS_NAME" "$NUT_UPS_DESC" "$NUT_DRIVER" \
    "$NUT_ADMIN_USER" "$NUT_ADMIN_PASS" \
    "$NUT_MONITOR_USER" "$NUT_MONITOR_PASS" \
    "$NUT_LISTEN_ADDR" "$NUT_LISTEN_PORT"
  enable_nut_services "$NUT_UPS_NAME"

  if prompt_yes_no "Install nut-detect service (auto-detects driver on next boot if USB UPS is connected)?" "y"; then
    install_nut_detect_service "$NUT_UPS_NAME" "$NUT_UPS_DESC"
  fi

  if prompt_yes_no "Install NutWatch web UI on port 8081?" "y"; then
    install_nutwatch
  fi

  start_nut_services
  configure_firewall
  print_summary
}

#===============================================================================
# Standalone NutWatch-only install (replaces scripts/install.sh)
#===============================================================================

do_install_only() {
  check_root
  check_distro
  check_dependencies
  install_nutwatch
}

#===============================================================================
# Main
#===============================================================================

main() {
  case "${1:-}" in
  --update | update)
    check_root
    check_distro
    check_dependencies
    update_nutwatch
    ;;
  --install-only | install-only)
    do_install_only
    ;;
  --help | -h)
    echo "Usage: sudo bash $0 [--update|--install-only|--help]"
    echo ""
    echo "  (no args)       Fresh install — configure NUT + NutWatch from scratch"
    echo "  --update        Update NutWatch application code only (preserves config, NUT, venv)"
    echo "  --install-only  Install NutWatch only (assumes NUT already configured)"
    echo "  --help          Show this help"
    echo ""
    echo "Environment variables:"
    echo "  AUTO=1          — non-interactive mode (fresh install only)"
    echo "  NUTWATCH_REF    — release tag (default: v1.2.0)"
    echo ""
    echo "NutWatch is open (no login) until an admin account is created via the"
    echo "dashboard's Setup page or 'manage.py create-admin' in the install dir."
    echo ""
    echo "See file header for full list of env vars."
    ;;
  *)
    do_fresh_install
    ;;
  esac
}

main "$@"
