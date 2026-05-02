# Version management

The project uses a simple file-based version tracking system. There is
no database, no metadata service — just a plain text file inside the
container.

## The version file

```
/opt/${APP}_version.txt
```

Examples:
- `/opt/Homarr_version.txt` → `0.15.4`
- `/opt/Pihole_version.txt` → `5.18.4`

This file is written **once after install** and **once after every
successful update**. It is the single source of truth.

## Writing the version (in `install/AppName-install.sh`)

After a successful install, always:

```bash
echo "${RELEASE}" > /opt/${APP}_version.txt
```

`${RELEASE}` is the version you fetched from the upstream API.
`${APP}` is the application name from the metadata.

## The `update_script()` function pattern

Every `ct/AppName.sh` must define `update_script()`. This is what runs
when a user re-executes the script on a host that already has the
container.

```bash
function update_script() {
    header_info
    check_container_storage
    check_container_resources

    # 1. Verify the app is installed
    if [[ ! -d /opt/appname ]]; then
        msg_error "No ${APP} Installation Found!"
        exit
    fi

    # 2. Fetch upstream version
    RELEASE=$(curl -fsSL https://api.github.com/repos/user/repo/releases/latest \
              | grep "tag_name" \
              | awk '{print substr($2, 3, length($2)-4)}')

    # 3. Compare
    if [[ ! -f /opt/${APP}_version.txt ]] || \
       [[ "${RELEASE}" != "$(cat /opt/${APP}_version.txt)" ]]; then

        msg_info "Updating ${APP} to v${RELEASE}"

        # 4. Apply the update (stop service, replace files, restart)
        systemctl stop appname
        cd /opt/appname
        wget -q "https://github.com/user/repo/archive/refs/tags/v${RELEASE}.tar.gz"
        tar -xzf "v${RELEASE}.tar.gz" --strip-components=1
        rm -f "v${RELEASE}.tar.gz"
        systemctl start appname

        # 5. Persist the new version
        echo "${RELEASE}" > /opt/${APP}_version.txt
        msg_ok "Updated ${APP} to v${RELEASE}"
    else
        msg_ok "No update required. ${APP} is already at v${RELEASE}."
    fi
    exit
}
```

## Three ways to fetch upstream version

### A) GitHub Releases API (most common)

```bash
# Without jq
RELEASE=$(curl -fsSL https://api.github.com/repos/USER/REPO/releases/latest \
          | grep "tag_name" \
          | awk '{print substr($2, 3, length($2)-4)}')

# With jq (preferred when jq is already a dependency)
RELEASE=$(curl -fsSL https://api.github.com/repos/USER/REPO/releases/latest \
          | jq -r '.tag_name' \
          | sed 's/^v//')
```

The `awk` trick strips the surrounding `"v…",` characters. Adjust the
substring offsets if upstream uses a different tag format.

### B) GitHub Tags API (when there are no releases)

```bash
RELEASE=$(curl -fsSL https://api.github.com/repos/USER/REPO/tags \
          | jq -r '.[0].name' \
          | sed 's/^v//')
```

### C) System packages (apt/apk)

For apps installed from distro repos (nginx, postgresql, etc.), the
update is just:

```bash
$STD apt update
$STD apt -y upgrade
```

No version file is written because the package manager owns the version.

## Edge cases

### App with prebuilt binary

```bash
fetch_and_deploy_gh_release "AppName" \
                            "user/repo" \
                            "prebuild" \
                            "${RELEASE}" \
                            "/opt/appname" \
                            "appname_Linux_x86_64.tar.gz"
echo "${RELEASE}" > /opt/${APP}_version.txt
```

### App installed via `git pull`

```bash
cd /opt/appname
RELEASE=$(git ls-remote --tags --refs origin | tail -n1 | awk -F/ '{print $NF}')
if [[ "${RELEASE}" != "$(cat /opt/${APP}_version.txt)" ]]; then
    git fetch --tags
    git checkout "${RELEASE}"
    echo "${RELEASE}" > /opt/${APP}_version.txt
fi
```

### App with Docker Compose

Update the compose file and pull:

```bash
cd /opt/appname
$STD docker compose pull
$STD docker compose up -d
echo "${RELEASE}" > /opt/${APP}_version.txt
```

## Don't

- ❌ Store versions in environment variables only — they don't survive reboots
- ❌ Hardcode version strings (`wget .../app-1.2.3.tar.gz`)
- ❌ Skip writing `/opt/${APP}_version.txt` — `update_script` will always re-update
- ❌ Use a different filename scheme (`version`, `.version`, `VERSION`) — the
  ecosystem expects `${APP}_version.txt` exactly
