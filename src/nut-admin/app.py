#!/usr/bin/env python3
import os
import re
import subprocess

try:
    from flask import Flask, request, jsonify, Response, send_from_directory
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

app = Flask(__name__)

NUT_DIR = "/etc/nut"
ALLOWED_CONFIGS = {"ups.conf", "upsd.conf", "upsmon.conf", "upsd.users"}


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
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


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
def index():
    return send_from_directory(
        os.path.join(os.path.dirname(__file__), "static"), "index.html"
    )


@app.route("/api/ups", methods=["GET"])
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
def add_ups():
    data = request.get_json(force=True) or {}
    name = data.get("name", "").strip()
    if not name:
        return jsonify({"error": "name is required"}), 400
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
    for key, val in data.get("directives", {}).items():
        new_entry["directives"].append([key, val])
    entries.append(new_entry)
    write_file(path, serialize_ups_conf(entries))
    return jsonify(new_entry), 201


@app.route("/api/ups/<name>", methods=["GET"])
def get_ups(name):
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
def edit_ups(name):
    data = request.get_json(force=True) or {}
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
            if "directives" in data:
                e["directives"] = []
                for k, v in data["directives"].items():
                    e["directives"].append([k, v])
            write_file(path, serialize_ups_conf(entries))
            e["status"] = ups_status(name)
            return jsonify(e)
    return jsonify({"error": "not found"}), 404


@app.route("/api/ups/<name>", methods=["DELETE"])
def delete_ups(name):
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
def scan_ups():
    rc, out, err = run_cmd(["nut-scanner", "-U"], timeout=30)
    return jsonify({"returncode": rc, "stdout": out, "stderr": err})


@app.route("/api/users", methods=["GET"])
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
def add_user():
    data = request.get_json(force=True) or {}
    name = data.get("name", "").strip()
    if not name:
        return jsonify({"error": "name is required"}), 400
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
    for key, val in data.get("directives", {}).items():
        new_entry["directives"].append([key, val])
    entries.append(new_entry)
    write_file(path, serialize_upsd_users(entries))
    new_entry["password"] = "\u2022\u2022\u2022\u2022\u2022\u2022"
    return jsonify(new_entry), 201


@app.route("/api/users/<name>", methods=["PUT"])
def edit_user(name):
    data = request.get_json(force=True) or {}
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
            if "directives" in data:
                e["directives"] = []
                for k, v in data["directives"].items():
                    e["directives"].append([k, v])
            write_file(path, serialize_upsd_users(entries))
            e["password"] = "\u2022\u2022\u2022\u2022\u2022\u2022"
            return jsonify(e)
    return jsonify({"error": "not found"}), 404


@app.route("/api/users/<name>", methods=["DELETE"])
def delete_user(name):
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
def get_config(filename):
    if filename not in ALLOWED_CONFIGS:
        return jsonify({"error": "not allowed"}), 403
    path = os.path.join(NUT_DIR, filename)
    try:
        return read_file(path)
    except FileNotFoundError:
        return "", 404


@app.route("/api/config/<filename>", methods=["PUT"])
def put_config(filename):
    if filename not in ALLOWED_CONFIGS:
        return jsonify({"error": "not allowed"}), 403
    if filename == "upsd.users":
        return jsonify({"error": "upsd.users is read-only via this endpoint"}), 403
    path = os.path.join(NUT_DIR, filename)
    write_file(path, request.get_data(as_text=True))
    return jsonify({"ok": True})


@app.route("/api/service/<action>", methods=["POST"])
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
def driver_action(ups_name, action):
    if action not in ("start", "stop"):
        return jsonify({"error": "unknown action"}), 400
    rc, out, err = run_cmd(["upsdrvctl", action, ups_name], timeout=30)
    return jsonify({"returncode": rc, "stdout": out, "stderr": err})


@app.route("/api/logs/stream")
def stream_logs():
    def generate():
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
        try:
            for line in proc.stdout:
                yield f"data: {line.rstrip(chr(10))}\n\n"
        finally:
            proc.terminate()
            proc.wait()

    return Response(generate(), mimetype="text/event-stream")


@app.route("/api/logs/recent")
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
    app.run(host="0.0.0.0", port=8081)
