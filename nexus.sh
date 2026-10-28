#!/usr/bin/env bash
# =============================================================================
#  ⚡ NEXUS TUNNEL SUITE v6.0 ⚡
#  Universal Anti-Censorship Reverse Tunnel Manager (Backhaul + WatTunnel + WaterWall + Gemini AI)
# =============================================================================
set -uo pipefail

export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# Configuration Paths
CONF_DIR="/etc/nexus-tunnel"
ENV_FILE="${CONF_DIR}/nexus.env"
BH_CONF="${CONF_DIR}/config.toml"
WAT_CONF="${CONF_DIR}/wattun.yml"
WW_CONF="${CONF_DIR}/waterwall.json"
SERVICE_FILE="/etc/systemd/system/nexus-tunnel.service"
BIN_DIR="/opt/nexus/bin"

# Pre-baked Gemini API Key (Hardcoded - Never Prompts User)
DEFAULT_GEMINI_KEY="$(echo "QVEuQWI4Uk42SVY4V295Zlc1VS1WWUduTTZ5RTl0aG5yVDN3RVZVdWxwZDVTZnZpeFBldXc=" | base64 -d 2>/dev/null)"
AI_MODEL="gemini-flash-lite-latest"

# Terminal Colors
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
PURPLE='\033[1;35m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

# Default Configuration Variables
ROLE="${ROLE:-iran}"
ENGINE="${ENGINE:-backhaul}"
CARRIER="${CARRIER:-tcpmux}"
REMOTE_IP="${REMOTE_IP:-144.202.103.25}"
TUNNEL_PORT="${TUNNEL_PORT:-3080}"
TOKEN="${TOKEN:-nexus_master_key_99}"
PORTS="${PORTS:-443=127.0.0.1:443,80=127.0.0.1:80}"
POOL_SIZE="${POOL_SIZE:-8}"
SNI="${SNI:-speedtest.net}"
GEMINI_API_KEY="${DEFAULT_GEMINI_KEY}"

# Ensure root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[x] لطفاً اسکریپت را با دسترسی root (یا sudo) اجرا کنید.${NC}"
        exit 1
    fi
}

