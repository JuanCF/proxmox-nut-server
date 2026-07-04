<h1><img src="assets/icons/logo-mark.svg" alt="" width="76" valign="middle"> NutWatch — NUT Web Administration Panel</h1>

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A standalone web administration panel for NUT (Network UPS Tools), installable on a Raspberry Pi or any Linux system, with Wake on LAN support and detailed UPS monitoring.

This repository also includes `vm/nut-vm.sh`, a bash script to automatically create an Ubuntu 24.04 VM on Proxmox VE with NUT pre-configured in netserver mode and the NutWatch web UI installed.

> **Why a VM instead of LXC?** NUT cannot run reliably in LXC containers due to kernel driver detachment restrictions. The VM script creates a lightweight VM specifically for NUT.

---

## Features

### Web Administration UI (NutWatch)

- **Dashboard** — System overview with stat cards (UPS count, users, active services, system health), CPU/memory/disk resource gauges, and quick-lists for all UPS devices and NUT services; one-click system actions (restart NutWatch, reboot, shutdown) with confirmation prompts
- **UPS Devices** — CRUD management with card-grid view showing real-time telemetry (battery charge bar, load bar, runtime, voltage), per-card driver start/stop/restart, USB scan integration, and recommended config defaults
- **UPS Detail Telemetry** — Deep-dive view grouped by subsystem (Battery, Input, Output, UPS, Device, Driver) with color-coded charge/load bars, unit-formatted values (V, Hz, W, VA, °C, A), runtime formatting, and raw variable dump; D3 gauge visualizations for battery charge and load
- **Historical Data & Charts** — Per-UPS time-series data collected every 60 seconds into SQLite, displayed as D3 line charts with selectable ranges (1h, 24h, 7d, 30d) and per-variable filtering; configurable poll interval and 90-day retention
- **NUT Users** — CRUD for NUT daemon users (upsd.users) with password masking and per-user roles (master/slave/admin); distinct from dashboard **Accounts** (see below)
- **Notifications** — Full upsmon.conf editor with monitor line management (add/remove/edit per UPS), global commands (MINSUPPLIES, SHUTDOWNCMD, NOTIFYCMD, POWERDOWNFLAG), timing parameters grid (POLLFREQ, POLLFREQALERT, HOSTSYNC, DEADTIME, etc.), and notification message/flag matrix for all 9 events with SYSLOG/WALL/EXEC/IGNORE checkboxes
- **Per-UPS Event Hooks** — Fine-grained script hooks per UPS per event (ONLINE, ONBATT, LOWBATT, COMMOK, COMMBAD, SHUTDOWN, REPLBATT, NOCOMM, NOPARENT) with in-browser script editor (Tab support), status badges, and instant save/delete
- **Live Log Streaming** — Real-time SSE log viewer tailing nut-server, nut-monitor, and nut-driver journals with pause/resume, auto-scroll, color-coded lines (error/warn/info), and configurable recent log loading
- **Config Files** — Raw in-browser editor for ups.conf, upsd.conf, upsmon.conf, and upsd.users (read-only via this endpoint)
- **Wake on LAN** — Manage WOL targets (MAC, broadcast, description), create event-to-target mappings for automatic wake on UPS events (ONLINE, ONBATT, etc.), manual "Wake Now" and "Wake All" buttons, and non-destructive auto-dispatch via notifycmd.sh; MAC address field shows a dropdown of hosts discovered from the ARP cache (with hostnames via reverse DNS) and auto-suggests the target name from the hostname
- **Service Management** — One-click restart (nut-server, nut-monitor, or both) and per-UPS driver start/stop/restart with multi-fallback cleanup (upsdrvctl, systemctl, PID kill, pkill); system-level actions: restart NutWatch (with automatic page reload), reboot, and shutdown
- **Accounts & API Keys** — Optional session login (admin/viewer roles) for the dashboard and per-user API keys (`Authorization: Bearer <key>`) for scripts; a key inherits its owner's role. Fully open until the first admin account is created via the first-run Setup page (or skipped, keeping the app open) or `manage.py create-admin`
- **Atomic Config Writes** — All file writes use `tempfile` + `os.replace` to prevent corruption
- **Input Validation** — Identifier regex, newline injection prevention, type checking on all inputs

