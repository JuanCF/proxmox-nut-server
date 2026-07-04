# nutwatch Modularization Plan

> **Note:** This is a historical design spec. The modularization has been completed and the codebase has evolved significantly since this document was written. See `AGENTS.md` and `README.md` for the current architecture.

Extracted from the architecture session (`architecture.md`) — covers migrating from the monolithic `app.py` to a modular structure, including the proposed bundling and release pipeline.

## Current State (historical)

`app.py` (~685 lines) is a monolith containing:
- Flask app setup and `require_admin` auth decorator
- Parsers/serializers for NUT config files (`ups.conf`, `upsd.users`, `nut-scanner`, `upsmon.conf`)
- File I/O helpers (`read_file`, `write_file` with atomic replace)
- NUT command wrappers (`run_cmd`, `ups_status`, service/driver actions, journalctl)
- All Flask routes (~15 routes) for UPS, users, config, services, logs

The frontend is a single `static/index.html` (~580 lines) with inline CSS and inline JavaScript.

## Goals

1. Modularize **both** backend and frontend
2. **More structured architecture** (not just file splitting) — Flask Blueprints + service layer
3. **Lightweight component structure** for the frontend — plain ES modules, no framework

## Key Architectural Decisions

| Aspect | Approach |
|--------|----------|
| **Backend route grouping** | Flask Blueprints per resource (ups, users, config, service) |
| **Business logic** | Service layer (`services/`) separated from routes — routes only handle HTTP |
| **Parsers** | Pure functions with no side effects — move to `parsers/` |
| **Config I/O** | Single `services/nut_config.py` with atomic writes |
| **Auth** | Extracted to `auth.py` |
| **Frontend modules** | ES modules (`<script type="module">`), no build step |
| **State** | Simple pub/sub state object (`state.js`) — no framework |
| **Components** | Vanilla JS helper functions (modal, dialog, badge, card rendering) |
| **Test imports** | `parsers/__init__.py` re-exports symbols for backward-compatible test imports |

## Directory Layout

```
src/backend/
├── app.py                    # Flask app factory, entrypoint
├── config.py                 # Env vars, NUT_DIR, ALLOWED_CONFIGS, IDENTIFIER_REGEX
├── auth.py                   # require_admin decorator
├── utils.py                  # Shared utilities
├── __init__.py               # Package marker
├── parsers/
│   ├── __init__.py           # Re-exports for backward-compatible test imports
│   ├── ups_conf.py           # parse_ups_conf, serialize_ups_conf
│   ├── upsd_users.py         # parse_upsd_users, serialize_upsd_users
│   ├── nut_scanner.py        # parse_nut_scanner_output
│   └── monitor.py            # parse_monitor_lines, add/remove_monitor_line, find_monitor_user
├── services/
│   ├── __init__.py
│   ├── ups.py                # UPS business logic
│   ├── users.py              # User management logic
│   └── system.py             # System/service command wrappers
├── routes/
│   ├── __init__.py           # Registers all blueprints with app
│   ├── ups.py                # Blueprint: /api/ups*
│   ├── users.py              # Blueprint: /api/users*
│   ├── logs.py               # Blueprint: /api/logs/*
│   └── system.py             # Blueprint: /api/service, /api/driver
├── static/
│   ├── index.html            # SPA shell (HTML structure only)
│   └── src/                  # (future: split frontend ES modules)
├── tests/
│   └── test_parsers.py       # Parser roundtrip tests
├── install.sh                # Deploy script (local copy or tarball download)
├── nutwatch.service         # Systemd unit
└── requirements.txt          # Python dependencies
```

## Module Breakdown

### `config.py`
Constants and configuration from environment variables:
- `NUT_DIR` — path to NUT config files
- `ALLOWED_CONFIGS` — set of config filenames the API can read/write
- `IDENTIFIER_REGEX` — validation regex for UPS names and usernames
- `NUTWATCH_HOST`, `NUTWATCH_PORT`

### `auth.py`

The `require_admin` and `require_admin_strict` decorators. `require_admin` checks whether a principal is resolved (session cookie or per-user API key); if no accounts exist yet, auth is disabled. `require_admin_strict` returns 403 until an admin account is configured — used for destructive endpoints (reboot, shutdown). Both validate a `Bearer` token from the `Authorization` header as one of the resolution paths.

