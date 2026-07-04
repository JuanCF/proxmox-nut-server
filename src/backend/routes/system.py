from flask import Blueprint, request, jsonify

from auth import require_admin, require_admin_strict, require_auth
from config import ALLOWED_CONFIGS, IDENTIFIER_REGEX
from services.resources import get_system_resources
from services.system import (
    restart_server,
    restart_monitor,
    restart_all,
    reboot_system,
    shutdown_system,
    restart_nutwatch,
    service_status,
    detailed_service_status,
    driver_action,
    get_config,
    put_config,
)

system_bp = Blueprint("system", __name__)


@system_bp.route("/api/config/<filename>", methods=["GET"])
@require_auth
def get_config_handler(filename):
    if filename not in ALLOWED_CONFIGS:
        return jsonify({"error": "not allowed"}), 403
    content = get_config(filename)
    if content is None:
        return "", 404
    return content


@system_bp.route("/api/config/<filename>", methods=["PUT"])
@require_admin
def put_config_handler(filename):
    if filename not in ALLOWED_CONFIGS:
        return jsonify({"error": "not allowed"}), 403
    if filename == "upsd.users":
        return jsonify({"error": "upsd.users is read-only via this endpoint"}), 403
    if not put_config(filename, request.get_data(as_text=True)):
        return jsonify({"error": "failed"}), 500
    return jsonify({"ok": True})


@system_bp.route("/api/service/<action>", methods=["POST"])
@require_admin
def service_action_handler(action):
    if action == "restart-server":
        rc, out, err = restart_server()
    elif action == "restart-monitor":
        rc, out, err = restart_monitor()
    elif action == "restart-all":
        rc, out, err = restart_all()
    elif action == "status":
        rc, out, err = service_status()
    else:
        return jsonify({"error": "unknown action"}), 400
    return jsonify({"returncode": rc, "stdout": out, "stderr": err})


@system_bp.route("/api/service/status-detailed", methods=["GET"])
@require_auth
def service_status_detailed_handler():
    return jsonify(detailed_service_status())


@system_bp.route("/api/driver/<ups_name>/<action>", methods=["POST"])
@require_admin
def driver_action_handler(ups_name, action):
    if not IDENTIFIER_REGEX.match(ups_name):
        return jsonify({"error": "invalid ups name"}), 400
    if action not in ("start", "stop", "restart"):
        return jsonify({"error": "unknown action"}), 400
    rc, out, err = driver_action(ups_name, action)
    return jsonify({"returncode": rc, "stdout": out, "stderr": err})


@system_bp.route("/api/system/resources", methods=["GET"])
@require_auth
def system_resources_handler():
    return jsonify(get_system_resources())


@system_bp.route("/api/system/reboot", methods=["POST"])
@require_admin_strict
def system_reboot_handler():
    rc, out, err = reboot_system()
    return jsonify({"returncode": rc, "stdout": out, "stderr": err})


@system_bp.route("/api/system/shutdown", methods=["POST"])
@require_admin_strict
def system_shutdown_handler():
    rc, out, err = shutdown_system()
    return jsonify({"returncode": rc, "stdout": out, "stderr": err})


@system_bp.route("/api/system/restart-nutwatch", methods=["POST"])
@require_admin_strict
def system_restart_nutwatch_handler():
    rc, out, err = restart_nutwatch()
    return jsonify({"returncode": rc, "stdout": out, "stderr": err})
