from flask import Blueprint, request, jsonify

from auth import require_admin, require_auth
from services.hooks import get_hook, put_hook, delete_hook, list_hooks
from config import IDENTIFIER_REGEX

hooks_bp = Blueprint("hooks", __name__)


@hooks_bp.route("/api/hooks/<upsname>", methods=["GET"])
@require_auth
def list_hooks_handler(upsname):
    if not IDENTIFIER_REGEX.match(upsname):
        return jsonify({"error": "invalid ups name"}), 400
    return jsonify({"hooks": list_hooks(upsname)})


@hooks_bp.route("/api/hooks/<upsname>/<event>", methods=["GET"])
@require_admin
def get_hook_handler(upsname, event):
    if not IDENTIFIER_REGEX.match(upsname):
        return jsonify({"error": "invalid ups name"}), 400
    if not IDENTIFIER_REGEX.match(event):
        return jsonify({"error": "invalid event"}), 400
    content = get_hook(upsname, event)
    if content is None:
        return jsonify({"error": "not found"}), 404
    return jsonify({"content": content})


@hooks_bp.route("/api/hooks/<upsname>/<event>", methods=["PUT"])
@require_admin
def put_hook_handler(upsname, event):
    if not IDENTIFIER_REGEX.match(upsname):
        return jsonify({"error": "invalid ups name"}), 400
    if not IDENTIFIER_REGEX.match(event):
        return jsonify({"error": "invalid event"}), 400
    data = request.get_json(force=True) or {}
    content = data.get("content", "")
    try:
        put_hook(upsname, event, content)
    except ValueError as e:
        return jsonify({"error": str(e)}), 400
    return jsonify({"ok": True})


@hooks_bp.route("/api/hooks/<upsname>/<event>", methods=["DELETE"])
@require_admin
def delete_hook_handler(upsname, event):
    if not IDENTIFIER_REGEX.match(upsname):
        return jsonify({"error": "invalid ups name"}), 400
    if not IDENTIFIER_REGEX.match(event):
        return jsonify({"error": "invalid event"}), 400
    delete_hook(upsname, event)
    return jsonify({"ok": True})
