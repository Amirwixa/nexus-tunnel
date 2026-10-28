#!/usr/bin/env bash
# ==============================================================================
# Nexus-Tunnel v7.0 — Unified Multi-Transport & Kernel Tunnel Matrix
# Combines: BackPack + WaterWall + WatTunnel + Backhaul Features
# Zero-Hang Instant Log Engine | 14 Transports | DPI Desync | L3 TUN/GRE/NOTRACK
# ==============================================================================

umask 022

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

INSTALL_DIR="/opt/nexus-tunnel"
CONFIG_DIR="/etc/nexus-tunnel"
LOG_DIR="/var/log/nexus-tunnel"
RUN_DIR="/run/nexus-tunnel"
BIN_PATH="/usr/local/bin/nexus-tunnel"
CLI_PATH="/usr/local/bin/nexus"
TEMPLATE_SERVICE="/etc/systemd/system/nexus-tunnel@.service"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[✘] خطا: لطفاً با دسترسی root اجرا کنید (sudo bash nexus.sh).${NC}"
   exit 1
fi

mkdir -p "${INSTALL_DIR}/cmd/nexus" "${CONFIG_DIR}" "${LOG_DIR}" "${RUN_DIR}"

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

# ۱. بهینه‌سازی محاسباتی کرنل + BBR + TCP FastOpen
apply_kernel_tuning() {
    detect_specs
    echo -e "${CYAN}[*] محاسبه پارامترهای شبکه کرنل بر اساس سخت‌افزار (${TOTAL_RAM_MB}MB RAM | ${CPU_CORES} Cores)...${NC}"

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
    echo -e "${GREEN}[✔] کرنل لینوکس، IP Forwarding و BBR با بافر $((max_buf / 1048576))MB بهینه شدند.${NC}"
}

# ۲. کامپایل ایمن هسته و ثبت سرویس بدون استفاده از journalctl سنگین
build_core() {
    if ! command -v go >/dev/null 2>&1; then
        echo -e "${YELLOW}[*] در حال نصب کامپایلر Go...${NC}"
        apt-get update -y >/dev/null 2>&1 || true
        if ! apt-get install -y golang-go >/dev/null 2>&1; then
            local arch="amd64"
            [[ "$(uname -m)" == "aarch64" ]] && arch="arm64"
            curl -fSL "https://go.dev/dl/go1.22.5.linux-${arch}.tar.gz" -o /tmp/go.tar.gz
            rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tar.gz
            ln -sf /usr/local/go/bin/go /usr/bin/go
            rm -f /tmp/go.tar.gz
        fi
    fi

    cat > "${INSTALL_DIR}/go.mod" <<'EOF'
module nexus-tunnel

go 1.20
EOF

    if [[ -f "./cmd/nexus/main.go" ]]; then
        local src_real dst_real
        src_real=$(realpath "./cmd/nexus/main.go" 2>/dev/null || echo "")
        dst_real=$(realpath "${INSTALL_DIR}/cmd/nexus/main.go" 2>/dev/null || echo "")
        if [[ -n "$src_real" && "$src_real" != "$dst_real" ]]; then
            cp -f "./cmd/nexus/main.go" "${INSTALL_DIR}/cmd/nexus/main.go"
        fi
    fi

    if [[ ! -f "${INSTALL_DIR}/cmd/nexus/main.go" ]]; then
        echo -e "${RED}[✘] فایل ${INSTALL_DIR}/cmd/nexus/main.go یافت نشد!${NC}"
        return 1
    fi

    echo -e "${CYAN}[*] در حال کامپایل هسته بومی Nexus-Tunnel v7.0...${NC}"
    if (cd "${INSTALL_DIR}" && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o "${BIN_PATH}" ./cmd/nexus/main.go); then
        chmod +x "${BIN_PATH}"
        echo -e "${GREEN}[✔] باینری هسته با موفقیت در ${BIN_PATH} کامپایل شد.${NC}"
    else
        echo -e "${RED}[✘] خطا در کامپایل فایل main.go!${NC}"
        return 1
    fi

    # هدایت لاگ به فایل چرخشی به جای journald برای جلوگیری ۱۰۰٪ از هنگ کردن سرور
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
}