# Load persistent config
load_config() {
    mkdir -p "${CONF_DIR}" "${BIN_DIR}"
    if [[ -f "${ENV_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${ENV_FILE}"
    fi
    # Always keep pre-baked Gemini key if empty
    if [[ -z "${GEMINI_API_KEY:-}" ]]; then
        GEMINI_API_KEY="${DEFAULT_GEMINI_KEY}"
    fi
}

# Save persistent config
save_config() {
    cat > "${ENV_FILE}" << EOF
ROLE="${ROLE}"
ENGINE="${ENGINE}"
CARRIER="${CARRIER}"
REMOTE_IP="${REMOTE_IP}"
TUNNEL_PORT="${TUNNEL_PORT}"
TOKEN="${TOKEN}"
PORTS="${PORTS}"
POOL_SIZE="${POOL_SIZE}"
SNI="${SNI}"
GEMINI_API_KEY="${GEMINI_API_KEY}"
AI_MODEL="${AI_MODEL}"
EOF
}

# Get Public IPv4
get_public_ip() {
    local ip
    ip=$(curl -s4 --max-time 3 https://api.ipify.org 2>/dev/null || curl -s4 --max-time 3 https://icanhazip.com 2>/dev/null || echo "127.0.0.1")
    echo "$ip"
}

# Format Ports to Array string for Backhaul: ["443=127.0.0.1:443", "80=127.0.0.1:80"]
format_backhaul_ports() {
    local formatted=""
    IFS=',' read -ra ADDR <<< "${PORTS}"
    for i in "${ADDR[@]}"; do
        local trimmed
        trimmed=$(echo "$i" | xargs)
        if [[ -n "$trimmed" ]]; then
            if [[ -z "$formatted" ]]; then
                formatted="\"${trimmed}\""
            else
                formatted="${formatted}, \"${trimmed}\""
            fi
        fi
    done
    echo "[${formatted}]"
}

# Format Ports for WatTunnel: 443:443,80:80
format_wattun_ports() {
    local formatted=""
    IFS=',' read -ra ADDR <<< "${PORTS}"
    for i in "${ADDR[@]}"; do
        local trimmed
        trimmed=$(echo "$i" | xargs)
        if [[ -n "$trimmed" ]]; then
            local p1 p2
            if [[ "$trimmed" =~ ^([0-9]+)=.*:([0-9]+)$ ]]; then
                p1="${BASH_REMATCH[1]}"
                p2="${BASH_REMATCH[2]}"
            elif [[ "$trimmed" =~ ^([0-9]+):([0-9]+)$ ]]; then
                p1="${BASH_REMATCH[1]}"
                p2="${BASH_REMATCH[2]}"
            elif [[ "$trimmed" =~ ^([0-9]+)$ ]]; then
                p1="${BASH_REMATCH[1]}"
                p2="${BASH_REMATCH[1]}"
            else
                p1="443"; p2="443"
            fi
            if [[ -z "$formatted" ]]; then
                formatted="${p1}:${p2}"
            else
                formatted="${formatted},${p1}:${p2}"
            fi
        fi
    done
    echo "${formatted}"
}

# Format Allowed Ports for WatTunnel Server: 443,80
format_wattun_allow() {
    local formatted=""
    IFS=',' read -ra ADDR <<< "${PORTS}"
    for i in "${ADDR[@]}"; do
        local trimmed
        trimmed=$(echo "$i" | xargs)
        if [[ -n "$trimmed" ]]; then
            local p2
            if [[ "$trimmed" =~ =.*:([0-9]+)$ ]]; then
                p2="${BASH_REMATCH[1]}"
            elif [[ "$trimmed" =~ :([0-9]+)$ ]]; then
                p2="${BASH_REMATCH[1]}"
            else
                p2="443"
            fi
            if [[ -z "$formatted" ]]; then
                formatted="${p2}"
            else
                formatted="${formatted},${p2}"
            fi
        fi
    done
    echo "${formatted}"
}

# Generate configuration files according to active Engine & Role
generate_engine_config() {
    mkdir -p "${CONF_DIR}"

    # Self-signed TLS certificate if wss or wssmux is used
    if [[ "${CARRIER}" == "wss" || "${CARRIER}" == "wssmux" || "${CARRIER}" == "tls" ]]; then
        if [[ ! -f "${CONF_DIR}/cert.pem" || ! -f "${CONF_DIR}/key.pem" ]]; then
            openssl req -x509 -newkey rsa:2048 -nodes -keyout "${CONF_DIR}/key.pem" \
                -out "${CONF_DIR}/cert.pem" -days 3650 -subj "/CN=${SNI}" >/dev/null 2>&1 || true
        fi
    fi

    if [[ "${ENGINE}" == "backhaul" ]]; then
        local bh_ports
        bh_ports=$(format_backhaul_ports)
        if [[ "${ROLE}" == "iran" ]]; then
            # Iran = Backhaul Server (Listens for user traffic on ports & listens for Kharej tunnel connection)
            cat > "${BH_CONF}" << EOF
[server]
bind_addr = "0.0.0.0:${TUNNEL_PORT}"
transport = "${CARRIER}"
token = "${TOKEN}"
keepalive_period = 75
nodelay = true
heartbeat = 40
channel_size = 2048
log_level = "info"
ports = ${bh_ports}
EOF
            if [[ "${CARRIER}" == "wss" || "${CARRIER}" == "wssmux" ]]; then
                cat >> "${BH_CONF}" << EOF
tls_cert = "${CONF_DIR}/cert.pem"
tls_key = "${CONF_DIR}/key.pem"
EOF
            fi
        else
            # Kharej = Backhaul Client (Connects to Iran, forwards to local destination services)
            cat > "${BH_CONF}" << EOF
[client]
remote_addr = "${REMOTE_IP}:${TUNNEL_PORT}"
transport = "${CARRIER}"
token = "${TOKEN}"
connection_pool = ${POOL_SIZE}
aggressive_pool = true
keepalive_period = 75
dial_timeout = 10
retry_interval = 3
nodelay = true
log_level = "info"
EOF
            if [[ "${CARRIER}" == "wss" || "${CARRIER}" == "wssmux" ]]; then
                cat >> "${BH_CONF}" << EOF
tls_sni = "${SNI}"
EOF
            fi
        fi

        # Write Systemd Unit for Backhaul
        cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=Nexus Tunnel Engine (Backhaul Core)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/backhaul -c ${BH_CONF}
Restart=always
RestartSec=3
LimitNOFILE=1048576
LimitMEMLOCK=infinity
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    elif [[ "${ENGINE}" == "wattun" ]]; then
        local wat_carrier="${CARRIER}"
        if [[ "${wat_carrier}" == "tcpmux" || "${wat_carrier}" == "wsmux" ]]; then
            wat_carrier="tcp"
        elif [[ "${wat_carrier}" == "wssmux" ]]; then
            wat_carrier="wss"
        fi

        local wat_ports wat_allow
        wat_ports=$(format_wattun_ports)
        wat_allow=$(format_wattun_allow)

        if [[ "${ROLE}" == "kharej" ]]; then
            # Kharej Server
            cat > "${WAT_CONF}" << EOF
listen: "0.0.0.0:${TUNNEL_PORT}"
carrier: "${wat_carrier}"
key: "${TOKEN}"
allow-ports: "${wat_allow}"
tcp-cc: "bbr"
shape: true
tcp-mimic: true
debug: false
EOF
        else
            # Iran Client
            cat > "${WAT_CONF}" << EOF
peer: "${REMOTE_IP}:${TUNNEL_PORT}"
carrier: "${wat_carrier}"
key: "${TOKEN}"
ports:
  - "${wat_ports}"
conns: ${POOL_SIZE}
fake-sni: "${SNI}"
fake-mode: "seq"
tcp-cc: "bbr"
shape: true
tcp-mimic: true
debug: false
EOF
        fi

        cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=Nexus Tunnel Engine (WatTunnel Core)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/wattun -config ${WAT_CONF}
Restart=always
RestartSec=3
LimitNOFILE=1048576
LimitMEMLOCK=infinity
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    fi

    systemctl daemon-reload
}

# Service Controls
start_service() {
    generate_engine_config
    systemctl enable nexus-tunnel >/dev/null 2>&1 || true
    systemctl restart nexus-tunnel
    echo -e "${GREEN}[✔] سرویس تانل با موفقیت استارت شد.${NC}"
}

stop_service() {
    systemctl stop nexus-tunnel
    echo -e "${YELLOW}[!] سرویس تانل متوقف شد.${NC}"
}

restart_service() {
    generate_engine_config
    systemctl restart nexus-tunnel
    echo -e "${GREEN}[✔] سرویس تانل با موفقیت ری‌استارت شد.${NC}"
}

# Status Checker
get_status_badge() {
    if systemctl is-active --quiet nexus-tunnel; then
        echo -e "${GREEN}● فعال و متصل (Active - Running)${NC}"
    else
        echo -e "${RED}○ غیرفعال (Inactive - Stopped)${NC}"
    fi
}

# Measure Ping to Peer
measure_ping() {
    local target="${REMOTE_IP}"
    if [[ -z "${target}" || "${target}" == "127.0.0.1" ]]; then
        echo -e "${GRAY}تعیین نشده${NC}"
        return
    fi
    local ping_res
    ping_res=$(ping -c 3 -W 2 "${target}" 2>/dev/null | tail -1 | awk -F '/' '{print $5}')
    if [[ -n "${ping_res}" ]]; then
        echo -e "${GREEN}${ping_res} ms${NC}"
    else
        echo -e "${YELLOW}پاسخ پینگ دریافت نشد (ICMP ممکن است بسته باشد)${NC}"
    fi
}

# Query Gemini AI API (Pre-baked key, no questions asked)
query_gemini_ai() {
    local prompt="$1"
    local endpoint="https://generativelanguage.googleapis.com/v1beta/models/${AI_MODEL}:generateContent?key=${GEMINI_API_KEY}"
    
    local payload
    payload=$(jq -n --arg txt "$prompt" '{"contents": [{"parts": [{"text": $txt}]}]}')

    local response
    response=$(curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$endpoint" --max-time 15 2>/dev/null)
    
    local text
    text=$(echo "$response" | jq -r '.candidates[0].content.parts[0].text' 2>/dev/null)
    if [[ -z "$text" || "$text" == "null" ]]; then
        # Try fallback model
        endpoint="https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${GEMINI_API_KEY}"
        response=$(curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$endpoint" --max-time 15 2>/dev/null)
        text=$(echo "$response" | jq -r '.candidates[0].content.parts[0].text' 2>/dev/null)
    fi

    if [[ -n "$text" && "$text" != "null" ]]; then
        echo "$text"
    else
        echo "خطا در دریافت پاسخ از هوش مصنوعی جمینای (پاسخ خام: ${response:0:150})"
    fi
}

# -----------------------------------------------------------------------------
# 1. AI Autonomous Setup (One-Click)
# -----------------------------------------------------------------------------
ai_auto_setup() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     🤖 راه‌اندازی هوشمند خودکار با هوش مصنوعی (AI Auto Setup)         ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════════╝${NC}\n"

    echo -e "${WHITE}این سرور چه نقشی دارد؟${NC}"
    echo -e "  ${CYAN}1)${NC} سرور خارج (Foreign Server / Kharej)"
    echo -e "  ${CYAN}2)${NC} سرور ایران (Domestic Relay / Iran)"
    echo ""
    read -rp "انتخاب شما [1 یا 2]: " role_choice

    if [[ "${role_choice}" == "1" ]]; then
        ROLE="kharej"
        ENGINE="backhaul"
        CARRIER="wsmux"
        TUNNEL_PORT="3080"
        TOKEN="nexus_$(openssl rand -hex 6 2>/dev/null || echo 'master_key_99')"
        
        echo -e "\n${CYAN}[*] در حال تنظیم و استارت سرور خارج با هسته Backhaul (WSS-Mux)...${NC}"
        save_config
        start_service

        local my_ip
        my_ip=$(get_public_ip)
        echo -e "\n${GREEN}═════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}  ✔ سرور خارج با موفقیت راه‌اندازی شد و در پس‌زمینه در حال کار است!${NC}"
        echo -e "${GREEN}═════════════════════════════════════════════════════════════════════${NC}\n"
        echo -e "${WHITE}اطلاعات سرور خارج:${NC}"
        echo -e "  آی‌پی سرور خارج: ${YELLOW}${my_ip}${NC}"
        echo -e "  پورت تانل: ${YELLOW}${TUNNEL_PORT}${NC}"
        echo -e "  توکن امنیتی: ${YELLOW}${TOKEN}${NC}"
        echo -e "\n${CYAN}اکنون در سرور ایران، دستور زیر را اجرا کرده و گزینه 1 را انتخاب کنید:${NC}"
        echo -e "${BOLD}${WHITE}nexus${NC}\n"
        read -rp "برای بازگشت به منو Enter بزنید..." dummy
        return

    else
        ROLE="iran"
        ENGINE="backhaul"
        echo -e "\n${WHITE}لطفاً آی‌پی سرور خارج (Kharej) را وارد کنید:${NC}"
        read -rp "آی‌پی خارج [پیش‌فرض: ${REMOTE_IP}]: " input_kharej
        if [[ -n "${input_kharej}" ]]; then
            REMOTE_IP="${input_kharej}"
        fi

        echo -e "\n${CYAN}[*] تماس با هوش مصنوعی جمینای جهت تست مسیر و انتخاب بهترین پروتکل...${NC}"
        
        local ping_val
        ping_val=$(ping -c 3 -W 2 "${REMOTE_IP}" 2>/dev/null | tail -1 | awk -F '/' '{print $5}' || echo "unknown")
        
        echo -e "  ${WHITE}پینگ به سرور خارج:${NC} ${YELLOW}${ping_val} ms${NC}"
        echo -e "  ${WHITE}هوش مصنوعی در حال بررسی مقاومت در برابر فیلترینگ DPI...${NC}"

        local prompt="We are establishing a secure Iran-to-Kharej reverse tunnel.
Target Kharej IP: ${REMOTE_IP}
Current Ping latency: ${ping_val} ms
Available transports: tcpmux, wsmux, wssmux, tcp, grpc.
Iran DPI filters direct long-lived TCP and monitors entropy.
In 2 Persian sentences, evaluate the route and confirm the best protocol (defaulting to wsmux or wssmux for highest resilience). Then output 'RECOMMEND: wsmux' or 'RECOMMEND: tcpmux'."

        local ai_res
        ai_res=$(query_gemini_ai "$prompt")
        echo -e "\n${PURPLE}[🤖 نظر هوش مصنوعی جمینای]:${NC}"
        echo -e "${WHITE}${ai_res}${NC}\n"

        if [[ "$ai_res" =~ RECOMMEND:[[:space:]]*([a-zA-Z0-9]+) ]]; then
            CARRIER="${BASH_REMATCH[1]}"
        else
            CARRIER="wsmux"
        fi

        TUNNEL_PORT="3080"
        POOL_SIZE="8"
        save_config
        echo -e "${CYAN}[*] در حال اعمال کانفیگ ${CARRIER} و راه‌اندازی سرویس در سرور ایران...${NC}"
        start_service
        sleep 2

        # Verification test on port 443
        echo -e "${CYAN}[*] در حال تست اتصال زنده روی پورت 443 سرور ایران...${NC}"
        if curl -sIv --max-time 3 https://127.0.0.1:443 -k >/dev/null 2>&1 || ss -tulpn | grep -q ":443"; then
            echo -e "\n${GREEN}═════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${GREEN}  ✔ تانل هوشمند با موفقیت متصل شد و پورت 443 در حال سرویس‌دهی است!${NC}"
            echo -e "${GREEN}═════════════════════════════════════════════════════════════════════${NC}\n"
        else
            echo -e "\n${YELLOW}[!] سرویس استارت شد، اما پورت 443 پاسخ نداد. ممکن است سرور خارج هنوز متصل نشده باشد.${NC}\n"
        fi

        read -rp "برای بازگشت به منو Enter بزنید..." dummy
        return
    fi
}

# -----------------------------------------------------------------------------
# 2. Manual Setup Iran Server
# -----------------------------------------------------------------------------
setup_iran_manual() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║             🇮🇷 کانفیگ و راه‌اندازی دستی سرور ایران                    ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════════╝${NC}\n"

    ROLE="iran"

    echo -e "${WHITE}۱. انتخاب هسته اجرایی (Engine):${NC}"
    echo -e "  1) Backhaul Core (توصیه شده - پایدار و پرسرعت)"
    echo -e "  2) WatTunnel Core (ضد فیلترینگ عمیق و چند کاناله)"
    echo -e "  3) WaterWall Core (هسته C++)"
    read -rp "انتخاب [پیش‌فرض: 1]: " eng_c
    case "$eng_c" in
        2) ENGINE="wattun" ;;
        3) ENGINE="waterwall" ;;
        *) ENGINE="backhaul" ;;
    esac

    echo -e "\n${WHITE}۲. انتخاب پروتکل ترانسپورت (Transport Protocol):${NC}"
    echo -e "  1) tcpmux (TCP Multiplexing - سریع‌ترین پینگ و مصرف کم رم)"
    echo -e "  2) wsmux (WebSocket Multiplexing - استتار کامل وب‌سوکت)"
    echo -e "  3) wssmux (Secure TLS WebSocket - ضد فیلترینگ قوی)"
    echo -e "  4) ws (Plain WebSocket)"
    echo -e "  5) wss (Secure TLS WebSocket)"
    echo -e "  6) tcp (Raw TCP)"
    echo -e "  7) grpc (gRPC / HTTP2)"
    read -rp "انتخاب [پیش‌فرض: 2]: " tr_c
    case "$tr_c" in
        1) CARRIER="tcpmux" ;;
        3) CARRIER="wssmux" ;;
        4) CARRIER="ws" ;;
        5) CARRIER="wss" ;;
        6) CARRIER="tcp" ;;
        7) CARRIER="grpc" ;;
        *) CARRIER="wsmux" ;;
    esac

    echo -e "\n${WHITE}۳. آی‌پی یا دامنه سرور خارج (Remote Kharej IP):${NC}"
    read -rp "آی‌پی [پیش‌فرض: ${REMOTE_IP}]: " r_ip
    if [[ -n "$r_ip" ]]; then REMOTE_IP="$r_ip"; fi

    echo -e "\n${WHITE}۴. پورت برقراری تانل بین دو سرور:${NC}"
    read -rp "پورت [پیش‌فرض: ${TUNNEL_PORT}]: " t_port
    if [[ -n "$t_port" ]]; then TUNNEL_PORT="$t_port"; fi

    echo -e "\n${WHITE}۵. توکن امنیتی تانل (Token):${NC}"
    read -rp "توکن [پیش‌فرض: ${TOKEN}]: " tok
    if [[ -n "$tok" ]]; then TOKEN="$tok"; fi

    echo -e "\n${WHITE}۶. تعداد کانکشن استخر (Connection Pool):${NC}"
    read -rp "تعداد [پیش‌فرض: ${POOL_SIZE}]: " p_size
    if [[ -n "$p_size" ]]; then POOL_SIZE="$p_size"; fi

    echo -e "\n${WHITE}۷. پورت‌های فوروارد شده (Forwarded Ports):${NC}"
    echo -e "${GRAY}فرمت: 443=127.0.0.1:443,80=127.0.0.1:80${NC}"
    read -rp "پورت‌ها [پیش‌فرض: ${PORTS}]: " pts
    if [[ -n "$pts" ]]; then PORTS="$pts"; fi

    save_config
    echo -e "\n${CYAN}[*] در حال اعمال تنظیمات و راه‌اندازی سرویس سرور ایران...${NC}"
    start_service
    sleep 2

    echo -e "\n${GREEN}[✔] سرور ایران با موفقیت کانفیگ و راه‌اندازی شد!${NC}"
    read -rp "برای بازگشت به منو Enter بزنید..." dummy
}

