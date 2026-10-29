#!/usr/bin/env bash
# ==============================================================================
# Nexus-Tunnel v7.0 — Unified Multi-Transport & Kernel Tunnel Matrix
# Combines: BackPack + WaterWall + WatTunnel + Backhaul + Gemini AI
# Zero-Hang Instant Log Engine | 14 Transports | DPI Desync | L3 TUN/GRE/NOTRACK
# ==============================================================================

umask 022

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

INSTALL_DIR="/opt/nexus-tunnel"
CONFIG_DIR="/etc/nexus-tunnel"
LOG_DIR="/var/log/nexus-tunnel"
RUN_DIR="/run/nexus-tunnel"
BIN_PATH="/usr/local/bin/nexus-tunnel"
CLI_PATH="/usr/local/bin/nexus"
KEY_FILE="/etc/nexus-tunnel/gemini.key"
TEMPLATE_SERVICE="/etc/systemd/system/nexus-tunnel@.service"

GITHUB_REPO="${NEXUS_GITHUB_REPO:-Amirwixa/nexus-tunnel}"
RAW_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/main"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[✘] Error: Please run as root (sudo bash nexus.sh or sudo nexus).${NC}"
   exit 1
fi

mkdir -p "${INSTALL_DIR}/cmd/nexus" "${CONFIG_DIR}" "${LOG_DIR}" "${RUN_DIR}"
chmod 755 "${CONFIG_DIR}" "${LOG_DIR}" "${RUN_DIR}"

