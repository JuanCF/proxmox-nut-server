from flask import Blueprint, request, jsonify

from auth import require_admin, require_auth
from config import IDENTIFIER_REGEX
from services import wol as wol_service

wol_bp = Blueprint("wol", __name__)


@wol_bp.route("/api/wol/targets", methods=["GET"])
@require_auth
def list_targets():
    targets = wol_service.list_targets()
    return jsonify({"targets": targets})


@wol_bp.route("/api/wol/targets", methods=["POST"])
@require_admin
def create_target():
    data = request.get_json(force=True) or {}
    name = data.get("name", "").strip()
    mac = data.get("mac", "").strip()
    if not name:
        return jsonify({"error": "name is required"}), 400
    if not IDENTIFIER_REGEX.match(name):
        return jsonify({"error": "invalid name format"}), 400
    if not mac:
        return jsonify({"error": "mac is required"}), 400
    try:
        target = wol_service.add_target(
            name=name,
            mac=mac,
            broadcast=data.get("broadcast", "255.255.255.255").strip(),
            description=data.get("description", "").strip(),
        )
    except ValueError as e:
        return jsonify({"error": str(e)}), 400
    if target is None:
        return jsonify({"error": "target already exists"}), 409
    return jsonify(target), 201


@wol_bp.route("/api/wol/targets/<name>", methods=["PUT"])
@require_admin
def update_target(name):
    if not IDENTIFIER_REGEX.match(name):
        return jsonify({"error": "invalid name format"}), 400
    data = request.get_json(force=True) or {}
    try:
        target = wol_service.update_target(
            name=name,
            mac=data.get("mac", "").strip() or None,
            broadcast=data.get("broadcast", "").strip() or None,
            description=data.get("description", "").strip() if "description" in data else None,
        )
    except ValueError as e:
        return jsonify({"error": str(e)}), 400
    if target is None:
        return jsonify({"error": "not found"}), 404
    return jsonify(target)


@wol_bp.route("/api/wol/targets/<name>", methods=["DELETE"])
@require_admin
def delete_target(name):
    if not IDENTIFIER_REGEX.match(name):
        return jsonify({"error": "invalid name format"}), 400
    if not wol_service.delete_target(name):
        return jsonify({"error": "not found"}), 404
    return jsonify({"ok": True})


@wol_bp.route("/api/wol/targets/<name>/wake", methods=["POST"])
@require_admin
def wake_target(name):
    if not IDENTIFIER_REGEX.match(name):
        return jsonify({"error": "invalid name format"}), 400
    try:
        wol_service.send_wol(name)
    except ValueError as e:
        return jsonify({"error": str(e)}), 404
    except RuntimeError as e:
        return jsonify({"error": str(e)}), 500
    return jsonify({"ok": True})


@wol_bp.route("/api/wol/wake-all", methods=["POST"])
@require_admin
def wake_all():
    results = wol_service.wake_all()
    return jsonify({"results": results})


@wol_bp.route("/api/wol/mappings", methods=["GET"])
@require_auth
def list_mappings():
    mappings = wol_service.list_mappings()
    return jsonify({"mappings": mappings})


@wol_bp.route("/api/wol/mappings", methods=["POST"])
@require_admin
def create_mapping():
    data = request.get_json(force=True) or {}
    ups = data.get("ups", "").strip()
    event = data.get("event", "").strip()
    targets = data.get("targets", [])
    if not ups:
        return jsonify({"error": "ups is required"}), 400
    if not IDENTIFIER_REGEX.match(ups):
        return jsonify({"error": "ups must match IDENTIFIER_REGEX"}), 400
    if not event:
        return jsonify({"error": "event is required"}), 400
    if not isinstance(targets, list) or len(targets) == 0:
        return jsonify({"error": "targets must be a non-empty list"}), 400
    try:
        mapping = wol_service.add_mapping(ups, event, targets)
    except ValueError as e:
        return jsonify({"error": str(e)}), 400
    return jsonify(mapping), 201


@wol_bp.route("/api/wol/mappings/<int:index>", methods=["DELETE"])
@require_admin
def delete_mapping(index):
    if not wol_service.delete_mapping(index):
        return jsonify({"error": "not found"}), 404
    return jsonify({"ok": True})


@wol_bp.route("/api/wol/network-hosts", methods=["GET"])
@require_auth
def list_network_hosts():
    return jsonify({"hosts": wol_service.scan_network_hosts()})