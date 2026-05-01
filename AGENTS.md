# Agent Notes: nut-vm-setup

Single bash script that creates an Ubuntu 24.04 VM on Proxmox and configures NUT (Network UPS Tools) in netserver mode.

## Files

- `nut-vm-setup.sh` — Main deliverable (creates VM, configures NUT, sets up USB passthrough)
- `plan.md` — Complete specification with all constants, function signatures, and config templates

## Environment

- **Must run on Proxmox host** (requires `qm`, `pvesh`, root access)
- Downloads Ubuntu 24.04 cloud image to `/var/lib/vz/template/iso`
- Generates temp SSH keys in `/tmp/` for VM provisioning (auto-cleaned on exit)

## Key Commands

```bash
# Run the setup script (on Proxmox host as root)
bash nut-vm-setup.sh

# Verify VM created
qm list

# Check USB passthrough config
qm config <vmid> | grep usb

# Test NUT server from another machine
upsc ups@<VM_IP>:3493
```

## Architecture Notes

- NUT install script is embedded as a heredoc, SCP'd to VM, executed via SSH
- USB UPS detection parses `lsusb` output, cross-references known vendor IDs
- VM uses cloud-init with DHCP; guest agent required for IP detection
- NUT config requires specific permissions: `chmod 640`, `chown root:nut`

## Edge Cases Handled

- Duplicate UPS models: use bus-port notation (`host=4-1`)
- Partial image download: uses `wget -c` for resume
- Slow DHCP: 2-minute retry for guest agent IP detection
- Special chars in passwords: use single-quoted heredoc delimiters

## Reference

See `plan.md` for: complete function list, NUT config file templates, order of operations, and verification steps.
