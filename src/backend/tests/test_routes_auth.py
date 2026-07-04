import pytest
from flask import Flask

from routes.auth import auth_bp, _login_attempts
from services import auth_db


def _make_app():
    app = Flask(__name__)
    app.config["TESTING"] = True
    app.secret_key = "test-secret"
    app.register_blueprint(auth_bp)
    return app


@pytest.fixture(autouse=True)
def _clear_login_attempts():
    _login_attempts.clear()


# ── /api/auth/status ───────────────────────────────────────────────────

def test_status_not_bootstrapped():
    app = _make_app()
    with app.test_client() as c:
        resp = c.get("/api/auth/status")
        assert resp.status_code == 200
        assert resp.get_json() == {"bootstrapped": False, "authenticated": False}


def test_status_bootstrapped_not_authenticated():
    auth_db.create_account("admin", "adminpass123", role="admin")
    app = _make_app()
    with app.test_client() as c:
        resp = c.get("/api/auth/status")
        data = resp.get_json()
        assert data["bootstrapped"] is True
        assert data["authenticated"] is False


# ── /api/auth/setup ─────────────────────────────────────────────────────

def test_setup_creates_first_admin_and_logs_in():
    app = _make_app()
    with app.test_client() as c:
        resp = c.post("/api/auth/setup", json={"username": "admin", "password": "adminpass123"})
        assert resp.status_code == 201
        data = resp.get_json()
        assert data["role"] == "admin"

        me = c.get("/api/auth/me")
        assert me.status_code == 200
        assert me.get_json()["username"] == "admin"


def test_setup_blocked_once_account_exists():
    auth_db.create_account("admin", "adminpass123", role="admin")
    app = _make_app()
    with app.test_client() as c:
        resp = c.post("/api/auth/setup", json={"username": "someone", "password": "password123"})
        assert resp.status_code == 403


def test_setup_requires_username_and_password():
    app = _make_app()
    with app.test_client() as c:
        resp = c.post("/api/auth/setup", json={"username": "admin"})
        assert resp.status_code == 400


def test_setup_requires_min_password_length():
    app = _make_app()
    with app.test_client() as c:
        resp = c.post("/api/auth/setup", json={"username": "admin", "password": "short"})
        assert resp.status_code == 400


# ── /api/auth/login + /logout + /me ────────────────────────────────────

def test_login_logout_flow():
    auth_db.create_account("admin", "adminpass123", role="admin")
    app = _make_app()
    with app.test_client() as c:
        resp = c.post("/api/auth/login", json={"username": "admin", "password": "adminpass123"})
        assert resp.status_code == 200

        me = c.get("/api/auth/me")
        assert me.status_code == 200
        assert me.get_json()["username"] == "admin"

        logout = c.post("/api/auth/logout")
        assert logout.status_code == 200

        me_after = c.get("/api/auth/me")
        assert me_after.status_code == 401


def test_login_invalid_credentials():
    auth_db.create_account("admin", "adminpass123", role="admin")
    app = _make_app()
    with app.test_client() as c:
        resp = c.post("/api/auth/login", json={"username": "admin", "password": "wrong"})
        assert resp.status_code == 401


def test_login_rate_limited_after_repeated_failures():
    auth_db.create_account("admin", "adminpass123", role="admin")
    app = _make_app()
    with app.test_client() as c:
        for _ in range(5):
            c.post("/api/auth/login", json={"username": "admin", "password": "wrong"})
        resp = c.post("/api/auth/login", json={"username": "admin", "password": "wrong"})
        assert resp.status_code == 429


def test_me_unauthorized_without_session_or_key():
    auth_db.create_account("admin", "adminpass123", role="admin")
    app = _make_app()
    with app.test_client() as c:
        resp = c.get("/api/auth/me")
        assert resp.status_code == 401


# ── /api/accounts (admin only) ──────────────────────────────────────────

def _login(client, username, password):
    return client.post("/api/auth/login", json={"username": username, "password": password})


def test_accounts_crud_as_admin():
    auth_db.create_account("admin", "adminpass123", role="admin")
    app = _make_app()
    with app.test_client() as c:
        _login(c, "admin", "adminpass123")

        create = c.post("/api/accounts", json={"username": "bob", "password": "bobpass123", "role": "viewer"})
        assert create.status_code == 201
        bob_id = create.get_json()["id"]

        listing = c.get("/api/accounts")
        assert listing.status_code == 200
        usernames = [a["username"] for a in listing.get_json()]
        assert "bob" in usernames

        update = c.put(f"/api/accounts/{bob_id}", json={"role": "admin"})
        assert update.status_code == 200
        assert update.get_json()["role"] == "admin"

        deactivate = c.delete(f"/api/accounts/{bob_id}")
        assert deactivate.status_code == 200
        assert deactivate.get_json()["is_active"] is False


def test_accounts_forbidden_for_viewer():
    auth_db.create_account("admin", "adminpass123", role="admin")
    auth_db.create_account("bob", "bobpass123", role="viewer")
    app = _make_app()
    with app.test_client() as c:
        _login(c, "bob", "bobpass123")
        resp = c.get("/api/accounts")
        assert resp.status_code == 403


def test_accounts_unauthorized_without_login():
    auth_db.create_account("admin", "adminpass123", role="admin")
    app = _make_app()
    with app.test_client() as c:
        resp = c.get("/api/accounts")
        assert resp.status_code == 401


# ── /api/apikeys (self-service) ─────────────────────────────────────────

def test_apikeys_create_list_revoke():
    auth_db.create_account("admin", "adminpass123", role="admin")
    app = _make_app()
    with app.test_client() as c:
        _login(c, "admin", "adminpass123")

        create = c.post("/api/apikeys", json={"label": "ci key"})
        assert create.status_code == 201
        created = create.get_json()
        assert "key" in created
        key_id = created["id"]

        listing = c.get("/api/apikeys")
        assert listing.status_code == 200
        keys = listing.get_json()
        assert len(keys) == 1
        assert "key" not in keys[0]

        revoke = c.delete(f"/api/apikeys/{key_id}")
        assert revoke.status_code == 200


def test_apikeys_scoped_to_owner():
    auth_db.create_account("admin", "adminpass123", role="admin")
    auth_db.create_account("bob", "bobpass123", role="viewer")
    app = _make_app()
    with app.test_client() as c:
        _login(c, "admin", "adminpass123")
        create = c.post("/api/apikeys", json={"label": "admin key"})
        key_id = create.get_json()["id"]
        c.post("/api/auth/logout")

        _login(c, "bob", "bobpass123")
        revoke = c.delete(f"/api/apikeys/{key_id}")
        assert revoke.status_code == 404

        listing = c.get("/api/apikeys")
        assert listing.get_json() == []
