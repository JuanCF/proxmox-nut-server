# Compliance Review: `src/nut-vm.sh` vs Agent Guidelines

Reviewed against `SKILL.md` and `references/vm-scripts.md`.  
Source of truth for `build.func` / `cloud-init.func` verified from the live
community-scripts/ProxmoxVED repository.

---

## 1. Guidelines Compliance

### Passing

| Rule | Notes |
|------|-------|
| `#!/usr/bin/env bash` shebang | Correct |
| Use `qm`, not `pct` | Correct throughout |
| No `update_script()` | Correctly omitted for a VM script |
| No `/opt/${APP}_version.txt` | Correctly absent |
| `[[ ]]` for conditionals, variables quoted | Consistent |
| `msg_info` / `msg_ok` / `msg_error` pattern | Implemented and used |
| `catch_errors` called | Present in `main()` |

### Violations

| # | Rule | Finding |
|---|------|---------|
| 1 | Source `build.func` + `cloud-init.func` | Script reimplements all helpers (spinner, colors, `msg_*`) from scratch. Rule 2: "Never reimplement helpers — reuse them." |
| 2 | Call `header_info`, `variables`, `color`, `catch_errors` in order | `variables` and `color` are never called; color vars are defined inline instead of via `build.func`. |
| 3 | Use `$STD` instead of `&>/dev/null` | Every silenced command uses `&>/dev/null`. `$STD` respects the user's `VERBOSE` setting; `&>/dev/null` doesn't. |
| 4 | File lives in `vm/`, not `src/` | File is at `src/nut-vm.sh`; convention requires `vm/nut-vm.sh`. |
| 5 | No custom spinner reimplementation | `spinner()` re-coded at lines 70–79. Explicit anti-pattern in SKILL.md. |
| 6 | Delete image after `qm importdisk` | Image kept at `/var/lib/vz/template/iso` for caching. Guideline requires deletion after import. Intentional design conflict (see Section 3). |
| 7 | SHA-256 checksum after download | `download_cloud_image()` performs no checksum verification. |
| 8 | Architecture detection | No `ARCH=$(dpkg --print-architecture)` guard; always assumes amd64. |
| 9 | Storage-type disk naming | No `STORAGE_TYPE` detection; `DISK_EXT` / `DISK_REF` / `DISK_IMPORT` never set. Disk ref hardcoded to `vm-${VM_ID}-disk-0`, which is wrong for nfs/btrfs storage backends. |
| 10 | `-onboot 1` in `qm create` | Missing. Template requires it. |
| 11 | `-tags community-script` in `qm create` | Missing. |
| 12 | Use `cloud-init.func`'s `setup_cloud_init` | Script hand-rolls cloud-init setup. **Partial exception applies — see Section 2.** |

---

## 2. Special Case: `qemu-guest-agent` on First Boot

`setup_cloud_init` from `cloud-init.func` handles user, network, SSH keys, and
the cloud-init drive — but it has no parameter for custom package installation.

The script's `get_vm_ip()` depends on the QEMU guest agent being running inside
the VM (it polls `pvesh … /agent/network-get-interfaces`). The agent must be
installed on first boot via cloud-init.

The current approach uses a `cicustom vendor` YAML snippet
(`/var/lib/vz/snippets/nut-vm-${VM_ID}-cloudinit.yaml`) that installs and
enables `qemu-guest-agent`. This snippet must be kept even if `setup_cloud_init`
is adopted, by calling `qm set` for `--cicustom` after `setup_cloud_init`:

```bash
setup_cloud_init "$VMID" "$STORAGE" "$HN" "yes"
qm set "$VMID" --cicustom "vendor=local:snippets/nut-vm-${VMID}-cloudinit.yaml"
```

Rule 12 is therefore reclassified as **partial** — `setup_cloud_init` should be
adopted, but the vendor snippet mechanism must be preserved alongside it.

---

## 3. Impact Analysis: What Each Fix Would Break

### Key finding: `build.func` is LXC-scoped, but safe to source for utilities

The file header states it *"provides main build functions for creating and
configuring LXC containers."* VM scripts source it only for the shared utility
layer: colors, `msg_*`, spinner, `$STD`, `catch_errors`. LXC-specific functions
(`start`, `build_container`, `description`, etc.) must not be called from a VM
script.

`variables()` — despite what the reference file implies — **does not show
whiptail dialogs**. It only performs initialization: lowercases `$APP` into
`$NSAPP`, generates a session ID, sets log paths, and captures `pveversion`.
The whiptail wizard lives in `advanced_settings()`, which is LXC-only. Calling
`variables()` in a VM script is therefore safe and does not replace
`collect_vm_config()`.

