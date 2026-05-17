# Agent Notes: nut-vm-setup

Two components in this repo:

| Path | What it is | Runs where |
|------|-----------|------------|
| `vm/nut-vm.sh` | Proxmox VM creation + NUT installer script | Proxmox host (as root) |
| `src/nut-admin/` | Flask web UI for NUT config management | Inside the VM |

`plan.md` is a historical design spec — do **not** trust it literally; verify behavior in the actual scripts.

## Developer Commands

```bash
make check          # lint (shellcheck) + format check (shfmt) + Python lint + pytest
make lint           # shellcheck only
make fmt            # shfmt -d -i 2 (check only)
make fmt-fix        # shfmt -w -i 2 (auto-fix)
make lint-python    # py_compile check on app.py
make test-python    # pytest on src/nut-admin/tests/
make install-tools  # apt-get shellcheck shfmt python3-pytest
```

CI runs `shellcheck` + `shfmt -d -i 2` on `vm/*.sh` only (see `.github/workflows/lint.yml`). It does **not** run Python tests — `make check` does locally.

## Shell Conventions

- `.shellcheckrc` sets `external-sources=true` because `build.func` / `cloud-init.func` are fetched at runtime.
- Use `[[ ]]` for conditionals; quote variables.
- VM scripts live in `vm/`, not `ct/` or `src/`.
- Do **not** implement `update_script()` or write `/opt/${APP}_version.txt`.
- `msg_error` intentionally calls `exit 1` — do **not** replace it with the community-scripts `msg_error` (which just logs and returns). See `docs/compliance-review.md`.

## nut-vm.sh Architecture

- Sources `build.func` and `cloud-init.func` at runtime via `curl` from `community-scripts/ProxmoxVED`.
- Reimplements some helpers (spinner, colors) — a documented deviation from community-scripts conventions.
- The NUT install script is embedded as a heredoc, SCP'd to the VM, executed via SSH.
- The NUT admin install is a separate pipeline inside the heredoc; it can fail gracefully without killing the main NUT setup.
- Cloud-init vendor snippet (`/var/lib/vz/snippets/nut-vm-${VM_ID}-cloudinit.yaml`) installs `qemu-guest-agent` on first boot. Required for `get_vm_ip()`. Do not remove.
- `get_vm_ip()` has a 2-minute retry loop using `qm guest exec`; falls back to manual IP entry.
- USB UPS detection parses `lsusb` and cross-references known vendor IDs. Duplicate models use bus-port notation (`host=4-1`).
- Image is cached at `/var/lib/vz/template/iso` — not deleted after import.

## nut-admin (src/nut-admin/)

- Flask app (`app.py`) + static SPA (`static/index.html`).
- Runs as `nut-admin.service` on port 8081 (configurable via `NUT_ADMIN_HOST`, `NUT_ADMIN_PORT` env vars).
- Auth: Bearer token via `NUT_ADMIN_API_KEY` env var — if empty, auth is disabled.
- Config writes use atomic `tempfile` + `os.replace`; input validated with `IDENTIFIER_REGEX`.
- `install.sh` can deploy from local files (if running from cloned repo) or curl from GitHub (pinned by `NUT_ADMIN_REF` sha).
- Unit tests in `tests/test_parsers.py` cover parser roundtrips. Import from `app` (not `src.nut-admin.app`) — tests run from `src/nut-admin/`.

## Edge Cases

- Partial image download: uses `wget -c` for resume.
- Duplicate `VENDOR:PRODUCT` UPS models: falls back to bus-port notation.
- Slow DHCP / guest agent: retries for up to 2 minutes.
- Special chars in passwords: single-quoted heredoc delimiters for remote config writes.
- Script interruption: `trap INT TERM` kills spinner and prints interrupt message.
- NUT driver service name varies by distro: `nut-driver-enumerator` → `nut-driver@` → `nut-driver`. The installer probes via `systemctl list-unit-files`.