from flask import Blueprint, request, jsonify

from auth import require_admin, require_auth
from services.upsmon import get_upsmon_config, put_upsmon_config

upsmon_bp = Blueprint("upsmon", __name__)


@upsmon_bp.route("/api/upsmon/config", methods=["GET"])
@require_auth
def get_upsmon_config_handler():
    return jsonify(get_upsmon_config())


@upsmon_bp.route("/api/upsmon/config", methods=["PUT"])
@require_admin
def put_upsmon_config_handler():
    data = request.get_json(force=True) or {}
    if not isinstance(data, dict):
        return jsonify({"error": "body must be an object"}), 400
    try:
        put_upsmon_config(data)
    except ValueError as e:
        return jsonify({"error": str(e)}), 400
    return jsonify({"ok": True})