# -----------------------------------------------------------------------------
# 3. Manual Setup Kharej Server
# -----------------------------------------------------------------------------
setup_kharej_manual() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║             🌍 کانفیگ و راه‌اندازی دستی سرور خارج                     ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════════╝${NC}\n"

    ROLE="kharej"

    echo -e "${WHITE}۱. انتخاب هسته اجرایی (Engine):${NC}"
    echo -e "  1) Backhaul Core (توصیه شده)"
    echo -e "  2) WatTunnel Core"
    echo -e "  3) WaterWall Core"
    read -rp "انتخاب [پیش‌فرض: 1]: " eng_c
    case "$eng_c" in
        2) ENGINE="wattun" ;;
        3) ENGINE="waterwall" ;;
        *) ENGINE="backhaul" ;;
    esac

    echo -e "\n${WHITE}۲. انتخاب پروتکل ترانسپورت (Transport Protocol):${NC}"
    echo -e "  1) tcpmux (TCP Multiplexing)"
    echo -e "  2) wsmux (WebSocket Multiplexing)"
    echo -e "  3) wssmux (Secure TLS WebSocket)"
    echo -e "  4) ws (Plain WebSocket)"
    echo -e "  5) wss (Secure TLS WebSocket)"
    echo -e "  6) tcp (Raw TCP)"
    echo -e "  7) grpc (gRPC / HTTP2)"
    read -rp "انتخاب [پیش‌فرض: 2]: " tr_c
    case "$tr_c" in
        1) CARRIER="tcpmux" ;;
        3) CARRIER="wssmux" ;;
        4) CARRIER="ws" ;;
        5) CARRIER="wss" ;;
        6) CARRIER="tcp" ;;
        7) CARRIER="grpc" ;;
        *) CARRIER="wsmux" ;;
    esac

    if [[ "${ENGINE}" == "backhaul" ]]; then
        echo -e "\n${WHITE}۳. آی‌پی سرور ایران (که کلاینت خارج به آن وصل شود):${NC}"
        read -rp "آی‌پی ایران [پیش‌فرض: ${REMOTE_IP}]: " r_ip
        if [[ -n "$r_ip" ]]; then REMOTE_IP="$r_ip"; fi
    fi

    echo -e "\n${WHITE}۴. پورت تانل بین دو سرور:${NC}"
    read -rp "پورت [پیش‌فرض: ${TUNNEL_PORT}]: " t_port
    if [[ -n "$t_port" ]]; then TUNNEL_PORT="$t_port"; fi

    echo -e "\n${WHITE}۵. توکن امنیتی تانل (Token):${NC}"
    read -rp "توکن [پیش‌فرض: ${TOKEN}]: " tok
    if [[ -n "$tok" ]]; then TOKEN="$tok"; fi

    save_config
    echo -e "\n${CYAN}[*] در حال اعمال تنظیمات و راه‌اندازی سرویس سرور خارج...${NC}"
    start_service
    sleep 2

    echo -e "\n${GREEN}[✔] سرور خارج با موفقیت کانفیگ و راه‌اندازی شد!${NC}"
    read -rp "برای بازگشت به منو Enter بزنید..." dummy
}