### Proxmox VM Automation (`vm/nut-vm.sh`)

- **One-Command VM Creation** — Downloads Ubuntu 24.04 minimal cloud image (SHA-256 verified), creates a Proxmox VM with EFI boot, virtio-scsi, and QEMU Guest Agent
- **Offline Disk Customization** — Uses `virt-customize` to install packages, write NUT configs, and set up NutWatch directly into the disk image before VM creation
- **USB UPS Detection** — Scans `lsusb` output, cross-references known vendor IDs (APC `051d`, CyberPower `0764`, Eaton `0463`, Tripp Lite `09ae`, Liebert `10af`), handles duplicate models via bus-port notation, and configures USB passthrough
- **First-Boot Driver Auto-Detection** — `nut-detect` oneshot systemd service runs `nut-scanner -U` on first boot and rewrites `ups.conf` with the detected driver/vendor/product IDs
- **Cloud-Init** — Network configuration, rootfs resize, SSH host keys, and VM password via Proxmox cloud-init
- **Guest Agent IP Detection** — 5-minute retry loop querying `network-get-interfaces`; manual IP entry fallback
- **Interactive Configuration** — Default or Advanced setup modes with whiptail prompts for VM settings (ID, hostname, storage, bridge, RAM, CPU, disk) and NUT settings (UPS name, driver, users, listen address/port)
- **Auto-Generated Passwords** — Optional secure password generation via `openssl rand` with fallback to `/dev/urandom`
- **Graceful Failure Handling** — NutWatch install failure inside virt-customize is non-fatal; NUT service enablement handles multiple distro systemd variants (nut-driver-enumerator, nut-driver@, nut-driver) with `|| true`
- **Signal Safety** — `trap` handlers for ERR, EXIT, SIGINT, SIGTERM with cleanup and API status reporting
- **Resume Support** — Partial cloud image downloads use `wget -c`
- **Debian 13 Compatibility** — Auto-installs `dhcpcd-base` when missing for virt-customize network support

### Notify Script & Hook Samples

- **`notifycmd.sh`** — Central notify dispatcher that logs all UPS events, executes per-UPS per-event hook scripts from `/etc/nut/notify.d/<UPSNAME>_<EVENT>.sh`, and then triggers WOL auto-dispatch for any matching event mappings
- **Hook Samples** (`hook-samples/`):
  - `01-test-marker.sh` — Write a marker file when an event fires
  - `02-wall-notification.sh` — Broadcast a `wall` message to all logged-in users
  - `03-remote-ssh-shutdown.sh` — SSH-shutdown another machine when UPS goes on battery
  - `04-webhook-alert.sh` — Send Discord/Slack webhook alerts with JSON payload

### CI/CD & Developer Tooling

- **GitHub Actions** — Lint (shellcheck, shfmt), Python syntax check (py_compile), pytest, frontend tests (Vitest), and automated release workflow on tag push
- **Makefile** — `check`, `lint`, `fmt`, `fmt-fix`, `lint-python`, `test-python`, `tsc-check`, `lint-frontend`, `build-frontend`, `build-tarball`, `install-tools`
- **`build-tarball`** — Creates `nutwatch.tar.gz` for release distribution (git-ignored)
- **Backend Tests** — Pytest suite covering parsers, service layer (UPS, users, upsmon, hooks, WOL, system), auth, route handlers, and utility functions
- **Frontend Tests** — Vitest suite covering components (Badge, ConfirmDialog, Dashboard, ErrorBoundary, Gauge, HistoryChart, Modal, RestartPromptModal, Skeleton, theme, UpsCard, UpsDetail, WakeOnLan) and utilities (alerts, api, directives, format, logs, service)
- **TypeScript** — Strict mode (`strict: true`, `noUnusedLocals`, `noUnusedParameters`) with ESLint flat config; `tsc --noEmit` and `eslint .` run as part of `make check`

