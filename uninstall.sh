#!/usr/bin/env bash
# ==============================================================================
# Nexus-Tunnel v5.0 — Clean Uninstaller (uninstall.sh)
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[✘] لطفاً اسکریپت حذف را با دسترسی root اجرا کنید (sudo bash uninstall.sh).${NC}"
   exit 1
fi

echo -e "${YELLOW}[*] در حال توقف سرویس و حذف کامل Nexus-Tunnel...${NC}"

systemctl stop nexus-tunnel.service 2>/dev/null || true
systemctl disable nexus-tunnel.service 2>/dev/null || true

rm -f /etc/systemd/system/nexus-tunnel.service
rm -f /usr/local/bin/nexus-tunnel
rm -f /usr/local/bin/nexus
rm -f /etc/sysctl.d/99-nexus-tunnel.conf
rm -rf /opt/nexus-tunnel /etc/nexus-tunnel

systemctl daemon-reload
sysctl --system >/dev/null 2>&1 || true

echo -e "${GREEN}[✔] پروژه Nexus-Tunnel و تمام کانفیگ‌های مربوط به آن به طور کامل از سرور پاک شدند.${NC}"
