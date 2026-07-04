from flask import Blueprint, request, jsonify

from auth import require_admin, require_auth
from config import IDENTIFIER_REGEX
from services.system import restart_server
from services.users import list_users, add_user, edit_user, delete_user

users_bp = Blueprint("users", __name__)


@users_bp.route("/api/users", methods=["GET"])
@require_auth
def list_users_handler():
    return jsonify(list_users())


@users_bp.route("/api/users", methods=["POST"])
@require_admin
def add_user_handler():
    data = request.get_json(force=True) or {}
    name = data.get("name", "").strip()
    if not name:
        return jsonify({"error": "name is required"}), 400
    if not IDENTIFIER_REGEX.match(name):
        return jsonify({"error": "name contains invalid characters"}), 400
    directives = data.get("directives")
    if directives is not None and not isinstance(directives, dict):
        return jsonify({"error": "directives must be an object"}), 400
    new_entry, err = add_user(data)
    if err:
        return jsonify({"error": err}), 409
    rc, _, _ = restart_server()
    if rc != 0:
        return jsonify({"error": "Failed to restart nut-server"}), 500
    return jsonify(new_entry), 201


@users_bp.route("/api/users/<name>", methods=["PUT"])
@require_admin
def edit_user_handler(name):
    if not IDENTIFIER_REGEX.match(name):
        return jsonify({"error": "name contains invalid characters"}), 400
    data = request.get_json(force=True) or {}
    directives = data.get("directives")
    if directives is not None and not isinstance(directives, dict):
        return jsonify({"error": "directives must be an object"}), 400
    e = edit_user(name, data)
    if e is None:
        return jsonify({"error": "not found"}), 404
    rc, _, _ = restart_server()
    if rc != 0:
        return jsonify({"error": "Failed to restart nut-server"}), 500
    return jsonify(e)


@users_bp.route("/api/users/<name>", methods=["DELETE"])
@require_admin
def delete_user_handler(name):
    if not IDENTIFIER_REGEX.match(name):
        return jsonify({"error": "name contains invalid characters"}), 400
    if not delete_user(name):
        return jsonify({"error": "not found"}), 404
    rc, _, _ = restart_server()
    if rc != 0:
        return jsonify({"error": "Failed to restart nut-server"}), 500
    return jsonify({"ok": True})