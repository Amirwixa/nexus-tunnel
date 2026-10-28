#!/usr/bin/env bash
# ==============================================================================
# Nexus-Tunnel v7.0 — Complete Uninstaller & Network Cleaner (uninstall.sh)
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[✘] لطفاً با دسترسی root اجرا کنید (sudo bash uninstall.sh).${NC}"
   exit 1
fi

echo -e "${YELLOW}[*] در حال توقف تمام پروفایل‌های تانل و پاکسازی کامل شبکه...${NC}"

# ۱. توقف و غیرفعال‌سازی تمام سرویس‌های nexus-tunnel@
for f in /etc/nexus-tunnel/*.json; do
    [[ ! -e "$f" ]] && continue
    name=$(basename "$f" .json)
    systemctl stop "nexus-tunnel@${name}.service" 2>/dev/null || true
    systemctl disable "nexus-tunnel@${name}.service" 2>/dev/null || true
done
systemctl stop "nexus-tunnel@*" 2>/dev/null || true
systemctl stop nexus-tunnel.service 2>/dev/null || true

# ۲. حذف اینترفیس‌های لایه ۳ کرنل و قوانین فایروال
for ifc in nx-gre nx-ipip nx-sit nx-vxlan; do
    ip link del "$ifc" 2>/dev/null || true
done
iptables -t nat -F PREROUTING 2>/dev/null || true
iptables -t nat -F POSTROUTING 2>/dev/null || true
iptables -t mangle -F FORWARD 2>/dev/null || true
iptables -t raw -F 2>/dev/null || true

# ۳. حذف فایل‌ها و دایرکتوری‌ها
rm -f /etc/systemd/system/nexus-tunnel@.service
rm -f /etc/systemd/system/nexus-tunnel.service
rm -f /usr/local/bin/nexus-tunnel
rm -f /usr/local/bin/nexus
rm -f /etc/sysctl.d/99-nexus-tunnel.conf
rm -rf /opt/nexus-tunnel /etc/nexus-tunnel /var/log/nexus-tunnel /run/nexus-tunnel

systemctl daemon-reload
sysctl --system >/dev/null 2>&1 || true

echo -e "${GREEN}[✔] تمام سرویس‌ها، تانل‌های L3 و فایل‌های Nexus-Tunnel به طور کامل پاک شدند.${NC}"