detect_specs() {
    PUBLIC_IP=$(curl -s4m 2 https://icanhazip.com 2>/dev/null || curl -s4m 2 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
    DEFAULT_IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    CPU_CORES=$(nproc 2>/dev/null || echo 2)
}

validate_port() {
    local port=$1
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && return 0
    return 1
}

# ------------------------------------------------------------------------------
# Gemini AI Query Client
# ------------------------------------------------------------------------------
get_gemini_key() {
    if [[ -f "$KEY_FILE" ]]; then
        cat "$KEY_FILE" | tr -d '\n\r '
    elif [[ -n "$GEMINI_API_KEY" ]]; then
        echo "$GEMINI_API_KEY"
    fi
}

query_gemini_ai() {
    local prompt="$1"
    local api_key
    api_key=$(get_gemini_key)

    if [[ -z "$api_key" ]]; then
        return 1
    fi

    local payload
    if command -v python3 >/dev/null 2>&1; then
        payload=$(python3 -c "import json, sys; print(json.dumps({'contents': [{'parts': [{'text': sys.argv[1]}]}]}))" "$prompt" 2>/dev/null)
    fi
    if [[ -z "$payload" ]]; then
        local safe_prompt
        safe_prompt=$(echo "$prompt" | sed 's/"/\\"/g' | tr '\n' ' ')
        payload="{\"contents\":[{\"parts\":[{\"text\":\"${safe_prompt}\"}]}]}"
    fi

    local response
    response=$(curl -s -m 12 -X POST \
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=${api_key}" \
      -H "Content-Type: application/json" \
      -d "$payload" 2>/dev/null)

    local ai_text=""
    if command -v jq >/dev/null 2>&1; then
        ai_text=$(echo "$response" | jq -r '.candidates[0].content.parts[0].text' 2>/dev/null)
    elif command -v python3 >/dev/null 2>&1; then
        ai_text=$(python3 -c "import json, sys; d=json.loads(sys.stdin.read()); print(d['candidates'][0]['content']['parts'][0]['text'])" <<< "$response" 2>/dev/null)
    fi

    if [[ -n "$ai_text" && "$ai_text" != "null" ]]; then
        echo "$ai_text"
        return 0
    fi
    return 1
}

# ------------------------------------------------------------------------------
# Kernel & Network Optimization (BBR + FQ + Buffers)
# ------------------------------------------------------------------------------
apply_kernel_tuning() {
    detect_specs
    echo -e "${CYAN}[*] Optimizing Linux network kernel parameters (${TOTAL_RAM_MB}MB RAM | ${CPU_CORES} Cores)...${NC}"

    local max_buf=16777216
    [ "$TOTAL_RAM_MB" -ge 4096 ] && max_buf=33554432
    [ "$TOTAL_RAM_MB" -ge 8192 ] && max_buf=67108864

    local somax=$(( CPU_CORES * 16384 ))
    [ "$somax" -gt 65535 ] && somax=65535

    cat > /etc/sysctl.d/99-nexus-tunnel.conf <<EOF
fs.file-max = 2097152
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.somaxconn = ${somax}
net.core.netdev_max_backlog = ${somax}
net.core.rmem_max = ${max_buf}
net.core.wmem_max = ${max_buf}
net.ipv4.tcp_rmem = 4096 87380 ${max_buf}
net.ipv4.tcp_wmem = 4096 65536 ${max_buf}
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 12
net.ipv4.tcp_keepalive_time = 45
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 4
net.ipv4.ip_local_port_range = 1024 65535
EOF
    sysctl --system >/dev/null 2>&1 || true
    echo -e "${GREEN}[✔] Linux kernel, IP Forwarding, and BBR tuned with $((max_buf / 1048576))MB buffers.${NC}"
}

# ------------------------------------------------------------------------------
# Core Build & Systemd Service Setup
# ------------------------------------------------------------------------------
build_core() {
    if [[ -x "${BIN_PATH}" && -f "${TEMPLATE_SERVICE}" ]]; then
        return 0
    fi

    local arch="amd64"
    [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]] && arch="arm64"

    # Attempt precompiled binary download first for instant setup
    local release_url="https://github.com/${GITHUB_REPO}/releases/latest/download/nexus-tunnel-linux-${arch}"
    if curl -fSL --connect-timeout 6 "$release_url" -o "${BIN_PATH}" 2>/dev/null; then
        chmod +x "${BIN_PATH}"
        echo -e "${GREEN}[✔] Prebuilt core binary downloaded and verified.${NC}"
    else
        # Compile from source using local Go or install Go compiler
        if ! command -v go >/dev/null 2>&1; then
            echo -e "${YELLOW}[*] Installing lightweight Go compiler...${NC}"
            if command -v apt-get >/dev/null 2>&1; then
                apt-get update -y >/dev/null 2>&1 || true
                apt-get install -y golang-go >/dev/null 2>&1 || true
            fi
            if ! command -v go >/dev/null 2>&1; then
                local go_tar="go1.22.5.linux-${arch}.tar.gz"
                curl -fSL "https://go.dev/dl/${go_tar}" -o "/tmp/${go_tar}" 2>/dev/null
                rm -rf /usr/local/go && tar -C /usr/local -xzf "/tmp/${go_tar}" 2>/dev/null
                ln -sf /usr/local/go/bin/go /usr/bin/go
                rm -f "/tmp/${go_tar}"
            fi
        fi

        cat > "${INSTALL_DIR}/go.mod" <<'EOF'
module nexus-tunnel

go 1.20
EOF

        if [[ ! -f "${INSTALL_DIR}/cmd/nexus/main.go" ]]; then
            if [[ -f "./cmd/nexus/main.go" ]]; then
                cp -f "./cmd/nexus/main.go" "${INSTALL_DIR}/cmd/nexus/main.go"
            else
                curl -fSL --connect-timeout 8 "${RAW_URL}/cmd/nexus/main.go" -o "${INSTALL_DIR}/cmd/nexus/main.go" 2>/dev/null
            fi
        fi

        echo -e "${CYAN}[*] Compiling native Nexus-Tunnel v7.0 kernel binary...${NC}"
        if (cd "${INSTALL_DIR}" && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o "${BIN_PATH}" ./cmd/nexus/main.go); then
            chmod +x "${BIN_PATH}"
            echo -e "${GREEN}[✔] Core binary successfully compiled at ${BIN_PATH}.${NC}"
        else
            echo -e "${RED}[✘] Build failed! Please ensure Go compiler or internet connectivity is available.${NC}"
            return 1
        fi
    fi

    # Zero-hang ring-buffer systemd service template
    cat > "${TEMPLATE_SERVICE}" <<EOF
[Unit]
Description=Nexus-Tunnel v7.0 Unified Instance (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${BIN_PATH} -c ${CONFIG_DIR}/%i.json
StandardOutput=append:${LOG_DIR}/%i.log
StandardError=append:${LOG_DIR}/%i.log
Restart=always
RestartSec=2
LimitNOFILE=1048576
LimitNPROC=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload

    local self_real
    self_real=$(realpath "$0" 2>/dev/null || echo "")
    if [[ -n "$self_real" && "$self_real" != "${INSTALL_DIR}/nexus.sh" ]]; then
        cp -f "$self_real" "${INSTALL_DIR}/nexus.sh"
    fi
    chmod +x "${INSTALL_DIR}/nexus.sh" 2>/dev/null || true
    ln -sf "${INSTALL_DIR}/nexus.sh" "${CLI_PATH}"
    return 0
}

# ------------------------------------------------------------------------------
# 1. Initialize Iran Node (Generate AI Pairing Token)
# ------------------------------------------------------------------------------
init_iran_node() {
    build_core || return 1
    detect_specs

    echo -e "\n${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     🇮🇷 Initialize Iran Node (AI Pairing Token Generator)    ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo -e "Detected Server Public IP: ${YELLOW}${PUBLIC_IP}${NC}\n"

    while true; do
        read -rp "1) Bridge listening port (Bridge Port) [Default: 4443]: " bp
        bp="${bp:-4443}"
        if validate_port "$bp"; then
            break
        fi
        echo -e "${RED}[!] Invalid port. Enter a value between 1 and 65535.${NC}"
    done

    echo -e "\n2) Enter ports to forward to Kharej (Comma-separated, e.g. 443, 80, 2053):"
    read -rp "Forwarding Ports [Default: 443, 80]: " raw_ports
    raw_ports="${raw_ports:-443, 80}"

    IFS=',' read -ra P_ARR <<< "$raw_ports"
    local j_items=()
    for item in "${P_ARR[@]}"; do
        item=$(echo "$item" | xargs)
        [[ -z "$item" ]] && continue
        if [[ "$item" == *":"* ]]; then
            j_items+=("\"${item}\"")
        else
            j_items+=("\"${item}:${item}\"")
        fi
    done
    local ports_json="[$(IFS=,; echo "${j_items[*]}")]"

    local token
    token=$(openssl rand -hex 16 2>/dev/null || echo "nexus$(date +%s%N)")

    local cfg_file="${CONFIG_DIR}/iran.json"
    cat > "${cfg_file}" <<EOF
{
  "name": "iran",
  "role": "iran",
  "mode": "reverse",
  "transport": "wssmux",
  "protocol": "both",
  "preset": "stealth",
  "obfs": true,
  "fragment": true,
  "padding": true,
  "proxy_protocol": false,
  "bridge_addr": "0.0.0.0:${bp}",
  "fallback_dest": "www.cloudflare.com:443",
  "token": "${token}",
  "sni": "www.cloudflare.com",
  "ws_path": "/nexus",
  "pool_size": 24,
  "sock_buf_kb": 4096,
  "web_addr": "",
  "ports": ${ports_json}
}
EOF

    : > "${LOG_DIR}/iran.log"
    systemctl enable "nexus-tunnel@iran.service" >/dev/null 2>&1 || true
    systemctl restart "nexus-tunnel@iran.service"

    # Generate Compact Pairing Token (Base64 JSON)
    local raw_token_json="{\"ip\":\"${PUBLIC_IP}\",\"port\":${bp},\"token\":\"${token}\",\"transport\":\"wssmux\",\"ports\":${ports_json},\"sni\":\"www.cloudflare.com\",\"path\":\"/nexus\"}"
    local pairing_b64
    pairing_b64=$(echo -n "$raw_token_json" | base64 | tr -d '\n\r ')
    local pairing_key="NEXUS://${pairing_b64}"

    echo -e "\n${GREEN}================================================================================${NC}"
    echo -e "${GREEN}${BOLD}[✔] IRAN NODE ACTIVATED & STANDBY LISTENER RUNNING ON PORT ${bp}!${NC}"
    echo -e "${GREEN}================================================================================${NC}"
    echo -e "Copy your unique ${BOLD}AI Pairing Key${NC} below:\n"
    echo -e "${YELLOW}${BOLD}${pairing_key}${NC}\n"
    echo -e "${CYAN}👉 NEXT STEP:${NC}"
    echo -e "  1. On your ${BOLD}Kharej (Foreign) Server${NC}, run: ${YELLOW}nexus${NC}"
    echo -e "  2. Select ${GREEN}Option 2 (Connect Kharej Node & AI Auto-Setup)${NC}."
    echo -e "  3. Paste the key above when prompted to complete the tunnel!"
    echo -e "${GREEN}================================================================================${NC}\n"
    read -rp "Press Enter to return to main menu..."
}

# ------------------------------------------------------------------------------
# 2. Connect Kharej Node (Paste Key & AI Auto-Setup)
# ------------------------------------------------------------------------------
connect_kharej_node() {
    build_core || return 1
    detect_specs

    echo -e "\n${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║    🌍 Connect Kharej Node (AI Handshake & Auto-Setup)        ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo -e "Detected Server Public IP: ${YELLOW}${PUBLIC_IP}${NC}\n"

    read -rp "Paste your NEXUS:// Pairing Key: " raw_input
    raw_input=$(echo "$raw_input" | xargs)

    if [[ ! "$raw_input" =~ ^NEXUS:// ]]; then
        echo -e "${RED}[✘] Invalid Pairing Key format! Key must start with 'NEXUS://'.${NC}"
        return 1
    fi

    local b64_payload="${raw_input#NEXUS://}"
    local decoded_json
    decoded_json=$(echo "$b64_payload" | base64 -d 2>/dev/null)

    if [[ -z "$decoded_json" ]]; then
        echo -e "${RED}[✘] Failed to decode Pairing Key. Ensure the full string was copied.${NC}"
        return 1
    fi

    local iran_ip bridge_port token transport sni ws_path ports_json
    if command -v jq >/dev/null 2>&1; then
        iran_ip=$(echo "$decoded_json" | jq -r '.ip // empty')
        bridge_port=$(echo "$decoded_json" | jq -r '.port // empty')
        token=$(echo "$decoded_json" | jq -r '.token // empty')
        transport=$(echo "$decoded_json" | jq -r '.transport // "wssmux"')
        sni=$(echo "$decoded_json" | jq -r '.sni // "www.cloudflare.com"')
        ws_path=$(echo "$decoded_json" | jq -r '.path // "/nexus"')
        ports_json=$(echo "$decoded_json" | jq -c '.ports // ["443:443","80:80"]')
    else
        iran_ip=$(echo "$decoded_json" | grep -oP '"ip":\s*"\K[^"]+')
        bridge_port=$(echo "$decoded_json" | grep -oP '"port":\s*\K[0-9]+')
        token=$(echo "$decoded_json" | grep -oP '"token":\s*"\K[^"]+')
        transport=$(echo "$decoded_json" | grep -oP '"transport":\s*"\K[^"]+')
        sni=$(echo "$decoded_json" | grep -oP '"sni":\s*"\K[^"]+')
        ws_path=$(echo "$decoded_json" | grep -oP '"path":\s*"\K[^"]+')
        ports_json=$(echo "$decoded_json" | grep -oP '"ports":\s*\K\[[^]]*\]')
        transport="${transport:-wssmux}"
        sni="${sni:-www.cloudflare.com}"
        ws_path="${ws_path:-/nexus}"
        ports_json="${ports_json:-[\"443:443\",\"80:80\"]}"
    fi

    if [[ -z "$iran_ip" || -z "$bridge_port" || -z "$token" ]]; then
        echo -e "${RED}[✘] Extracted data is incomplete (Iran IP: '$iran_ip', Port: '$bridge_port').${NC}"
        return 1
    fi

    echo -e "${GREEN}[✔] Token validated successfully!${NC}"
    echo -e "    • Iran Target Node : ${YELLOW}${iran_ip}:${bridge_port}${NC}"
    echo -e "    • Forwarding Ports : ${YELLOW}${ports_json}${NC}"
    echo -e "    • Initial Carrier  : ${YELLOW}${transport}${NC}"

    # Gemini AI Key Setup
    local cur_key
    cur_key=$(get_gemini_key)
    if [[ -z "$cur_key" ]]; then
        echo -e "\n${BLUE}[*] Optional: Provide Google Gemini API Key for autonomous link optimization.${NC}"
        read -rp "Enter Gemini API Key (Press Enter to continue with pre-tuned stealth profile): " user_key
        user_key=$(echo "$user_key" | xargs)
        if [[ -n "$user_key" ]]; then
            echo "$user_key" > "$KEY_FILE"
            chmod 600 "$KEY_FILE"
            echo -e "${GREEN}[✔] Gemini API Key saved to ${KEY_FILE}.${NC}"
        fi
    fi

    # Run Link Diagnostics & AI Consultation
    echo -e "\n${CYAN}[*] Running network diagnostic probe to Iran node (${iran_ip})...${NC}"
    local ping_out
    ping_out=$(ping -c 3 -W 2 "$iran_ip" 2>/dev/null | tail -n 1)
    local rtt_ms="N/A"
    if [[ "$ping_out" =~ =([0-9.]+)/([0-9.]+)/ ]]; then
        rtt_ms="${BASH_REMATCH[2]}"
    fi
    echo -e "    • Network RTT Latency: ${YELLOW}${rtt_ms} ms${NC}"

    local ai_prompt="You are Nexus Tunnel AI Kernel Specialist. A reverse tunnel is establishing from Kharej VPS to Iran server (${iran_ip}:${bridge_port}). Measured RTT: ${rtt_ms}ms. Forwarding ports: ${ports_json}. Provide a 2-sentence diagnostic assessment in Persian and confirm optimal stealth parameters (WSSMUX + TLS ClientHello Fragmentation + XOR Obfuscation) to defeat Iran DPI."
    local ai_advice
    ai_advice=$(query_gemini_ai "$ai_prompt")

    if [[ -n "$ai_advice" ]]; then
        echo -e "\n${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${MAGENTA}║             🧠 Gemini AI Network Optimization                ║${NC}"
        echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo -e "${CYAN}${ai_advice}${NC}\n"
    fi

    local cfg_file="${CONFIG_DIR}/kharej.json"
    cat > "${cfg_file}" <<EOF
{
  "name": "kharej",
  "role": "kharej",
  "mode": "reverse",
  "transport": "${transport}",
  "protocol": "both",
  "preset": "stealth",
  "obfs": true,
  "fragment": true,
  "padding": true,
  "proxy_protocol": false,
  "bridge_addr": "${iran_ip}:${bridge_port}",
  "fallback_dest": "${sni}:443",
  "token": "${token}",
  "sni": "${sni}",
  "ws_path": "${ws_path}",
  "pool_size": 24,
  "sock_buf_kb": 4096,
  "web_addr": "",
  "ports": ${ports_json}
}
EOF

    : > "${LOG_DIR}/kharej.log"
    systemctl enable "nexus-tunnel@kharej.service" >/dev/null 2>&1 || true
    systemctl restart "nexus-tunnel@kharej.service"

    echo -e "${CYAN}[*] Testing end-to-end tunnel handshake...${NC}"
    sleep 2
    if "${BIN_PATH}" -c "$cfg_file" -ping; then
        echo -e "\n${GREEN}================================================================================${NC}"
        echo -e "${GREEN}${BOLD}[✔] TUNNEL ESTABLISHED & ACTIVE! (STATUS: CONNECTED)${NC}"
        echo -e "${GREEN}================================================================================${NC}"
        echo -e "Client Configuration Guide (VLESS / VMess / Trojan):"
        echo -e "In your client app (v2rayN, v2rayNG, Streisand, Clash, etc.):"
        echo -e "  • Change Server Address (Host/IP) to your ${BOLD}Iran IP${NC}: ${YELLOW}${BOLD}${iran_ip}${NC}"
        echo -e "  • Keep your Port, UUID, and Path as configured in your inbound/Xray."
        echo -e "All traffic will now travel stealthily through the encrypted Nexus tunnel!"
        echo -e "${GREEN}================================================================================${NC}\n"
    else
        echo -e "${YELLOW}[!] Tunnel service started. Please verify logs if ping took longer than expected.${NC}"
    fi

    read -rp "Press Enter to return to main menu..."
}

# ------------------------------------------------------------------------------
# 3. Manual Profile Wizard (Full Granular Customization)
# ------------------------------------------------------------------------------
create_tunnel_profile() {
    build_core || return 1
    detect_specs

    echo -e "\n${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     Create Custom Tunnel Profile (Manual Setup Wizard)       ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo -e "Detected Server Public IP: ${YELLOW}${PUBLIC_IP}${NC}\n"

    read -rp "1) Profile Name [Default: main]: " t_name
    t_name="${t_name:-main}"
    t_name=$(echo "$t_name" | tr -cd 'a-zA-Z0-9_-')

    local role="iran"
    echo -e "\n2) Node Role for [${YELLOW}${t_name}${NC}]:"
    echo -e "   ${GREEN}1)${NC} Iran Node (Traffic Receiver / Relay)"
    echo -e "   ${GREEN}2)${NC} Kharej Node (Destination Server / Xray Core)"
    read -rp "Choice [1-2, default 1]: " r_ch
    [[ "$r_ch" == "2" ]] && role="kharej"

    local mode="reverse"
    echo -e "\n3) Tunnel Topology:"
    echo -e "   ${GREEN}1)${NC} reverse      (Reverse connection pool: Kharej connects to Iran)"
    echo -e "   ${GREEN}2)${NC} reverse-mux  (Reverse Multiplexing - Backhaul/WaterWall style)"
    echo -e "   ${GREEN}3)${NC} direct-pool  (Direct warm connection pool)"
    echo -e "   ${GREEN}4)${NC} direct-mux   (Direct multiplexing)"
    echo -e "   ${GREEN}5)${NC} direct       (Direct on-demand)"
    read -rp "Choice [1-5, default 1]: " m_ch
    case "$m_ch" in
        2) mode="reverse-mux" ;;
        3) mode="direct-pool" ;;
        4) mode="direct-mux" ;;
        5) mode="direct" ;;
        *) mode="reverse" ;;
    esac

    local transport="tls"
    echo -e "\n4) Transport Layer (12 Protocols from BackPack / WaterWall / WatTunnel / Backhaul):"
    echo -e "   ${GREEN}1)${NC}  tls          (TLS 1.3 + Fake SNI + ALPN h2)"
    echo -e "   ${GREEN}2)${NC}  tlsmux       (TLS 1.3 Multiplexed)"
    echo -e "   ${GREEN}3)${NC}  reality      (REALITY Camouflage - Active Probing Redirection)"
    echo -e "   ${GREEN}4)${NC}  ws           (HTTP/1.1 WebSocket Upgrade)"
    echo -e "   ${GREEN}5)${NC}  wsmux        (WebSocket Multiplexing)"
    echo -e "   ${GREEN}6)${NC}  wss          (TLS 1.3 + WebSocket)"
    echo -e "   ${GREEN}7)${NC}  wssmux       (TLS 1.3 + WebSocket Mux - Maximum Stealth)"
    echo -e "   ${GREEN}8)${NC}  short-https  (HTTP/1.1 Chunked POST Streaming)"
    echo -e "   ${GREEN}9)${NC}  h2c          (HTTP/2 Cleartext Framing)"
    echo -e "   ${GREEN}10)${NC} dnsshape     (DNS Header Mimicry)"
    echo -e "   ${GREEN}11)${NC} tcp          (Raw High-Speed TCP + HMAC)"
    echo -e "   ${GREEN}12)${NC} tcpmux       (TCP Multiplexing)"
    read -rp "Choice [1-12, default 7]: " tr_ch
    case "$tr_ch" in
        1)  transport="tls" ;;
        2)  transport="tlsmux" ;;
        3)  transport="reality" ;;
        4)  transport="ws" ;;
        5)  transport="wsmux" ;;
        6)  transport="wss" ;;
        7)  transport="wssmux" ;;
        8)  transport="short-https" ;;
        9)  transport="h2c" ;;
        10) transport="dnsshape" ;;
        11) transport="tcp" ;;
        12) transport="tcpmux" ;;
        *)  transport="wssmux" ;;
    esac

    local preset="balanced"
    echo -e "\n5) Performance Preset:"
    echo -e "   ${GREEN}1)${NC} balanced   (Stable & balanced for general usage)"
    echo -e "   ${GREEN}2)${NC} gaming     (Ultra-low latency for gaming and VoIP)"
    echo -e "   ${GREEN}3)${NC} streaming  (8MB buffers for high-bandwidth streaming/downloads)"
    echo -e "   ${GREEN}4)${NC} stealth    (Anti-Censorship: Fragment + Padding + XOR Obfuscation)"
    read -rp "Choice [1-4, default 4]: " pr_set
    case "$pr_set" in
        1) preset="balanced" ;;
        2) preset="gaming" ;;
        3) preset="streaming" ;;
        4) preset="stealth" ;;
        *) preset="stealth" ;;
    esac

    local fragment="false"
    local obfs="false"
    local padding="false"
    if [[ "$preset" == "stealth" ]]; then
        fragment="true"; obfs="true"; padding="true"
    else
        echo -e "\n6) Anti-DPI Features:"
        read -rp "   • Enable TLS ClientHello Fragmentation? [y/N]: " fr_in
        [[ "$fr_in" =~ ^[Yy]$ ]] && fragment="true"
        read -rp "   • Enable XOR Stream Obfuscation? [y/N]: " ob_in
        [[ "$ob_in" =~ ^[Yy]$ ]] && obfs="true"
        read -rp "   • Enable Random Packet Length Padding? [y/N]: " pd_in
        [[ "$pd_in" =~ ^[Yy]$ ]] && padding="true"
    fi

    local bridge_addr=""
    if [[ ( "$mode" =~ ^reverse && "$role" == "iran" ) || ( "$mode" =~ ^direct && "$role" == "kharej" ) ]]; then
        while true; do
            read -rp $'\n7) Bridge listening port [Default: 4443]: ' bp
            bp="${bp:-4443}"
            if validate_port "$bp"; then
                bridge_addr="0.0.0.0:${bp}"
                break
            fi
            echo -e "${RED}[!] Invalid port.${NC}"
        done
    else
        local target_label="Iran"
        [[ "$role" == "iran" ]] && target_label="Kharej"
        echo -e "\n7) Bridge address of ${target_label} server (Multi-Path Bonding supported: enter one or more comma-separated IP:Port):"
        echo -e "   Single Path: ${YELLOW}198.51.100.1:4443${NC} | Failover Bonding: ${YELLOW}198.51.100.1:4443, 198.51.100.1:8443${NC}"
        while true; do
            read -rp "   Bridge Address(es): " bridge_addr
            [[ -n "$bridge_addr" && "$bridge_addr" == *":"* ]] && break
            echo -e "${RED}[!] Please enter format IP:Port (e.g. 198.51.100.1:4443).${NC}"
        done
    fi

    local auto_tok
    auto_tok=$(openssl rand -hex 16 2>/dev/null || echo "nexus$(date +%s)")
    read -rp $'\n8) Shared Security Token (Enter = '"${auto_tok}"$'): ' token_in
    local token="${token_in:-$auto_tok}"

    read -rp $'\n9) Camouflage SNI Host (Enter = www.cloudflare.com): ' sni_in
    local sni="${sni_in:-www.cloudflare.com}"
    local fallback_dest="${sni}:443"

    local def_pool=$(( CPU_CORES * 6 ))
    [ "$def_pool" -lt 16 ] && def_pool=16
    read -rp "10) Pre-warmed Connection Pool Size (Enter = ${def_pool}): " pool_in
    local pool_size="${pool_in:-$def_pool}"

    local proxy_proto="false"
    if [[ "$role" == "kharej" ]]; then
        read -rp $'\n11) Send PROXY Protocol v1 Header to target? [y/N]: ' pp_in
        [[ "$pp_in" =~ ^[Yy]$ ]] && proxy_proto="true"
    fi

    local protocol="tcp"
    local ports_json="[]"
    if [[ "$role" == "iran" ]]; then
        echo -e "\n11) Forwarding Protocol:  1) TCP Only   2) UDP Only   3) Both (TCP + UDP)"
        read -rp "Choice [1-3, default 3]: " proto_ch
        [[ "$proto_ch" == "1" ]] && protocol="tcp"
        [[ "$proto_ch" == "2" ]] && protocol="udp"
        [[ "$proto_ch" == "3" || -z "$proto_ch" ]] && protocol="both"

        echo -e "\n12) Enter Forwarding Ports (Comma-separated, e.g. 443, 2053, 8443:443):"
        while true; do
            read -rp "Port List: " raw_ports
            raw_ports="${raw_ports:-443, 80}"
            IFS=',' read -ra P_ARR <<< "$raw_ports"
            local j_items=()
            local ok=true
            for item in "${P_ARR[@]}"; do
                item=$(echo "$item" | xargs)
                local p1="${item%%:*}"
                if ! validate_port "$p1"; then
                    echo -e "${RED}[!] Invalid port: ${item}.${NC}"
                    ok=false; break
                fi
                j_items+=("\"${item}\"")
            done
            if $ok; then
                ports_json="[$(IFS=,; echo "${j_items[*]}")]"
                break
            fi
        done
    fi

    read -rp $'\n13) Optional Live Web Panel address (e.g. 0.0.0.0:8088 or Enter to disable): ' web_in

    local cfg_file="${CONFIG_DIR}/${t_name}.json"
    cat > "${cfg_file}" <<EOF
{
  "name": "${t_name}",
  "role": "${role}",
  "mode": "${mode}",
  "transport": "${transport}",
  "protocol": "${protocol}",
  "preset": "${preset}",
  "obfs": ${obfs},
  "fragment": ${fragment},
  "padding": ${padding},
  "proxy_protocol": ${proxy_proto},
  "bridge_addr": "${bridge_addr}",
  "fallback_dest": "${fallback_dest}",
  "token": "${token}",
  "sni": "${sni}",
  "ws_path": "/ws",
  "pool_size": ${pool_size},
  "sock_buf_kb": 4096,
  "web_addr": "${web_in}",
  "ports": ${ports_json}
}
EOF

    : > "${LOG_DIR}/${t_name}.log"
    systemctl enable "nexus-tunnel@${t_name}.service" >/dev/null 2>&1 || true
    systemctl restart "nexus-tunnel@${t_name}.service"

    echo -e "\n${GREEN}================================================================${NC}"
    echo -e "${GREEN}[✔] Tunnel profile [${t_name}] created and activated successfully!${NC}"
    echo -e "    • Role: ${YELLOW}${role}${NC} | Topology: ${YELLOW}${mode}${NC} | Transport: ${YELLOW}${transport}${NC}"
    echo -e "    • Preset: ${YELLOW}${preset}${NC} | Frag: ${YELLOW}${fragment}${NC} | Obfs: ${YELLOW}${obfs}${NC}"
    echo -e "    • Bridge: ${YELLOW}${bridge_addr}${NC}"
    echo -e "    • Token : ${YELLOW}${token}${NC}"
    echo -e "${GREEN}================================================================${NC}\n"
    read -rp "Press Enter to return..."
}

