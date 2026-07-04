import time
from collections import defaultdict

from flask import Blueprint, jsonify, request, session

from auth import require_admin, require_admin_strict, require_auth, resolve_principal
from services import auth_db

auth_bp = Blueprint("auth", __name__)

_LOGIN_MAX_ATTEMPTS = 5
_LOGIN_WINDOW_SECONDS = 300
_login_attempts: dict[str, list] = defaultdict(list)


def _login_rate_limited(key: str) -> bool:
    now = time.time()
    attempts = _login_attempts[key]
    attempts[:] = [t for t in attempts if now - t < _LOGIN_WINDOW_SECONDS]
    return len(attempts) >= _LOGIN_MAX_ATTEMPTS


def _record_login_attempt(key: str) -> None:
    _login_attempts[key].append(time.time())


@auth_bp.route("/api/auth/status", methods=["GET"])
def auth_status():
    bootstrapped = auth_db.count_accounts() > 0
    return jsonify({
        "bootstrapped": bootstrapped,
        "authenticated": bootstrapped and resolve_principal() is not None,
    })


@auth_bp.route("/api/auth/setup", methods=["POST"])
def auth_setup():
    data = request.get_json(force=True) or {}
    username = (data.get("username") or "").strip()
    password = data.get("password") or ""
    if not username or not password:
        return jsonify({"error": "username and password are required"}), 400
    if len(password) < 8:
        return jsonify({"error": "password must be at least 8 characters"}), 400
    # Atomic check-and-insert so concurrent setups can't create two admins.
    account, err = auth_db.create_initial_admin(username, password)
    if err == "setup already completed":
        return jsonify({"error": err}), 403
    if err:
        return jsonify({"error": err}), 409
    session.clear()
    session["account_id"] = account["id"]
    return jsonify(account), 201


@auth_bp.route("/api/auth/login", methods=["POST"])
def auth_login():
    data = request.get_json(force=True) or {}
    username = (data.get("username") or "").strip()
    password = data.get("password") or ""
    rate_key = f"{request.remote_addr}:{username}"
    if _login_rate_limited(rate_key):
        return jsonify({"error": "too many attempts, try again later"}), 429
    account = auth_db.verify_login(username, password) if username and password else None
    if account is None:
        _record_login_attempt(rate_key)
        return jsonify({"error": "invalid credentials"}), 401
    session.clear()
    session["account_id"] = account["id"]
    return jsonify(account)


@auth_bp.route("/api/auth/logout", methods=["POST"])
def auth_logout():
    session.clear()
    return jsonify({"ok": True})


@auth_bp.route("/api/auth/me", methods=["GET"])
def auth_me():
    principal = resolve_principal()
    if principal is None:
        return jsonify({"error": "unauthorized"}), 401
    return jsonify(principal)


# ── Accounts (admin only) ─────────────────────────────────────────────

@auth_bp.route("/api/accounts", methods=["GET"])
@require_admin
def list_accounts_handler():
    return jsonify(auth_db.list_accounts())


@auth_bp.route("/api/accounts", methods=["POST"])
@require_admin_strict
def create_account_handler():
    data = request.get_json(force=True) or {}
    username = (data.get("username") or "").strip()
    password = data.get("password") or ""
    role = data.get("role", "viewer")
    if not username or not password:
        return jsonify({"error": "username and password are required"}), 400
    if len(password) < 8:
        return jsonify({"error": "password must be at least 8 characters"}), 400
    account, err = auth_db.create_account(username, password, role=role)
    if err:
        return jsonify({"error": err}), 409
    return jsonify(account), 201


@auth_bp.route("/api/accounts/<int:account_id>", methods=["PUT"])
@require_admin
def update_account_handler(account_id):
    data = request.get_json(force=True) or {}
    try:
        account = auth_db.update_account(
            account_id,
            role=data.get("role"),
            is_active=data.get("is_active"),
            password=data.get("password") or None,
        )
    except ValueError as e:
        return jsonify({"error": str(e)}), 409
    if account is None:
        return jsonify({"error": "not found"}), 404
    return jsonify(account)


@auth_bp.route("/api/accounts/<int:account_id>", methods=["DELETE"])
@require_admin
def deactivate_account_handler(account_id):
    try:
        account = auth_db.update_account(account_id, is_active=False)
    except ValueError as e:
        return jsonify({"error": str(e)}), 409
    if account is None:
        return jsonify({"error": "not found"}), 404
    return jsonify(account)


# ── API keys (any authenticated principal, scoped to self) ───────────

@auth_bp.route("/api/apikeys", methods=["GET"])
@require_auth
def list_apikeys_handler():
    principal = resolve_principal()
    if principal is None:
        return jsonify([])
    return jsonify(auth_db.list_api_keys(principal["id"]))


@auth_bp.route("/api/apikeys", methods=["POST"])
@require_auth
def create_apikey_handler():
    principal = resolve_principal()
    if principal is None:
        return jsonify({"error": "create an account first"}), 400
    data = request.get_json(force=True) or {}
    raw_key, record = auth_db.create_api_key(principal["id"], label=data.get("label"))
    result = dict(record)
    result["key"] = raw_key
    return jsonify(result), 201


@auth_bp.route("/api/apikeys/<int:key_id>", methods=["DELETE"])
@require_auth
def revoke_apikey_handler(key_id):
    principal = resolve_principal()
    if principal is None or not auth_db.revoke_api_key(key_id, principal["id"]):
        return jsonify({"error": "not found"}), 404
    return jsonify({"ok": True})