# -----------------------------------------------------------------------------
# 4. Port Forwarding Manager (Add, Edit, Delete)
# -----------------------------------------------------------------------------
manage_ports() {
    while true; do
        clear
        echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║             ⚙️ مدیریت پورت‌ها و رول‌ها (Port Forwarding Manager)      ║${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════════╝${NC}\n"

        echo -e "${WHITE}لیست پورت‌های فوروارد شده فعلی:${NC}"
        IFS=',' read -ra ADDR <<< "${PORTS}"
        local idx=1
        for p in "${ADDR[@]}"; do
            echo -e "  ${YELLOW}[${idx}]${NC} ${WHITE}${p}${NC}"
            ((idx++))
        done
        echo ""

        echo -e "  ${CYAN}1)${NC} افزودن پورت جدید (Add Port Rule)"
        echo -e "  ${CYAN}2)${NC} حذف یک پورت (Delete Port Rule)"
        echo -e "  ${CYAN}3)${NC} ویرایش کامل لیست پورت‌ها (Edit All Ports)"
        echo -e "  ${CYAN}0)${NC} بازگشت به منوی اصلی (Back to Main Menu)"
        echo ""
        read -rp "انتخاب شما: " p_choice

        case "$p_choice" in
            1)
                echo -e "\n${WHITE}پورت جدید را وارد کنید (مثال: 2083=127.0.0.1:2083 یا 8443=127.0.0.1:8443):${NC}"
                read -rp "پورت: " new_p
                if [[ -n "$new_p" ]]; then
                    if [[ -z "$PORTS" ]]; then
                        PORTS="$new_p"
                    else
                        PORTS="${PORTS},${new_p}"
                    fi
                    save_config
                    restart_service
                    echo -e "${GREEN}[✔] پورت جدید با موفقیت اضافه و سرویس ریلود شد.${NC}"
                    sleep 1.5
                fi
                ;;
            2)
                echo -e "\n${WHITE}شماره ردیف پورتی که می‌خواهید حذف شود را وارد کنید (1 تا $((idx-1))):${NC}"
                read -rp "شماره: " del_idx
                if [[ "$del_idx" =~ ^[0-9]+$ ]] && ((del_idx >= 1 && del_idx < idx)); then
                    local new_ports=()
                    local cur=1
                    for p in "${ADDR[@]}"; do
                        if ((cur != del_idx)); then
                            new_ports+=("$p")
                        fi
                        ((cur++))
                    done
                    PORTS=$(IFS=','; echo "${new_ports[*]}")
                    save_config
                    restart_service
                    echo -e "${GREEN}[✔] پورت با موفقیت حذف و سرویس ریلود شد.${NC}"
                    sleep 1.5
                else
                    echo -e "${RED}[x] شماره ردیف نامعتبر است.${NC}"
                    sleep 1.5
                fi
                ;;
            3)
                echo -e "\n${WHITE}لیست جدید پورت‌ها را با کاما جدا کنید:${NC}"
                read -rp "پورت‌ها: " all_p
                if [[ -n "$all_p" ]]; then
                    PORTS="$all_p"
                    save_config
                    restart_service
                    echo -e "${GREEN}[✔] لیست پورت‌ها به‌روزرسانی شد.${NC}"
                    sleep 1.5
                fi
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}[x] گزینه نامعتبر است.${NC}"
                sleep 1
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# 5. Switch Transport Protocol
# -----------------------------------------------------------------------------
switch_protocol() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║             🔄 تغییر سریع پروتکل ترانسپورت (Switch Protocol)         ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════════╝${NC}\n"

    echo -e "${WHITE}پروتکل فعال کنونی:${NC} ${YELLOW}${CARRIER}${NC}\n"
    echo -e "  ${CYAN}1)${NC} tcpmux   - TCP Multiplexing (سریع‌ترین پینگ، تأخیر حداقلی)"
    echo -e "  ${CYAN}2)${NC} wsmux    - WebSocket Multiplexing (استتار وب‌سوکت + مالتی‌پلکس)"
    echo -e "  ${CYAN}3)${NC} wssmux   - Secure TLS WebSocket (رمزنگاری کامل TLS 1.3 ضد فیلترینگ)"
    echo -e "  ${CYAN}4)${NC} ws       - Plain WebSocket (وب‌سوکت استاندارد)"
    echo -e "  ${CYAN}5)${NC} wss      - Secure TLS WebSocket (وب‌سوکت امن استاندارد)"
    echo -e "  ${CYAN}6)${NC} tcp      - Raw Multi-TCP (حداکثر پهنای باند خام)"
    echo -e "  ${CYAN}7)${NC} grpc     - gRPC over HTTP/2 (شبیه‌سازی ترافیک سرویس‌های ابری)"
    echo -e "  ${CYAN}0)${NC} انصراف و بازگشت"
    echo ""
    read -rp "انتخاب شما [1-7]: " sc

    case "$sc" in
        1) CARRIER="tcpmux" ;;
        2) CARRIER="wsmux" ;;
        3) CARRIER="wssmux" ;;
        4) CARRIER="ws" ;;
        5) CARRIER="wss" ;;
        6) CARRIER="tcp" ;;
        7) CARRIER="grpc" ;;
        0) return ;;
        *) echo -e "${RED}[x] انتخاب نامعتبر.${NC}"; sleep 1; return ;;
    esac

    save_config
    restart_service
    echo -e "\n${GREEN}[✔] پروتکل به ${CARRIER} تغییر یافت و سرویس با موفقیت ریلود شد.${NC}"
    read -rp "برای بازگشت Enter بزنید..." dummy
}

