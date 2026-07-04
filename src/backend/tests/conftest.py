import os

import pytest


@pytest.fixture(autouse=True)
def _patch_auth_db(tmp_path, monkeypatch) -> None:
    # Fresh, empty auth DB per test -> bootstrap-open mode (mirrors the old
    # no-auth-configured default of fully open access) unless a test seeds
    # accounts itself.
    db_path = os.path.join(tmp_path, "test_auth.db")
    monkeypatch.setattr("services.auth_db.AUTH_DB", db_path)
    monkeypatch.setattr("services.auth_db._schema_ready_for", None)
