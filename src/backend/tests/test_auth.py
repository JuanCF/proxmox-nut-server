import os

import pytest
from flask import Flask, session

from services import auth_db


def _make_app():
    app = Flask(__name__)
    app.config["TESTING"] = True
    app.secret_key = "test-secret"
    return app


@pytest.fixture(autouse=True)
def _patch_auth_db(tmp_path, monkeypatch):
    db_path = os.path.join(tmp_path, "test_auth.db")
    monkeypatch.setattr("services.auth_db.AUTH_DB", db_path)
    monkeypatch.setattr("services.auth_db._schema_ready_for", None)


def _make_admin():
    account, _ = auth_db.create_account("admin", "adminpass123", role="admin")
    return account


def _make_viewer():
    account, _ = auth_db.create_account("bob", "viewerpass123", role="viewer")
    return account


# ── Bootstrap (no accounts yet) -> fully open ─────────────────────────

def test_require_admin_open_when_no_accounts():
    app = _make_app()

    from auth import require_admin

    @app.route("/test")
    @require_admin
    def handler():
        return "ok"

    with app.test_client() as c:
        resp = c.get("/test")
        assert resp.status_code == 200


def test_require_auth_open_when_no_accounts():
    app = _make_app()

    from auth import require_auth

    @app.route("/test")
    @require_auth
    def handler():
        return "ok"

    with app.test_client() as c:
        resp = c.get("/test")
        assert resp.status_code == 200


def test_require_admin_strict_blocked_when_no_accounts():
    app = _make_app()

    from auth import require_admin_strict

    @app.route("/test")
    @require_admin_strict
    def handler():
        return "ok"

    with app.test_client() as c:
        resp = c.get("/test")
        assert resp.status_code == 403


# ── Bearer API key resolution ─────────────────────────────────────────

def test_require_admin_valid_admin_bearer_key():
    admin = _make_admin()
    raw_key, _ = auth_db.create_api_key(admin["id"])
    app = _make_app()

    from auth import require_admin

    @app.route("/test")
    @require_admin
    def handler():
        return "ok"

    with app.test_client() as c:
        resp = c.get("/test", headers={"Authorization": f"Bearer {raw_key}"})
        assert resp.status_code == 200


def test_require_admin_viewer_bearer_key_forbidden():
    _make_admin()  # any admin account closes the bootstrap-open window
    viewer = _make_viewer()
    raw_key, _ = auth_db.create_api_key(viewer["id"])
    app = _make_app()

    from auth import require_admin

    @app.route("/test")
    @require_admin
    def handler():
        return "ok"

    with app.test_client() as c:
        resp = c.get("/test", headers={"Authorization": f"Bearer {raw_key}"})
        assert resp.status_code == 403


def test_require_auth_viewer_bearer_key_allowed():
    _make_admin()
    viewer = _make_viewer()
    raw_key, _ = auth_db.create_api_key(viewer["id"])
    app = _make_app()

    from auth import require_auth

    @app.route("/test")
    @require_auth
    def handler():
        return "ok"

    with app.test_client() as c:
        resp = c.get("/test", headers={"Authorization": f"Bearer {raw_key}"})
        assert resp.status_code == 200


def test_require_admin_invalid_bearer_key():
    _make_admin()
    app = _make_app()

    from auth import require_admin

    @app.route("/test")
    @require_admin
    def handler():
        return "ok"

    with app.test_client() as c:
        resp = c.get("/test", headers={"Authorization": "Bearer not-a-real-key"})
        assert resp.status_code == 401


def test_require_admin_missing_header():
    _make_admin()
    app = _make_app()

    from auth import require_admin

    @app.route("/test")
    @require_admin
    def handler():
        return "ok"

    with app.test_client() as c:
        resp = c.get("/test")
        assert resp.status_code == 401


def test_revoked_key_rejected():
    admin = _make_admin()
    raw_key, record = auth_db.create_api_key(admin["id"])
    auth_db.revoke_api_key(record["id"], admin["id"])
    app = _make_app()

    from auth import require_admin

    @app.route("/test")
    @require_admin
    def handler():
        return "ok"

    with app.test_client() as c:
        resp = c.get("/test", headers={"Authorization": f"Bearer {raw_key}"})
        assert resp.status_code == 401


def test_inactive_account_key_rejected():
    admin = _make_admin()
    # A second admin keeps an active admin around so the first can be
    # deactivated (the last active admin can't be deactivated).
    auth_db.create_account("admin2", "adminpass123", role="admin")
    raw_key, _ = auth_db.create_api_key(admin["id"])
    auth_db.update_account(admin["id"], is_active=False)
    app = _make_app()

    from auth import require_admin

    @app.route("/test")
    @require_admin
    def handler():
        return "ok"

    with app.test_client() as c:
        resp = c.get("/test", headers={"Authorization": f"Bearer {raw_key}"})
        assert resp.status_code == 401


# ── Session cookie resolution ─────────────────────────────────────────

def test_require_admin_valid_admin_session():
    admin = _make_admin()
    app = _make_app()

    from auth import require_admin

    @app.route("/set-session")
    def set_session():
        session["account_id"] = admin["id"]
        return "ok"

    @app.route("/test")
    @require_admin
    def handler():
        return "ok"

    with app.test_client() as c:
        c.get("/set-session")
        resp = c.get("/test")
        assert resp.status_code == 200


def test_require_admin_viewer_session_forbidden():
    _make_admin()
    viewer = _make_viewer()
    app = _make_app()

    from auth import require_admin

    @app.route("/set-session")
    def set_session():
        session["account_id"] = viewer["id"]
        return "ok"

    @app.route("/test")
    @require_admin
    def handler():
        return "ok"

    with app.test_client() as c:
        c.get("/set-session")
        resp = c.get("/test")
        assert resp.status_code == 403


def test_require_admin_strict_valid_admin_bearer():
    admin = _make_admin()
    raw_key, _ = auth_db.create_api_key(admin["id"])
    app = _make_app()

    from auth import require_admin_strict

    @app.route("/test")
    @require_admin_strict
    def handler():
        return "ok"

    with app.test_client() as c:
        resp = c.get("/test", headers={"Authorization": f"Bearer {raw_key}"})
        assert resp.status_code == 200


def test_require_admin_strict_invalid_bearer():
    _make_admin()
    app = _make_app()

    from auth import require_admin_strict

    @app.route("/test")
    @require_admin_strict
    def handler():
        return "ok"

    with app.test_client() as c:
        resp = c.get("/test", headers={"Authorization": "Bearer wrong"})
        assert resp.status_code == 401


# ── resolve_principal ──────────────────────────────────────────────────

def test_resolve_principal_none_without_credentials():
    _make_admin()
    app = _make_app()

    from auth import resolve_principal

    @app.route("/test")
    def handler():
        principal = resolve_principal()
        return "none" if principal is None else principal["username"]

    with app.test_client() as c:
        resp = c.get("/test")
        assert resp.data.decode() == "none"


def test_resolve_principal_key_inherits_owner_role():
    admin = _make_admin()
    raw_key, _ = auth_db.create_api_key(admin["id"])
    app = _make_app()

    from auth import resolve_principal

    @app.route("/test")
    def handler():
        principal = resolve_principal()
        return principal["role"]

    with app.test_client() as c:
        resp = c.get("/test", headers={"Authorization": f"Bearer {raw_key}"})
        assert resp.data.decode() == "admin"
