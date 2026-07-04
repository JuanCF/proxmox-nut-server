import select
import subprocess

from flask import Blueprint, Response, stream_with_context, request, jsonify

from auth import require_auth
from utils import run_cmd

logs_bp = Blueprint("logs", __name__)


@logs_bp.route("/api/logs/stream")
@require_auth
def stream_logs():
    proc = subprocess.Popen(
        [
            "journalctl",
            "-u", "nut-server",
            "-u", "nut-monitor",
            "-u", "nut-driver",
            "-f",
            "-n", "0",
            "--no-pager",
        ],
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
    rc, out, err = run_cmd(
        [
            "journalctl",
            "-u", "nut-server",
            "-u", "nut-monitor",
            "-u", "nut-driver",
            "-n", lines,
            "--no-pager",
        ],
        timeout=30,
    )
    return jsonify({"returncode": rc, "stdout": out, "stderr": err})