> Note: this section predates the accounts/API-keys system in `docs/auth-plan.md`; see that doc and `services/auth_db.py` for the current design.

### `parsers/`
Pure functions for parsing and serializing NUT configuration files. Each parser has zero side effects and is independently testable.

| Module | Functions |
|--------|-----------|
| `ups_conf.py` | `parse_ups_conf(content: str) -> list`, `serialize_ups_conf(entries: list) -> str` |
| `upsd_users.py` | `parse_upsd_users(content: str) -> list`, `serialize_upsd_users(entries: list) -> str` |
| `nut_scanner.py` | `parse_nut_scanner_output(stdout: str) -> list` |
| `monitor.py` | `parse_monitor_lines(content: str) -> list`, `remove_monitor_line(content, upsname) -> str`, `add_monitor_line(content, ...) -> str`, `find_monitor_user(content) -> tuple` |

### `services/`
Business logic layer — operations that interact with the system (filesystem, subprocesses, NUT commands).

| Module | Functions |
|--------|-----------|
| `ups.py` | UPS status, ups.conf read/write, nut-scanner integration |
| `users.py` | upsd.users read/write, user CRUD helpers |
| `system.py` | Service control (start/stop/restart), journalctl log retrieval, driver actions |

### `routes/`
Flask Blueprints — one per resource. Each blueprint only handles HTTP concerns (request parsing, response formatting) and delegates to services.

| Blueprint | Endpoints |
|-----------|-----------|
| `ups.py` | `GET/POST /api/ups`, `GET/PUT/DELETE /api/ups/<name>`, `POST /api/ups/scan` |
| `users.py` | `GET/POST /api/users`, `PUT/DELETE /api/users/<name>` |
| `logs.py` | `GET /api/logs/stream`, `GET /api/logs/recent` |
| `system.py` | `POST /api/service/<action>`, `POST /api/driver/<ups_name>/<action>` |

### `static/` (Frontend)
Currently a single `static/index.html` with inline CSS and JavaScript. Planned split into ES modules (see Frontend Bundling Strategy above).

## Test Import Strategy

Existing tests do `from app import parse_ups_conf, ...`. To keep backward compatibility, `parsers/__init__.py` will re-export the main symbols:

```python
from parsers.ups_conf import parse_ups_conf, serialize_ups_conf
from parsers.upsd_users import parse_upsd_users, serialize_upsd_users
from parsers.nut_scanner import parse_nut_scanner_output
from parsers.monitor import (parse_monitor_lines, remove_monitor_line,
                              add_monitor_line, find_monitor_user)
```

Tests can then import from `parsers` directly, or continue using `from app import ...` if `app.py` also re-exports.

## Frontend Bundling Strategy (Future)

The frontend is currently a single `static/index.html` with inline CSS/JS. The plan is to split it into ES modules:

- **`index.html`** — HTML structure only (nav, sections, modal overlays). Loads modules via `<script type="module">`.
- **`styles.css`** — All CSS extracted from the original inline `<style>` block.
- **`js/api.js`** — Fetch wrapper: `api(path, opts)` that prefixes `/api`, handles errors, parses JSON.
- **`js/state.js`** — Simple reactive state object with pub/sub for cross-module communication.
- **`js/components.js`** — Shared UI helpers: `showDialog()`, `showConfirm()`, `showDangerConfirm()`, `showAlert()`, `badge(status)`, modal open/close.
- **`js/ups.js`** — UPS section: `loadUps()`, `openUpsModal()`, `saveUps()`, `deleteUps()`, `driverAction()`, `scanUps()`, `addScannedUps()`.
- **`js/users.js`** — Users section: `loadUsers()`, `openUserModal()`, `saveUser()`, `deleteUser()`.
- **`js/logs.js`** — Logs section: `startLogStream()`, `toggleLogPause()`, `loadRecentLogs()`.
- **`js/config.js`** — Config editor section: `loadConfig()`, `saveConfig()`.
- **`js/main.js`** — App initialization: `showSection()` routing, event delegation for UPS/user action buttons, initial data load.

**Development mode**: `index.html` loads individual source files directly via `<script type="module" src="js/api.js">` etc. No build step needed.

