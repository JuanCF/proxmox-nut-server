# Proxmox NUT VM Setup Script

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A bash script to automatically create an Ubuntu 24.04 VM on Proxmox VE, configure USB passthrough for your UPS, and set up NUT (Network UPS Tools) in netserver mode.

> **Why a VM instead of LXC?** NUT cannot run reliably in LXC containers due to kernel driver detachment restrictions. This script creates a lightweight VM specifically for NUT.

## Features

- 🖥️ **Automated VM Creation** - Creates Ubuntu 24.04 VM with optimized settings
- 🔌 **USB UPS Detection** - Auto-detects and configures USB passthrough for supported UPS devices
- ⚡ **NUT Server Setup** - Installs and configures NUT in netserver mode
- 🔒 **Secure by Default** - Creates temporary SSH keys, sets proper NUT permissions
- 🎯 **Interactive Configuration** - Guided prompts for all settings with sensible defaults
- 📊 **Status Summary** - Provides test commands and client configuration snippets
- 🛡️ **Error Handling** - Validates inputs, handles edge cases (duplicate UPS models, slow DHCP, etc.)

## Supported UPS Vendors

| Vendor | USB ID | Driver |
|--------|--------|--------|
| APC | `051d` | usbhid-ups |
| CyberPower | `0764` | usbhid-ups |
| Eaton | `0463` | usbhid-ups |
| Tripp Lite | `09ae` | usbhid-ups |
| Liebert | `10af` | usbhid-ups |

Other USB UPS devices can be configured manually.

## Prerequisites

- Proxmox VE 7.x or 8.x
- Root access on Proxmox host
- Internet connectivity (downloads Ubuntu cloud image)
- `wget`, `ssh`, `scp`, `lsusb`, `nc` installed (usually present by default)
- A USB UPS connected to the Proxmox host

## Installation

### Quick Install (One-Liner)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/JuanCF/proxmox-nut-server/main/src/nut-vm.sh)"
```

### Manual Download

```bash
# Download the script
curl -fsSL https://raw.githubusercontent.com/JuanCF/proxmox-nut-server/main/src/nut-vm.sh -o nut-vm.sh

# Or clone the repository
git clone https://github.com/JuanCF/proxmox-nut-server.git
cd proxmox-nut-server

# Run from source
bash src/nut-vm.sh
```

## Usage

```bash
# Run on Proxmox host as root (from cloned repo)
bash src/nut-vm.sh

# Or if downloaded directly
bash nut-vm.sh
```

### CLI Options

```bash
bash src/nut-vm.sh --help     # Show help
bash src/nut-vm.sh --version  # Show version
```

### Interactive Prompts

The script will guide you through:

1. **VM Configuration**
   - VM ID (auto-detects next available)
   - Hostname (default: `nut-server`)
   - Storage pool selection
   - Network bridge (default: `vmbr0`)
   - RAM, CPU cores, disk size
   - VM username and password

2. **UPS Detection**
   - Automatically scans for connected UPS devices
   - Presents list if multiple detected
   - Handles duplicate models using bus-port notation

3. **NUT Configuration**
   - UPS name and description
   - Driver selection (usbhid-ups recommended for most)
   - Admin and monitor user credentials
   - Listen address and port

## Example Output

```
╔═══════════════════════════════════════════════════════════╗
║              NUT VM Setup - Complete!                     ║
╠═══════════════════════════════════════════════════════════╣
║  VM ID:          100                                      ║
║  VM Name:        nut-server                               ║
║  VM IP:          192.168.1.50                             ║
║                                                           ║
║  NUT Server:     192.168.1.50:3493                        ║
║  UPS Name:       ups                                      ║
║                                                           ║
║  Test command:                                            ║
║    upsc ups@192.168.1.50                                  ║
╠═══════════════════════════════════════════════════════════╣
║  Client upsmon.conf snippet:                              ║
║  MONITOR ups@192.168.1.50:3493 1 monuser PASS slave       ║
╚═══════════════════════════════════════════════════════════╝
```

## Verification

After the script completes, verify the setup:

```bash
# Check VM status
qm list

# Verify USB passthrough
qm config <vmid> | grep usb

# Test NUT from Proxmox host
upsc ups@<VM_IP>

# Test from another machine
upsc ups@<VM_IP>:3493

# Check NUT services inside VM
ssh ubuntu@<VM_IP> systemctl status nut-server nut-monitor
```

## Configuring NUT Clients

Once the NUT server is running, configure other Proxmox nodes or clients:

### Proxmox Node (as NUT Client)

```bash
# Install NUT client
apt update && apt install nut-client

# Configure /etc/nut/nut.conf
MODE=netclient

# Configure /etc/nut/upsmon.conf
MONITOR ups@192.168.1.50:3493 1 monuser <password> slave

# Restart
systemctl restart nut-client
```

## Troubleshooting

### UPS Not Detected

- Ensure UPS is connected via USB
- Run `lsusb` on Proxmox host to verify it's visible
- Try manual entry of vendor:product ID

### NUT Test Fails

- Check UPS driver compatibility: https://networkupstools.org/stable-hcl.html
- SSH to VM and check logs: `journalctl -u nut-server`
- Verify UPS is visible in VM: `lsusb`

### VM IP Not Detected

- Ensure QEMU Guest Agent is running in VM
- Check DHCP server is functioning
- Manually enter IP when prompted

### Permission Denied on NUT Files

The script automatically sets `chmod 640` and `chown root:nut` on all NUT config files. If you manually edit configs, ensure these permissions are maintained.

## Security Notes

- Temporary SSH keys are generated in `/tmp/` and auto-deleted on exit
- NUT passwords should be strong and unique
- The netserver listens on all interfaces by default (`0.0.0.0`)
- Consider firewall rules to restrict NUT port (3493) access

## Architecture

```
Proxmox Host
├── USB UPS Device
│   └── USB Passthrough ──┐
│                         ▼
├── src/nut-vm.sh  VM (Ubuntu 24.04)
│   ├── Downloads        │   ├── NUT Server
│   ├── Creates VM ────►│   │   ├── nut-driver (usbhid-ups)
│   ├── Detects UPS      │   │   ├── upsd (port 3493)
│   ├── Configures ─────┘   │   └── upsmon
│   └── Deploys via         └── SSH (temp keys)
       embedded script
```

## License

MIT License - See [LICENSE](LICENSE) file for details.

## Contributing

Contributions welcome! Please feel free to submit a Pull Request.

## Acknowledgments

- [Network UPS Tools](https://networkupstools.org/) project
- Proxmox VE community
- Ubuntu Cloud Images

## Support

For issues, questions, or feature requests:

- Open an [issue](https://github.com/JuanCF/proxmox-nut-server/issues)
- Proxmox Forums: https://forum.proxmox.com/
- NUT Users Mailing List: https://alioth-lists.debian.net/lists/lists.alioth.debian.net

---

**Disclaimer**: This script modifies your Proxmox configuration. Always review scripts before running them as root. Test in a non-production environment first.
