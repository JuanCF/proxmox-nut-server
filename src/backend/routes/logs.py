import os
import select
import subprocess

from flask import Blueprint, Response, stream_with_context, request, jsonify

from auth import require_auth
from services.system import _driver_status_units
from utils import run_cmd

logs_bp = Blueprint("logs", __name__)

# Syslog capture file used when journald is unavailable (e.g. inside the
# Docker container, where NUT daemons log via syslog()).
SYSLOG_FILE = os.environ.get("NUTWATCH_SYSLOG_FILE", "/var/log/messages")


def _journal_units() -> list[str]:
    # The driver has no bare nut-driver.service on most NUT 2.8.x distros
    # (drivers run as nut-driver@<name> instances), so resolve the unit names
    # the same way service status does, or journalctl would drop driver logs.
    return ["nut-server", "nut-monitor", *_driver_status_units()]


def _journal_available() -> bool:
    """Return True when journalctl can serve the NUT unit logs.

    Containers usually run without journald; journalctl then prints
    "No journal files were found" on stderr and returns nothing usable,
    so the Logs tab would stay empty. In that case we fall back to
    tailing the syslog capture file instead.
    """
    rc, _, err = run_cmd(["journalctl", "--no-pager", "-n", "1"], timeout=10)
    return rc == 0 and "No journal files" not in err


def _recent_command(lines: str, journal: bool) -> list:
    if journal:
        cmd = ["journalctl", "--no-pager", "-n", lines]
        for unit in _journal_units():
            cmd += ["-u", unit]
        return cmd
    return ["tail", "-n", lines, SYSLOG_FILE]


def _stream_command(journal: bool) -> list:
    if journal:
        cmd = ["journalctl", "--no-pager", "-f", "-n", "0"]
        for unit in _journal_units():
            cmd += ["-u", unit]
        return cmd
    return ["tail", "-F", "-n", "0", SYSLOG_FILE]


@logs_bp.route("/api/logs/stream")
@require_auth
def stream_logs():
    proc = subprocess.Popen(
        _stream_command(_journal_available()),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )

    def generate():
        try:
            while True:
                ready, _, _ = select.select([proc.stdout], [], [], 5)
                if ready:
                    line = proc.stdout.readline()
                    if not line:
                        break
                    yield f"data: {line.rstrip(chr(10))}\n\n"
                else:
                    yield ": heartbeat\n\n"
        finally:
            proc.terminate()
            proc.wait()

    def cleanup():
        proc.terminate()
        proc.wait()

    response = Response(stream_with_context(generate()), mimetype="text/event-stream")
    response.call_on_close(cleanup)
    return response


@logs_bp.route("/api/logs/recent")
@require_auth
def recent_logs():
    lines = request.args.get("lines", "100")
    if not lines.isdigit():
        lines = "100"
    journal = _journal_available()
    if not journal and not os.path.exists(SYSLOG_FILE):
        return jsonify({"returncode": 0, "stdout": "", "stderr": ""})
    rc, out, err = run_cmd(_recent_command(lines, journal), timeout=30)
    return jsonify({"returncode": rc, "stdout": out, "stderr": err})