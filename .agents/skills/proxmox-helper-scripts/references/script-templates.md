# Script anatomy

The project has two script types that work together.

## `ct/AppName.sh` (host-side, container creator)

Runs on the Proxmox host. Orchestrates LXC creation and then runs the
matching install script inside the container.

### Required structure

```bash
#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: <YourGitHubUsername>
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/upstream/project

# ---- Application metadata ----
APP="ApplicationName"
var_tags="${var_tags:-tag1;tag2}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-10}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

# ---- Initialization (in this exact order) ----
header_info "$APP"
variables
color
catch_errors

# ---- Update path ----
function update_script() {
    # See references/version-management.md
}

# ---- Creation path ----
start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:PORT${CL}"
```

### Order of calls (do not reorder)

1. `source build.func` — loads framework
2. Metadata block (`APP`, `var_*`)
3. `header_info "$APP"` — ASCII art header
4. `variables` — parses CLI args, applies defaults
5. `color` — sets up `${GN}`, `${YW}`, etc.
6. `catch_errors` — installs error trap
7. `update_script()` definition (called automatically if container exists)
8. `start` — kicks off the wizard or runs `update_script`
9. `build_container` — only reached on fresh install
10. `description` — sets the LXC description in the Proxmox UI
11. Final success message

## `install/AppName-install.sh` (container-side, app installer)

Runs **inside** the freshly created LXC. Sourced via `lxc-attach` by
`build_container`. Has access to all of `core.func`, `tools.func`,
`install.func`.

### Required structure

```bash
#!/usr/bin/env bash
# Copyright (c) 2021-2026 community-scripts ORG
# Author: <YourGitHubUsername>
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/upstream/project

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt-get install -y \
    curl \
    wget \
    git \
    gnupg \
    ca-certificates
msg_ok "Installed Dependencies"

# Optional: language/runtime setup
NODE_VERSION="22"
setup_nodejs

msg_info "Installing ${APPLICATION}"
RELEASE=$(curl -fsSL https://api.github.com/repos/user/repo/releases/latest \
          | grep "tag_name" \
          | awk '{print substr($2, 3, length($2)-4)}')
cd /opt
$STD wget -q "https://github.com/user/repo/archive/refs/tags/v${RELEASE}.tar.gz"
$STD tar -xzf "v${RELEASE}.tar.gz"
mv "repo-${RELEASE}" appname
rm -f "v${RELEASE}.tar.gz"
echo "${RELEASE}" > /opt/${APPLICATION}_version.txt
msg_ok "Installed ${APPLICATION}"

msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/appname.service
[Unit]
Description=${APPLICATION}
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/appname
ExecStart=/opt/appname/start.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now appname
msg_ok "Created Service"

motd_ssh
customize

msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"
```

### Environment provided by `build.func`

These variables are exported by the parent `build_container` and are
available inside the install script:

| Variable             | Meaning                                                |
| -------------------- | ------------------------------------------------------ |
| `$APPLICATION`       | App display name (`$APP` from the ct/ script)          |
| `$app`               | Lowercased name (used for tags, paths)                 |
| `$CTID`              | The new container's ID                                 |
| `$PASSWORD`          | Root password generated for the container              |
| `$VERBOSE`           | `"yes"` or `"no"` — controls `$STD`                    |
| `$STD`               | Either empty or `>/dev/null 2>&1`                      |
| `$tz`                | Timezone string                                        |
| `$DISABLEIPV6`       | `"yes"` or `"no"`                                      |
| `$SSH_ROOT`          | `"yes"` or `"no"`                                      |
| `$SSH_AUTHORIZED_KEY`| Optional pubkey injected into root's `authorized_keys` |
| `$CACHER`, `$CACHER_IP` | Optional apt-cacher proxy settings                  |

### Function call order (install side)

1. `source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"` — load helpers
2. `color`
3. `verb_ip6`
4. `catch_errors`
5. `setting_up_container` — locale, timezone, network
6. `network_check`
7. `update_os` — apt/apk update + upgrade
8. Install dependencies, runtimes, the app itself
9. Configure services, write `/opt/${APP}_version.txt`
10. `motd_ssh` — final MOTD/SSH banner
11. `customize` — final touches
12. Cleanup (`autoremove`, `autoclean`)

## File locations summary

```
ProxmoxVE/
├── ct/AppName.sh           # Host-side creator
├── install/AppName-install.sh   # Container-side installer
├── frontend/public/json/AppName.json   # Metadata for the website
├── misc/
│   ├── build.func          # Host-side framework
│   ├── core.func           # Shared UI (colors, msg_*, spinner)
│   ├── install.func        # Container OS setup
│   ├── tools.func          # setup_nodejs, setup_php, etc.
│   ├── alpine-install.func # Alpine equivalent of install.func
│   └── error_handler.func  # Error trap implementation
```
