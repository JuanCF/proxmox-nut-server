import pytest

from services import auth_db


def test_get_or_create_secret_key_persists():
    key1 = auth_db.get_or_create_secret_key()
    key2 = auth_db.get_or_create_secret_key()
    assert key1 == key2
    assert len(key1) == 64


def test_count_accounts_empty():
    assert auth_db.count_accounts() == 0


def test_create_account_and_login():
    account, err = auth_db.create_account("admin", "hunter22", role="admin")
    assert err is None
    assert account["username"] == "admin"
    assert account["role"] == "admin"
    assert account["is_active"] is True
    assert auth_db.count_accounts() == 1

    result = auth_db.verify_login("admin", "hunter22")
    assert result is not None
    assert result["username"] == "admin"

    assert auth_db.verify_login("admin", "wrongpass") is None
    assert auth_db.verify_login("nosuchuser", "hunter22") is None


def test_create_account_duplicate_username():
    auth_db.create_account("admin", "hunter22", role="admin")
    account, err = auth_db.create_account("admin", "other", role="viewer")
    assert account is None
    assert err == "username already exists"


def test_create_account_invalid_role():
    account, err = auth_db.create_account("bob", "pw", role="superuser")
    assert account is None
    assert err == "invalid role"


def test_inactive_account_cannot_login():
    account, _ = auth_db.create_account("bob", "pw12345", role="viewer")
    auth_db.update_account(account["id"], is_active=False)
    assert auth_db.verify_login("bob", "pw12345") is None


def test_update_account_role_and_password():
    account, _ = auth_db.create_account("bob", "pw12345", role="viewer")
    updated = auth_db.update_account(account["id"], role="admin")
    assert updated["role"] == "admin"

    auth_db.update_account(account["id"], password="newpassword")
    assert auth_db.verify_login("bob", "newpassword") is not None
    assert auth_db.verify_login("bob", "pw12345") is None


def test_cannot_deactivate_last_active_admin():
    admin, _ = auth_db.create_account("admin", "pw123456", role="admin")
    with pytest.raises(ValueError, match="cannot demote or deactivate the last active admin"):
        auth_db.update_account(admin["id"], is_active=False)
    with pytest.raises(ValueError, match="cannot demote or deactivate the last active admin"):
        auth_db.update_account(admin["id"], role="viewer")
    # Password-only change on the last admin is still allowed.
    assert auth_db.update_account(admin["id"], password="newpass123") is not None


def test_can_deactivate_admin_when_another_exists():
    a1, _ = auth_db.create_account("admin", "pw123456", role="admin")
    auth_db.create_account("admin2", "pw123456", role="admin")
    updated = auth_db.update_account(a1["id"], is_active=False)
    assert updated["is_active"] is False


def test_create_initial_admin_atomic():
    account, err = auth_db.create_initial_admin("admin", "pw123456")
    assert err is None
    assert account["role"] == "admin"
    # A second attempt is rejected once an account exists.
    account2, err2 = auth_db.create_initial_admin("admin2", "pw123456")
    assert account2 is None
    assert err2 == "setup already completed"


def test_list_accounts():
    auth_db.create_account("zed", "pw12345", role="viewer")
    auth_db.create_account("amy", "pw12345", role="admin")
    accounts = auth_db.list_accounts()
    assert [a["username"] for a in accounts] == ["amy", "zed"]


def test_api_key_create_and_resolve():
    account, _ = auth_db.create_account("bob", "pw12345", role="viewer")
    raw_key, record = auth_db.create_api_key(account["id"], label="my key")
    assert record["label"] == "my key"
    assert record["key_prefix"] == raw_key[:8]

    resolved = auth_db.resolve_api_key(raw_key)
    assert resolved is not None
    assert resolved["username"] == "bob"
    assert resolved["role"] == "viewer"


def test_api_key_resolve_invalid():
    assert auth_db.resolve_api_key("not-a-real-key") is None


def test_api_key_resolve_revoked():
    account, _ = auth_db.create_account("bob", "pw12345", role="viewer")
    raw_key, record = auth_db.create_api_key(account["id"])
    assert auth_db.revoke_api_key(record["id"], account["id"]) is True
    assert auth_db.resolve_api_key(raw_key) is None
    # Revoking again fails.
    assert auth_db.revoke_api_key(record["id"], account["id"]) is False


def test_api_key_resolve_inactive_account():
    account, _ = auth_db.create_account("bob", "pw12345", role="viewer")
    raw_key, _ = auth_db.create_api_key(account["id"])
    auth_db.update_account(account["id"], is_active=False)
    assert auth_db.resolve_api_key(raw_key) is None


def test_api_key_owner_cannot_revoke_others_key():
    a1, _ = auth_db.create_account("bob", "pw12345", role="viewer")
    a2, _ = auth_db.create_account("amy", "pw12345", role="viewer")
    _, record = auth_db.create_api_key(a1["id"])
    assert auth_db.revoke_api_key(record["id"], a2["id"]) is False


def test_list_api_keys_scoped_to_account():
    a1, _ = auth_db.create_account("bob", "pw12345", role="viewer")
    a2, _ = auth_db.create_account("amy", "pw12345", role="viewer")
    auth_db.create_api_key(a1["id"], label="bob-key")
    auth_db.create_api_key(a2["id"], label="amy-key")
    assert [k["label"] for k in auth_db.list_api_keys(a1["id"])] == ["bob-key"]
    assert [k["label"] for k in auth_db.list_api_keys(a2["id"])] == ["amy-key"]
