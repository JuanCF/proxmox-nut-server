#!/usr/bin/env bash
# Copyright (c) 2021-2026 community-scripts ORG
# Author: YOUR_USERNAME
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/UPSTREAM_USER/UPSTREAM_REPO

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# ---- Dependencies ----
msg_info "Installing Dependencies"
$STD apt-get install -y \
    curl \
    wget \
    git \
    gnupg \
    ca-certificates \
    sudo
msg_ok "Installed Dependencies"

# ---- Optional: language/runtime setup ----
# Uncomment and adapt as needed:
#
# NODE_VERSION="22"
# NODE_MODULE="yarn"
# setup_nodejs
#
# PHP_VERSION="8.4"
# PHP_MODULE="bcmath,curl,gd,intl,mbstring"
# setup_php
#
# MARIADB_VERSION="11.4"
# setup_mariadb

# ---- Application install ----
msg_info "Installing ${APPLICATION}"
RELEASE=$(curl -fsSL https://api.github.com/repos/UPSTREAM_USER/UPSTREAM_REPO/releases/latest \
          | grep "tag_name" \
          | awk '{print substr($2, 3, length($2)-4)}')

cd /opt || { msg_error "Failed to change to /opt directory"; exit 1; }
$STD wget -q "https://github.com/UPSTREAM_USER/UPSTREAM_REPO/archive/refs/tags/v${RELEASE}.tar.gz"
$STD tar -xzf "v${RELEASE}.tar.gz"
mv "UPSTREAM_REPO-${RELEASE}" appname
rm -f "v${RELEASE}.tar.gz"

# TODO: build / configure the app here

echo "${RELEASE}" > "/opt/${APPLICATION}_version.txt"
msg_ok "Installed ${APPLICATION}"

# ---- systemd service ----
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

# ---- Final touches ----
motd_ssh
customize

msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"
