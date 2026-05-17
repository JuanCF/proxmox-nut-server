#!/usr/bin/env bash
set -euo pipefail

: "${NUT_ADMIN_REF:=7a6e201dbddd93223c4e47caa46783161575bcdd}"
NUT_ADMIN_URL="${NUT_ADMIN_URL:-https://raw.githubusercontent.com/JuanCF/proxmox-nut-server/${NUT_ADMIN_REF}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[NUT-ADMIN] Installing dependencies..."
apt-get update -qq
apt-get install -y python3-venv python3-pip nut-scanner curl

echo "[NUT-ADMIN] Creating application directory..."
mkdir -p /opt/nut-admin/static

echo "[NUT-ADMIN] Deploying admin files..."
if [[ -f "${SCRIPT_DIR}/app.py" ]]; then
  cp "${SCRIPT_DIR}/app.py" /opt/nut-admin/app.py
  cp "${SCRIPT_DIR}/static/index.html" /opt/nut-admin/static/index.html
  if [[ -f "${SCRIPT_DIR}/nut-admin.service" ]]; then
    cp "${SCRIPT_DIR}/nut-admin.service" /etc/systemd/system/nut-admin.service
  else
    curl -fsSL "${NUT_ADMIN_URL}/src/nut-admin/nut-admin.service" -o /etc/systemd/system/nut-admin.service
  fi
else
  echo "[NUT-ADMIN] Downloading admin files from ${NUT_ADMIN_URL}..."
  curl -fsSL "${NUT_ADMIN_URL}/src/nut-admin/app.py" -o /opt/nut-admin/app.py
  curl -fsSL "${NUT_ADMIN_URL}/src/nut-admin/static/index.html" -o /opt/nut-admin/static/index.html
  curl -fsSL "${NUT_ADMIN_URL}/src/nut-admin/nut-admin.service" -o /etc/systemd/system/nut-admin.service
fi

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