---

## Screenshots

| Dashboard | UPS Devices | UPS Detail (Info) |
|:---:|:---:|:---:|
| [![Dashboard](docs/screenshots/dashboard.png)](docs/screenshots/dashboard.png) | [![UPS Devices](docs/screenshots/ups-devices.png)](docs/screenshots/ups-devices.png) | [![UPS Detail](docs/screenshots/ups-detail.png)](docs/screenshots/ups-detail.png) |

| UPS Charts (Input Voltage) | UPS Charts (Runtime) | Hooks |
|:---:|:---:|:---:|
| [![Input Voltage](docs/screenshots/ups-charts-voltage.png)](docs/screenshots/ups-charts-voltage.png) | [![Runtime](docs/screenshots/ups-charts-runtime.png)](docs/screenshots/ups-charts-runtime.png) | [![Hooks](docs/screenshots/hooks.png)](docs/screenshots/hooks.png) |

| Users | Notifications | Logs |
|:---:|:---:|:---:|
| [![Users](docs/screenshots/users.png)](docs/screenshots/users.png) | [![Notifications](docs/screenshots/notifications.png)](docs/screenshots/notifications.png) | [![Logs](docs/screenshots/logs.png)](docs/screenshots/logs.png) |

| Config Files | Wake on LAN | Edit UPS |
|:---:|:---:|:---:|
| [![Config Files](docs/screenshots/config-files.png)](docs/screenshots/config-files.png) | [![Wake on LAN](docs/screenshots/wake-on-lan.png)](docs/screenshots/wake-on-lan.png) | [![Edit UPS](docs/screenshots/edit-ups.png)](docs/screenshots/edit-ups.png) |

---

## Supported UPS Vendors

| Vendor | USB ID | Driver |
|--------|--------|--------|
| APC | `051d` | usbhid-ups |
| CyberPower | `0764` | usbhid-ups |
| Eaton | `0463` | usbhid-ups |
| Tripp Lite | `09ae` | usbhid-ups |
| Liebert | `10af` | usbhid-ups |

Other USB UPS devices can be configured manually.

---

## Architecture

```text
Proxmox Host
├── USB UPS Device
│   └── USB Passthrough ──┐
│                          ▼
├── vm/nut-vm.sh   VM (Ubuntu 24.04 minimal)
│   ├── Downloads         │   ├── NUT Server
│   ├── virt-customize ──►│   │   ├── nut-driver (usbhid-ups)
│   ├── Creates VM        │   │   ├── upsd (port 3493)
│   ├── Detects UPS       │   │   ├── upsmon (with notifycmd hooks + WOL dispatch)
│   └── Configures        │   ├── NutWatch (port 8081)
│       (offline disk     │   └── cloud-init (network, resize)
│        modification)    │
                           └── First boot: nut-detect scans USB,
                                auto-configures driver in ups.conf
```

### NutWatch Backend Module Layout

