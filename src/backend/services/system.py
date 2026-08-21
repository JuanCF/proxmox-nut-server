import glob
import os
import threading
import time

from config import NUT_DIR, ALLOWED_CONFIGS, IDENTIFIER_REGEX
from parsers.ups_conf import parse_ups_conf
from utils import run_cmd, read_file, write_file, stop_driver_and_cleanup


def restart_server():
    return run_cmd(["systemctl", "restart", "nut-server"])


def restart_monitor():
    return run_cmd(["systemctl", "restart", "nut-monitor"])


def _ups_names() -> list[str]:
    try:
        content = read_file(os.path.join(NUT_DIR, "ups.conf"))
    except FileNotFoundError:
        return []
    return [entry["name"] for entry in parse_ups_conf(content)]


def _driver_status_units() -> list[str]:
    # NUT's systemd unit set varies by distro/version. Current packaging
    # (NUT 2.8.x, e.g. Ubuntu noble) starts drivers as nut-driver@<name>
    # template instances managed by nut-driver-enumerator and ships no bare
    # nut-driver.service; only some distros provide that wrapper unit.
    rc, out, _ = run_cmd(
        ["systemctl", "list-unit-files", "--no-legend", "--no-pager", "nut-driver.service"],
        timeout=5,
    )
    if rc == 0:
        for line in out.splitlines():
            if line.split() and line.split()[0] == "nut-driver.service":
                return ["nut-driver"]
    return [f"nut-driver@{name}" for name in _ups_names()]


def _pidfile_driver_active() -> tuple[bool, str]:
    # No systemd unit to ask (matches the Docker systemctl shim logic).
    for base in ("/var/run/nut", "/run/nut"):
        for pid_file in glob.glob(os.path.join(base, "*.pid")):
            if os.path.basename(pid_file) in ("upsd.pid", "upsmon.pid"):
                continue
            try:
                with open(pid_file, encoding="utf-8") as f:
                    pid = f.read().strip()
                if pid.isdigit() and os.path.exists(f"/proc/{pid}"):
                    return True, "active"
            except OSError:
                pass
    return False, "inactive"


def restart_driver():
    units = _driver_status_units()
    if units:
        rc = 0
        out = err = ""
        for unit in units:
            r, o, e = run_cmd(["systemctl", "restart", unit])
            rc = rc or r
            out += o
            err += e
        return rc, out, err
    # No systemd driver unit at all: fall back to upsdrvctl, which also works
    # through the Docker systemctl shim.
    rc1, out1, err1 = run_cmd(["upsdrvctl", "stop"], timeout=30)
    rc2, out2, err2 = run_cmd(["upsdrvctl", "start"], timeout=30)
    return rc1 or rc2, out1 + out2, err1 + err2


def restart_all():
    rc1, out1, err1 = run_cmd(["systemctl", "restart", "nut-server"])
    rc2, out2, err2 = run_cmd(["systemctl", "restart", "nut-monitor"])
    return rc1 or rc2, out1 + out2, err1 + err2


def reboot_system():
    return run_cmd(["systemctl", "reboot"], timeout=10)


def shutdown_system():
    return run_cmd(["systemctl", "poweroff"], timeout=10)


def restart_nutwatch():
    def _deferred():
        time.sleep(1)
        run_cmd(["systemctl", "restart", "nutwatch"], timeout=10)
    threading.Thread(target=_deferred, daemon=True).start()
    return 0, "restart scheduled", ""


def service_status():
    return run_cmd(["systemctl", "status", "nut-server", "nut-monitor"])


def detailed_service_status():
    services = ["nut-driver", "nut-server", "nut-monitor"]
    result = {}
    for svc in services:
        if svc == "nut-driver":
            units = _driver_status_units()
            if not units:
                active, state = _pidfile_driver_active()
                result[svc] = {"active": active, "state": state}
                continue
        else:
            units = [svc]
        rc, out, err = run_cmd(["systemctl", "is-active", *units], timeout=5)
        state = (out or err).strip()
        result[svc] = {"active": rc == 0, "state": state}
    return result


def _remove_stale_pid_files(ups_name: str) -> None:
    for base in ("/var/run/nut", "/run/nut"):
        for pid_file in glob.glob(os.path.join(base, f"*-{ups_name}.pid")):
            try:
                with open(pid_file, "r", encoding="utf-8") as f:
                    pid = f.read().strip()
                if pid and pid.isdigit() and not os.path.exists(f"/proc/{pid}"):
                    os.unlink(pid_file)
            except (OSError, ValueError):
                pass


def driver_action(ups_name: str, action: str):
    if not IDENTIFIER_REGEX.fullmatch(ups_name):
        return 1, "", f"Invalid UPS name: {ups_name}"
    if action == "stop":
        return stop_driver_and_cleanup(ups_name)
    if action == "restart":
        rc1, out1, err1 = stop_driver_and_cleanup(ups_name)
        rc2, out2, err2 = run_cmd(["upsdrvctl", "start", ups_name], timeout=30)
        return rc2, out1 + out2, err1 + err2
    if action == "start":
        _remove_stale_pid_files(ups_name)
        return run_cmd(["upsdrvctl", "start", ups_name], timeout=30)
    return run_cmd(["upsdrvctl", action, ups_name], timeout=30)


def get_config(filename: str):
    if filename not in ALLOWED_CONFIGS:
        return None
    path = os.path.join(NUT_DIR, filename)
    try:
        return read_file(path)
    except FileNotFoundError:
        return None


def put_config(filename: str, content: str):
    if filename not in ALLOWED_CONFIGS:
        return False
    if filename == "upsd.users":
        return False
    path = os.path.join(NUT_DIR, filename)
    try:
        write_file(path, content)
    except OSError:
        return False
    return True
