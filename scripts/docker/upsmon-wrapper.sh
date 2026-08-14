#!/bin/bash
# upsmon wrapper for supervisord.
#
# `upsmon -F` still forks: a root parent (the PID supervisord would track) and
# an unprivileged child running as `nut` in its own session (setsid). A plain
# `supervisorctl restart upsmon` signals only the tracked parent, so the child
# survives holding the PID file and every respawn dies instantly with
# "A previous upsmon instance is already running!", putting the program into
# FATAL. This wrapper stays in the foreground, traps termination signals, and
# brings the whole upsmon pair down so restarts are clean.

set -euo pipefail

PIDFILE="/var/run/nut/upsmon.pid"

stop_upsmon() {
  # The unprivileged child escapes the process group via setsid(), so signal
  # by name. This container runs exactly one upsmon instance, launched by this
  # wrapper, so any match is safe to kill.
  pkill -x upsmon 2>/dev/null || true
}

on_term() {
  stop_upsmon
  exit 0
}
trap on_term TERM INT

# Clean up orphans from a previous unclean stop so the new instance can claim
# its PID file. Give them a moment to exit on SIGTERM before escalating.
if pgrep -x upsmon >/dev/null 2>&1; then
  stop_upsmon
  for _ in $(seq 1 50); do
    pgrep -x upsmon >/dev/null 2>&1 || break
    sleep 0.1
  done
  if pgrep -x upsmon >/dev/null 2>&1; then
    pkill -9 -x upsmon 2>/dev/null || true
  fi
fi

# Drop a stale PID file left behind by a SIGKILLed instance, otherwise upsmon
# refuses to start. A live process holding it was handled above.
if [[ -f "$PIDFILE" ]]; then
  old_pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [[ -z "$old_pid" ]] || ! kill -0 "$old_pid" 2>/dev/null; then
    rm -f "$PIDFILE"
  fi
fi

/usr/sbin/upsmon -F &
upsmon_pid=$!

# Surface upsmon's exit status to supervisord so autorestart works on crash.
# If the wrapper is signaled, the trap above runs and brings the pair down.
wait "$upsmon_pid"
