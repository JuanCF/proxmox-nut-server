# Core functions reference

These are the helpers exposed by `misc/build.func` (host-side) and
`misc/core.func` + `misc/install.func` (container-side). Reuse them —
do not reimplement.

## Color variables

```bash
YW=$(echo "\033[33m")       # Yellow
YWB=$(echo "\033[93m")      # Bright yellow (used for spinner)
BL=$(echo "\033[36m")       # Cyan/Blue
RD=$(echo "\033[01;31m")    # Red
BGN=$(echo "\033[4;92m")    # Bright green underlined
GN=$(echo "\033[1;92m")     # Bright green
DGN=$(echo "\033[32m")      # Dark green
CL=$(echo "\033[m")         # Reset
```

These are set up by calling `color` at the start of the script.

## Symbol variables

```bash
CM="${TAB}✔️${TAB}${CL}"     # Success checkmark
CROSS="${TAB}✖️${TAB}${CL}"  # Failure cross
INFO="${TAB}💡${TAB}${CL}"   # Info bulb
NETWORK="${TAB}📡${TAB}"
GATEWAY="${TAB}🌐${TAB}"
CREATING="${TAB}🚀${TAB}"
HOSTNAME="${TAB}🏠${TAB}"
CPUCORE="${TAB}🧠${TAB}"
DISKSIZE="${TAB}💾${TAB}"
OS="${TAB}🖥️${TAB}"
```

## Layout helpers

```bash
BFR="\\r\\033[K"   # Clear current line and return to start
HOLD=" "
TAB="  "
```

## Message functions

These are the only correct way to display progress. Each `msg_info`
starts a spinner; the next `msg_ok` or `msg_error` stops it.

```bash
msg_info "Installing Dependencies"
$STD apt-get install -y curl wget git
msg_ok "Installed Dependencies"

# On failure (rarely called manually — `catch_errors` handles it)
msg_error "Something went wrong"
```

### Internal implementation (do not redefine)

```bash
msg_info() {
    local msg="$1"
    echo -ne "${TAB}${YW}${HOLD}${msg}${HOLD}"
    spinner &
    SPINNER_PID=$!
}

msg_ok() {
    if [ -n "$SPINNER_PID" ] && ps -p $SPINNER_PID > /dev/null; then
        kill $SPINNER_PID > /dev/null
    fi
    printf "\e[?25h"
    local msg="$1"
    echo -e "${BFR}${CM}${GN}${msg}${CL}"
}

msg_error() {
    if [ -n "$SPINNER_PID" ] && ps -p $SPINNER_PID > /dev/null; then
        kill $SPINNER_PID > /dev/null
    fi
    printf "\e[?25h"
    local msg="$1"
    echo -e "${BFR}${CROSS}${RD}${msg}${CL}"
}
```

## Spinner

Braille Unicode frames U+2800–U+28FF. Don't substitute with ASCII.

```bash
spinner() {
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local spin_i=0
    local interval=0.1
    printf "\e[?25l"
    while true; do
        printf "\r ${YWB}%s${CL}" "${frames[spin_i]}"
        spin_i=$(( (spin_i + 1) % ${#frames[@]} ))
        sleep "$interval"
    done
}
```

## Error handling

Always call `catch_errors` immediately after `color`. It enables
`set -Eeuo pipefail` and traps errors with a styled message that also
kills any running spinner.

```bash
catch_errors() {
    set -Eeuo pipefail
    trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
}

error_handler() {
    if [ -n "$SPINNER_PID" ] && ps -p $SPINNER_PID > /dev/null; then
        kill $SPINNER_PID > /dev/null
    fi
    printf "\e[?25h"
    local exit_code="$?"
    local line_number="$1"
    local command="$2"
    echo -e "\n${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: while executing command ${YW}$command${CL}\n"
}
```

## The `$STD` mechanism

`$STD` is set by the framework. It expands to:
- `>/dev/null 2>&1` when `VERBOSE="no"` (default)
- empty string when `VERBOSE="yes"`

Always prefix non-essential commands with it:

```bash
$STD apt-get update
$STD apt-get install -y package
$STD systemctl enable myservice
```

## Other key functions

| Function                        | Purpose                                              |
| ------------------------------- | ---------------------------------------------------- |
| `header_info "$APP"`            | Render the ASCII art header                          |
| `variables`                     | Parse CLI args and resolve defaults                  |
| `color`                         | Initialize color and symbol variables                |
| `verb_ip6`                      | Apply `DISABLEIPV6` setting                          |
| `setting_up_container`          | Configure locale, timezone, network                  |
| `network_check`                 | Validate IPv4/IPv6 connectivity                      |
| `update_os`                     | `apt-get update && upgrade` (or `apk` on Alpine)     |
| `motd_ssh`                      | Configure MOTD and SSH banner                        |
| `customize`                     | Apply final container customizations                 |
| `cleanup_lxc`                   | Remove temp files and clear apt cache                |
| `start`                         | Begin the container creation flow (host-side)        |
| `build_container`               | Create the LXC and run the install script inside     |
| `description`                   | Set the container description shown in Proxmox UI    |
| `check_container_storage`       | Used in `update_script()` — verify disk space        |
| `check_container_resources`     | Used in `update_script()` — verify CPU/RAM           |
| `silent <command>`              | Suppress output unless the command fails             |

## Tool setup helpers (in `install/` scripts)

```bash
NODE_VERSION="22"
NODE_MODULE="yarn,@vue/cli@5.0.0"   # optional
setup_nodejs

PHP_VERSION="8.4"
PHP_MODULE="bcmath,curl,gd,intl,mbstring,redis"
setup_php

MARIADB_VERSION="11.4"
setup_mariadb

setup_python
setup_docker
setup_composer
setup_ruby
setup_rust
setup_go
setup_java
setup_postgresql
setup_mongodb
setup_mysql
```

## GitHub release deployment helper

```bash
fetch_and_deploy_gh_release "AppName" \
                            "user/repo" \
                            "prebuild" \
                            "${RELEASE}" \
                            "/opt/app" \
                            "app_Linux_x86_64.tar.gz"
```