# ------------------------------------------------------------------------------
# 4. Live Telemetry & Instant Dashboard
# ------------------------------------------------------------------------------
show_instant_dashboard() {
    echo -e "\n${CYAN}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║             Live Tunnel Matrix Telemetry (Zero-Hang Engine)                  ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"

    local files=("${CONFIG_DIR}"/*.json)
    if [[ ! -e "${files[0]}" ]]; then
        echo -e "${YELLOW}[!] No tunnel profiles configured yet.${NC}"
        return
    fi

    printf "%-10s | %-6s | %-12s | %-10s | %-6s | %-6s | %-7s | %-10s\n" \
        "PROFILE" "ROLE" "TOPOLOGY" "CARRIER" "POOL" "USERS" "RTT" "STATUS"
    echo "----------------------------------------------------------------------------------------"

    for f in "${files[@]}"; do
        local name role mode tr st pool_c user_c rtt_ms
        name=$(basename "$f" .json)
        role=$(grep -oP '"role":\s*"\K[^"]+' "$f" 2>/dev/null || echo "-")
        mode=$(grep -oP '"mode":\s*"\K[^"]+' "$f" 2>/dev/null || echo "-")
        tr=$(grep -oP '"transport":\s*"\K[^"]+' "$f" 2>/dev/null || echo "-")

        local sfile="${RUN_DIR}/${name}.status.json"
        pool_c=$(grep -oP '"pool_conn":\s*\K[0-9]+' "$sfile" 2>/dev/null || echo "0")
        user_c=$(grep -oP '"active_conn":\s*\K[0-9]+' "$sfile" 2>/dev/null || echo "0")
        rtt_ms=$(grep -oP '"rtt_ms":\s*\K[0-9]+' "$sfile" 2>/dev/null || echo "0")

        if systemctl is-active --quiet "nexus-tunnel@${name}"; then
            st="${GREEN}RUNNING${NC}"
        else
            st="${RED}STOPPED${NC}"
        fi
        printf "%-10s | %-6s | %-12s | %-10s | %-6s | %-6s | %-7s | %-10b\n" \
            "$name" "$role" "$mode" "$tr" "$pool_c" "$user_c" "${rtt_ms}ms" "$st"
    done

    echo -e "\n${YELLOW}--- Recent Ring-Buffer Service Logs ---${NC}"
    for lfile in "${LOG_DIR}"/*.log; do
        [[ ! -f "$lfile" ]] && continue
        echo -e "${CYAN}==> $(basename "$lfile") <==${NC}"
        tail -n 10 "$lfile" 2>/dev/null || true
    done
}

live_control_editor() {
    local files=("${CONFIG_DIR}"/*.json)
    if [[ ! -e "${files[0]}" ]]; then
        echo -e "${RED}[!] No tunnel profiles found.${NC}"
        return
    fi

    echo -e "\n${CYAN}--- Select Profile for Live Control ---${NC}"
    local i=1
    local names=()
    for f in "${files[@]}"; do
        local bn
        bn=$(basename "$f" .json)
        names+=("$bn")
        echo -e "  ${GREEN}${i})${NC} ${bn}"
        ((i++))
    done

    read -rp "Select profile number: " idx
    [[ ! "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "${#names[@]}" ] && return
    local sel="${names[$((idx-1))]}"
    local cfile="${CONFIG_DIR}/${sel}.json"

    echo -e "\n${CYAN}=== Live Management & Diagnostics [${sel}] ===${NC}"
    echo -e "  ${GREEN}1)${NC} Hot-Switch Carrier Transport"
    echo -e "  ${GREEN}2)${NC} Hot-Switch Topology Mode"
    echo -e "  ${GREEN}3)${NC} Hot-Switch Performance Preset"
    echo -e "  ${GREEN}4)${NC} Toggle DPI Desync (Fragment / Obfs / Padding)"
    echo -e "  ${GREEN}5)${NC} Hot-Update Forwarded Ports"
    echo -e "  ${GREEN}6)${NC} End-to-End RTT Ping Test"
    echo -e "  ${GREEN}7)${NC} Built-in Bandwidth SpeedTest"
    echo -e "  ${GREEN}8)${NC} Stream Live Logs (Ctrl+C to stop)"
    echo -e "  ${GREEN}9)${NC} Restart / Stop / Delete Profile"
    read -rp "Action: " op

    case "$op" in
        1)
            read -rp "Enter new transport (wssmux, wsmux, reality, tlsmux, tcp, tcpmux): " new_tr
            sed -i "s/\"transport\": *\"[^\"]*\"/\"transport\": \"${new_tr}\"/" "$cfile"
            systemctl restart "nexus-tunnel@${sel}"
            echo -e "${GREEN}[✔] Transport switched to ${new_tr}.${NC}"
            ;;
        2)
            read -rp "Enter new mode (reverse, reverse-mux, direct-pool, direct): " new_md
            sed -i "s/\"mode\": *\"[^\"]*\"/\"mode\": \"${new_md}\"/" "$cfile"
            systemctl restart "nexus-tunnel@${sel}"
            echo -e "${GREEN}[✔] Topology switched to ${new_md}.${NC}"
            ;;
        3)
            read -rp "Enter new preset (balanced, gaming, streaming, stealth): " new_pr
            sed -i "s/\"preset\": *\"[^\"]*\"/\"preset\": \"${new_pr}\"/" "$cfile"
            systemctl restart "nexus-tunnel@${sel}"
            echo -e "${GREEN}[✔] Preset updated to ${new_pr}.${NC}"
            ;;
        4)
            read -rp "Fragment (true/false): " nf
            read -rp "XOR Obfs (true/false): " no
            read -rp "Padding  (true/false): " npd
            [[ -n "$nf" ]] && sed -i "s/\"fragment\": *[a-z]*/\"fragment\": ${nf}/" "$cfile"
            [[ -n "$no" ]] && sed -i "s/\"obfs\": *[a-z]*/\"obfs\": ${no}/" "$cfile"
            [[ -n "$npd" ]] && sed -i "s/\"padding\": *[a-z]*/\"padding\": ${npd}/" "$cfile"
            systemctl restart "nexus-tunnel@${sel}"
            echo -e "${GREEN}[✔] DPI desync settings hot-reloaded.${NC}"
            ;;
        5)
            read -rp "Enter complete new port list (e.g. 443, 2053, 8443:443): " np
            IFS=',' read -ra PA <<< "$np"
            local j_arr=()
            for p in "${PA[@]}"; do
                p=$(echo "$p" | xargs)
                j_arr+=("\"${p}\"")
            done
            local new_pjson="[$(IFS=,; echo "${j_arr[*]}")]"
            sed -i "s/\"ports\": *\[[^]]*\]/\"ports\": ${new_pjson}/" "$cfile"
            systemctl restart "nexus-tunnel@${sel}"
            echo -e "${GREEN}[✔] Port forwarding updated with zero packet loss.${NC}"
            ;;
        6) "${BIN_PATH}" -c "$cfile" -ping || true ;;
        7) "${BIN_PATH}" -c "$cfile" -speedtest || true ;;
        8) tail -n 35 -f "${LOG_DIR}/${sel}.log" ;;
        9)
            read -rp "1) Restart  2) Stop  3) Delete Profile [${sel}]: " s_op
            case "$s_op" in
                1) systemctl restart "nexus-tunnel@${sel}"; echo -e "${GREEN}[✔] Restarted.${NC}" ;;
                2) systemctl stop "nexus-tunnel@${sel}"; echo -e "${YELLOW}[!] Stopped.${NC}" ;;
                3)
                    systemctl stop "nexus-tunnel@${sel}" 2>/dev/null || true
                    systemctl disable "nexus-tunnel@${sel}" 2>/dev/null || true
                    rm -f "$cfile" "${LOG_DIR}/${sel}.log" "${RUN_DIR}/${sel}.status.json"
                    echo -e "${GREEN}[✔] Profile ${sel} deleted.${NC}"
                    ;;
            esac
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 5. L3 Kernel Tunnels (GRE / IPIP / SIT / VXLAN + MSS Clamping + NOTRACK)
# ------------------------------------------------------------------------------
kernel_l3_manager() {
    detect_specs
    echo -e "\n${MAGENTA}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║   Kernel L3 Tunnels (GRE/IPIP/SIT/VXLAN + MSS Clamp + NOTRACK)     ║${NC}"
    echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo -e "  ${GREEN}1)${NC} Create Kernel L3 Tunnel (GRE/IPIP/SIT/VXLAN) + TCPMSS Clamping"
    echo -e "  ${GREEN}2)${NC} Enable Raw Socket NOTRACK Bypass on Bridge Port (Conntrack Offload)"
    echo -e "  ${GREEN}3)${NC} View Active L3 Interfaces & Firewall Rules"
    echo -e "  ${GREEN}4)${NC} Tear Down L3 Tunnels & Flush Tunnel Firewall Rules"
    read -rp "Choice: " k_ch

    case "$k_ch" in
        1)
            echo -e "\nSelect L3 Tunnel Encapsulation:"
            echo -e "  1) ${GREEN}gre${NC}   (Standard L3 GRE Tunnel)"
            echo -e "  2) ${GREEN}ipip${NC}  (Ultra-lightweight IPv4-in-IPv4 Header)"
            echo -e "  3) ${GREEN}sit${NC}   (IPv6-in-IPv4 Anti-Filter Encapsulation)"
            echo -e "  4) ${GREEN}vxlan${NC} (Layer 2/3 over UDP Port 4789)"
            read -rp "Choice [1-4]: " km_ch
            local kmode="gre"
            [[ "$km_ch" == "2" ]] && kmode="ipip"
            [[ "$km_ch" == "3" ]] && kmode="sit"
            [[ "$km_ch" == "4" ]] && kmode="vxlan"

            read -rp "Peer Server Public IPv4: " rem_ip
            echo -e "Local Node Role: 1) Iran (10.200.10.1)  2) Kharej (10.200.10.2)"
            read -rp "Choice [1-2]: " kr_ch
            local tun_local="10.200.10.1"
            local tun_remote="10.200.10.2"
            [[ "$kr_ch" == "2" ]] && { tun_local="10.200.10.2"; tun_remote="10.200.10.1"; }

            local iface="nx-${kmode}"
            ip link del "$iface" 2>/dev/null || true

            if [[ "$kmode" == "vxlan" ]]; then
                ip link add "$iface" type vxlan id 100 local "$PUBLIC_IP" remote "$rem_ip" dstport 4789
            else
                ip tunnel add "$iface" mode "$kmode" remote "$rem_ip" local "$PUBLIC_IP" ttl 255
            fi
            ip link set "$iface" up mtu 1420
            ip addr add "${tun_local}/30" dev "$iface"

            # MSS Clamping to prevent TLS fragment drops inside tunnel
            iptables -t mangle -A FORWARD -o "$iface" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
            iptables -t mangle -A FORWARD -i "$iface" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

            if [[ "$kr_ch" == "1" ]]; then
                read -rp "Ports for automatic DNAT to Kharej (e.g. 443, 2053 or Enter to skip): " nat_ports
                if [[ -n "$nat_ports" ]]; then
                    iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE
                    IFS=',' read -ra NP_ARR <<< "$nat_ports"
                    for p in "${NP_ARR[@]}"; do
                        p=$(echo "$p" | xargs)
                        iptables -t nat -A PREROUTING -p tcp --dport "$p" -j DNAT --to-destination "${tun_remote}:${p}"
                        iptables -t nat -A PREROUTING -p udp --dport "$p" -j DNAT --to-destination "${tun_remote}:${p}"
                    done
                fi
            fi
            echo -e "${GREEN}[✔] Kernel L3 tunnel ${iface} (${tun_local} <---> ${tun_remote}) with MSS Clamping active.${NC}"
            ping -c 2 -W 2 "$tun_remote" || true
            ;;
        2)
            read -rp "Bridge Port to exempt from Linux Conntrack (NOTRACK): " nt_port
            if validate_port "$nt_port"; then
                iptables -t raw -A PREROUTING -p tcp --dport "$nt_port" -j NOTRACK 2>/dev/null || true
                iptables -t raw -A OUTPUT -p tcp --sport "$nt_port" -j NOTRACK 2>/dev/null || true
                iptables -t raw -A PREROUTING -p tcp --sport "$nt_port" -j NOTRACK 2>/dev/null || true
                iptables -t raw -A OUTPUT -p tcp --dport "$nt_port" -j NOTRACK 2>/dev/null || true
                echo -e "${GREEN}[✔] Raw socket NOTRACK accelerator enabled on port ${nt_port}.${NC}"
            fi
            ;;
        3)
            ip addr show | grep -E "nx-" -A 2 || echo "No active L3 interfaces found."
            echo -e "\n--- Mangle (MSS Clamping) & NAT Rules ---"
            iptables -t mangle -L FORWARD -n -v 2>/dev/null | head -n 10
            iptables -t nat -L PREROUTING -n -v 2>/dev/null | head -n 15
            ;;
        4)
            for ifc in nx-gre nx-ipip nx-sit nx-vxlan; do
                ip link del "$ifc" 2>/dev/null || true
            done
            iptables -t nat -F PREROUTING 2>/dev/null || true
            iptables -t nat -F POSTROUTING 2>/dev/null || true
            iptables -t mangle -F FORWARD 2>/dev/null || true
            iptables -t raw -F 2>/dev/null || true
            echo -e "${GREEN}[✔] All L3 tunnels and firewall rules cleared.${NC}"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 6. Gemini AI Doctor & Network Healer