# ۳. ویزارد کامل ساخت تانل با تمام ترنسپورت‌ها و قابلیت‌های هر ۴ پروژه
create_tunnel_profile() {
    detect_specs
    echo -e "\n${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     ساخت پروفایل تانل جدید (Nexus v7.0 Unified Matrix)       ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo -e "آی‌پی شناسایی‌شده این سرور: ${YELLOW}${PUBLIC_IP}${NC}\n"

    read -rp "۱) نام پروفایل تانل (پیش‌فرض با Enter: main): " t_name
    t_name="${t_name:-main}"
    t_name=$(echo "$t_name" | tr -cd 'a-zA-Z0-9_-')

    local role="iran"
    echo -e "\n۲) نقش این سرور در تانل [${YELLOW}${t_name}${NC}]:"
    echo -e "   ${GREEN}1)${NC} سرور ایران (Iran - دریافت‌کننده ترافیک کاربران)"
    echo -e "   ${GREEN}2)${NC} سرور خارج (Kharej - سرور مقصد / Xray)"
    read -rp "انتخاب [1-2، پیش‌فرض 1]: " r_ch
    [[ "$r_ch" == "2" ]] && role="kharej"

    local mode="reverse"
    echo -e "\n۳) توپولوژی و معماری تانل:"
    echo -e "   ${GREEN}1)${NC} reverse      (معکوس با استخر اتصال و پینگ خودکار: خارج به ایران وصل می‌شود)"
    echo -e "   ${GREEN}2)${NC} reverse-mux  (معکوس مالتی‌پلکس به سبک Backhaul / WaterWall)"
    echo -e "   ${GREEN}3)${NC} direct-pool  (مستقیم با استخر اتصال آماده و بدون تأخیر هندشیک)"
    echo -e "   ${GREEN}4)${NC} direct-mux   (مستقیم مالتی‌پلکس با کانال‌های پایدار)"
    echo -e "   ${GREEN}5)${NC} direct       (مستقیم کلاسیک در لحظه)"
    read -rp "انتخاب [1-5، پیش‌فرض 1]: " m_ch
    case "$m_ch" in
        2) mode="reverse-mux" ;;
        3) mode="direct-pool" ;;
        4) mode="direct-mux" ;;
        5) mode="direct" ;;
        *) mode="reverse" ;;
    esac

    local transport="tls"
    echo -e "\n۴) انتخاب لایه ترنسپورت و حامل (۱۲ پروتکل از BackPack / WaterWall / WatTunnel / Backhaul):"
    echo -e "   ${GREEN}1)${NC}  tls          (TLS 1.3 + Fake SNI + ALPN h2)"
    echo -e "   ${GREEN}2)${NC}  tlsmux       (مالتی‌پلکس روی بستر TLS 1.3)"
    echo -e "   ${GREEN}3)${NC}  reality      (استتار فعال REALITY: هدایت کاوشگر فیلترینگ به سایت واقعی SNI)"
    echo -e "   ${GREEN}4)${NC}  ws           (HTTP/1.1 WebSocket Upgrade به سبک Backhaul)"
    echo -e "   ${GREEN}5)${NC}  wsmux        (WebSocket Multiplexing به سبک Backhaul)"
    echo -e "   ${GREEN}6)${NC}  wss          (WebSocket داخل بستر TLS 1.3)"
    echo -e "   ${GREEN}7)${NC}  wssmux       (WebSocket Mux داخل بستر TLS 1.3 - حداکثر استتار)"
    echo -e "   ${GREEN}8)${NC}  short-https  (استتار HTTP/1.1 Chunked POST به سبک BackPack)"
    echo -e "   ${GREEN}9)${NC}  h2c          (استتار HTTP/2 & Naive Framing به سبک WaterWall/BackPack)"
    echo -e "   ${GREEN}10)${NC} dnsshape     (استتار باینری در قالب پکت‌های DNS به سبک WatTunnel)"
    echo -e "   ${GREEN}11)${NC} tcp          (TCP خام پرسرعت + HMAC)"
    echo -e "   ${GREEN}12)${NC} tcpmux       (TCP Multiplexing به سبک Backhaul)"
    read -rp "انتخاب [1-12، پیش‌فرض 1]: " tr_ch
    case "$tr_ch" in
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
        *)  transport="tls" ;;
    esac

    local preset="balanced"
    echo -e "\n۵) پریست بهینه‌سازی عملکرد (Performance Preset به سبک BackPack):"
    echo -e "   ${GREEN}1)${NC} balanced   (متعادل و پایدار برای استفاده عمومی)"
    echo -e "   ${GREEN}2)${NC} gaming     (تأخیر و پینگ حداقل برای گیمینگ و تماس صوتی)"
    echo -e "   ${GREEN}3)${NC} streaming  (بافرهای ۸ مگابایتی برای دانلود و استریم سرعت بالا)"
    echo -e "   ${GREEN}4)${NC} stealth    (ضد فیلترینگ شدید: فعال‌سازی خودکار Fragment + Padding + XOR Obfs)"
    read -rp "انتخاب [1-4، پیش‌فرض 1]: " pr_set
    case "$pr_set" in
        2) preset="gaming" ;;
        3) preset="streaming" ;;
        4) preset="stealth" ;;
        *) preset="balanced" ;;
    esac

    local fragment="false"
    local obfs="false"
    local padding="false"
    if [[ "$preset" == "stealth" ]]; then
        fragment="true"; obfs="true"; padding="true"
    else
        echo -e "\n۶) تنظیمات ضد DPI (از WaterWall و WatTunnel):"
        read -rp "   • آیا تکه تکه کردن هندشیک (TLS/TCP Fragmentation) فعال شود؟ [y/N]: " fr_in
        [[ "$fr_in" =~ ^[Yy]$ ]] && fragment="true"
        read -rp "   • آیا مبهم‌سازی استریم (XOR Obfuscation) فعال شود؟ [y/N]: " ob_in
        [[ "$ob_in" =~ ^[Yy]$ ]] && obfs="true"
        read -rp "   • آیا تزریق پدینگ تصادفی (Random Length Padding) فعال شود؟ [y/N]: " pd_in
        [[ "$pd_in" =~ ^[Yy]$ ]] && padding="true"
    fi

    local bridge_addr=""
    if [[ ( "$mode" =~ ^reverse && "$role" == "iran" ) || ( "$mode" =~ ^direct && "$role" == "kharej" ) ]]; then
        while true; do
            read -rp $'\n۷) پورت پل ارتباطی (Bridge Port) که این سرور روی آن گوش می‌دهد (پیش‌فرض 4443): ' bp
            bp="${bp:-4443}"
            if validate_port "$bp"; then
                bridge_addr="0.0.0.0:${bp}"
                break
            fi
            echo -e "${RED}[!] پورت نامعتبر است.${NC}"
        done
    else
        local target_label="ایران"
        [[ "$role" == "iran" ]] && target_label="خارج"
        echo -e "\n۷) آدرس پل سرور ${target_label} (پشتیبانی از Multi-Path Bonding: می‌توانید یک یا چند IP:Port را با کاما وارد کنید):"
        echo -e "   مثال تک‌مسیره: ${YELLOW}1.2.3.4:4443${NC} | مثال چندمسیره (Failover): ${YELLOW}1.2.3.4:4443, 1.2.3.4:8443${NC}"
        while true; do
            read -rp "   آدرس(های) پل سرور ${target_label}: " bridge_addr
            [[ -n "$bridge_addr" && "$bridge_addr" == *":"* ]] && break
            echo -e "${RED}[!] لطفاً فرمت IP:Port (مثلاً 1.2.3.4:4443) را وارد کنید.${NC}"
        done
    fi

    local auto_tok
    auto_tok=$(openssl rand -hex 12 2>/dev/null || echo "nexus$(date +%s)")
    read -rp $'\n۸) توکن امنیتی مشترک (Enter = '"${auto_tok}"$'): ' token_in
    local token="${token_in:-$auto_tok}"

    read -rp $'\n۹) دامنه پوششی SNI / Fake Host (Enter = www.cloudflare.com): ' sni_in
    local sni="${sni_in:-www.cloudflare.com}"
    local fallback_dest="${sni}:443"

    local def_pool=$(( CPU_CORES * 6 ))
    [ "$def_pool" -lt 16 ] && def_pool=16
    read -rp "۱۰) تعداد کانال‌های آماده در استخر اتصال (Enter = ${def_pool}): " pool_in
    local pool_size="${pool_in:-$def_pool}"

    local proxy_proto="false"
    if [[ "$role" == "kharej" ]]; then
        read -rp $'\n۱۱) آیا ارسال IP واقعی کاربر (PROXY Protocol v1) به سرویس مقصد فعال شود؟ [y/N]: ' pp_in
        [[ "$pp_in" =~ ^[Yy]$ ]] && proxy_proto="true"
    fi

    local protocol="tcp"
    local ports_json="[]"
    if [[ "$role" == "iran" ]]; then
        echo -e "\n۱۱) پروتکل پورت‌های کاربران:  1) فقط TCP   2) فقط UDP   3) هر دو (TCP + UDP)"
        read -rp "انتخاب [1-3، پیش‌فرض 1]: " proto_ch
        [[ "$proto_ch" == "2" ]] && protocol="udp"
        [[ "$proto_ch" == "3" ]] && protocol="both"

        echo -e "\n۱۲) پورت‌های فورواردینگ را با کاما وارد کنید (مثال: 443, 2053 یا 8443:443):"
        while true; do
            read -rp "لیست پورت‌ها: " raw_ports
            [[ -z "$raw_ports" ]] && continue
            IFS=',' read -ra P_ARR <<< "$raw_ports"
            local j_items=()
            local ok=true
            for item in "${P_ARR[@]}"; do
                item=$(echo "$item" | xargs)
                local p1="${item%%:*}"
                if ! validate_port "$p1"; then
                    echo -e "${RED}[!] پورت ${item} نامعتبر است.${NC}"
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

    read -rp $'\n۱۳) پورت وب‌پنل زنده برای این تانل (مثال: 0.0.0.0:8088 یا Enter برای غیرفعال بودن): ' web_in

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
    echo -e "${GREEN}[✔] پروفایل تانل [${t_name}] با موفقیت ساخته و فعال شد!${NC}"
    echo -e "    • نقش: ${YELLOW}${role}${NC} | توپولوژی: ${YELLOW}${mode}${NC} | ترنسپورت: ${YELLOW}${transport}${NC}"
    echo -e "    • پریست: ${YELLOW}${preset}${NC} | Frag: ${YELLOW}${fragment}${NC} | Obfs: ${YELLOW}${obfs}${NC}"
    echo -e "    • آدرس پل: ${YELLOW}${bridge_addr}${NC}"
    echo -e "    • توکن مشترک: ${YELLOW}${token}${NC}"
    echo -e "${GREEN}================================================================${NC}"
}

