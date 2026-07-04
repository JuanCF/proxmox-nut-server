# Authentication Plan: Session Login + Per-User API Keys

Status: **implemented**. This is now a historical design doc — verify current behavior against the code (`auth.py`, `services/auth_db.py`, `routes/auth.py`, `manage.py`) rather than trusting it literally.

## Goal

Add two authentication layers to NutWatch:

1. **Session login** for humans using the web dashboard (cookie-based, automatic).
2. **Per-user API keys** for machines/scripts hitting the API (`Authorization: Bearer <key>`).

Both resolve to an **account** with a **role**. This keeps the lean stack (raw
`sqlite3` like `services/history.py`, no SQLAlchemy / Flask-Login).

Accounts + per-user API keys are the **only** auth mechanism. The legacy
single-secret env-var key is **removed** (see decision below);
bootstrap and lockout recovery are handled by a CLI command instead.

## Decisions (locked)

- **Roles:** `admin` + `viewer`.
  - `admin` — full access (edit config, restart services, manage accounts/keys).
  - `viewer` — read-only: can view the dashboard/data but cannot mutate config,
    restart services, or manage accounts/keys.
- **API-key scope:** a key **inherits its owner's role**. An admin's key acts as
  admin; a viewer's key acts as viewer.
- **First admin / bootstrap:** created via a **first-run Setup page** in the UI,
  **with an explicit "Skip" option**. If skipped, the app keeps working exactly
  as it does today — fully open, no auth, no API key required. Auth only turns on
  once an admin account exists.
- **Drop the legacy env-var key:** the single-secret env var is removed entirely
  (no parallel auth path). Bootstrap and lockout **recovery** are handled by a
  **CLI management command** (`create-admin` / `reset-password`), the standard
  approach (Django, GitLab, etc.).

## Design in one line

`require_admin` becomes "resolve a principal from **one of**: a Flask **session
cookie** (humans) or an `Authorization: Bearer <key>` (machines, per-user keys)."
Role checks gate mutating/admin-only endpoints.

---

## Backend

### Dependencies
None new required. Werkzeug (password hashing) and itsdangerous (signed
sessions) already ship with Flask 3.1.3. Login rate-limiting is hand-rolled
(small in-memory counter) rather than adding `flask-limiter`.

### 1. New DB module — `services/auth_db.py`
Reuses the `_ensure_schema` / `get_db` pattern from `services/history.py`.
New DB file `NUTWATCH_AUTH_DB` (default `/var/lib/nutwatch/auth.db`).

```sql
accounts(
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  username      TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  role          TEXT NOT NULL DEFAULT 'viewer',   -- 'admin' | 'viewer'
  is_active     INTEGER NOT NULL DEFAULT 1,
  created_at    REAL NOT NULL,
  last_login_at REAL
)

api_keys(
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  account_id   INTEGER NOT NULL,   -- FK -> accounts.id
  label        TEXT,
  key_prefix   TEXT NOT NULL,      -- first 8 chars, for display/identification
  key_hash     TEXT NOT NULL,      -- SHA-256 of the raw key (never store raw)
  created_at   REAL NOT NULL,
  last_used_at REAL,
  revoked_at   REAL
)
```

- Passwords: Werkzeug `generate_password_hash(method='pbkdf2:sha256')`.
- API keys: generated with `secrets.token_urlsafe(32)`; stored as SHA-256 hash
  only + an 8-char `key_prefix`. Raw key shown **once** at creation.
- Revoke = set `revoked_at` (soft delete, preserves audit trail).

### 2. `config.py` changes
- `NUTWATCH_SECRET_KEY` — auto-generate + persist (instance file / auth DB) if
  unset, so sessions survive restarts.
- Session cookie flags: `HttpOnly`, `SameSite=Lax`, `Secure` (env toggle for
  HTTP-only LAN deployments).
- **Remove the legacy env-var key** and every reference to it (`config.py:9`,
  imports in `auth.py`). Grep the tree to catch usages before deleting.

### 3. `auth.py` rewrite
- `resolve_principal()` returns the acting account from, in order: **session
  cookie -> Bearer API key (DB)**. Updates `api_keys.last_used_at` on key hits.
  Ignores revoked/inactive keys and inactive accounts.
- `require_admin` / `require_admin_strict` keep their names, now backed by
  `resolve_principal()` + role check (admin required).
- New `require_auth` (any authenticated principal, incl. viewer) for read
  endpoints that should still be gated once auth is on.
- **Bootstrap rule** (mirrors today): if zero accounts exist -> everything open
  (first-run + "Skip" path). Once an admin account exists -> enforce.

### 4. New blueprint — `routes/auth.py`
Registered in `routes/__init__.py` + `app.py`.

