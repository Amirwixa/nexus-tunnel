#!/usr/bin/env bash
# =============================================================================
#  NEXUS-TUNNEL v3.5 - Uninstaller Script (100% English)
#  Completely purges all tunnel services, binaries, and configurations.
# =============================================================================
set -euo pipefail

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${RED}"
cat << 'BANNER'
  _   _                 _   _       _           _        _ _           
 | \ | | _____  ___   _| | | |_ __ (_)_ __  ___| |_ __ _| | | ___ _ __ 
 |  \| |/ _ \ \/ / | | | | | | '_ \| | '_ \/ __| __/ _` | | |/ _ \ '__|
 | |\  |  __/>  <| |_| | |_| | | | | | | | \__ \ || (_| | | |  __/ |   
 |_| \_|\___/_/\_\\__,_|\___/|_| |_|_|_| |_|___/\__\__,_|_|_|\___|_|   
                     NexusTunnel Uninstaller
BANNER
echo -e "${NC}"

if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}[ERROR] This uninstaller must be run as root. Use: sudo bash uninstall.sh${NC}"
    exit 1
fi

echo -e "${YELLOW}WARNING: This will completely remove NexusTunnel and all its services.${NC}"
read -rp "Are you sure you want to proceed? [y/N]: " CONFIRM
CONFIRM=$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')

if [[ "$CONFIRM" != "y" && "$CONFIRM" != "yes" ]]; then
    echo -e "${GREEN}[OK] Uninstallation cancelled.${NC}"
    exit 0
fi

echo ""
echo -e "${CYAN}[1/5] Stopping and removing systemd services...${NC}"
SERVICES=("nexus-tunnel" "nexus-watchdog" "sing-box" "backhaul" "rathole")
for SVC in "${SERVICES[@]}"; do
    systemctl stop "$SVC" 2>/dev/null || true
    systemctl disable "$SVC" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SVC}.service"
done
systemctl daemon-reload

echo -e "${CYAN}[2/5] Removing configuration and log directories...${NC}"
rm -rf /etc/nexus-tunnel
rm -rf /var/log/nexus-tunnel
rm -rf /tmp/backhaul* /tmp/rathole*

echo -e "${CYAN}[3/5] Removing tunnel binaries and CLI symlinks...${NC}"
rm -f /usr/local/bin/nexus
rm -f /usr/local/bin/backhaul
rm -f /usr/local/bin/rathole
rm -f /usr/local/bin/sing-box

echo -e "${CYAN}[4/5] Cleaning up background processes...${NC}"
pkill -9 -f "nexus_core.py" 2>/dev/null || true
pkill -9 -f "backhaul" 2>/dev/null || true
pkill -9 -f "rathole" 2>/dev/null || true
pkill -9 -f "watchdog.py" 2>/dev/null || true

echo -e "${CYAN}[5/5] Resetting firewall rules (optional)...${NC}"
read -rp "Do you want to close opened ports (3080, 443, 8443, 2096) in firewall? [y/N]: " CLOSE_PORTS
CLOSE_PORTS=$(echo "$CLOSE_PORTS" | tr '[:upper:]' '[:lower:]')
if [[ "$CLOSE_PORTS" == "y" || "$CLOSE_PORTS" == "yes" ]]; then
    if command -v ufw &>/dev/null; then
        ufw delete allow 3080/tcp 2>/dev/null || true
        ufw delete allow 443/tcp 2>/dev/null || true
        ufw delete allow 443/udp 2>/dev/null || true
        ufw delete allow 8443/tcp 2>/dev/null || true
        ufw delete allow 8443/udp 2>/dev/null || true
        ufw delete allow 2096/tcp 2>/dev/null || true
        ufw delete allow 2096/udp 2>/dev/null || true
    fi
fi

echo ""
echo -e "${GREEN}======================================================================${NC}"
echo -e "${GREEN}  🎉 NexusTunnel has been completely uninstalled from this system.   ${NC}"
echo -e "${GREEN}======================================================================${NC}"
echo ""