# ۴. داشبورد و مشاهده لاگ آنی (بدون هیچ‌گونه هنگ کردن)
show_instant_dashboard() {
    echo -e "\n${CYAN}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                  داشبورد وضعیت زنده تانل‌ها (Zero-Hang Engine)               ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"

    local files=("${CONFIG_DIR}"/*.json)
    if [[ ! -e "${files[0]}" ]]; then
        echo -e "${YELLOW}[!] هنوز هیچ پروفایل تانلی ساخته نشده است.${NC}"
        return
    fi

    printf "%-10s | %-6s | %-11s | %-11s | %-6s | %-6s | %-7s | %-10s\n" \
        "PROFILE" "ROLE" "TOPOLOGY" "TRANSPORT" "POOL" "USERS" "RTT" "STATUS"
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
            st="RUNNING"
        else
            st="STOPPED"
        fi
        printf "%-10s | %-6s | %-11s | %-11s | %-6s | %-6s | %-7s | %-10s\n" \
            "$name" "$role" "$mode" "$tr" "$pool_c" "$user_c" "${rtt_ms}ms" "$st"
    done

    echo -e "\n${YELLOW}--- آخرین لاگ‌های ثبت‌شده (خوانش مستقیم و بدون مکث از حافظه) ---${NC}"
    for lfile in "${LOG_DIR}"/*.log; do
        [[ ! -f "$lfile" ]] && continue
        echo -e "${CYAN}==> $(basename "$lfile") <==${NC}"
        tail -n 12 "$lfile" 2>/dev/null || true
    done
}

# ۵. پنل کنترل زنده، تست پینگ و تست سرعت (SpeedTest)
live_control_editor() {
    local files=("${CONFIG_DIR}"/*.json)
    if [[ ! -e "${files[0]}" ]]; then
        echo -e "${RED}[!] هیچ پروفایل تانلی یافت نشد.${NC}"
        return
    fi

    echo -e "\n${CYAN}--- انتخاب پروفایل تانل برای کنترل زنده ---${NC}"
    local i=1
    local names=()
    for f in "${files[@]}"; do
        local bn
        bn=$(basename "$f" .json)
        names+=("$bn")
        echo -e "  ${GREEN}${i})${NC} ${bn}"
        ((i++))
    done

    read -rp "شماره تانل را انتخاب کنید: " idx
    [[ ! "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "${#names[@]}" ] && return
    local sel="${names[$((idx-1))]}"
    local cfile="${CONFIG_DIR}/${sel}.json"

    echo -e "\n${CYAN}=== پنل کنترل زنده و ابزارهای تست تانل [${sel}] ===${NC}"
    cat "$cfile"
    echo -e "\n  ${GREEN}1)${NC} تغییر سریع ترنسپورت (tls / tlsmux / reality / ws / wsmux / wss / wssmux / short-https / h2c / dnsshape / tcp / tcpmux)"
    echo -e "  ${GREEN}2)${NC} تغییر سریع توپولوژی (reverse / reverse-mux / direct-pool / direct-mux / direct)"
    echo -e "  ${GREEN}3)${NC} تغییر سریع پریست (balanced / gaming / streaming / stealth)"
    echo -e "  ${GREEN}4)${NC} روشن/خاموش کردن Fragmentation / Obfuscation / Padding"
    echo -e "  ${GREEN}5)${NC} ویرایش گرم پورت‌های فورواردینگ (Hot Port Update)"
    echo -e "  ${GREEN}6)${NC} تست پینگ و هندشیک درون‌تانلی (End-to-End RTT Ping)"
    echo -e "  ${GREEN}7)${NC} تست سرعت واقعی پهنای باند تانل (Built-in SpeedTest)"
    echo -e "  ${GREEN}8)${NC} مشاهده لاگ زنده این تانل (بدون هنگ - خروج با Ctrl+C)"
    echo -e "  ${GREEN}9)${NC} ری‌استارت / توقف / حذف این تانل"
    read -rp "انتخاب عملیات: " op

    case "$op" in
        1)
            read -rp "ترنسپورت جدید را وارد کنید: " new_tr
            sed -i "s/\"transport\": *\"[^\"]*\"/\"transport\": \"${new_tr}\"/" "$cfile"
            systemctl restart "nexus-tunnel@${sel}"
            echo -e "${GREEN}[✔] ترنسپورت به ${new_tr} تغییر یافت.${NC}"
            ;;
        2)
            read -rp "توپولوژی جدید را وارد کنید: " new_md
            sed -i "s/\"mode\": *\"[^\"]*\"/\"mode\": \"${new_md}\"/" "$cfile"
            systemctl restart "nexus-tunnel@${sel}"
            echo -e "${GREEN}[✔] توپولوژی به ${new_md} تغییر یافت.${NC}"
            ;;
        3)
            read -rp "پریست جدید (balanced / gaming / streaming / stealth): " new_pr
            sed -i "s/\"preset\": *\"[^\"]*\"/\"preset\": \"${new_pr}\"/" "$cfile"
            systemctl restart "nexus-tunnel@${sel}"
            echo -e "${GREEN}[✔] پریست به ${new_pr} تغییر یافت.${NC}"
            ;;
        4)
            read -rp "Fragment (true/false): " nf
            read -rp "XOR Obfs (true/false): " no
            read -rp "Padding  (true/false): " npd
            [[ -n "$nf" ]] && sed -i "s/\"fragment\": *[a-z]*/\"fragment\": ${nf}/" "$cfile"
            [[ -n "$no" ]] && sed -i "s/\"obfs\": *[a-z]*/\"obfs\": ${no}/" "$cfile"
            [[ -n "$npd" ]] && sed -i "s/\"padding\": *[a-z]*/\"padding\": ${npd}/" "$cfile"
            systemctl restart "nexus-tunnel@${sel}"
            echo -e "${GREEN}[✔] تنظیمات ضد DPI بروزرسانی شد.${NC}"
            ;;
        5)
            read -rp "لیست کامل پورت‌های جدید را با کاما وارد کنید (مثال: 443, 2053, 8443:443): " np
            IFS=',' read -ra PA <<< "$np"
            local j_arr=()
            for p in "${PA[@]}"; do
                p=$(echo "$p" | xargs)
                j_arr+=("\"${p}\"")
            done
            local new_pjson="[$(IFS=,; echo "${j_arr[*]}")]"
            sed -i "s/\"ports\": *\[[^]]*\]/\"ports\": ${new_pjson}/" "$cfile"
            systemctl restart "nexus-tunnel@${sel}"
            echo -e "${GREEN}[✔] پورت‌ها بروزرسانی شدند.${NC}"
            ;;
        6) "${BIN_PATH}" -c "$cfile" -ping || true ;;
        7) "${BIN_PATH}" -c "$cfile" -speedtest || true ;;
        8) tail -n 30 -f "${LOG_DIR}/${sel}.log" ;;
        9)
            read -rp "عملیات: 1) ری‌استارت  2) توقف  3) حذف کامل [${sel}]: " s_op
            case "$s_op" in
                1) systemctl restart "nexus-tunnel@${sel}"; echo -e "${GREEN}[✔] ری‌استارت شد.${NC}" ;;
                2) systemctl stop "nexus-tunnel@${sel}"; echo -e "${YELLOW}[!] متوقف شد.${NC}" ;;
                3)
                    systemctl stop "nexus-tunnel@${sel}" 2>/dev/null || true
                    systemctl disable "nexus-tunnel@${sel}" 2>/dev/null || true
                    rm -f "$cfile" "${LOG_DIR}/${sel}.log" "${RUN_DIR}/${sel}.status.json"
                    echo -e "${GREEN}[✔] پروفایل ${sel} حذف شد.${NC}"
                    ;;
            esac
            ;;
    esac
}

