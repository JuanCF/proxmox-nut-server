# Whiptail dialog patterns

The project uses **whiptail** (not `dialog`) because it's preinstalled
on Debian/Ubuntu. All interactive prompts must follow these patterns
for visual consistency.

## Standard `--backtitle`

Always set the backtitle to `"Proxmox VE Helper Scripts"` so all dialogs
share the same window-bar identity.

## Yes/No

```bash
if whiptail --backtitle "Proxmox VE Helper Scripts" \
            --title "DATABASE SETUP" \
            --yesno "Configure a custom database?" 10 58; then
    # User chose Yes
    configure_db
else
    # User chose No
    msg_info "Skipping custom DB"
fi
```

The dimensions `10 58` (height, width) are the project default for
yes/no boxes. Use `8 60` only for very short prompts.

## Single-line input

```bash
DB_HOST=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
                   --inputbox "Database host:" \
                   8 58 \
                   "localhost" \
                   --title "DB HOST" 3>&1 1>&2 2>&3)

exitstatus=$?
if [ $exitstatus -ne 0 ]; then
    msg_error "Cancelled by user"
    exit 1
fi
```

The `3>&1 1>&2 2>&3` swap is non-negotiable — whiptail writes the
result to file descriptor 3, and this redirects it back to stdout
so command substitution captures it.

## Password input

```bash
DB_PASS=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
                   --passwordbox "Database password:" \
                   8 58 \
                   --title "DB PASSWORD" 3>&1 1>&2 2>&3)
```

## Menu (single choice)

```bash
CHOICE=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
                  --title "INSTALL TYPE" \
                  --menu "Choose an option:" 14 58 4 \
                  "1" "Basic Install" \
                  "2" "Advanced Install" \
                  "3" "Exit" 3>&1 1>&2 2>&3)

case "$CHOICE" in
    1) basic_install ;;
    2) advanced_install ;;
    3) exit 0 ;;
esac
```

Format: `height width listheight tag1 item1 tag2 item2 …`

## Checklist (multiple choice)

```bash
SELECTED=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
                    --title "OPTIONAL PACKAGES" \
                    --checklist "Choose packages to install:" 14 58 4 \
                    "curl"  "HTTP client"        ON \
                    "git"   "Version control"    ON \
                    "vim"   "Text editor"        OFF \
                    "htop"  "Process monitor"    OFF 3>&1 1>&2 2>&3)

# Result is space-separated, quoted: "curl" "git"
for pkg in $SELECTED; do
    pkg=$(echo "$pkg" | tr -d '"')
    $STD apt-get install -y "$pkg"
done
```

## Radiolist (single choice with descriptions)

```bash
DISTRO=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
                  --title "DISTRIBUTION" \
                  --radiolist "Choose OS:" 14 58 3 \
                  "debian"  "Debian 12 (Bookworm)"  ON \
                  "ubuntu"  "Ubuntu 24.04 LTS"      OFF \
                  "alpine"  "Alpine 3.20"           OFF 3>&1 1>&2 2>&3)
```

## Progress gauge

```bash
{
    for i in 10 30 50 80 100; do
        echo "$i"
        echo "XXX"
        echo "Step $i%"
        echo "XXX"
        sleep 1
    done
} | whiptail --backtitle "Proxmox VE Helper Scripts" \
             --gauge "Installing…" 8 58 0
```

## Message box

```bash
whiptail --backtitle "Proxmox VE Helper Scripts" \
         --title "INSTALL COMPLETE" \
         --msgbox "Installation finished. Press OK to continue." 8 58
```

## Cancellation handling

A user pressing Cancel or Esc returns a non-zero exit code (typically 1
for Cancel, 255 for Esc). Always check it on prompts that gate further
action:

```bash
HOSTNAME=$(whiptail --inputbox "Hostname:" 8 58 \
                    --title "HOSTNAME" 3>&1 1>&2 2>&3)

if [ $? -ne 0 ] || [ -z "$HOSTNAME" ]; then
    msg_error "Hostname is required"
    exit 1
fi
```
