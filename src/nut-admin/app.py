#!/usr/bin/env python3
import functools
import logging
import os
import re
import select
import subprocess
import tempfile

try:
    from flask import Flask, request, jsonify, Response, send_from_directory, stream_with_context
except ImportError:  # pragma: no cover
    class _FakeFlask:
        def __init__(self, *args, **kwargs):
            pass

        def route(self, *args, **kwargs):
            return lambda f: f

    Flask = _FakeFlask
    request = None
    jsonify = None
    Response = None
    send_from_directory = None
    stream_with_context = None

app = Flask(__name__)

NUT_DIR = "/etc/nut"
ALLOWED_CONFIGS = {"ups.conf", "upsd.conf", "upsmon.conf", "upsd.users"}
IDENTIFIER_REGEX = re.compile(r"^[A-Za-z][A-Za-z0-9._-]{0,127}$")

NUT_ADMIN_API_KEY = os.environ.get("NUT_ADMIN_API_KEY", "")
NUT_ADMIN_HOST = os.environ.get("NUT_ADMIN_HOST", "0.0.0.0")

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("nut-admin")

try:
    NUT_ADMIN_PORT = int(os.environ.get("NUT_ADMIN_PORT", "8081"))
except ValueError:
    logger.error("Invalid NUT_ADMIN_PORT=%r, falling back to 8081", os.environ.get("NUT_ADMIN_PORT"))
    NUT_ADMIN_PORT = 8081


def require_admin(f):
    @functools.wraps(f)
    def decorated(*args, **kwargs):
        if not NUT_ADMIN_API_KEY:
            return f(*args, **kwargs)
        auth_header = request.headers.get("Authorization", "")
        if auth_header.startswith("Bearer "):
            token = auth_header[len("Bearer "):]
            if token == NUT_ADMIN_API_KEY:
                return f(*args, **kwargs)
        logger.warning("Auth failure from %s for %s", request.remote_addr, request.path)
        return jsonify({"error": "unauthorized"}), 401

    return decorated


# --- UPS Conf Parser ---

def parse_ups_conf(content: str) -> list:
    entries = []
    current = None
    for line in content.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        m = re.match(r"^\[(.+)\]$", stripped)
        if m:
            if current:
                entries.append(current)
            current = {"name": m.group(1), "directives": []}
            continue
        if current is None:
            continue
        if "=" in stripped:
            key, val = stripped.split("=", 1)
            key = key.strip()
            val = val.strip()
            if key == "driver":
                current["driver"] = val
            elif key == "port":
                current["port"] = val
            elif key == "desc":
                current["desc"] = val.strip('"')
            else:
                current["directives"].append([key, val])
    if current:
        entries.append(current)
    return entries


def serialize_ups_conf(entries: list) -> str:
    lines = []
    for e in entries:
        lines.append(f"[{e['name']}]")
        if "driver" in e:
            lines.append(f"  driver = {e['driver']}")
        if "port" in e:
            lines.append(f"  port = {e['port']}")
        if "desc" in e:
            lines.append(f'  desc = "{e["desc"]}"')
        for key, val in e.get("directives", []):
            lines.append(f"  {key} = {val}")
        lines.append("")
    return "\n".join(lines)


# --- UPSD Users Parser ---

def parse_upsd_users(content: str) -> list:
    entries = []
    current = None
    for line in content.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        m = re.match(r"^\[(.+)\]$", stripped)
        if m:
            if current:
                entries.append(current)
            current = {"name": m.group(1), "directives": []}
            continue
        if current is None:
            continue
        if "=" in stripped:
            key, val = stripped.split("=", 1)
            key = key.strip()
            val = val.strip()
            if key == "password":
                current["password"] = val
            elif key == "upsmon":
                current["upsmon"] = val
            elif key == "actions":
                current["actions"] = val
            elif key == "instcmds":
                current["instcmds"] = val
            else:
                current["directives"].append([key, val])
        else:
            parts = stripped.split(None, 1)
            key = parts[0]
            val = parts[1] if len(parts) > 1 else ""
            if key == "upsmon":
                current["upsmon"] = val
            else:
                current["directives"].append([key, val])
    if current:
        entries.append(current)
    return entries


