import time

from flask import Blueprint, request, jsonify

from auth import require_auth
from config import IDENTIFIER_REGEX
from services.history import get_history, get_available_variables

history_bp = Blueprint("history", __name__)

RANGE_MAP = {
    "1h": 3600,
    "24h": 86400,
    "7d": 604800,
    "30d": 2592000,
}


@history_bp.route("/api/history/<ups>", methods=["GET"])
@require_auth
def history_query(ups):
    if not IDENTIFIER_REGEX.match(ups):
        return jsonify({"error": "invalid UPS name"}), 400
    range_str = request.args.get("range", "24h")
    if range_str not in RANGE_MAP:
        return jsonify({"error": f"invalid range, must be one of: {','.join(RANGE_MAP)}"}), 400
    since = time.time() - RANGE_MAP[range_str]
    variables_param = request.args.get("variables")
    variables = variables_param.split(",") if variables_param else None
    if variables is not None:
        variables = [v.strip() for v in variables if v.strip()]
    result = get_history(ups, variables=variables, since=since)
    result["range"] = range_str
    result["since"] = since
    return jsonify(result)


@history_bp.route("/api/history/<ups>/variables", methods=["GET"])
@require_auth
def history_variables(ups):
    if not IDENTIFIER_REGEX.match(ups):
        return jsonify({"error": "invalid UPS name"}), 400
    vars_list = get_available_variables(ups)
    return jsonify({"ups": ups, "variables": vars_list})