**Production mode**: `index.html` loads a single bundle `<script type="module" src="app.js">` produced by esbuild:
```bash
esbuild static/js/*.js --bundle --minify --outfile=static/app.js
```

The `Makefile` and CI workflow can be extended to include esbuild bundling when the frontend is modularized.

## CI + Release Pipeline

### Trigger
Every git tag pushed matching `v*.*.*`.

### Build Steps
1. Run lint, shellcheck, and Python tests (existing CI steps)
2. Build the tarball with `make build-tarball`
3. Upload `nutwatch.tar.gz` as a GitHub Release asset attached to the tag

### Release Host
The release lives on the user's personal GitHub account (e.g., `github.com/JuanCF/nutwatch/releases`). The Proxmox helper script (submitted to `community-scripts/ProxmoxVE`) only references the release URL — the release artifacts stay in the personal repo.

### Bundle Contents
The tarball includes everything the VM needs to run nutwatch:

| What | Included |
|------|----------|
| Python backend modules | `app.py`, `auth.py`, `config.py`, `utils.py`, `__init__.py`, `parsers/`, `services/`, `routes/` |
| Frontend | `static/index.html` |
| Service file | `nutwatch.service` |
| Dependencies | `requirements.txt` |

## Deploy Script Changes (`vm/nut-vm.sh`)

### Current Behavior
`build_nutwatch_script()` downloads individual files from raw GitHub URLs:
```bash
curl .../src/backend/app.py          → /opt/nutwatch/app.py
curl .../src/backend/static/index.html  → /opt/nutwatch/static/index.html
curl .../nutwatch.service            → /etc/systemd/system/nutwatch.service
```

### New Behavior (Release-based)
Instead of individual file downloads, the deploy script downloads one tarball:

```bash
NUTWATCH_URL_PREFIX="https://github.com/JuanCF/nutwatch/releases/download/${NUTWATCH_REF}/"
curl -fsSL "${NUTWATCH_URL_PREFIX}nutwatch.tar.gz" -o /tmp/nutwatch.tar.gz
tar -xzf /tmp/nutwatch.tar.gz -C /opt/nutwatch/
```

`NUTWATCH_REF` is pinned to a specific tag (e.g., `v1.0.0`).

### Systemd Service Update
`ExecStart` path stays the same since the tarball extracts the app entry point at the expected location:
```ini
ExecStart=/opt/nutwatch/venv/bin/python3 /opt/nutwatch/app.py
```

### URL Override for Local Development
`nut-vm.sh` accepts an env var or flag to override the download URL:

```bash
# Production (default): GitHub Release
NUTWATCH_URL_PREFIX="https://github.com/JuanCF/nutwatch/releases/download/v1.0.0/"

# Local development override:
NUTWATCH_URL_PREFIX="http://192.168.1.100:8080/" ./nut-vm.sh
```

This can be exposed as:
- An environment variable: `NUTWATCH_URL_PREFIX`
- A CLI flag: `--nutwatch-url=http://...`
- A prompt in `collect_nut_config()`: "Use custom nutwatch URL? (leave blank for GitHub release)"

## Dev Workflow

Since nutwatch must run on the VM (it calls `upsdrvctl`, `systemctl`, `journalctl`, reads/writes `/etc/nut/`), there is no local dev server that fully works. The VM with NUT installed is the runtime environment. Development approaches:

### 1. Direct Edit on VM
SSH into VM, edit Python/JS files directly, `systemctl restart nutwatch`. Simplest but no version control on the VM.

### 2. Local Source, Remote Deploy
Edit locally in the repo, `scp`/`rsync` individual files to the VM, restart the service.

### 3. Local Tarball Build + Serve (Mirrors CI)
Build the tarball locally exactly as CI would, then serve it over HTTP so the VM can download it:

```bash
# 1. Create the tarball
make build-tarball

# 2. Serve it locally
cd /tmp && python3 -m http.server 8080

# 3. Override URL in nut-vm.sh
NUTWATCH_URL_PREFIX="http://YOUR_IP:8080" ./nut-vm.sh
```

The tarball built locally is indistinguishable from a CI-generated one — same structure, same files. The VM doesn't know or care where it came from. The developer's machine must be reachable from the VM (same LAN or accessible IP), which is typical for Proxmox setups.