```text
src/backend/
├── app.py               # Flask application factory & entry point
├── auth.py              # Principal resolution (session cookie / Bearer key) + role checks
├── manage.py            # CLI: create-admin, reset-password, list-accounts (bootstrap/recovery)
├── config.py            # Constants (NUT_DIR, regex, env vars)
├── utils.py             # Helpers (atomic write, run_cmd, upsc queries, driver stop)
├── parsers/             # Config file parsers (parse + serialize roundtrip)
│   ├── ups_conf.py
│   ├── upsd_users.py
│   ├── upsmon_conf.py
│   ├── monitor.py       # MONITOR line manipulation, MINSUPPLIES
│   └── nut_scanner.py   # nut-scanner -U output parser
├── services/            # Business logic layer
│   ├── ups.py           # UPS CRUD, auto-add to upsmon, scan
│   ├── users.py         # User CRUD with password masking
│   ├── upsmon.py        # Full upsmon.conf read/write with validation
│   ├── hooks.py         # Per-UPS event hook file management
│   ├── system.py        # Service/driver restart, config file raw I/O
│   ├── wol.py           # WOL target/event registry, magic packet dispatch
│   ├── history.py       # SQLite collection, retention, and range queries
│   ├── resources.py     # CPU, memory, and disk monitoring via psutil
│   └── auth_db.py       # Accounts + API keys SQLite store (auth.db)
├── routes/              # Flask blueprints (API endpoints)
│   ├── ups.py
│   ├── users.py
│   ├── upsmon.py
│   ├── hooks.py
│   ├── system.py
│   ├── logs.py          # SSE log streaming + recent log fetch
│   ├── wol.py           # WOL target and event-mapping CRUD endpoints
│   ├── history.py       # Historical time-series data endpoints
│   └── auth.py          # Setup/login/logout/me, accounts CRUD, API key CRUD
├── static/              # Built React SPA (index.html + assets/)
├── tests/
│   ├── test_parsers.py           # Parser roundtrip tests
│   ├── test_auth.py              # Principal resolution, role gating tests
│   ├── test_routes.py            # API endpoint integration tests
│   ├── test_routes_auth.py       # Setup/login/accounts/apikeys route tests
│   ├── test_manage_cli.py        # CLI create-admin/reset-password/list-accounts tests
│   ├── test_services_hooks.py    # Hook file CRUD tests
│   ├── test_services_system.py   # Service/driver/config tests
│   ├── test_services_ups.py      # UPS CRUD tests
│   ├── test_services_upsmon.py   # Upsmon config tests
│   ├── test_services_users.py    # User CRUD tests
│   ├── test_services_wol.py      # WOL target/mapping tests
│   ├── test_services_history.py  # History collection/query tests
│   ├── test_services_auth_db.py  # Account/API key store tests
│   └── test_utils.py             # Utility function tests
├── scripts/
│   ├── notifycmd.sh          # UPS event notify dispatcher (hooks + WOL)
│   └── nutwatch-wol-dispatch # WOL auto-dispatch called by notifycmd.sh
├── nutwatch.service     # systemd unit file
└── requirements.txt     # flask, psutil, pytest, wakeonlan
```

### Frontend Module Layout

```text
src/frontend/src/
├── App.tsx              # Root component with section routing + auth gating
├── api.ts               # Fetch wrapper for /api/* (generic typed, 401 handling)
├── AuthProvider.tsx      # Session/account context (status, login, logout, setup)
├── types.ts             # Shared TypeScript interfaces and types
├── constants/index.ts   # Section IDs, API paths, event lists, defaults
├── theme.tsx            # Light/dark theme provider
├── styles/
│   ├── base.css         # Global resets and base styles
│   ├── components.css   # Shared component styles
│   └── variables.css    # CSS custom properties (colors, spacing)
├── components/
│   ├── Dashboard.tsx    # Stat cards + UPS/services overview, resource gauges, system actions
│   ├── ErrorBoundary.tsx # Error boundary with fallback UI
│   ├── UpsDevices.tsx   # UPS card grid + scan/add/edit/delete
│   ├── UpsCard.tsx      # Individual UPS card with metrics & actions
│   ├── UpsDetail.tsx    # Deep-dive telemetry grouped by subsystem
│   ├── UpsModal.tsx     # Add/edit UPS form with recommended defaults
│   ├── Gauge.tsx        # D3 gauge for battery charge and load
│   ├── HistoryChart.tsx # D3 line charts with time-range selector
│   ├── Users.tsx        # User table with CRUD
│   ├── UserModal.tsx    # Add/edit user form
│   ├── Notifications.tsx # Full upsmon.conf editor (monitors, messages, flags, timing)
│   ├── RestartPromptModal.tsx # Restart prompt after config saves
│   ├── HooksSection.tsx # Per-UPS event hook table
│   ├── HookEditor.tsx   # In-browser script editor with Tab support
│   ├── Logs.tsx         # Live SSE log viewer with pause/auto-scroll
│   ├── WakeOnLan.tsx    # WOL target registry + event mapping management
│   ├── ConfigFiles.tsx  # Raw config file editor
│   ├── ServiceStatus.tsx # Service active/inline status bar
│   ├── Skeleton.tsx     # Loading skeleton placeholder
│   ├── Sidebar.tsx      # Navigation sidebar
│   ├── Badge.tsx        # Status badge (online/onbatt/offline/unknown)
│   ├── Modal.tsx        # Reusable modal dialog system
│   ├── ConfirmDialog.tsx # Confirm/alert/dangerConfirm dialog system
│   ├── ThemeSettings.tsx # Theme toggle UI
│   ├── Setup.tsx        # First-run admin creation (with Skip)
│   ├── Login.tsx        # Session login form
│   ├── ApiKeys.tsx      # Self-service API key list/create/revoke
│   ├── ApiKeyModal.tsx  # Create-key modal (shows raw key once)
│   ├── Accounts.tsx     # Admin-only account table
│   └── AccountModal.tsx # Add/edit account form with role selector
└── utils/
    ├── alerts.ts        # System alert/resource status helpers
    ├── directives.ts    # Key=value directive parsing/formatting
    ├── format.ts        # Runtime seconds → "Xh Ym" formatter
    ├── logs.ts          # Log line color classification
    ├── metrics.ts       # UPS variable selection and chart data helpers
    └── service.ts       # Service status → badge class mapping
```

