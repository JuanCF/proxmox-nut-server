#!/bin/bash
# Docker entrypoint for NutWatch.
# Generates a minimal NUT configuration on first boot, ensures permissions,
# starts USB drivers, and then hands off to supervisord.

set -euo pipefail

NUT_UPS_NAME="${NUT_UPS_NAME:-ups}"
NUT_UPS_DESC="${NUT_UPS_DESC:-My UPS}"
NUT_DRIVER="${NUT_DRIVER:-usbhid-ups}"
NUT_ADMIN_USER="${NUT_ADMIN_USER:-admin}"
NUT_ADMIN_PASS="${NUT_ADMIN_PASS:-}"
NUT_MONITOR_USER="${NUT_MONITOR_USER:-monuser}"
NUT_MONITOR_PASS="${NUT_MONITOR_PASS:-}"

# Generate a password only when the caller did not provide one. Stick to
# alphanumerics: NUT's config parser treats '#' as the start of a comment
# and would silently truncate the password (and the rest of the line).
generate_password() {
  local length="${1:-16}"
  openssl rand -base64 48 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c "$length" || true
}

if [[ -z "$NUT_ADMIN_PASS" ]]; then
  NUT_ADMIN_PASS="$(generate_password 16)"
  echo "[nutwatch] Generated NUT admin password: $NUT_ADMIN_PASS"
fi

if [[ -z "$NUT_MONITOR_PASS" ]]; then
  NUT_MONITOR_PASS="$(generate_password 16)"
  echo "[nutwatch] Generated NUT monitor password: $NUT_MONITOR_PASS"
fi

mkdir -p /etc/nut/notify.d /var/log/nut /var/run/nut /var/lib/nutwatch /var/log/supervisor

if [[ ! -f /etc/nut/nut.conf ]]; then
  echo 'MODE=netserver' >/etc/nut/nut.conf
fi

if [[ ! -f /etc/nut/upsd.conf ]]; then
  cat >/etc/nut/upsd.conf <<EOF
LISTEN ${NUT_LISTEN_ADDR} ${NUT_LISTEN_PORT}
MAXAGE 15
STATEPATH /var/run/nut
EOF
fi

if [[ ! -f /etc/nut/upsd.users ]]; then
  cat >/etc/nut/upsd.users <<EOF
[${NUT_ADMIN_USER}]
  password = ${NUT_ADMIN_PASS}
  actions = SET
  instcmds = ALL

[${NUT_MONITOR_USER}]
  password = ${NUT_MONITOR_PASS}
  upsmon master
EOF
fi

if [[ ! -f /etc/nut/ups.conf ]]; then
  cat >/etc/nut/ups.conf <<EOF
[${NUT_UPS_NAME}]
  driver = ${NUT_DRIVER}
  port = auto
  desc = "${NUT_UPS_DESC}"
  pollinterval = 5
  # Run the driver as root: host USB device nodes are typically root-owned
  # (mode 660/664) and the container's 'nut' user has no write access to them.
  user = root
EOF
fi

if [[ ! -f /etc/nut/upsmon.conf ]]; then
  cat >/etc/nut/upsmon.conf <<EOF
MONITOR ${NUT_UPS_NAME}@localhost:${NUT_LISTEN_PORT} 1 ${NUT_MONITOR_USER} ${NUT_MONITOR_PASS} master

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
EOF
fi

# Install the notify dispatcher and WOL helper if they are not already mounted.
if [[ ! -f /etc/nut/notifycmd.sh ]]; then
  cp "$NUTWATCH_DIR/scripts/notifycmd.sh" /etc/nut/notifycmd.sh
fi
chmod 750 /etc/nut/notifycmd.sh
chown root:nut /etc/nut/notifycmd.sh

if [[ ! -f /usr/local/bin/nutwatch-wol-dispatch ]]; then
  cp "$NUTWATCH_DIR/scripts/nutwatch-wol-dispatch" /usr/local/bin/nutwatch-wol-dispatch
fi
chmod 755 /usr/local/bin/nutwatch-wol-dispatch

# Permissions expected by NUT. upsd.users holds passwords and must not be
# world-readable; it doesn't match the *.conf glob so list it explicitly.
chown root:nut /etc/nut/*.conf /etc/nut/upsd.users 2>/dev/null || true
chmod 640 /etc/nut/*.conf /etc/nut/upsd.users 2>/dev/null || true
chown root:nut /etc/nut/notify.d && chmod 750 /etc/nut/notify.d
chown nut:nut /var/log/nut /var/run/nut

# Start USB drivers. This may fail if no USB device is present yet or if the
# configuration is intentionally empty; upsd/upsmon will keep retrying and the
# UI can start drivers later via upsdrvctl.
echo "[nutwatch] Starting NUT drivers..."
upsdrvctl start || true

echo "[nutwatch] Starting supervisord..."
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
