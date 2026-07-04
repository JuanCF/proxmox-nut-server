import hashlib
import logging
import os
import secrets
import sqlite3
import threading
import time

from werkzeug.security import check_password_hash, generate_password_hash

logger = logging.getLogger(__name__)

AUTH_DB = os.environ.get("NUTWATCH_AUTH_DB", "/var/lib/nutwatch/auth.db")
ROLES = ("admin", "viewer")

# Schema is created once per database path. Tracking the path (rather than a
# bool) keeps this correct when AUTH_DB is repointed, e.g. in tests.
_schema_lock = threading.Lock()
_schema_ready_for = None


def _ensure_schema(conn):
    global _schema_ready_for
    if _schema_ready_for == AUTH_DB:
        return
    with _schema_lock:
        if _schema_ready_for == AUTH_DB:
            return
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("""CREATE TABLE IF NOT EXISTS accounts (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            username      TEXT NOT NULL UNIQUE,
            password_hash TEXT NOT NULL,
            role          TEXT NOT NULL DEFAULT 'viewer',
            is_active     INTEGER NOT NULL DEFAULT 1,
            created_at    REAL NOT NULL,
            last_login_at REAL
        )""")
        conn.execute("""CREATE TABLE IF NOT EXISTS api_keys (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            account_id   INTEGER NOT NULL,
            label        TEXT,
            key_prefix   TEXT NOT NULL,
            key_hash     TEXT NOT NULL UNIQUE,
            created_at   REAL NOT NULL,
            last_used_at REAL,
            revoked_at   REAL
        )""")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_api_keys_account ON api_keys(account_id)")
        conn.execute("""CREATE TABLE IF NOT EXISTS meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )""")
        conn.commit()
        _schema_ready_for = AUTH_DB


def get_db():
    db_dir = os.path.dirname(AUTH_DB)
    if db_dir:
        os.makedirs(db_dir, exist_ok=True)
    conn = sqlite3.connect(AUTH_DB)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("PRAGMA foreign_keys=ON")
    _ensure_schema(conn)
    return conn


def get_or_create_secret_key() -> str:
    conn = get_db()
    try:
        row = conn.execute("SELECT value FROM meta WHERE key = 'secret_key'").fetchone()
        if row:
            return row["value"]
        value = secrets.token_hex(32)
        conn.execute(
            "INSERT INTO meta (key, value) VALUES ('secret_key', ?)", [value]
        )
        conn.commit()
        return value
    finally:
        conn.close()


def _row_to_account(row) -> dict:
    return {
        "id": row["id"],
        "username": row["username"],
        "role": row["role"],
        "is_active": bool(row["is_active"]),
        "created_at": row["created_at"],
        "last_login_at": row["last_login_at"],
    }


def count_accounts() -> int:
    conn = get_db()
    try:
        row = conn.execute("SELECT COUNT(*) AS n FROM accounts").fetchone()
        return row["n"]
    finally:
        conn.close()


def create_account(username: str, password: str, role: str = "viewer") -> tuple:
    if role not in ROLES:
        return None, "invalid role"
    conn = get_db()
    try:
        existing = conn.execute(
            "SELECT id FROM accounts WHERE username = ?", [username]
        ).fetchone()
        if existing:
            return None, "username already exists"
        password_hash = generate_password_hash(password, method="pbkdf2:sha256")
        cursor = conn.execute(
            "INSERT INTO accounts (username, password_hash, role, is_active, created_at) "
            "VALUES (?, ?, ?, 1, ?)",
            [username, password_hash, role, time.time()],
        )
        conn.commit()
        row = conn.execute(
            "SELECT * FROM accounts WHERE id = ?", [cursor.lastrowid]
        ).fetchone()
        return _row_to_account(row), None
    finally:
        conn.close()


def get_account_by_id(account_id: int) -> dict | None:
    conn = get_db()
    try:
        row = conn.execute("SELECT * FROM accounts WHERE id = ?", [account_id]).fetchone()
        return _row_to_account(row) if row else None
    finally:
        conn.close()


def get_account_by_username(username: str) -> dict | None:
    conn = get_db()
    try:
        row = conn.execute(
            "SELECT * FROM accounts WHERE username = ?", [username]
        ).fetchone()
        return _row_to_account(row) if row else None
    finally:
        conn.close()


def list_accounts() -> list[dict]:
    conn = get_db()
    try:
        rows = conn.execute("SELECT * FROM accounts ORDER BY username").fetchall()
        return [_row_to_account(r) for r in rows]
    finally:
        conn.close()


