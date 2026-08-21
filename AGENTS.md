# Agent Notes: nutwatch

Two components in this repo:

| Path | What it is | Runs where |
|------|-----------|------------|
| `vm/nut-vm.sh` | Proxmox VM creation + NUT installer script | Proxmox host (as root) |
| `src/backend/` | NutWatch (modular Flask web UI for NUT config management) | Inside the VM or standalone Linux host |

`plan.md` is a historical design spec — do **not** trust it literally; verify behavior in the actual scripts. `CONTRIBUTING.md` has the version bump checklist and tag conventions.

## Developer Commands

```bash
make check          # lint (shellcheck) + format check (shfmt) + Python lint + pytest
make lint           # shellcheck only
make fmt            # shfmt -d -i 2 (check only)
make fmt-fix        # shfmt -w -i 2 (auto-fix)
make lint-python    # py_compile check on app.py
make test-python    # pytest on src/backend/tests/
make install-tools  # apt-get shellcheck shfmt python3-pytest

# Python tests require a venv — do not install deps directly on the host:
#   python3 -m venv .venv && source .venv/bin/activate && pip install -r src/backend/requirements.txt
```

CI runs `shellcheck` + `shfmt -d -i 2` on `vm/`, `src/backend/`, and `scripts/` (same set as the Makefile's `SHELL_FILES`) plus Python lint + tests (see `.github/workflows/lint.yml`). `make check` reproduces the full local suite.

## Shell Conventions

- `.shellcheckrc` sets `external-sources=true` because `api.func`, `vm-core.func`, and `cloud-init.func` are fetched at runtime.
- Use `[[ ]]` for conditionals; quote variables.
- VM scripts live in `vm/`, not `ct/` or `src/`.
- Do **not** implement `update_script()` or write `/opt/${APP}_version.txt`.
- The script uses the community-scripts `msg_error` (which logs and returns). All call sites that must abort are written as `{ msg_error "..."; exit; }`.

## nut-vm.sh Architecture

- Sources `api.func`, `vm-core.func`, and `cloud-init.func` at runtime via `curl` from `community-scripts/ProxmoxVED`.
- Uses `virt-customize` for offline disk image modification: installs packages, writes NUT configs, creates a `nut-detect` oneshot systemd service, and installs NutWatch directly into the disk image before the VM is created.
- Cloud-init (via `setup_cloud_init` from `cloud-init.func`) handles first-boot network configuration, rootfs resize, and SSH host key generation. The password is set via `qm set --cipassword`.
- `get_vm_ip()` has a 5-minute retry loop querying `network-get-interfaces` via the guest agent (`qm guest cmd <vmid> network-get-interfaces`); falls back to manual IP entry.
- USB UPS detection parses `lsusb` and cross-references known vendor IDs. Duplicate models use bus-port notation (`host=4-1`).
- Image is cached at `/var/lib/vz/template/cache` — not deleted after import.

## NutWatch (src/backend/)

- Modular Flask app: `app.py` (bootstrap), `auth.py` (principal resolution + role checks), `manage.py` (account CLI), `config.py` (constants), `utils.py` (helpers), `parsers/` (config parsers), `services/` (business logic), `routes/` (API blueprints), `static/` (SPA frontend).
- Web UI tabs: **Dashboard**, **UPS Devices** (with per-UPS hook editor), **UPS Detail Telemetry**, **Historical Data & Charts**, **NUT Users** (upsd.users — distinct from dashboard Accounts), **Notifications** (`upsmon.conf` editor), **Logs**, **Config Files**, **Wake on LAN**, **API Keys**, **Accounts** (admin only).
- API endpoints: `/api/ups`, `/api/config/<filename>`, `/api/users`, `/api/upsmon/config`, `/api/hooks/<upsname>/<event>`, `/api/driver/<name>/<action>`, `/api/service/...`, `/api/system/...`, `/api/logs/...`, `/api/history/<ups>...`, `/api/wol/targets`, `/api/wol/mappings`, `/api/auth/...`, `/api/accounts`, `/api/apikeys`.
- Runs as `nutwatch.service` on port 8081 (configurable via `NUTWATCH_HOST`, `NUTWATCH_PORT` env vars).
- Auth: accounts (admin/viewer role) in `services/auth_db.py` (SQLite, `NUTWATCH_AUTH_DB`). `auth.resolve_principal()` checks a Flask session cookie, then an `Authorization: Bearer <key>` API key (a key inherits its owner's role) — see `docs/auth-plan.md` for the full design. Bootstrap rule: **zero accounts → everything open** (mirrors the old open-by-default behavior); once the first admin account exists (via the UI's first-run Setup page, or `manage.py create-admin`), auth is enforced. Destructive system endpoints (reboot, shutdown) use `require_admin_strict`, which 403s until an admin account exists. `manage.py create-admin` / `reset-password` / `list-accounts` is the lockout-recovery escape hatch (shell access always wins).
- Config writes use atomic `tempfile` + `os.replace`; input validated with `IDENTIFIER_REGEX`.
- `services/resources.py` uses `psutil` for CPU, memory, and disk monitoring, exposed via `GET /api/system/resources`.
- Config saves (UPS, users, upsmon.conf) auto-restart affected NUT services, and the frontend shows a restart prompt modal after successful saves.
- `scripts/setup.sh --install-only` downloads a pre-built tarball from GitHub Releases (pinned by `NUTWATCH_REF` tag). To test a local build, run `make build-tarball`, serve the tarball, and set `NUTWATCH_URL_PREFIX`.
- Tests live in `tests/` (14 files): parser roundtrips, service-layer CRUD, auth (principal resolution + routes), the `manage.py` CLI, and utilities. Import from `parsers`, `utils`, `services`, `auth`, `routes`, or `manage` (not from `app.py`) — tests run from `src/backend/`.

## Edge Cases

- Partial image download: uses `wget -c` for resume.
- Duplicate `VENDOR:PRODUCT` UPS models: falls back to bus-port notation (`host=4-1`).
- Slow DHCP / guest agent: retries for up to 5 minutes.
- virt-customize network failure on Debian 13 (Proxmox VE 9): auto-installs `dhcpcd-base` when missing.
- NUT service enablement varies by distro: `nut-driver-enumerator` → `nut-driver@` → `nut-driver`. Each unit is enabled individually with `|| true` so missing units don't abort the whole run.
- NUT 2.8.x has no bare `nut-driver.service` on most distros (drivers run as `nut-driver@<name>` instances); `services/system.py::_driver_status_units()` resolves the right unit for status/restart and `routes/logs.py::_journal_units()` uses it for journalctl, falling back to pid-file checks or `upsdrvctl`.
- NutWatch install failure inside virt-customize: wrapped in `&& ... || echo` so a download failure doesn't abort the VM setup.
- Script interruption: `trap ERR` calls `error_handler`, `trap EXIT` runs `cleanup` (removes temp dir and working disk image), and `trap SIGINT/SIGTERM` posts failure to the API before exiting.
- Hook ownership: per-UPS hook scripts must be `root:nut 750` so `upsmon` (running as the `nut` user) can execute them. `services/hooks.py::put_hook()` explicitly `chown`s to `root:nut` after writing.
- `$UPSNAME` environment variable includes `@host:port` (e.g. `ups@localhost:3493`), but hook filenames use the bare UPS name. `notifycmd.sh` strips the suffix with `${UPSNAME%%@*}` before looking for the hook file.
- UPS deletion cleans up orphaned hooks: `services/ups.py::delete_ups()` calls `delete_hook(name, event)` for every existing hook before returning.
- UPS deletion also cleans up WOL mappings: `services/ups.py::delete_ups()` calls `services.wol.cleanup_for_ups(name)` to remove all WOL event mappings for the deleted UPS.
- WOL is non-destructive to user hooks: `notifycmd.sh` runs WOL dispatch **after** the per-UPS per-event hook script, so user-written hooks are never touched.
- WOL target deletion also cleans up orphaned target references in event mappings: `services/wol.py::delete_target()` removes the target name from all mapping target lists and drops any mappings with empty target lists.
- `NOTIFYFLAG` must include `EXEC` for `upsmon` to actually invoke `NOTIFYCMD`. The VM template sets `SYSLOG+WALL+EXEC` for all 9 events by default.
- WOL dispatch double-fires: both standalone install (`scripts/setup.sh`) and VM install (`vm/nut-vm.sh`) set up the same WOL dispatch call in `notifycmd.sh`, so the dispatch runs on both installation paths.
- Config-save auto-restart: `routes/ups.py`, `routes/users.py`, and `routes/upsmon.py` trigger `restart_all()` (both nut-server and nut-monitor) after PUT/POST/DELETE to ensure NUT picks up changes immediately.
- Restart prompt modal: the frontend `RestartPromptModal.tsx` component prompts users to restart NUT services after successful config saves; canceling the prompt reverts the UI to avoid stale state.