---

## API Endpoints

### UPS Management

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/ups` | List all UPS devices with status |
| `POST` | `/api/ups` | Add a new UPS (auto-adds to upsmon.conf) |
| `GET` | `/api/ups/<name>` | Get single UPS config |
| `GET` | `/api/ups/<name>/detail` | Get live telemetry via `upsc` |
| `PUT` | `/api/ups/<name>` | Update UPS config |
| `DELETE` | `/api/ups/<name>` | Delete UPS (stops driver, cleans hooks) |
| `POST` | `/api/ups/scan` | Run `nut-scanner -U` to detect USB UPS devices |

### User Management

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/users` | List all users (passwords masked) |
| `POST` | `/api/users` | Add a new user |
| `PUT` | `/api/users/<name>` | Update user |
| `DELETE` | `/api/users/<name>` | Delete user |

### Notifications

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/upsmon/config` | Read full upsmon.conf |
| `PUT` | `/api/upsmon/config` | Write upsmon.conf (with validation) |

### Per-UPS Hooks

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/hooks/<upsname>` | List existing hooks for a UPS |
| `GET` | `/api/hooks/<upsname>/<event>` | Get hook script content |
| `PUT` | `/api/hooks/<upsname>/<event>` | Create/update hook script |
| `DELETE` | `/api/hooks/<upsname>/<event>` | Delete hook script |

### Service & Driver Control

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/service/restart-server` | Restart nut-server |
| `POST` | `/api/service/restart-monitor` | Restart nut-monitor |
| `POST` | `/api/service/restart-all` | Restart both services |
| `POST` | `/api/service/status` | Combined nut-server + nut-monitor status |
| `GET` | `/api/service/status-detailed` | Per-service active state (nut-driver, nut-server, nut-monitor) |
| `POST` | `/api/driver/<name>/start` | Start UPS driver |
| `POST` | `/api/driver/<name>/stop` | Stop UPS driver (multi-fallback cleanup) |
| `POST` | `/api/driver/<name>/restart` | Restart UPS driver |

### System

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/system/resources` | CPU%, memory usage/GB, and disk usage/GB |
| `POST` | `/api/system/restart-nutwatch` | Restart the NutWatch web service (page reloads automatically) |
| `POST` | `/api/system/reboot` | Reboot the entire system (requires an admin account to be configured) |
| `POST` | `/api/system/shutdown` | Shut down the system (requires an admin account to be configured) |

### Auth (Accounts & API Keys)