def verify_login(username: str, password: str) -> dict | None:
    conn = get_db()
    try:
        row = conn.execute(
            "SELECT * FROM accounts WHERE username = ?", [username]
        ).fetchone()
        if not row or not row["is_active"]:
            return None
        if not check_password_hash(row["password_hash"], password):
            return None
        conn.execute(
            "UPDATE accounts SET last_login_at = ? WHERE id = ?",
            [time.time(), row["id"]],
        )
        conn.commit()
        return _row_to_account(row)
    finally:
        conn.close()


def update_account(account_id: int, role: str | None = None, is_active: bool | None = None,
                    password: str | None = None) -> dict | None:
    if role is not None and role not in ROLES:
        return None
    conn = get_db()
    try:
        row = conn.execute("SELECT * FROM accounts WHERE id = ?", [account_id]).fetchone()
        if not row:
            return None
        if role is not None:
            conn.execute("UPDATE accounts SET role = ? WHERE id = ?", [role, account_id])
        if is_active is not None:
            conn.execute(
                "UPDATE accounts SET is_active = ? WHERE id = ?",
                [1 if is_active else 0, account_id],
            )
        if password is not None:
            password_hash = generate_password_hash(password, method="pbkdf2:sha256")
            conn.execute(
                "UPDATE accounts SET password_hash = ? WHERE id = ?",
                [password_hash, account_id],
            )
        conn.commit()
        row = conn.execute("SELECT * FROM accounts WHERE id = ?", [account_id]).fetchone()
        return _row_to_account(row)
    finally:
        conn.close()


def _hash_api_key(raw_key: str) -> str:
    return hashlib.sha256(raw_key.encode()).hexdigest()


def _row_to_api_key(row) -> dict:
    return {
        "id": row["id"],
        "account_id": row["account_id"],
        "label": row["label"],
        "key_prefix": row["key_prefix"],
        "created_at": row["created_at"],
        "last_used_at": row["last_used_at"],
        "revoked_at": row["revoked_at"],
    }


def create_api_key(account_id: int, label: str | None = None) -> tuple:
    raw_key = secrets.token_urlsafe(32)
    key_prefix = raw_key[:8]
    key_hash = _hash_api_key(raw_key)
    conn = get_db()
    try:
        cursor = conn.execute(
            "INSERT INTO api_keys (account_id, label, key_prefix, key_hash, created_at) "
            "VALUES (?, ?, ?, ?, ?)",
            [account_id, label, key_prefix, key_hash, time.time()],
        )
        conn.commit()
        row = conn.execute(
            "SELECT * FROM api_keys WHERE id = ?", [cursor.lastrowid]
        ).fetchone()
        return raw_key, _row_to_api_key(row)
    finally:
        conn.close()


def list_api_keys(account_id: int) -> list[dict]:
    conn = get_db()
    try:
        rows = conn.execute(
            "SELECT * FROM api_keys WHERE account_id = ? ORDER BY created_at DESC",
            [account_id],
        ).fetchall()
        return [_row_to_api_key(r) for r in rows]
    finally:
        conn.close()


def resolve_api_key(raw_key: str) -> dict | None:
    """Look up the active account owning a raw API key, updating last_used_at."""
    key_hash = _hash_api_key(raw_key)
    conn = get_db()
    try:
        row = conn.execute(
            "SELECT ak.*, a.username, a.role, a.is_active AS account_active "
            "FROM api_keys ak JOIN accounts a ON a.id = ak.account_id "
            "WHERE ak.key_hash = ?",
            [key_hash],
        ).fetchone()
        if not row or row["revoked_at"] or not row["account_active"]:
            return None
        conn.execute(
            "UPDATE api_keys SET last_used_at = ? WHERE id = ?",
            [time.time(), row["id"]],
        )
        conn.commit()
        return {
            "id": row["account_id"],
            "username": row["username"],
            "role": row["role"],
            "is_active": bool(row["account_active"]),
        }
    finally:
        conn.close()


def revoke_api_key(key_id: int, account_id: int) -> bool:
    conn = get_db()
    try:
        row = conn.execute(
            "SELECT * FROM api_keys WHERE id = ? AND account_id = ?",
            [key_id, account_id],
        ).fetchone()
        if not row or row["revoked_at"]:
            return False
        conn.execute(
            "UPDATE api_keys SET revoked_at = ? WHERE id = ?", [time.time(), key_id]
        )
        conn.commit()
        return True
    finally:
        conn.close()