# ۶. مدیریت تانل‌های لایه ۳ کرنل (L3 Direct / GRE / IPIP / SIT / VXLAN + MSS Clamping + NOTRACK)
kernel_l3_manager() {
    detect_specs
    echo -e "\n${MAGENTA}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║   تانل‌های سطح کرنل L3 (GRE/IPIP/SIT/VXLAN + MSS Clamp + NOTRACK)  ║${NC}"
    echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo -e "  ${GREEN}1)${NC} ساخت تانل L3 کرنلی (GRE / IPIP / SIT / VXLAN) + TCPMSS Clamp + Iptables NAT"
    echo -e "  ${GREEN}2)${NC} فعال‌سازی شتاب‌دهنده Raw Socket NOTRACK روی پورت پل (الهام از WaterWall)"
    echo -e "  ${GREEN}3)${NC} نمایش وضعیت اینترفیس‌های L3 و قوانین فایروال"
    echo -e "  ${GREEN}4)${NC} حذف تانل‌های L3 و پاکسازی قوانین iptables"
    read -rp "انتخاب: " k_ch

    case "$k_ch" in
        1)
            echo -e "\nنوع تانل لایه ۳ کرنل را انتخاب کنید:"
            echo -e "  1) ${GREEN}gre${NC}   (استاندارد L3)"
            echo -e "  2) ${GREEN}ipip${NC}  (سبک‌ترین هدر IPv4-in-IPv4)"
            echo -e "  3) ${GREEN}sit${NC}   (کپسوله‌سازی 6to4 ضد فیلتر)"
            echo -e "  4) ${GREEN}vxlan${NC} (تانل لایه ۲/۳ روی بستر UDP پورت 4789)"
            read -rp "انتخاب [1-4]: " km_ch
            local kmode="gre"
            [[ "$km_ch" == "2" ]] && kmode="ipip"
            [[ "$km_ch" == "3" ]] && kmode="sit"
            [[ "$km_ch" == "4" ]] && kmode="vxlan"

            read -rp "آدرس IPv4 عمومی سرور مقابل: " rem_ip
            echo -e "نقش این سرور: 1) ایران (10.200.10.1)  2) خارج (10.200.10.2)"
            read -rp "انتخاب [1-2]: " kr_ch
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

            # اعمال خودکار MSS Clamping برای جلوگیری از تکه شدن پکت‌های TLS داخل تانل L3 (از BackPack)
            iptables -t mangle -A FORWARD -o "$iface" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
            iptables -t mangle -A FORWARD -i "$iface" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

            if [[ "$kr_ch" == "1" ]]; then
                read -rp "پورت‌ها برای فوروارد خودکار با DNAT به ${tun_remote} (مثال: 443,2053 یا Enter برای رد): " nat_ports
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
            echo -e "${GREEN}[✔] تانل کرنل ${iface} (${tun_local} <---> ${tun_remote}) به همراه MSS Clamping فعال شد.${NC}"
            ping -c 2 -W 2 "$tun_remote" || true
            ;;
        2)
            read -rp "شماره پورت پل برای معاف کردن از Conntrack کرنل (NOTRACK): " nt_port
            if validate_port "$nt_port"; then
                iptables -t raw -A PREROUTING -p tcp --dport "$nt_port" -j NOTRACK 2>/dev/null || true
                iptables -t raw -A OUTPUT -p tcp --sport "$nt_port" -j NOTRACK 2>/dev/null || true
                iptables -t raw -A PREROUTING -p tcp --sport "$nt_port" -j NOTRACK 2>/dev/null || true
                iptables -t raw -A OUTPUT -p tcp --dport "$nt_port" -j NOTRACK 2>/dev/null || true
                echo -e "${GREEN}[✔] شتاب‌دهنده NOTRACK روی پورت ${nt_port} فعال شد.${NC}"
            fi
            ;;
        3)
            ip addr show | grep -E "nx-" -A 2 || echo "تانل L3 فعالی یافت نشد."
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
            echo -e "${GREEN}[✔] تانل‌های L3 و قوانین فایروال پاکسازی شدند.${NC}"
            ;;
    esac
}

