#!/usr/bin/env bash
# Replace YOUR_USERNAME with your GitHub username while developing.
# BEFORE OPENING A PR: change the URL back to community-scripts/ProxmoxVE
source <(curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/ProxmoxVED/main/misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: YOUR_USERNAME
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/UPSTREAM_USER/UPSTREAM_REPO

# ---- Application metadata ----
APP="ApplicationName"
var_tags="${var_tags:-tag1;tag2}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-10}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
    header_info
    check_container_storage
    check_container_resources

    if [[ ! -d /opt/appname ]]; then
        msg_error "No ${APP} Installation Found!"
        exit
    fi

    RELEASE=$(curl -fsSL https://api.github.com/repos/UPSTREAM_USER/UPSTREAM_REPO/releases/latest \
              | grep "tag_name" \
              | awk '{print substr($2, 3, length($2)-4)}')

    if [[ ! -f /opt/${APP}_version.txt ]] || \
       [[ "${RELEASE}" != "$(cat /opt/${APP}_version.txt)" ]]; then

        msg_info "Updating ${APP} to v${RELEASE}"
        systemctl stop appname
        cd /opt/appname || { echo "Failed to change directory to /opt/appname" >&2; exit 1; }
        # TODO: replace with the actual update steps for this app
        wget -q "https://github.com/UPSTREAM_USER/UPSTREAM_REPO/archive/refs/tags/v${RELEASE}.tar.gz"
        tar -xzf "v${RELEASE}.tar.gz" --strip-components=1
        rm -f "v${RELEASE}.tar.gz"
        systemctl start appname
        echo "${RELEASE}" > "/opt/${APP}_version.txt"
        msg_ok "Updated ${APP} to v${RELEASE}"
    else
        msg_ok "No update required. ${APP} is already at v${RELEASE}."
    fi
    exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:PORT${CL}"
