# Agent Notes: nut-vm-setup

Proxmox NUT Server VM script — creates an Ubuntu 24.04 VM, passes through a USB UPS, and installs NUT in `netserver` mode.

## Files

- `vm/nut-vm.sh` — Main deliverable (do **not** edit `src/`; that directory is empty and README paths are stale)
- `plan.md` — Original design spec; the script has diverged from it, so verify behavior in `vm/nut-vm.sh` rather than trusting `plan.md` literally
- `docs/compliance-review.md` — Known deviations from community-scripts conventions

## Environment

- **Must run on a Proxmox host** as root (needs `qm`, `pvesh`, `pveversion`)
- Downloads Ubuntu 24.04 minimal cloud image to `/var/lib/vz/template/iso`
- Generates temp SSH keys in `/tmp/` for VM provisioning; cleaned on exit via `trap`
- Requires `ssh`, `scp`, `wget`/`curl`, `lsusb`, `nc` on the Proxmox host

## Developer Commands

```bash
# Lint + format check (targets vm/*.sh)
make check

# Auto-fix formatting
make fmt-fix

# Install tools
make install-tools
```

CI runs: `shellcheck` + `shfmt -d -i 2` on `vm/*.sh` (see `.github/workflows/lint.yml`).

## Architecture Notes

- **Community-scripts ecosystem**: The script sources `build.func` and `cloud-init.func` at runtime via `curl` from `community-scripts/ProxmoxVED`. It intentionally overrides `msg_error` to add `exit 1` and reimplements some helpers (spinner, colors) — this is a documented deviation; see `docs/compliance-review.md`.
- **Cloud-init vendor snippet**: `get_vm_ip()` relies on `qemu-guest-agent` being installed on first boot. The script injects a custom vendor YAML snippet (`/var/lib/vz/snippets/nut-vm-${VM_ID}-cloudinit.yaml`) for this; do not remove it.
- **NUT install script is embedded as a heredoc**, SCP'd to the VM, and executed via SSH.
- **USB UPS detection** parses `lsusb` and cross-references known vendor IDs. Duplicate models use bus-port notation (`host=4-1`).
- **VM uses cloud-init with DHCP**; guest agent is required for IP detection. There is a 2-minute retry loop before falling back to manual IP entry.

## Key Conventions (from `proxmox-helper-scripts` skill)

- VM scripts live in `vm/`, not `ct/` or `src/`.
- Do **not** implement `update_script()` — VMs manage their own OS updates.
- Do **not** write `/opt/${APP}_version.txt` from a VM script.
- Use `qm`, never `pct`.
- Use `[[ ]]` for conditionals; quote variables.
- `.shellcheckrc` sets `external-sources=true` because `build.func` / `cloud-init.func` are fetched at runtime.

## Edge Cases Handled

- Partial image download: uses `wget -c` for resume.
- Duplicate `VENDOR:PRODUCT` UPS models: falls back to bus-port notation (`host=4-1`).
- Slow DHCP / guest agent: retries `qm guest exec` for up to 2 minutes.
- Special chars in passwords: uses single-quoted heredoc delimiters for remote config writes.
- Script interruption: `trap INT TERM` kills the spinner and prints an interrupt message.

## Verification

```bash
# After running the script on Proxmox
qm list
qm config <vmid> | grep usb

# Test NUT server from another machine
upsc ups@<VM_IP>:3493

# Check services inside VM
ssh <VM_USER>@<VM_IP> systemctl status nut-server nut-monitor
```