| Method + path              | Access        | Purpose                                   |
|----------------------------|---------------|-------------------------------------------|
| `GET  /api/auth/status`    | public        | Is login configured? current bootstrap state |
| `POST /api/auth/setup`     | first-run only| Create first admin (blocked once any account exists) |
| `POST /api/auth/login`     | public        | username+password -> set session cookie (rate-limited) |
| `POST /api/auth/logout`    | session       | Clear session                             |
| `GET  /api/auth/me`        | session       | Current identity + role                   |
| `GET/POST/PUT/DELETE /api/accounts` | admin | Account management (create/edit/deactivate) |
| `GET  /api/apikeys`        | auth          | List current account's keys (metadata only) |
| `POST /api/apikeys`        | auth          | Create key -> returns raw key ONCE        |
| `DELETE /api/apikeys/<id>` | auth (owner)  | Revoke a key                              |

### 5. `app.py`
Set `app.secret_key`, session config, register `auth_bp`.

### 6. CLI management command — `manage.py` (or `python -m nutwatch`)
Replaces the legacy env-var key for bootstrap/recovery. Runs against `auth.db`
directly, no HTTP/session needed:
- `create-admin <username>` — create (or promote) an admin; prompts for password.
- `reset-password <username>` — set a new password for an existing account.
- `list-accounts` — show accounts + roles (for confirming/recovering access).

This is the lockout escape hatch: even with the UI enforcing auth, an operator
with shell access can always create/reset an admin.

### 7. Tests
- Extend `tests/test_auth.py`: principal resolution (session vs Bearer),
  bootstrap open->closed, revoked keys, inactive accounts, admin vs viewer role
  gating, key-inherits-owner-role.
- New `tests/test_routes_auth.py`: setup (and skip), login/logout, `/me`,
  accounts CRUD, apikeys create/list/revoke, first-run guard on `/setup`.
- New `tests/test_manage_cli.py`: create-admin, reset-password, list-accounts.

---

## Frontend

### 1. `api.ts`
Same-origin cookies are sent automatically; add optional in-memory bearer
fallback and a 401 handler that redirects to login.

### 2. `AuthProvider` (new context)
Loads `GET /api/auth/me` + `GET /api/auth/status`. `App.tsx` gates rendering:
- No accounts yet and not skipped -> **Setup** page (with Skip button).
- Skipped / open mode -> app renders as today.
- Auth on, not logged in -> **Login** page.
- Logged in -> app; role gates admin-only UI (hide/disable edit + Accounts for
  viewers).

### 3. New components
- `Setup.tsx` — first-run admin creation, with **Skip** (continue open).
- `Login.tsx` — username/password.
- `ApiKeys.tsx` — list (label / prefix / created / last-used), create modal
  (shows raw key once + copy button), revoke.
- `Accounts.tsx` — admin-only user CRUD with role selector.
- Header: show username + logout control.
- Sidebar: add **Accounts** and **API Keys** entries (admin sees both; viewer
  sees API Keys for their own account). Routes wired in `App.tsx`.

> Naming: **Accounts / API Keys** — never "Users" — to avoid colliding with the
> existing NUT `upsd.users` section (`components/Users.tsx`).

---

## Rollout & safety
- Stays open until a first admin is created (or Skip chosen), so existing
  installs keep working until the operator opts in to auth.
- **Breaking change:** the legacy single-secret env-var key is removed. Anyone
  currently setting it must migrate to an account (`manage.py create-admin`) +
  per-user API key. Call this out in the changelog / release notes.
- Lockout recovery: `manage.py create-admin` / `reset-password` via shell.
- New DB auto-creates; no migration of existing data.
- Update `README.md` / `AGENTS.md` docs: remove the legacy env-var key, add
  `NUTWATCH_AUTH_DB`, `NUTWATCH_SECRET_KEY`, cookie flags, and the CLI commands.
- No git commits will be made automatically; changes left in the working tree
  for review.

## Implementation order
1. `services/auth_db.py` (schema + helpers) + unit tests
2. `config.py` (secret key, cookie config; **remove the legacy env-var key**)
3. `auth.py` (`resolve_principal`, role checks, bootstrap)
4. `routes/auth.py` + register in `routes/__init__.py`, `app.py`
5. `manage.py` CLI (`create-admin`, `reset-password`, `list-accounts`)
6. Backend tests (`test_auth.py`, `test_routes_auth.py`, `test_manage_cli.py`)
7. Frontend: `AuthProvider`, `api.ts`, Setup/Login gating
8. Frontend: `ApiKeys.tsx`, `Accounts.tsx`, Sidebar/header wiring
9. Docs update