uninstall_all() {
    echo -e "${YELLOW}[*] در حال توقف و حذف کامل تمام تانل‌ها...${NC}"
    systemctl stop "nexus-tunnel@*" 2>/dev/null || true
    rm -f "${TEMPLATE_SERVICE}" "${BIN_PATH}" "${CLI_PATH}" /etc/sysctl.d/99-nexus-tunnel.conf
    rm -rf "${INSTALL_DIR}" "${CONFIG_DIR}" "${LOG_DIR}" "${RUN_DIR}"
    systemctl daemon-reload
    echo -e "${GREEN}[✔] پروژه به طور کامل حذف شد.${NC}"
}

main_menu() {
    while true; do
        echo -e "\n${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║   Nexus-Tunnel v7.0 — Ultimate Unified Tunnel Suite (Zero-Hang)  ║${NC}"
        echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════╣${NC}"
        echo -e "║  ${GREEN}1)${NC} نصب زیرساخت، کامپایل هسته و ساخت پروفایل تانل جدید           ║"
        echo -e "║  ${GREEN}2)${NC} افزودن پروفایل تانل جدید (اجرای چند تانل هم‌زمان)            ║"
        echo -e "║  ${GREEN}3)${NC} پنل کنترل زنده، تغییر ترنسپورت، تست پینگ و تست سرعت تانل     ║"
        echo -e "║  ${GREEN}4)${NC} تانل‌های لایه ۳ کرنل (GRE/IPIP/SIT/VXLAN + MSS + NOTRACK)    ║"
        echo -e "║  ${GREEN}5)${NC} داشبورد وضعیت زنده و لاگ آنی (بدون هیچ‌گونه مکث یا هنگ)      ║"
        echo -e "║  ${GREEN}6)${NC} بهینه‌سازی محاسباتی کرنل و BBR                                ║"
        echo -e "║  ${RED}7)${NC} حذف کامل کل پروژه و پاکسازی (Uninstall)                      ║"
        echo -e "║  ${YELLOW}0)${NC} خروج                                                         ║"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
        read -rp "گزینه مورد نظر را انتخاب کنید: " ch
        case "$ch" in
            1)
                apply_kernel_tuning
                if build_core; then
                    create_tunnel_profile
                    show_instant_dashboard
                fi
                ;;
            2)
                [[ ! -x "${BIN_PATH}" ]] && build_core
                create_tunnel_profile
                show_instant_dashboard
                ;;
            3) live_control_editor ;;
            4) kernel_l3_manager ;;
            5) show_instant_dashboard ;;
            6) apply_kernel_tuning ;;
            7) uninstall_all; exit 0 ;;
            0) exit 0 ;;
            *) echo -e "${RED}[!] گزینه نامعتبر است.${NC}" ;;
        esac
    done
}

main_menu
