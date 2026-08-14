#!/bin/bash
# systemctl shim for NutWatch running inside a Docker container supervised by
# supervisord. Translates the systemctl calls issued by the backend into
# supervisorctl commands so the UI restart buttons keep working.

set -euo pipefail

map_service() {
  case "$1" in
  nut-server) echo "upsd" ;;
  nut-monitor) echo "upsmon" ;;
  nutwatch) echo "nutwatch" ;;
  *) echo "" ;;
  esac
}

supervisor_running() {
  supervisorctl status "$1" 2>/dev/null | grep -q "RUNNING"
}

# Drivers run via upsdrvctl (not supervisord), so report on them by looking
# for a live driver PID file in the NUT state directory.
driver_running() {
  local pidfile pid
  for pidfile in /var/run/nut/*.pid; do
    [[ -e "$pidfile" ]] || continue
    case "$(basename "$pidfile")" in
    upsd.pid | upsmon.pid) continue ;;
    esac
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

is_active() {
  local svc="$1" target
  target="$(map_service "$svc")"
  if [[ -n "$target" ]]; then
    supervisor_running "$target"
    return
  fi
  case "$svc" in
  nut-driver | nut-driver@*) driver_running ;;
  *) return 3 ;;
  esac
}

cmd="${1:-}"
shift || true

case "$cmd" in
restart | start | stop)
  # Propagate failures so the UI can report them instead of claiming success.
  rc=0
  for svc in "$@"; do
    target="$(map_service "$svc")"
    if [[ -n "$target" ]]; then
      supervisorctl "$cmd" "$target" || rc=$?
    fi
  done
  exit "$rc"
  ;;

is-active)
  # Mirror systemctl: print the state, exit 0 when active, 3 otherwise.
  rc=3
  for svc in "$@"; do
    if is_active "$svc"; then
      echo "active"
      rc=0
    else
      echo "inactive"
    fi
  done
  exit "$rc"
  ;;

status)
  for svc in "$@"; do
    if is_active "$svc"; then
      state="active (running)"
    else
      state="inactive (dead)"
    fi
    echo "● ${svc}.service"
    echo "     Active: ${state}"
  done
  exit 0
  ;;

reboot | poweroff)
  echo "systemctl $cmd is not supported inside a container" >&2
  exit 1
  ;;

*)
  # Unknown command: fall back to the real systemctl if one exists.
  if command -v /usr/bin/systemctl &>/dev/null; then
    /usr/bin/systemctl "$cmd" "$@"
  else
    exit 0
  fi
  ;;
esac