def serialize_upsd_users(entries: list) -> str:
    lines = []
    for e in entries:
        lines.append(f"[{e['name']}]")
        if "password" in e:
            lines.append(f"  password = {e['password']}")
        if "actions" in e:
            lines.append(f"  actions = {e['actions']}")
        if "instcmds" in e:
            lines.append(f"  instcmds = {e['instcmds']}")
        if "upsmon" in e:
            lines.append(f"  upsmon = {e['upsmon']}")
        for key, val in e.get("directives", []):
            lines.append(f"  {key} = {val}")
        lines.append("")
    return "\n".join(lines)


# --- Helpers ---

def read_file(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def write_file(path: str, content: str) -> None:
    dir_path = os.path.dirname(path)
    fd, tmp_path = tempfile.mkstemp(dir=dir_path, prefix=".nut-admin-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, path)
        tmp_path = None
    finally:
        if tmp_path and os.path.exists(tmp_path):
            os.unlink(tmp_path)


def run_cmd(cmd: list, timeout: int = 30) -> tuple:
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return proc.returncode, proc.stdout, proc.stderr
    except Exception as e:
        return -1, "", str(e)


def ups_status(name: str) -> str:
    rc, out, _ = run_cmd(["upsc", f"{name}@localhost"], timeout=5)
    if rc != 0:
        return "unknown"
    for line in out.splitlines():
        if line.startswith("ups.status:"):
            status = line.split(":", 1)[1].strip()
            if "OL" in status:
                return "online"
            elif "OB" in status:
                return "onbatt"
            return "offline"
    return "unknown"


# --- Routes ---

@app.route("/")
@require_admin
def index():
    return send_from_directory(
        os.path.join(os.path.dirname(__file__), "static"), "index.html"
    )


@app.route("/api/ups", methods=["GET"])
@require_admin
def list_ups():
    try:
        content = read_file(os.path.join(NUT_DIR, "ups.conf"))
    except FileNotFoundError:
        return jsonify([])
    entries = parse_ups_conf(content)
    for e in entries:
        e["status"] = ups_status(e["name"])
    return jsonify(entries)


@app.route("/api/ups", methods=["POST"])
@require_admin
def add_ups():
    data = request.get_json(force=True) or {}
    name = data.get("name", "").strip()
    if not name:
        return jsonify({"error": "name is required"}), 400
    if not IDENTIFIER_REGEX.match(name):
        return jsonify({"error": "name contains invalid characters"}), 400
    directives = data.get("directives")
    if directives is not None and not isinstance(directives, dict):
        return jsonify({"error": "directives must be an object"}), 400
    path = os.path.join(NUT_DIR, "ups.conf")
    try:
        content = read_file(path)
    except FileNotFoundError:
        content = ""
    entries = parse_ups_conf(content)
    if any(e["name"] == name for e in entries):
        return jsonify({"error": "UPS already exists"}), 409
    new_entry = {"name": name, "directives": []}
    for key in ("driver", "port", "desc"):
        if key in data:
            new_entry[key] = data[key]
    for key, val in (directives or {}).items():
        new_entry["directives"].append([key, val])
    entries.append(new_entry)
    write_file(path, serialize_ups_conf(entries))
    return jsonify(new_entry), 201


@app.route("/api/ups/<name>", methods=["GET"])
@require_admin
def get_ups(name):
    if not IDENTIFIER_REGEX.match(name):
        return jsonify({"error": "name contains invalid characters"}), 400
    path = os.path.join(NUT_DIR, "ups.conf")
    try:
        content = read_file(path)
    except FileNotFoundError:
        return jsonify({"error": "not found"}), 404
    entries = parse_ups_conf(content)
    for e in entries:
        if e["name"] == name:
            e["status"] = ups_status(name)
            return jsonify(e)
    return jsonify({"error": "not found"}), 404


@app.route("/api/ups/<name>", methods=["PUT"])
@require_admin
def edit_ups(name):
    if not IDENTIFIER_REGEX.match(name):
        return jsonify({"error": "name contains invalid characters"}), 400
    data = request.get_json(force=True) or {}
    directives = data.get("directives")
    if directives is not None and not isinstance(directives, dict):
        return jsonify({"error": "directives must be an object"}), 400
    path = os.path.join(NUT_DIR, "ups.conf")
    try:
        content = read_file(path)
    except FileNotFoundError:
        return jsonify({"error": "not found"}), 404
    entries = parse_ups_conf(content)
    for e in entries:
        if e["name"] == name:
            for key in ("driver", "port", "desc"):
                if key in data:
                    e[key] = data[key]
                elif data.get("remove_" + key, False) and key in e:
                    del e[key]
            if directives is not None:
                e["directives"] = []
                for k, v in directives.items():
                    e["directives"].append([k, v])
            write_file(path, serialize_ups_conf(entries))
            e["status"] = ups_status(name)
            return jsonify(e)
    return jsonify({"error": "not found"}), 404


@app.route("/api/ups/<name>", methods=["DELETE"])
@require_admin
def delete_ups(name):
    if not IDENTIFIER_REGEX.match(name):
        return jsonify({"error": "name contains invalid characters"}), 400
    path = os.path.join(NUT_DIR, "ups.conf")
    try:
        content = read_file(path)
    except FileNotFoundError:
        return jsonify({"error": "not found"}), 404
    entries = parse_ups_conf(content)
    new_entries = [e for e in entries if e["name"] != name]
    if len(new_entries) == len(entries):
        return jsonify({"error": "not found"}), 404
    write_file(path, serialize_ups_conf(new_entries))
    return jsonify({"ok": True})


@app.route("/api/ups/scan", methods=["POST"])
@require_admin
def scan_ups():
    rc, out, err = run_cmd(["nut-scanner", "-U"], timeout=30)
    return jsonify({"returncode": rc, "stdout": out, "stderr": err})


@app.route("/api/users", methods=["GET"])
@require_admin
def list_users():
    try:
        content = read_file(os.path.join(NUT_DIR, "upsd.users"))
    except FileNotFoundError:
        return jsonify([])
    entries = parse_upsd_users(content)
    for e in entries:
        e["password"] = "\u2022\u2022\u2022\u2022\u2022\u2022"
    return jsonify(entries)


@app.route("/api/users", methods=["POST"])
@require_admin
def add_user():
    data = request.get_json(force=True) or {}
    name = data.get("name", "").strip()
    if not name:
        return jsonify({"error": "name is required"}), 400
    if not IDENTIFIER_REGEX.match(name):
        return jsonify({"error": "name contains invalid characters"}), 400
    directives = data.get("directives")
    if directives is not None and not isinstance(directives, dict):
        return jsonify({"error": "directives must be an object"}), 400
    path = os.path.join(NUT_DIR, "upsd.users")
    try:
        content = read_file(path)
    except FileNotFoundError:
        content = ""
    entries = parse_upsd_users(content)
    if any(e["name"] == name for e in entries):
        return jsonify({"error": "user already exists"}), 409
    new_entry = {"name": name, "directives": []}
    for key in ("password", "upsmon", "actions", "instcmds"):
        if key in data:
            new_entry[key] = data[key]
    for key, val in (directives or {}).items():
        new_entry["directives"].append([key, val])
    entries.append(new_entry)
    write_file(path, serialize_upsd_users(entries))
    new_entry["password"] = "\u2022\u2022\u2022\u2022\u2022\u2022"
    return jsonify(new_entry), 201


@app.route("/api/users/<name>", methods=["PUT"])
@require_admin
def edit_user(name):
    if not IDENTIFIER_REGEX.match(name):
        return jsonify({"error": "name contains invalid characters"}), 400
    data = request.get_json(force=True) or {}
    directives = data.get("directives")
    if directives is not None and not isinstance(directives, dict):
        return jsonify({"error": "directives must be an object"}), 400
    path = os.path.join(NUT_DIR, "upsd.users")
    try:
        content = read_file(path)
    except FileNotFoundError:
        return jsonify({"error": "not found"}), 404
    entries = parse_upsd_users(content)
    for e in entries:
        if e["name"] == name:
            for key in ("password", "upsmon", "actions", "instcmds"):
                if key in data:
                    e[key] = data[key]
            if directives is not None:
                e["directives"] = []
                for k, v in directives.items():
                    e["directives"].append([k, v])
            write_file(path, serialize_upsd_users(entries))
            e["password"] = "\u2022\u2022\u2022\u2022\u2022\u2022"
            return jsonify(e)
    return jsonify({"error": "not found"}), 404


@app.route("/api/users/<name>", methods=["DELETE"])
@require_admin
def delete_user(name):
    if not IDENTIFIER_REGEX.match(name):
        return jsonify({"error": "name contains invalid characters"}), 400
    path = os.path.join(NUT_DIR, "upsd.users")
    try:
        content = read_file(path)
    except FileNotFoundError:
        return jsonify({"error": "not found"}), 404
    entries = parse_upsd_users(content)
    new_entries = [e for e in entries if e["name"] != name]
    if len(new_entries) == len(entries):
        return jsonify({"error": "not found"}), 404
    write_file(path, serialize_upsd_users(new_entries))
    return jsonify({"ok": True})


@app.route("/api/config/<filename>", methods=["GET"])
@require_admin
def get_config(filename):
    if filename not in ALLOWED_CONFIGS:
        return jsonify({"error": "not allowed"}), 403
    path = os.path.join(NUT_DIR, filename)
    try:
        return read_file(path)
    except FileNotFoundError:
        return "", 404


@app.route("/api/config/<filename>", methods=["PUT"])
@require_admin
def put_config(filename):
    if filename not in ALLOWED_CONFIGS:
        return jsonify({"error": "not allowed"}), 403
    if filename == "upsd.users":
        return jsonify({"error": "upsd.users is read-only via this endpoint"}), 403
    path = os.path.join(NUT_DIR, filename)
    write_file(path, request.get_data(as_text=True))
    return jsonify({"ok": True})


@app.route("/api/service/<action>", methods=["POST"])
@require_admin
def service_action(action):
    if action == "restart-server":
        rc, out, err = run_cmd(["systemctl", "restart", "nut-server"])
    elif action == "restart-monitor":
        rc, out, err = run_cmd(["systemctl", "restart", "nut-monitor"])
    elif action == "restart-all":
        rc1, out1, err1 = run_cmd(["systemctl", "restart", "nut-server"])
        rc2, out2, err2 = run_cmd(["systemctl", "restart", "nut-monitor"])
        rc = rc1 or rc2
        out = out1 + out2
        err = err1 + err2
    elif action == "status":
        rc, out, err = run_cmd(["systemctl", "status", "nut-server", "nut-monitor"])
    else:
        return jsonify({"error": "unknown action"}), 400
    return jsonify({"returncode": rc, "stdout": out, "stderr": err})


@app.route("/api/driver/<ups_name>/<action>", methods=["POST"])
@require_admin
def driver_action(ups_name, action):
    if not IDENTIFIER_REGEX.match(ups_name):
        return jsonify({"error": "invalid ups name"}), 400
    if action not in ("start", "stop"):
        return jsonify({"error": "unknown action"}), 400
    rc, out, err = run_cmd(["upsdrvctl", action, ups_name], timeout=30)
    return jsonify({"returncode": rc, "stdout": out, "stderr": err})


@app.route("/api/logs/stream")
@require_admin
def stream_logs():
    proc = subprocess.Popen(
        [
            "journalctl",
            "-u", "nut-server",
            "-u", "nut-monitor",
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


@app.route("/api/logs/recent")
@require_admin
def recent_logs():
    lines = request.args.get("lines", "100")
    if not lines.isdigit():
        lines = "100"
    rc, out, err = run_cmd(
        [
            "journalctl",
            "-u", "nut-server",
            "-u", "nut-monitor",
            "-n", lines,
            "--no-pager",
        ],
        timeout=30,
    )
    return jsonify({"returncode": rc, "stdout": out, "stderr": err})


if __name__ == "__main__":
    app.run(host=NUT_ADMIN_HOST, port=NUT_ADMIN_PORT)