### Critical breaks

**`msg_error` from `build.func` does not call `exit`**

Verified from source: `msg_error()` prints and logs the error, then returns.
There is no `exit` call. The current script's `msg_error` calls `exit 1`
(line 103). Replacing it would silently neuter every error guard:

- `check_root()` — execution continues without root
- `check_proxmox()` — execution continues without `qm` / `pvesh`
- Every `|| msg_error "Cancelled by user"` in whiptail prompts — script
  continues instead of aborting

Fix options: append `|| exit 1` to every `msg_error` call site, or keep a
local `msg_error` that wraps the sourced one and adds `exit 1`.

**`setup_cloud_init` generates a random password, ignores user input**

Verified from source: `local cipassword=$(openssl rand -base64 16)`. There is
no parameter to supply a custom password. The `$VM_PASSWORD` collected from the
user in `collect_vm_config()` would be silently discarded, and `print_summary()`
would display the wrong credential.

**Fixed:** `qm set --cipassword "$VM_PASSWORD"` was removed to prevent the
user-supplied password from appearing on the Proxmox command line. The password
is now embedded into the vendor cloud-init snippet
(`/var/lib/vz/snippets/nut-vm-${VM_ID}-cloudinit.yaml`) via a `chpasswd.list`
block, and the snippet is referenced with `--cicustom vendor=...`. The snippet
file is created with mode `600`.

**Residual risk:** the plain-text password remains at rest in
`/var/lib/vz/snippets/` until the file is manually removed.

### Previously assessed as critical — corrected to non-breaking

**SSH key injection (temp keys for NUT installer)**

Earlier analysis assumed `setup_cloud_init` always reads from
`~/.ssh/authorized_keys`. Verified from source: it reads from the global
variable `CLOUDINIT_SSH_KEYS` and only injects keys *"if explicitly provided
(not auto-imported from host)."* Setting `CLOUDINIT_SSH_KEYS="$TEMP_SSH_PUB"`
before calling `setup_cloud_init` will correctly inject the temp key. The NUT
installer's SCP/SSH flow is therefore not broken by this change.

**`variables()` replacing `collect_vm_config()`**

Earlier analysis assumed `variables()` ran a whiptail configuration wizard and
would conflict with the custom VM config flow. Verified from source: `variables()`
is only initialization bookkeeping. No conflict.

### Intentional design conflict

**Image caching vs. deletion after import**

The guideline requires deleting the downloaded image after `qm importdisk`.
The script intentionally keeps it at `/var/lib/vz/template/iso` so re-runs skip
the ~600 MB download. Deleting after import breaks this caching behaviour.
Resolve by deciding which behaviour is preferred before applying the fix.

### Safe to apply without breaking anything

| Fix | Notes |
|-----|-------|
| `$STD` instead of `&>/dev/null` (non-capturing commands) | Additive; enables `VERBOSE=yes` support |
| Architecture detection via `dpkg --print-architecture` | Additive guard |
| SHA-256 checksum verification after download | Additive step |
| Storage-type disk naming (`STORAGE_TYPE` detection) | Fixes latent bug on nfs/btrfs backends |
| `-onboot 1` added to `qm create` | Behavioural addition; VM will autostart on Proxmox boot |
| `-tags community-script` added to `qm create` | Metadata only |
| Move file from `src/` to `vm/` | Organisational; no functional impact |
| Set `CLOUDINIT_SSH_KEYS="$TEMP_SSH_PUB"` before `setup_cloud_init` | Preserves temp key injection |

---

## 4. Summary

| Fix | Safe to apply? |
|-----|----------------|
| Source `build.func` + `cloud-init.func` for utilities | Yes — but keep local `msg_error` with `exit 1` |
| Call `variables()` and `color()` | Yes — no LXC-specific side effects |
| Replace custom spinner / colors / `msg_*` with sourced versions | Yes — except `msg_error` |
| `$STD` instead of `&>/dev/null` | Yes (non-capturing commands only) |
| Architecture detection | Yes |
| Checksum verification | Yes |
| Storage-type disk naming | Yes |
| `-onboot 1`, `-tags` | Yes |
| Move to `vm/` | Yes |
| `setup_cloud_init` + keep vendor snippet for guest agent | Yes — also set `CLOUDINIT_SSH_KEYS` and override password after |
| Delete image after import | Depends on whether caching is desired |