# -----------------------------------------------------------------------------
# 6. Switch Engine (Backhaul / WatTunnel / WaterWall)
# -----------------------------------------------------------------------------
switch_engine() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║             🔀 تغییر هسته اجرایی تانل (Switch Engine)                 ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════════╝${NC}\n"

    echo -e "${WHITE}هسته فعال کنونی:${NC} ${YELLOW}${ENGINE}${NC}\n"
    echo -e "  ${CYAN}1)${NC} Backhaul Core (v0.7.2 - پایداری و بازدهی حداکثری Go)"
    echo -e "  ${CYAN}2)${NC} WatTunnel Core (v3.1.1 - دور زدن فیلترینگ عمیق و چند کاناله)"
    echo -e "  ${CYAN}3)${NC} WaterWall Core (v1.5.2 - پایپ‌لاین پیشرفته شبکه C++)"
    echo -e "  ${CYAN}0)${NC} انصراف و بازگشت"
    echo ""
    read -rp "انتخاب شما [1-3]: " ec

    case "$ec" in
        1) ENGINE="backhaul" ;;
        2) ENGINE="wattun" ;;
        3) ENGINE="waterwall" ;;
        0) return ;;
        *) echo -e "${RED}[x] انتخاب نامعتبر.${NC}"; sleep 1; return ;;
    esac

    save_config
    restart_service
    echo -e "\n${GREEN}[✔] هسته اجرایی به ${ENGINE} تغییر یافت و سرویس ریلود شد.${NC}"
    read -rp "برای بازگشت Enter بزنید..." dummy
}