| Method | Path | Access | Description |
|--------|------|--------|-------------|
| `GET` | `/api/auth/status` | public | Bootstrap/authentication state |
| `POST` | `/api/auth/setup` | first-run only | Create the first admin account (blocked once any account exists) |
| `POST` | `/api/auth/login` | public | Username/password → session cookie (rate-limited) |
| `POST` | `/api/auth/logout` | session | Clear session |
| `GET` | `/api/auth/me` | session or key | Current identity + role |
| `GET` | `/api/accounts` | admin | List accounts |
| `POST` | `/api/accounts` | admin | Create an account |
| `PUT` | `/api/accounts/<id>` | admin | Edit role/password/active status |
| `DELETE` | `/api/accounts/<id>` | admin | Deactivate an account (soft delete) |
| `GET` | `/api/apikeys` | any account | List the caller's own API keys (metadata only) |
| `POST` | `/api/apikeys` | any account | Create a key — returns the raw key once |
| `DELETE` | `/api/apikeys/<id>` | owner | Revoke one of the caller's own keys |

### Config Files

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/config/<filename>` | Read config file content |
| `PUT` | `/api/config/<filename>` | Write config file (read-only for upsd.users) |

Allowed files: `ups.conf`, `upsd.conf`, `upsmon.conf`, `upsd.users`

### Logs

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/logs/recent?lines=N` | Recent N lines from NUT journals |
| `GET` | `/api/logs/stream` | SSE stream tailing nut-server + nut-monitor + nut-driver |

### History

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/history/<ups>?range=<range>&variables=<vars>` | Time-series snapshots (ranges: 1h, 24h, 7d, 30d) |
| `GET` | `/api/history/<ups>/variables` | Available tracked variables for a UPS |

### Wake on LAN

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/wol/targets` | List all WOL targets |
| `POST` | `/api/wol/targets` | Create a WOL target |
| `PUT` | `/api/wol/targets/<name>` | Update a WOL target |
| `DELETE` | `/api/wol/targets/<name>` | Delete a WOL target |
| `POST` | `/api/wol/targets/<name>/wake` | Send magic packet to target |
| `POST` | `/api/wol/wake-all` | Send magic packet to all targets |
| `GET` | `/api/wol/mappings` | List all event mappings |
| `POST` | `/api/wol/mappings` | Create an event mapping |
| `DELETE` | `/api/wol/mappings/<id>` | Delete an event mapping |
| `GET` | `/api/wol/network-hosts` | List ARP-cache hosts (IP, MAC, hostname) for MAC suggestions |

---

## Deployment Options

### Standalone Install (Raspberry Pi / Any Linux)

#### Option A — Full NUT + NutWatch setup (recommended)

