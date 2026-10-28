#!/usr/bin/env bash
# =============================================================================
#  ⚡ NEXUS TUNNEL SUITE v6.0 - One-Line Universal Installer ⚡
#  Install and run:
#    bash <(curl -fsSL https://raw.githubusercontent.com/Amirwixa/nexus-tunnel/main/install.sh)
# =============================================================================
set -euo pipefail

RED='\033[1;31m'
GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}"
cat << 'BANNER'
  _   _ _____ _   _ _   _ ____    _____ _   _ _   _ _   _ _____ _     
 | \ | | ____| \ | | | | / ___|  |_   _| | | | \ | | \ | | ____| |    
 |  \| |  _| |  \| | | | \___ \    | | | | | |  \| |  \| |  _| | |    
 | |\  | |___| |\  | |_| |___) |   | | | |_| | |\  | |\  | |___| |___ 
 |_| \_|_____|_| \_|\___/|____/    |_|  \___/|_| \_|_| \_|_____|_____|
       v6.0 - Universal Anti-Censorship Multi-Engine Tunnel Suite
BANNER
echo -e "${NC}"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[x] این اسکریپت باید با دسترسی root اجرا شود.${NC}"
    exit 1
fi

INSTALL_DIR="/etc/nexus-tunnel"
BIN_DIR="/opt/nexus/bin"
mkdir -p "${INSTALL_DIR}" "${BIN_DIR}"

echo -e "${CYAN}[*] 1/4 بررسی و نصب وابستگی‌های لینوکس...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1 || true
apt-get install -y -qq curl wget jq tar unzip openssl iproute2 net-tools ca-certificates >/dev/null 2>&1 || true

echo -e "${CYAN}[*] 2/4 بررسی و دانلود هسته‌های تانل (Backhaul + WatTunnel + WaterWall)...${NC}"

# 1. Backhaul v0.7.2
if [[ ! -f "${BIN_DIR}/backhaul" ]]; then
    echo -e "    ${WHITE}-> دانلود هسته Backhaul v0.7.2...${NC}"
    curl -sL "https://github.com/Musixal/Backhaul/releases/download/v0.7.2/backhaul_linux_amd64.tar.gz" -o /tmp/backhaul.tar.gz
    tar -xzf /tmp/backhaul.tar.gz -C "${BIN_DIR}/" backhaul
    chmod +x "${BIN_DIR}/backhaul"
    ln -sf "${BIN_DIR}/backhaul" /usr/local/bin/backhaul
    rm -f /tmp/backhaul.tar.gz
else
    ln -sf "${BIN_DIR}/backhaul" /usr/local/bin/backhaul
fi

# 2. WatTunnel v3.1.1
if [[ ! -f "${BIN_DIR}/wattun" ]]; then
    echo -e "    ${WHITE}-> دانلود هسته WatTunnel v3.1.1...${NC}"
    curl -sL "https://github.com/JohnWatsoon/WatTunnel/releases/download/v3.1.1/wattun-linux-amd64" -o "${BIN_DIR}/wattun"
    chmod +x "${BIN_DIR}/wattun"
    ln -sf "${BIN_DIR}/wattun" /usr/local/bin/wattun
else
    ln -sf "${BIN_DIR}/wattun" /usr/local/bin/wattun
fi

# 3. WaterWall v1.5.2
if [[ ! -f "${BIN_DIR}/waterwall" ]]; then
    echo -e "    ${WHITE}-> دانلود هسته WaterWall v1.5.2...${NC}"
    curl -sL "https://github.com/radkesvat/WaterWall/releases/download/v1.5.2/Waterwall-linux-gcc-x64.zip" -o /tmp/ww.zip
    unzip -q -o /tmp/ww.zip -d /tmp/ww_dir 2>/dev/null || true
    cp /tmp/ww_dir/Waterwall "${BIN_DIR}/waterwall" 2>/dev/null || true
    chmod +x "${BIN_DIR}/waterwall"
    ln -sf "${BIN_DIR}/waterwall" /usr/local/bin/waterwall
    rm -rf /tmp/ww.zip /tmp/ww_dir
else
    ln -sf "${BIN_DIR}/waterwall" /usr/local/bin/waterwall
fi

echo -e "${CYAN}[*] 3/4 پیکربندی کلید هوش مصنوعی جمینای و تنظیمات پیش‌فرض...${NC}"
DEFAULT_GEMINI_KEY="$(echo "QVEuQWI4Uk42SVY4V295Zlc1VS1WWUduTTZ5RTl0aG5yVDN3RVZVdWxwZDVTZnZpeFBldXc=" | base64 -d 2>/dev/null)"
if [[ ! -f "${INSTALL_DIR}/nexus.env" ]]; then
    cat > "${INSTALL_DIR}/nexus.env" << EOF
ROLE="iran"
ENGINE="backhaul"
CARRIER="tcpmux"
REMOTE_IP="144.202.103.25"
TUNNEL_PORT="3080"
TOKEN="nexus_$(openssl rand -hex 6 2>/dev/null || echo 'master_key_99')"
PORTS="443=127.0.0.1:443,80=127.0.0.1:80"
POOL_SIZE="8"
SNI="speedtest.net"
GEMINI_API_KEY="${DEFAULT_GEMINI_KEY}"
AI_MODEL="gemini-flash-lite-latest"
EOF
fi

echo -e "${CYAN}[*] 4/4 نصب منوی مدیریت تعاملی Nexus CLI...${NC}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-/tmp}")" 2>/dev/null && pwd || echo /tmp)"
if [[ -f "${SCRIPT_DIR}/nexus.sh" ]]; then
    cp "${SCRIPT_DIR}/nexus.sh" /usr/local/bin/nexus
else
    # Fetch from repository or install path
    curl -sL "https://raw.githubusercontent.com/Amirwixa/nexus-tunnel/main/nexus.sh" -o /usr/local/bin/nexus 2>/dev/null || true
fi
chmod +x /usr/local/bin/nexus

echo -e "\n${GREEN}═════════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✔ نصب Nexus Tunnel با موفقیت کامل انجام شد!${NC}"
echo -e "${GREEN}  از این پس می‌توانید با تایپ دستور ${WHITE}nexus${GREEN} منو را در هر زمان باز کنید.${NC}"
echo -e "${GREEN}═════════════════════════════════════════════════════════════════════${NC}\n"

sleep 1
# Launch the interactive menu directly
exec /usr/local/bin/nexus