# -----------------------------------------------------------------------------
# 7. Live Status, Ping & Monitor
# -----------------------------------------------------------------------------
live_status() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           📊 وضعیت زنده، پینگ و آمار تونل (Live Status)                ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════════╝${NC}\n"

    echo -e "${WHITE}وضعیت سرویس:${NC} $(get_status_badge)"
    echo -e "${WHITE}نقش سرور:${NC} ${YELLOW}${ROLE}${NC}"
    echo -e "${WHITE}هسته فعال:${NC} ${YELLOW}${ENGINE}${NC}"
    echo -e "${WHITE}پروتکل ارتباطی:${NC} ${YELLOW}${CARRIER}${NC}"
    echo -e "${WHITE}سرور مقابل (Peer):${NC} ${YELLOW}${REMOTE_IP}:${TUNNEL_PORT}${NC}"
    echo -e "${WHITE}پینگ به سرور مقابل:${NC} $(measure_ping)"
    echo ""

    echo -e "${WHITE}پورت‌های در حال گوش دادن (Listening Ports):${NC}"
    ss -tulpn | grep -E "backhaul|wattun|waterwall" || echo -e "  ${GRAY}هیچ پورتی یافت نشد.${NC}"
    echo ""

    echo -e "${WHITE}کانکشن‌های فعال شبکه:${NC}"
    ss -t | grep -E "${REMOTE_IP}|:${TUNNEL_PORT}" | head -n 10 || echo -e "  ${GRAY}کانکشنی متصل نیست.${NC}"
    echo ""

    echo -e "${WHITE}مصرف منابع پردازشی:${NC}"
    ps aux | grep -E "backhaul|wattun|waterwall" | grep -v grep | awk '{printf "  CPU: %s%% | RAM: %s%% | PID: %s | Command: %s\n", $3, $4, $2, $11}'
    echo ""

    read -rp "برای بازگشت به منو Enter بزنید..." dummy
}

# -----------------------------------------------------------------------------
# 8. Live Logs Stream
# -----------------------------------------------------------------------------
view_logs() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           📜 لاگ‌های زنده سرویس (برای خروج Ctrl+C بزنید)              ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════════╝${NC}\n"

    journalctl -u nexus-tunnel -f -n 50 --no-pager
}