Installs and configures NUT in netserver mode and the NutWatch web UI in one step:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/JuanCF/nutwatch/main/scripts/setup.sh)"
```

Non-interactive mode with auto-generated passwords:

```bash
curl -fsSL https://raw.githubusercontent.com/JuanCF/nutwatch/main/scripts/setup.sh | sudo AUTO=1 bash
```

**NutWatch-only mode** — Use `--install-only` on a machine that already has NUT configured:

```bash
sudo bash scripts/setup.sh --install-only
```

**Update mode** — Use `--update` to upgrade only the NutWatch application code in an existing installation (VM or standalone), preserving NUT configs, hooks, and the Python venv:

```bash
sudo bash scripts/setup.sh --update
```

Override any setting via environment variables:

```bash
sudo NUT_UPS_NAME="myups" NUT_ADMIN_PASS="securepass" AUTO=1 bash scripts/setup.sh
```

**What it does (fresh install):**
- Installs `nut-server`, `nut-client`, `usbutils`
- Writes all NUT config files (nut.conf, ups.conf, upsd.conf, upsd.users, upsmon.conf)
- Scans USB for UPS devices (first-boot auto-detection service available)
- Installs `notifycmd.sh` with per-UPS per-event hook support and WOL auto-dispatch
- Installs `nutwatch-wol-dispatch` to `/usr/local/bin/` for event-driven WOL
- Installs NutWatch web UI on port 8081 with systemd service
- Enables and starts all NUT services
- Configures firewall (ufw) rules

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `AUTO` | _(unset)_ | Set to `1` for non-interactive mode with defaults |
| `NUT_UPS_NAME` | `ups` | UPS identifier |
| `NUT_UPS_DESC` | `My UPS` | UPS description |
| `NUT_DRIVER` | `usbhid-ups` | NUT driver |
| `NUT_ADMIN_USER` | `admin` | NUT daemon admin username |
| `NUT_ADMIN_PASS` | _(auto-gen)_ | NUT daemon admin password |
| `NUT_MONITOR_USER` | `monuser` | NUT monitor username |
| `NUT_MONITOR_PASS` | _(auto-gen)_ | NUT monitor password |
| `NUT_LISTEN_ADDR` | `0.0.0.0` | NUT listen address |
| `NUT_LISTEN_PORT` | `3493` | NUT listen port |
| `NUTWATCH_REF` | `v1.1.2` | NutWatch release tag |
| `NUTWATCH_URL_PREFIX` | _(unset)_ | Override tarball URL for local testing |

After install, the app is fully open (no login). Create the first admin with `manage.py create-admin <username>` (run from the NutWatch install directory, e.g. `venv/bin/python manage.py create-admin admin`) to turn on session login and per-user API keys — or create it from the dashboard's first-run Setup page.

#### Option B — NutWatch only (existing NUT setup)

Install just the NutWatch web UI on a machine that already has NUT configured:

```bash
curl -fsSL https://raw.githubusercontent.com/JuanCF/nutwatch/main/scripts/setup.sh | sudo bash -s -- --install-only
```

Set the `NUTWATCH_REF` env var to pin a specific release version.

### Proxmox VM (One-Liner)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/JuanCF/nutwatch/main/vm/nut-vm.sh)"
```

### Manual Download

```bash
# Download the script
curl -fsSL https://raw.githubusercontent.com/JuanCF/nutwatch/main/vm/nut-vm.sh -o nut-vm.sh

# Or clone the repository
git clone https://github.com/JuanCF/nutwatch.git
cd nutwatch

# Run from source
bash vm/nut-vm.sh
```

---

## Usage

```bash
# Run on Proxmox host as root (from cloned repo)
bash vm/nut-vm.sh

# Or if downloaded directly
bash nut-vm.sh
```

### Environment Variables

#### vm/nut-vm.sh

| Variable | Default | Description |
|----------|---------|-------------|
| `VERBOSE` | _(unset)_ | Set to `yes` to show full command output |
| `NUTWATCH_URL_PREFIX` | _(unset)_ | Override the GitHub Releases URL for the nutwatch tarball |
| `COMMUNITY_SCRIPTS_URL` | `https://git.community-scripts.org/community-scripts/ProxmoxVED/raw/branch/main` | Base URL for sourcing helper functions |

```bash
VERBOSE=yes bash vm/nut-vm.sh                    # Verbose output
NUTWATCH_URL_PREFIX=https://example.com/my-fork bash vm/nut-vm.sh
COMMUNITY_SCRIPTS_URL=https://my-mirror.example.com bash vm/nut-vm.sh
```

#### NutWatch Web App

| Variable | Default | Description |
|----------|---------|-------------|
| `NUTWATCH_HOST` | `0.0.0.0` | Listen address for the web server |
| `NUTWATCH_PORT` | `8081` | Listen port for the web server |
| `NUTWATCH_HISTORY_INTERVAL` | `60` | Seconds between UPS variable snapshots |
| `NUTWATCH_HISTORY_RETENTION_DAYS` | `90` | Days of history to retain in SQLite |
| `NUTWATCH_AUTH_DB` | `/var/lib/nutwatch/auth.db` | SQLite path for accounts + API keys |
| `NUTWATCH_SECRET_KEY` | _(auto-generated)_ | Flask session signing key; auto-generated and persisted in the auth DB on first run if unset |
| `NUTWATCH_SESSION_COOKIE_SECURE` | `false` | Set to `true` to mark the session cookie `Secure` (only if serving over HTTPS — plain-HTTP LAN deployments must leave this `false`) |

