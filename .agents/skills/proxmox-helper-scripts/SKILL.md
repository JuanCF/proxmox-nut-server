---
name: proxmox-helper-scripts
description: Use this skill when creating, modifying, or reviewing scripts for the community-scripts/ProxmoxVE project (Proxmox VE Helper-Scripts). Triggers on requests involving Proxmox LXC container creation scripts, install scripts using build.func/core.func/install.func, whiptail dialogs in Proxmox style, msg_info/msg_ok/msg_error patterns, _version.txt update tracking, or anything related to the ct/ and install/ folder conventions of the community-scripts ecosystem.
license: MIT
---

# Proxmox VE Helper-Scripts (Community Edition) Skill

This skill encodes the conventions, helper functions, and contribution
guidelines of the [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE)
project so an AI agent can produce scripts that match the project's
style on the first try.

## When to use this skill

Activate this skill whenever the user asks to:

- Create a new helper script for installing an app in a Proxmox LXC
- Modify or fix an existing `ct/AppName.sh` or `install/AppName-install.sh`
- Review a script for compliance with project conventions before a PR
- Reproduce the visual style (spinner, ✔️/✖️, colors) in a custom script
- Implement update detection using the `/opt/${APP}_version.txt` pattern
- Build whiptail dialogs in the same style as the project

## Critical rules (MUST follow)

1. **New scripts go to the `ProxmoxVED` repo, not `ProxmoxVE`.** The main
   repo only accepts bug fixes and improvements to existing scripts.
2. **Always source `build.func`** at the top of `ct/` scripts and
   `install.func` (via `FUNCTIONS_FILE_PATH`) in `install/` scripts.
   Never reimplement helpers — reuse them.
3. **Never hardcode version numbers** in install URLs. Fetch the latest
   release from the upstream GitHub API and write it to
   `/opt/${APP}_version.txt`.
4. **Use `msg_info` / `msg_ok` / `msg_error`** for every visible step.
   Plain `echo` is only acceptable for the final post-install message.
5. **Use `$STD`** to silence verbose commands (e.g. `$STD apt-get install -y …`).
   This respects the user's `VERBOSE` setting.
6. **Shebang must be `#!/usr/bin/env bash`** (not `/bin/bash`).
7. **Use `[[ ]]`** for conditionals, never `[ ]`. Always quote variables.
8. **One PR per fix or feature.** Update the matching JSON metadata file
   in `frontend/public/json/` when behavior changes.

## Workflow when creating a new script

1. **Read the reference for the relevant subsystem first.** Don't guess
   helper names — load `references/core-functions.md` and confirm.
2. **Start from a template:**
   - Container script (host-side): `templates/ct-template.sh`
   - Install script (container-side): `templates/install-template.sh`
3. **Fill in the metadata block** (`APP`, `var_tags`, `var_cpu`, `var_ram`,
   `var_disk`, `var_os`, `var_version`, `var_unprivileged`).
4. **Implement `update_script()`** following `references/version-management.md`.
5. **Replace the import URL.** Templates point to the user's fork during
   development. Before opening a PR, change the URL back to
   `community-scripts/ProxmoxVE`.
6. **Validate:**
   - `bash -n script.sh` (syntax check)
   - `shellcheck script.sh` (lint — install via `apt install shellcheck`)
   - Run on a real Proxmox host (no full simulation possible).

## Reference index (load on demand)

| File                                     | When to load                                                       |
| ---------------------------------------- | ------------------------------------------------------------------ |
| `references/core-functions.md`           | Any time you need colors, symbols, `msg_*`, the spinner, or `$STD` |
| `references/whiptail-patterns.md`        | Building interactive dialogs (yes/no, input, menu, checklist)      |
| `references/version-management.md`       | Implementing `update_script()` or version detection                |
| `references/script-templates.md`         | Understanding the full anatomy of `ct/` and `install/` scripts     |
| `templates/ct-template.sh`               | Starting a new container script                                    |
| `templates/install-template.sh`          | Starting a new install script                                      |

## Anti-patterns to flag

When reviewing existing code, flag these as requiring a fix:

- ❌ Hardcoded versions (`wget https://.../app-1.2.3.tar.gz`)
- ❌ Missing `/opt/${APP}_version.txt` write after install
- ❌ Plain `echo` for status (should be `msg_info` / `msg_ok`)
- ❌ Custom ANSI color codes instead of `${YW}`, `${GN}`, etc.
- ❌ `apt-get install` without `$STD` prefix
- ❌ `[ "$x" = "y" ]` instead of `[[ "$x" == "y" ]]`
- ❌ Unquoted `$VARIABLES`
- ❌ `set -e` without `catch_errors`
- ❌ Custom spinner reimplementation
- ❌ Not calling `header_info`, `variables`, `color`, `catch_errors` at start
- ❌ Calling `start` / `build_container` / `description` out of order

## Style preferences

- Function names use `verb_noun` snake_case: `setup_database`, `install_dependencies`
- Multi-line commands use trailing `\` for readability
- Tags in `var_tags` are semicolon-separated, max 3-4, no spaces
- Keep `var_cpu`, `var_ram`, `var_disk` realistic minimums for the app

## Sources

- Main repo: <https://github.com/community-scripts/ProxmoxVE>
- Dev repo (new scripts): <https://github.com/community-scripts/ProxmoxVED>
- Wiki: <https://github.com/community-scripts/ProxmoxVE/wiki>
- Detailed CT guide: <https://community-scripts.org/docs/ct/detailed_guide>