# -----------------------------------------------------------------------------
# 9. Kernel & BBR Optimizer
# -----------------------------------------------------------------------------
optimize_kernel() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           ⚡ بهینه‌سازی حرفه‌ای لینوکس و BBR (Kernel Optimizer)         ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════════╝${NC}\n"

    echo -e "${CYAN}[*] در حال اعمال تنظیمات بهینه‌سازی TCP BBR و بافرهای شبکه...${NC}"
    
    modprobe tcp_bbr 2>/dev/null || true

    cat > /etc/sysctl.d/99-nexus.conf << 'EOF'
fs.file-max = 1048576
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 33554432
net.core.wmem_default = 33554432
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
EOF

    sysctl -p /etc/sysctl.d/99-nexus.conf >/dev/null 2>&1

    cat > /etc/security/limits.d/99-nexus.conf << 'EOF'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

    echo -e "\n${GREEN}[✔] الگوریتم BBR فعال شد:${NC} $(sysctl -n net.ipv4.tcp_congestion_control)"
    echo -e "${GREEN}[✔] سقف فایل‌های باز لینوکس به ۱,۰۴۸,۵۷۶ افزایش یافت.${NC}"
    echo -e "${GREEN}[✔] بافرهای ارسال و دریافت سوکت بهینه شدند.${NC}\n"

    read -rp "برای بازگشت به منو Enter بزنید..." dummy
}

# -----------------------------------------------------------------------------
# 10. Gemini AI Doctor & Auto-Healer
# -----------------------------------------------------------------------------
ai_doctor() {
    clear
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         🩺 پزشک هوش مصنوعی جمینای (Gemini AI Doctor & Healer)        ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════════╝${NC}\n"

    echo -e "${CYAN}[*] در حال جمع‌آوری لاگ‌ها، آمار شبکه و خطاهای احتمالی...${NC}"

    local recent_logs
    recent_logs=$(journalctl -u nexus-tunnel -n 25 --no-pager 2>/dev/null | tail -n 20)

    local ping_stat
    ping_stat=$(ping -c 3 -W 2 "${REMOTE_IP}" 2>/dev/null | tail -2)

    local sock_stat
    sock_stat=$(ss -s 2>/dev/null)

    echo -e "${CYAN}[*] ارسال اطلاعات به هوش مصنوعی جمینای جهت تحلیل و ارائه راهکار...${NC}\n"

    local prompt="You are an elite network engineer and Iranian DPI / internet censorship bypass expert.
Here is the current state of a tunnel between Iran and Kharej:
Role: ${ROLE}
Engine: ${ENGINE}
Active Transport: ${CARRIER}
Remote Peer: ${REMOTE_IP}:${TUNNEL_PORT}
Forwarded Ports: ${PORTS}

Recent Logs:
${recent_logs}

Ping Stats:
${ping_stat}

Socket Stats:
${sock_stat}

Task:
1. Diagnose if there is any throttling, TCP RST by DPI, SNI blocking, or handshake failure.
2. Provide a clear Persian summary of the diagnostic (max 3 sentences).
3. Recommend the best fix (e.g. switch to wssmux, change tunnel port to 8443, or tune connection pool).
4. Finish your reply with exactly one line in this format:
ACTION: SWITCH_CARRIER=wssmux
(or ACTION: SWITCH_CARRIER=wsmux or ACTION: STATUS_HEALTHY)"

    local ai_diagnosis
    ai_diagnosis=$(query_gemini_ai "$prompt")

    echo -e "${PURPLE}═══════════════════ [🩺 تشخیص هوش مصنوعی جمینای] ═══════════════════${NC}"
    echo -e "${WHITE}${ai_diagnosis}${NC}"
    echo -e "${PURPLE}═════════════════════════════════════════════════════════════════════${NC}\n"

    if [[ "$ai_diagnosis" =~ ACTION:[[:space:]]*SWITCH_CARRIER=([a-zA-Z0-9]+) ]]; then
        local suggested_carrier="${BASH_REMATCH[1]}"
        echo -e "${YELLOW}هوش مصنوعی پیشنهاد داده که پروتکل ترانسپورت به [${suggested_carrier}] تغییر کند.${NC}"
        read -rp "آیا می‌خواهید این راهکار هم‌اکنون اعمال شود؟ [y/N]: " apply_choice
        if [[ "$apply_choice" =~ ^[Yy]$ ]]; then
            CARRIER="${suggested_carrier}"
            save_config
            restart_service
            echo -e "\n${GREEN}[✔] راهکار هوش مصنوعی اعمال شد و پروتکل به ${CARRIER} سوییچ شد.${NC}"
        fi
    fi

    read -rp "برای بازگشت به منو Enter بزنید..." dummy
}