#### scripts/setup.sh (--install-only mode)

| Variable | Default | Description |
|----------|---------|-------------|
| `NUTWATCH_REF` | `v1.1.2` | Git tag for release download URL |
| `NUTWATCH_URL_PREFIX` | _(unset)_ | Override URL for testing local builds |

---

## Interactive VM Prompts

1. **VM Configuration** — VM ID, hostname, storage pool, network bridge, RAM, CPU cores, disk size, VM username/password
2. **UPS Detection** — Auto-scan for USB UPS devices, duplicate model handling, manual entry fallback
3. **NUT Configuration** — UPS name/description, driver, admin/monitor users, listen address/port

---

## Deployment & Releases

### Creating a Release

```bash
git tag v1.2.3
git push origin v1.2.3
```

The GitHub Actions workflow will run lint checks, build `nutwatch.tar.gz`, and create a GitHub Release.

### Testing a Local Build

```bash
make build-tarball
python3 -m http.server 8080 --directory .
NUTWATCH_URL_PREFIX="http://<your-ip>:8080" bash vm/nut-vm.sh
```

---

## Developer Commands

```bash
make check          # Full CI suite: lint + format check + Python lint + pytest + frontend tests
make lint           # shellcheck only
make fmt            # shfmt -d -i 2 (check only)
make fmt-fix        # shfmt -w -i 2 (auto-fix)
make lint-python    # py_compile check on all Python files
make test-python    # pytest on src/backend/tests/
make test-frontend  # Vitest on src/frontend/src/__tests__/
make build-frontend # npm ci + npm run build
make build-tarball  # Create nutwatch.tar.gz for distribution
make install-tools  # Install dev dependencies
```

---

## Hook Samples

Place scripts in `/etc/nut/notify.d/<UPSNAME>_<EVENT>.sh`:

| Sample | Description |
|--------|-------------|
| `01-test-marker.sh` | Write a marker file to `/tmp/ups-test.log` |
| `02-wall-notification.sh` | Broadcast `wall` message and syslog alert |
| `03-remote-ssh-shutdown.sh` | SSH into another machine and shut it down |
| `04-webhook-alert.sh` | Send Discord/Slack webhook JSON payload |

Each hook receives `$UPSNAME` and `$NOTIFYTYPE` environment variables from `upsmon`.

---

## Verification

```bash
# Check VM status
qm list

# Verify USB passthrough
qm config <vmid> | grep usb

# Test NUT from Proxmox host
upsc ups@<VM_IP>

# Test from another machine
upsc ups@<VM_IP>:3493

# Check NUT services inside VM
systemctl status nut-server nut-monitor

# Access NutWatch web UI
http://<VM_IP>:8081
```

---

## Security Notes

- NUT passwords should be strong and unique
- The netserver listens on all interfaces by default (`0.0.0.0`)
- Consider firewall rules to restrict NUT port (3493) access
- The VM password is set via Proxmox's built-in cloud-init (`qm set --cipassword`)
- Hook scripts are owned `root:nut` with `750` permissions for secure upsmon execution
- WOL registry files (`wol.json`, `wol-events.json`) are owned `root:nut` with `640` permissions
- Config file writes use atomic `tempfile` + `os.replace` to prevent partial writes

---

## License

MIT License — See [LICENSE](LICENSE) file for details.

## Contributing

Contributions welcome! Please feel free to submit a Pull Request.

## Acknowledgments

- [Network UPS Tools](https://networkupstools.org/) project
- Proxmox VE community
- Ubuntu Cloud Images

## Support

- Open an [issue](https://github.com/JuanCF/nutwatch/issues)
- NUT Users Mailing List: https://alioth-lists.debian.net/lists/lists.alioth.debian.net

---

**Disclaimer**: This script modifies your Proxmox configuration. Always review scripts before running them as root. Test in a non-production environment first.
