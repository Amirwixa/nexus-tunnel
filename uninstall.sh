#!/usr/bin/env bash
# ==============================================================================
# Nexus-Tunnel v7.0 — Complete Uninstaller & Network Cleaner (uninstall.sh)
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[✘] Error: Please run as root (sudo bash uninstall.sh).${NC}"
   exit 1
fi

echo -e "${YELLOW}[*] Stopping all tunnel instances and cleaning network rules...${NC}"

# 1. Stop and disable all nexus-tunnel@ instances
for f in /etc/nexus-tunnel/*.json; do
    [[ ! -e "$f" ]] && continue
    name=$(basename "$f" .json)
    systemctl stop "nexus-tunnel@${name}.service" 2>/dev/null || true
    systemctl disable "nexus-tunnel@${name}.service" 2>/dev/null || true
done
systemctl stop "nexus-tunnel@*" 2>/dev/null || true
systemctl stop nexus-tunnel.service 2>/dev/null || true

# 2. Remove L3 kernel interfaces and clear firewall rules
for ifc in nx-gre nx-ipip nx-sit nx-vxlan; do
    ip link del "$ifc" 2>/dev/null || true
done
iptables -t nat -F PREROUTING 2>/dev/null || true
iptables -t nat -F POSTROUTING 2>/dev/null || true
iptables -t mangle -F FORWARD 2>/dev/null || true
iptables -t raw -F 2>/dev/null || true

# 3. Remove files and directories
rm -f /etc/systemd/system/nexus-tunnel@.service
rm -f /etc/systemd/system/nexus-tunnel.service
rm -f /usr/local/bin/nexus-tunnel
rm -f /usr/local/bin/nexus
rm -f /etc/sysctl.d/99-nexus-tunnel.conf
rm -rf /opt/nexus-tunnel /etc/nexus-tunnel /var/log/nexus-tunnel /run/nexus-tunnel

systemctl daemon-reload
sysctl --system >/dev/null 2>&1 || true

echo -e "${GREEN}[✔] All Nexus-Tunnel v7.0 services, L3 interfaces, and files completely removed.${NC}"
