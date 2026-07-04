import argparse
import os

import pytest

import manage
from services import auth_db


@pytest.fixture(autouse=True)
def _patch_auth_db(tmp_path, monkeypatch):
    db_path = os.path.join(tmp_path, "test_auth.db")
    monkeypatch.setattr("services.auth_db.AUTH_DB", db_path)
    monkeypatch.setattr("services.auth_db._schema_ready_for", None)


def _args(**kwargs):
    return argparse.Namespace(**kwargs)


def test_create_admin_new_account(capsys):
    rc = manage.cmd_create_admin(_args(username="admin", password="adminpass123"))
    assert rc == 0
    account = auth_db.get_account_by_username("admin")
    assert account["role"] == "admin"
    assert auth_db.verify_login("admin", "adminpass123") is not None
    assert "Created admin account" in capsys.readouterr().out


def test_create_admin_promotes_existing(capsys):
    auth_db.create_account("bob", "oldpass123", role="viewer")
    rc = manage.cmd_create_admin(_args(username="bob", password="newpass123"))
    assert rc == 0
    account = auth_db.get_account_by_username("bob")
    assert account["role"] == "admin"
    assert auth_db.verify_login("bob", "newpass123") is not None
    assert "Promoted existing account" in capsys.readouterr().out


def test_create_admin_rejects_short_password():
    rc = manage.cmd_create_admin(_args(username="admin", password="short"))
    assert rc == 1
    assert auth_db.count_accounts() == 0


def test_reset_password():
    auth_db.create_account("bob", "oldpass123", role="viewer")
    rc = manage.cmd_reset_password(_args(username="bob", password="brandnew123"))
    assert rc == 0
    assert auth_db.verify_login("bob", "brandnew123") is not None
    assert auth_db.verify_login("bob", "oldpass123") is None


def test_reset_password_unknown_user():
    rc = manage.cmd_reset_password(_args(username="nosuchuser", password="brandnew123"))
    assert rc == 1


def test_reset_password_rejects_short_password():
    auth_db.create_account("bob", "oldpass123", role="viewer")
    rc = manage.cmd_reset_password(_args(username="bob", password="short"))
    assert rc == 1
    assert auth_db.verify_login("bob", "oldpass123") is not None


def test_list_accounts_empty(capsys):
    rc = manage.cmd_list_accounts(_args())
    assert rc == 0
    assert "No accounts configured" in capsys.readouterr().out


def test_list_accounts_lists_usernames(capsys):
    auth_db.create_account("admin", "adminpass123", role="admin")
    auth_db.create_account("bob", "bobpass123", role="viewer")
    rc = manage.cmd_list_accounts(_args())
    assert rc == 0
    out = capsys.readouterr().out
    assert "admin" in out
    assert "bob" in out