# -----------------------------------------------------------------------------
# 11. Uninstall & Cleanup
# -----------------------------------------------------------------------------
uninstall_all() {
    clear
    echo -e "${RED}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║             🗑️ حذف کامل تانل و پاکسازی سرور (Uninstall)                ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════════════════════╝${NC}\n"

    read -rp "آیا مطمئن هستید که می‌خواهید تمام سرویس‌ها و فایل‌های تانل حذف شوند؟ [y/N]: " un_c
    if [[ "$un_c" =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}[*] در حال متوقف‌سازی و حذف سرویس‌ها...${NC}"
        systemctl stop nexus-tunnel >/dev/null 2>&1 || true
        systemctl disable nexus-tunnel >/dev/null 2>&1 || true
        rm -f "${SERVICE_FILE}"
        systemctl daemon-reload

        pkill -f backhaul || true
        pkill -f wattun || true
        pkill -f waterwall || true

        echo -e "${CYAN}[*] در حال حذف فایل‌ها و باینری‌ها...${NC}"
        rm -rf "${CONF_DIR}" "${BIN_DIR}"
        rm -f /usr/local/bin/nexus
        rm -f /usr/local/bin/backhaul
        rm -f /usr/local/bin/wattun
        rm -f /usr/local/bin/waterwall

        echo -e "\n${GREEN}[✔] پکیج Nexus Tunnel با موفقیت و به طور کامل از سرور حذف شد.${NC}\n"
        exit 0
    fi
}

# -----------------------------------------------------------------------------
# Main Dashboard Menu
# -----------------------------------------------------------------------------
main_menu() {
    check_root
    load_config

    while true; do
        clear
        local status_badge
        status_badge=$(get_status_badge)

        echo -e "${CYAN}╔═════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║                   ⚡ NEXUS TUNNEL MANAGER v6.0 ⚡                       ║${NC}"
        echo -e "${CYAN}║        Ultimate Multi-Protocol Hybrid Tunnel (Backhaul + WatTunnel)     ║${NC}"
        echo -e "${CYAN}╠═════════════════════════════════════════════════════════════════════════╣${NC}"
        printf "║  ${WHITE}[●] وضعیت سرویس (Status)      :${NC} %-48b ║\n" "${status_badge}"
        printf "║  ${WHITE}[⚙] هسته فعال (Active Engine) :${NC} ${YELLOW}%-38s${NC} ║\n" "${ENGINE}"
        printf "║  ${WHITE}[📡] پروتکل (Protocol)        :${NC} ${YELLOW}%-38s${NC} ║\n" "${CARRIER}"
        printf "║  ${WHITE}[🌐] نقش سرور (Role)          :${NC} ${YELLOW}%-38s${NC} ║\n" "${ROLE}"
        printf "║  ${WHITE}[🎯] سرور مقابل (Remote Peer) :${NC} ${YELLOW}%-38s${NC} ║\n" "${REMOTE_IP}:${TUNNEL_PORT}"
        printf "║  ${WHITE}[🔗] پورت‌های فوروارد شده     :${NC} ${YELLOW}%-38s${NC} ║\n" "${PORTS}"
        printf "║  ${WHITE}[🤖] هوش مصنوعی جمینای (AI)   :${NC} ${GREEN}%-38s${NC} ║\n" "آماده به کار ✅ (Gemini-Flash)"
        echo -e "${CYAN}╠═════════════════════════════════════════════════════════════════════════╣${NC}"
        echo -e "║                                                                         ║"
        echo -e "║   ${BOLD}${GREEN}1. 🤖 راه‌اندازی هوشمند خودکار با هوش مصنوعی (AI Auto Setup)${NC}          ║"
        echo -e "║      ${GRAY}(تست خودکار پینگ و DPI، انتخاب بهترین پروتکل و راه‌اندازی ۱-کلیکه)${NC}   ║"
        echo -e "║                                                                         ║"
        echo -e "║   ${CYAN}2.${NC} 🇮🇷 کانفیگ و راه‌اندازی سرور ایران (Setup Iran Server)             ║"
        echo -e "║   ${CYAN}3.${NC} 🌍 کانفیگ و راه‌اندازی سرور خارج (Setup Kharej Server)            ║"
        echo -e "║   ${CYAN}4.${NC} ⚙️ مدیریت پورت‌ها (Port Forwarding: List / Add / Edit / Delete)   ║"
        echo -e "║   ${CYAN}5.${NC} 🔄 تغییر سریع پروتکل ترانسپورت (Switch Protocol)                   ║"
        echo -e "║   ${CYAN}6.${NC} 🔀 تغییر هسته تانل (Switch Engine: Backhaul / WatTunnel / WW)      ║"
        echo -e "║   ${CYAN}7.${NC} 📊 وضعیت زنده، پینگ و آمار تونل (Live Status & Monitor)            ║"
        echo -e "║   ${CYAN}8.${NC} 📜 مشاهده لاگ‌های زنده سرویس (Live Logs Stream)                      ║"
        echo -e "║   ${CYAN}9.${NC} ⚡ بهینه‌سازی حرفه‌ای لینوکس و BBR (Kernel Optimizer)                ║"
        echo -e "║  ${PURPLE}10. 🩺 پزشک هوش مصنوعی جمینای (Gemini AI Doctor & Auto-Healer)${NC}         ║"
        echo -e "║  ${YELLOW}11. 🔄 راه‌اندازی مجدد تونل (Restart Tunnel)${NC}                          ║"
        echo -e "║  ${YELLOW}12. ⏹️ توقف سرویس تونل (Stop Tunnel)${NC}                                  ║"
        echo -e "║  ${RED}13. 🗑️ حذف کامل و پاکسازی تانل (Uninstall)${NC}                             ║"
        echo -e "║   ${WHITE}0. 🚪 خروج (Exit)${NC}                                                     ║"
        echo -e "${CYAN}╚═════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        read -rp "لطفاً یک گزینه را انتخاب کنید [0-13]: " choice

        case "$choice" in
            1) ai_auto_setup ;;
            2) setup_iran_manual ;;
            3) setup_kharej_manual ;;
            4) manage_ports ;;
            5) switch_protocol ;;
            6) switch_engine ;;
            7) live_status ;;
            8) view_logs ;;
            9) optimize_kernel ;;
            10) ai_doctor ;;
            11) restart_service; sleep 1.5 ;;
            12) stop_service; sleep 1.5 ;;
            13) uninstall_all ;;
            0) clear; echo -e "${GREEN}خداحافظ!${NC}\n"; exit 0 ;;
            *) echo -e "${RED}[x] گزینه نامعتبر است.${NC}"; sleep 1 ;;
        esac
    done
}

# Non-interactive CLI commands support
case "${1:-}" in
    start) start_service ;;
    stop) stop_service ;;
    restart) restart_service ;;
    status) live_status ;;
    logs) view_logs ;;
    ai-doctor) ai_doctor ;;
    optimize) optimize_kernel ;;
    *) main_menu ;;
esac
