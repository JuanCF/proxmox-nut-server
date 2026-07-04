import functools
import logging

from flask import jsonify, request, session

from services.auth_db import count_accounts, get_account_by_id, resolve_api_key

logger = logging.getLogger("nutwatch")


def _sanitize_path(path: str) -> str:
    return path.replace("\n", "").replace("\r", "")


def resolve_principal() -> dict | None:
    """Resolve the acting account from a session cookie, then a Bearer API key.

    A key inherits its owner's role, so callers only need to check
    ``principal["role"]`` — there's no separate key-scope concept.
    """
    account_id = session.get("account_id")
    if account_id is not None:
        account = get_account_by_id(account_id)
        if account and account["is_active"]:
            return account
        # Stale session (account deleted/deactivated) — don't block a valid
        # Bearer key; fall through to Authorization-header resolution.

    auth_header = request.headers.get("Authorization", "")
    if auth_header.startswith("Bearer "):
        raw_key = auth_header[len("Bearer "):]
        account = resolve_api_key(raw_key)
        if account and account["is_active"]:
            return account
    return None


def _unauthorized():
    logger.warning("Auth failure from %s for %s", request.remote_addr, _sanitize_path(request.path))
    return jsonify({"error": "unauthorized"}), 401


def _forbidden():
    return jsonify({"error": "forbidden"}), 403


def require_auth(f):
    """Any authenticated principal (admin or viewer). Open during bootstrap."""
    @functools.wraps(f)
    def decorated(*args, **kwargs):
        if count_accounts() == 0:
            return f(*args, **kwargs)
        if resolve_principal() is None:
            return _unauthorized()
        return f(*args, **kwargs)

    return decorated


def require_admin(f):
    @functools.wraps(f)
    def decorated(*args, **kwargs):
        if count_accounts() == 0:
            return f(*args, **kwargs)
        principal = resolve_principal()
        if principal is None:
            return _unauthorized()
        if principal["role"] != "admin":
            return _forbidden()
        return f(*args, **kwargs)

    return decorated


def require_admin_strict(f):
    @functools.wraps(f)
    def decorated(*args, **kwargs):
        if count_accounts() == 0:
            logger.warning(
                "Strict-auth endpoint %s called with no admin account configured",
                _sanitize_path(request.path),
            )
            return jsonify({"error": "this endpoint requires an admin account to be configured"}), 403
        return require_admin(f)(*args, **kwargs)

    return decorated