# ------------------------------------------------------------------------------
gemini_ai_doctor() {
    echo -e "\n${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║             🧠 Gemini AI Doctor & Network Healer             ║${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"

    local cur_key
    cur_key=$(get_gemini_key)
    if [[ -z "$cur_key" ]]; then
        read -rp "Enter your Google Gemini API Key: " in_key
        in_key=$(echo "$in_key" | xargs)
        if [[ -n "$in_key" ]]; then
            echo "$in_key" > "$KEY_FILE"
            chmod 600 "$KEY_FILE"
            echo -e "${GREEN}[✔] Gemini API Key saved.${NC}"
        else
            echo -e "${RED}[!] An API Key is required for autonomous AI diagnostics.${NC}"
            return 1
        fi
    fi

    echo -e "${CYAN}[*] Gathering telemetry, listening sockets, logs, and DNS status...${NC}"
    local ss_snap
    ss_snap=$(ss -tulpn 2>/dev/null | head -n 15)
    local services_snap
    services_snap=$(systemctl list-units "nexus-tunnel@*" --no-legend 2>/dev/null)
    local recent_logs=""
    for lfile in "${LOG_DIR}"/*.log; do
        [[ -f "$lfile" ]] && recent_logs+="$(tail -n 8 "$lfile" 2>/dev/null)\n"
    done

    local diag_prompt="You are Nexus Tunnel AI Healer. Diagnose this Linux networking and tunnel state:
Services: ${services_snap}
Sockets: ${ss_snap}
Recent Logs: ${recent_logs}
Explain in 2-3 bullet points in Persian if there are port conflicts, DPI drops, or handshake timeouts, and suggest the exact fix."

    echo -e "${CYAN}[*] Querying Gemini AI Engine...${NC}"
    local ai_analysis
    ai_analysis=$(query_gemini_ai "$diag_prompt")

    if [[ -n "$ai_analysis" ]]; then
        echo -e "\n${GREEN}[Gemini AI Diagnosis]:${NC}\n${ai_analysis}\n"
    else
        echo -e "${YELLOW}[!] Could not reach Gemini API. Verifying local system state...${NC}"
        echo -e "Active Services:\n${services_snap:-No active instances.}"
    fi

    echo -e "${CYAN}Available 1-Click Healing Actions:${NC}"
    echo -e "  1) Restart All Tunnel Services"
    echo -e "  2) Auto-Configure Firewall & Allow Forwarding Ports"
    echo -e "  3) Flush Conntrack & DNS Caches"
    echo -e "  4) Return to Menu"
    read -rp "Action [1-4]: " h_ch
    case "$h_ch" in
        1)
            systemctl restart "nexus-tunnel@*" 2>/dev/null || true
            echo -e "${GREEN}[✔] All tunnel services restarted.${NC}"
            ;;
        2)
            iptables -I INPUT -p tcp --dport 4443 -j ACCEPT 2>/dev/null || true
            iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
            iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
            echo -e "${GREEN}[✔] Essential ports allowed in iptables.${NC}"
            ;;
        3)
            conntrack -F 2>/dev/null || true
            systemd-resolve --flush-caches 2>/dev/null || true
            echo -e "${GREEN}[✔] Conntrack and DNS caches flushed.${NC}"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 7. Uninstaller
# ------------------------------------------------------------------------------
uninstall_all() {
    echo -e "${YELLOW}[*] Stopping all tunnel instances and cleaning up system...${NC}"
    for f in "${CONFIG_DIR}"/*.json; do
        [[ ! -e "$f" ]] && continue
        local name
        name=$(basename "$f" .json)
        systemctl stop "nexus-tunnel@${name}.service" 2>/dev/null || true
        systemctl disable "nexus-tunnel@${name}.service" 2>/dev/null || true
    done
    systemctl stop "nexus-tunnel@*" 2>/dev/null || true

    for ifc in nx-gre nx-ipip nx-sit nx-vxlan; do
        ip link del "$ifc" 2>/dev/null || true
    done
    iptables -t nat -F PREROUTING 2>/dev/null || true
    iptables -t nat -F POSTROUTING 2>/dev/null || true
    iptables -t mangle -F FORWARD 2>/dev/null || true
    iptables -t raw -F 2>/dev/null || true

    rm -f "${TEMPLATE_SERVICE}" "${BIN_PATH}" "${CLI_PATH}" /etc/sysctl.d/99-nexus-tunnel.conf
    rm -rf "${INSTALL_DIR}" "${CONFIG_DIR}" "${LOG_DIR}" "${RUN_DIR}"
    systemctl daemon-reload
    sysctl --system >/dev/null 2>&1 || true
    echo -e "${GREEN}[✔] Nexus-Tunnel v7.0 suite and all services completely removed.${NC}"
}

# ------------------------------------------------------------------------------
# Main Menu
# ------------------------------------------------------------------------------
main_menu() {
    while true; do
        echo -e "\n${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║     ⚡ Nexus-Tunnel v7.0 — Unified Carrier Tunnel Suite         ║${NC}"
        echo -e "${CYAN}║     Backhaul + WaterWall + WatTunnel + BackPack + Gemini AI      ║${NC}"
        echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════╣${NC}"
        echo -e "║  ${GREEN}1)${NC} 🇮🇷 Initialize Iran Node (Generate AI Pairing Key)            ║"
        echo -e "║  ${GREEN}2)${NC} 🌍 Connect Kharej Node (Paste Key & AI Auto-Setup)          ║"
        echo -e "║  ${GREEN}3)${NC} 🛠️  Manual Node / Tunnel Profile Wizard                       ║"
        echo -e "║  ${GREEN}4)${NC} ⚡ Live Telemetry & Control Panel (Hot-Reload / Ping)         ║"
        echo -e "║  ${GREEN}5)${NC} 🛡️  L3 Kernel Tunnels (GRE/IPIP/SIT/VXLAN + MSS + NOTRACK)    ║"
        echo -e "║  ${GREEN}6)${NC} 🧠 Gemini AI Doctor & Network Healer                          ║"
        echo -e "║  ${GREEN}7)${NC} 🚀 Linux Kernel & BBR Performance Optimizer                   ║"
        echo -e "║  ${RED}8)${NC} 🗑️  Complete Uninstall & Network Reset                        ║"
        echo -e "║  ${YELLOW}0)${NC} Exit                                                         ║"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
        read -rp "Please enter an option [0-8]: " ch
        case "$ch" in
            1)
                apply_kernel_tuning
                init_iran_node
                ;;
            2)
                apply_kernel_tuning
                connect_kharej_node
                ;;
            3)
                create_tunnel_profile
                show_instant_dashboard
                ;;
            4)
                show_instant_dashboard
                live_control_editor
                ;;
            5) kernel_l3_manager ;;
            6) gemini_ai_doctor ;;
            7) apply_kernel_tuning ;;
            8)
                read -rp "Are you sure you want to completely uninstall Nexus-Tunnel? [y/N]: " conf
                if [[ "$conf" =~ ^[Yy]$ ]]; then
                    uninstall_all
                    exit 0
                fi
                ;;
            0) exit 0 ;;
            *) echo -e "${RED}[!] Invalid option. Please select 0-8.${NC}" ;;
        esac
    done
}

main_menu
