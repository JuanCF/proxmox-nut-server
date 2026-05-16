#!/usr/bin/env bash
set -euo pipefail

NUT_ADMIN_URL="${NUT_ADMIN_URL:-https://raw.githubusercontent.com/JuanCF/proxmox-nut-server/main}"

echo "[NUT-ADMIN] Installing dependencies..."
apt-get update -qq
apt-get install -y python3-venv python3-pip nut-scanner curl

echo "[NUT-ADMIN] Creating application directory..."
mkdir -p /opt/nut-admin/static

echo "[NUT-ADMIN] Downloading admin files..."
curl -fsSL "${NUT_ADMIN_URL}/src/nut-admin/app.py" -o /opt/nut-admin/app.py
curl -fsSL "${NUT_ADMIN_URL}/src/nut-admin/static/index.html" -o /opt/nut-admin/static/index.html
curl -fsSL "${NUT_ADMIN_URL}/src/nut-admin/nut-admin.service" -o /etc/systemd/system/nut-admin.service

echo "[NUT-ADMIN] Setting up Python virtual environment..."
python3 -m venv /opt/nut-admin/venv
/opt/nut-admin/venv/bin/pip install --quiet flask

echo "[NUT-ADMIN] Enabling systemd service..."
systemctl daemon-reload
systemctl enable nut-admin

echo "[NUT-ADMIN] Starting service..."
systemctl restart nut-admin

if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  echo "[NUT-ADMIN] Configuring firewall..."
  ufw allow 8081/tcp comment "NUT Admin"
fi

VM_IP="$(hostname -I | awk '{print $1}')"
echo ""
echo "NUT Admin web interface installed and running."
echo "URL: http://${VM_IP}:8081"
