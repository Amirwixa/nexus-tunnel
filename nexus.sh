#!/usr/bin/env bash
# ==============================================================================
# Nexus-Tunnel v6.0 — Multi-Instance & Multi-Transport Control Matrix
# Supports: Reverse / Direct-Pool / Direct | Raw / TLS1.3 / WS / TLS+WS | TCP+UDP
# Plus: Kernel L3/L4 Tunnels (GRE / IPIP / SIT) & Live Hot-Editor
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
BIN_PATH="/usr/local/bin/nexus-tunnel"
CLI_PATH="/usr/local/bin/nexus"
TEMPLATE_SERVICE="/etc/systemd/system/nexus-tunnel@.service"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[✘] خطا: این ابزار باید با دسترسی root اجرا شود (sudo bash nexus.sh).${NC}"
   exit 1
fi

mkdir -p "${INSTALL_DIR}/cmd/nexus" "${CONFIG_DIR}"

detect_specs() {
    PUBLIC_IP=$(curl -s4m 3 https://icanhazip.com 2>/dev/null || curl -s4m 3 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
    DEFAULT_IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    CPU_CORES=$(nproc 2>/dev/null || echo 2)
}

validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        local OIFS=$IFS; IFS='.'; local octets=($ip); IFS=$OIFS
        [[ ${octets[0]} -le 255 && ${octets[1]} -le 255 && ${octets[2]} -le 255 && ${octets[3]} -le 255 ]] && return 0
    fi
    return 1
}

validate_port() {
    local port=$1
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && return 0
    return 1
}

# ۱. بهینه‌سازی محاسباتی کرنل و BBR
apply_kernel_tuning() {
    detect_specs
    echo -e "${CYAN}[*] محاسبه پارامترهای کرنل بر اساس سخت‌افزار (${TOTAL_RAM_MB}MB RAM | ${CPU_CORES} Cores)...${NC}"

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
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.ip_local_port_range = 1024 65535
EOF
    sysctl --system >/dev/null 2>&1 || true
    echo -e "${GREEN}[✔] کرنل لینوکس، IP Forwarding و BBR با بافر $((max_buf / 1048576))MB بهینه شدند.${NC}"
}

# ۲. نصب Go و کامپایل ایمن هسته (بدون باگ cp روی فایل یکسان)
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

    # بررسی دقیق مسیر فایل قبل از کپی (رفع کامل باگ same file)
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

    echo -e "${CYAN}[*] در حال کامپایل هسته چندپروتکلی Go...${NC}"
    if (cd "${INSTALL_DIR}" && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o "${BIN_PATH}" ./cmd/nexus/main.go); then
        chmod +x "${BIN_PATH}"
        echo -e "${GREEN}[✔] باینری هسته با موفقیت در ${BIN_PATH} ساخته شد.${NC}"
    else
        echo -e "${RED}[✘] خطا در کامپایل فایل main.go!${NC}"
        return 1
    fi

    # ثبت سرویس Template در Systemd برای پشتیبانی از چند تانل هم‌زمان
    cat > "${TEMPLATE_SERVICE}" <<EOF
[Unit]
Description=Nexus-Tunnel v6.0 Instance (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${BIN_PATH} -c ${CONFIG_DIR}/%i.json
Restart=always
RestartSec=2
LimitNOFILE=1048576
LimitNPROC=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload

    # ثبت دستور سراسری nexus
    local self_real
    self_real=$(realpath "$0" 2>/dev/null || echo "")
    if [[ -n "$self_real" && "$self_real" != "${INSTALL_DIR}/nexus.sh" ]]; then
        cp -f "$self_real" "${INSTALL_DIR}/nexus.sh"
    fi
    chmod +x "${INSTALL_DIR}/nexus.sh" 2>/dev/null || true
    ln -sf "${INSTALL_DIR}/nexus.sh" "${CLI_PATH}"
}

# ۳. ساخت پروفایل تانل جدید با تمام ترکیب‌ها
create_tunnel_profile() {
    detect_specs
    echo -e "\n${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         ساخت پروفایل تانل جدید (ماتریس کامل ترکیب‌ها)      ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo -e "آی‌پی این سرور: ${YELLOW}${PUBLIC_IP}${NC}\n"

    read -rp "۱) نام پروفایل تانل (مثال: main یا de1 - پیش‌فرض با Enter: main): " t_name
    t_name="${t_name:-main}"
    t_name=$(echo "$t_name" | tr -cd 'a-zA-Z0-9_-')

    local role=""
    while true; do
        echo -e "\n۲) نقش این سرور در تانل [${YELLOW}${t_name}${NC}] چیست؟"
        echo -e "   ${GREEN}1)${NC} سرور ایران (Iran - ورودی کاربران)"
        echo -e "   ${GREEN}2)${NC} سرور خارج (Kharej - سرور مقصد)"
        read -rp "انتخاب [1-2]: " r_ch
        case "$r_ch" in
            1) role="iran"; break ;;
            2) role="kharej"; break ;;
            *) echo -e "${RED}[!] عدد 1 یا 2 را وارد کنید.${NC}" ;;
        esac
    done

    local mode=""
    while true; do
        echo -e "\n۳) توپولوژی اتصال (Topology) را انتخاب کنید:"
        echo -e "   ${GREEN}1)${NC} Reverse     (معکوس با استخر اتصال: خارج به ایران وصل می‌شود - ضد فیلتر)"
        echo -e "   ${GREEN}2)${NC} Direct-Pool (مستقیم با استخر اتصال آماده: ایران به خارج با تأخیر صفر)"
        echo -e "   ${GREEN}3)${NC} Direct      (مستقیم کلاسیک: اتصال در لحظه از ایران به خارج)"
        read -rp "انتخاب [1-3]: " m_ch
        case "$m_ch" in
            1) mode="reverse"; break ;;
            2) mode="direct-pool"; break ;;
            3) mode="direct"; break ;;
            *) echo -e "${RED}[!] عدد 1 تا 3 را وارد کنید.${NC}" ;;
        esac
    done

    local transport=""
    while true; do
        echo -e "\n۴) لایه ترنسپورت و استتار (Transport Layer) را انتخاب کنید:"
        echo -e "   ${GREEN}1)${NC} TLS 1.3     (رمزنگاری TLS 1.3 + Fake SNI + ALPN h2)"
        echo -e "   ${GREEN}2)${NC} WebSocket   (استتار HTTP/1.1 WebSocket Upgrade + Fake Host)"
        echo -e "   ${GREEN}3)${NC} TLS + WS    (ترکیب دوگانه: WebSocket داخل بستر TLS 1.3 - حداکثر استتار)"
        echo -e "   ${GREEN}4)${NC} Raw TCP     (TCP خام پرسرعت + احراز هویت HMAC - کمترین تأخیر)"
        read -rp "انتخاب [1-4]: " tr_ch
        case "$tr_ch" in
            1) transport="tls"; break ;;
            2) transport="ws"; break ;;
            3) transport="tls+ws"; break ;;
            4) transport="raw"; break ;;
            *) echo -e "${RED}[!] عدد 1 تا 4 را وارد کنید.${NC}" ;;
        esac
    done

    echo -e "\n۵) مبهم‌سازی بار داده (XOR Stream Obfuscation):"
    read -rp "آیا می‌خواهید کل استریم تانل با الگوریتم XOR مبهم‌سازی شود؟ [y/N]: " obfs_ch
    local obfs="false"
    [[ "$obfs_ch" =~ ^[Yy]$ ]] && obfs="true"

    local bridge_addr=""
    local bridge_port=""
    local remote_ip=""

    if [[ "${mode}-${role}" == "reverse-iran" || "${mode}-${role}" == "direct-kharej" || "${mode}-${role}" == "direct-pool-kharej" ]]; then
        while true; do
            read -rp $'\n۶) پورت پل ارتباطی (Bridge Port) که این سرور روی آن گوش می‌دهد (مثال: 4443): ' bridge_port
            if validate_port "$bridge_port"; then
                bridge_addr="0.0.0.0:${bridge_port}"
                break
            fi
            echo -e "${RED}[!] شماره پورت نامعتبر است.${NC}"
        done
    else
        local target_str="ایران"
        [[ "$role" == "iran" ]] && target_str="خارج"
        while true; do
            read -rp $'\n۶) آدرس IPv4 سرور '"${target_str}"$' را وارد کنید: ' remote_ip
            validate_ip "$remote_ip" && break
            echo -e "${RED}[!] آدرس IP معتبر نیست.${NC}"
        done
        while true; do
            read -rp "   پورت پل ارتباطی (Bridge Port) سرور ${target_str}: " bridge_port
            if validate_port "$bridge_port"; then
                bridge_addr="${remote_ip}:${bridge_port}"
                break
            fi
            echo -e "${RED}[!] پورت معتبر نیست.${NC}"
        done
    fi

    local auto_tok
    auto_tok=$(openssl rand -hex 12 2>/dev/null || echo "nexus$(date +%s)")
    read -rp $'\n۷) توکن امنیتی مشترک (Enter = '"${auto_tok}"$'): ' token_in
    local token="${token_in:-$auto_tok}"

    local sni="www.cloudflare.com"
    local ws_path="/ws"
    if [[ "$transport" != "raw" ]]; then
        read -rp $'\n۸) دامنه پوششی SNI / Fake Host (Enter = www.cloudflare.com): ' sni_in
        sni="${sni_in:-www.cloudflare.com}"
    fi
    if [[ "$transport" == "ws" || "$transport" == "tls+ws" ]]; then
        read -rp "   مسیر WebSocket Path (Enter = /ws): " wsp_in
        ws_path="${wsp_in:-/ws}"
    fi

    local def_pool=$(( CPU_CORES * 8 ))
    read -rp $'\n۹) تعداد کانال‌های استخر اتصال (Pool Size - پیش‌فرض با Enter: '"${def_pool}"$'): ' pool_in
    local pool_size="${pool_in:-$def_pool}"

    local protocol="tcp"
    local ports_json="[]"
    if [[ "$role" == "iran" ]]; then
        echo -e "\n۱۰) پروتکل پورت‌های کاربران:"
        echo -e "   ${GREEN}1)${NC} فقط TCP"
        echo -e "   ${GREEN}2)${NC} فقط UDP"
        echo -e "   ${GREEN}3)${NC} هر دو (TCP + UDP هم‌زمان)"
        read -rp "انتخاب [1-3، پیش‌فرض 1]: " pr_ch
        case "$pr_ch" in
            2) protocol="udp" ;;
            3) protocol="both" ;;
            *) protocol="tcp" ;;
        esac

        echo -e "\n۱۱) پورت‌های فورواردینگ را با کاما وارد کنید (مثال: 443, 2053 یا 8443:443):"
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

    local cfg_file="${CONFIG_DIR}/${t_name}.json"
    cat > "${cfg_file}" <<EOF
{
  "name": "${t_name}",
  "role": "${role}",
  "mode": "${mode}",
  "transport": "${transport}",
  "protocol": "${protocol}",
  "obfs": ${obfs},
  "bridge_addr": "${bridge_addr}",
  "token": "${token}",
  "sni": "${sni}",
  "ws_path": "${ws_path}",
  "pool_size": ${pool_size},
  "sock_buf_kb": 4096,
  "ports": ${ports_json}
}
EOF

    systemctl enable "nexus-tunnel@${t_name}.service" >/dev/null 2>&1 || true
    systemctl restart "nexus-tunnel@${t_name}.service"

    echo -e "\n${GREEN}==============================================================${NC}"
    echo -e "${GREEN}[✔] تانل [${t_name}] ساخته و فعال شد!${NC}"
    echo -e "    • توپولوژی: ${YELLOW}${mode}${NC} | ترنسپورت: ${YELLOW}${transport}${NC} | Obfs: ${YELLOW}${obfs}${NC}"
    echo -e "    • آدرس پل:  ${YELLOW}${bridge_addr}${NC}"
    echo -e "    • توکن:     ${YELLOW}${token}${NC}"
    echo -e "${GREEN}==============================================================${NC}"
}

# ۴. کنترل و ویرایش زنده پروفایل‌های تانل (بدون نیاز به ساخت مجدد)
live_control_editor() {
    local files=("${CONFIG_DIR}"/*.json)
    if [[ ! -e "${files[0]}" ]]; then
        echo -e "${RED}[!] هیچ پروفایل تانلی یافت نشد. ابتدا گزینه 1 را بزنید.${NC}"
        return
    fi

    echo -e "\n${CYAN}--- پروفایل‌های موجود ---${NC}"
    local i=1
    local names=()
    for f in "${files[@]}"; do
        local bn
        bn=$(basename "$f" .json)
        names+=("$bn")
        local st="${RED}متوقف${NC}"
        systemctl is-active --quiet "nexus-tunnel@${bn}" && st="${GREEN}فعال${NC}"
        echo -e "  ${GREEN}${i})${NC} ${bn} (${st})"
        ((i++))
    done

    read -rp "شماره تانل را برای کنترل انتخاب کنید: " idx
    [[ ! "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "${#names[@]}" ] && return
    local sel="${names[$((idx-1))]}"
    local cfile="${CONFIG_DIR}/${sel}.json"

    echo -e "\n${CYAN}=== پنل کنترل سریع تانل [${sel}] ===${NC}"
    cat "$cfile"
    echo -e "\n  ${GREEN}1)${NC} تغییر سریع لایه Transport (tls / ws / tls+ws / raw)"
    echo -e "  ${GREEN}2)${NC} تغییر سریع توپولوژی (reverse / direct-pool / direct)"
    echo -e "  ${GREEN}3)${NC} روشن/خاموش کردن XOR Obfuscation"
    echo -e "  ${GREEN}4)${NC} تغییر پورت‌های فورواردینگ (Hot Port Update)"
    echo -e "  ${GREEN}5)${NC} تغییر آدرس پل (Bridge IP:Port) یا Pool Size"
    echo -e "  ${GREEN}6)${NC} تست پینگ و هندشیک درون‌تانلی (Bridge Ping Test)"
    echo -e "  ${GREEN}7)${NC} ری‌استارت / توقف / حذف این تانل"
    read -rp "انتخاب عملیات: " op

    case "$op" in
        1)
            read -rp "ترنسپورت جدید را وارد کنید (tls / ws / tls+ws / raw): " new_tr
            sed -i "s/\"transport\": *\"[^\"]*\"/\"transport\": \"${new_tr}\"/" "$cfile"
            systemctl restart "nexus-tunnel@${sel}"
            echo -e "${GREEN}[✔] ترنسپورت به ${new_tr} تغییر یافت و سرویس ری‌استارت شد.${NC}"
            ;;
        2)
            read -rp "توپولوژی جدید را وارد کنید (reverse / direct-pool / direct): " new_md
            sed -i "s/\"mode\": *\"[^\"]*\"/\"mode\": \"${new_md}\"/" "$cfile"
            systemctl restart "nexus-tunnel@${sel}"
            echo -e "${GREEN}[✔] توپولوژی به ${new_md} تغییر یافت و سرویس ری‌استارت شد.${NC}"
            ;;
        3)
            read -rp "وضعیت XOR Obfs (true / false): " new_ob
            sed -i "s/\"obfs\": *[a-z]*/\"obfs\": ${new_ob}/" "$cfile"
            systemctl restart "nexus-tunnel@${sel}"
            echo -e "${GREEN}[✔] وضعیت Obfs به ${new_ob} تغییر یافت.${NC}"
            ;;
        4)
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
            echo -e "${GREEN}[✔] پورت‌ها بروزرسانی شدند و تانل ری‌استارت شد.${NC}"
            ;;
        5)
            read -rp "آدرس پل جدید (مثلاً 0.0.0.0:4443 یا 1.2.3.4:4443): " nb
            [[ -n "$nb" ]] && sed -i "s/\"bridge_addr\": *\"[^\"]*\"/\"bridge_addr\": \"${nb}\"/" "$cfile"
            read -rp "تعداد Pool Size جدید (مثلاً 32): " npool
            [[ -n "$npool" ]] && sed -i "s/\"pool_size\": *[0-9]*/\"pool_size\": ${npool}/" "$cfile"
            systemctl restart "nexus-tunnel@${sel}"
            echo -e "${GREEN}[✔] تغییرات اعمال شد.${NC}"
            ;;
        6)
            "${BIN_PATH}" -c "$cfile" -ping || true
            ;;
        7)
            read -rp "عملیات: 1) ری‌استارت  2) توقف  3) حذف کامل پروفایل [${sel}]: " s_op
            case "$s_op" in
                1) systemctl restart "nexus-tunnel@${sel}"; echo -e "${GREEN}[✔] ری‌استارت شد.${NC}" ;;
                2) systemctl stop "nexus-tunnel@${sel}"; echo -e "${YELLOW}[!] متوقف شد.${NC}" ;;
                3)
                    systemctl stop "nexus-tunnel@${sel}" 2>/dev/null || true
                    systemctl disable "nexus-tunnel@${sel}" 2>/dev/null || true
                    rm -f "$cfile"
                    echo -e "${GREEN}[✔] پروفایل ${sel} حذف شد.${NC}"
                    ;;
            esac
            ;;
    esac
}

# ۵. سازنده تانل‌های سطح کرنل (GRE / IPIP / SIT + Iptables NAT)
kernel_tunnel_manager() {
    detect_specs
    echo -e "\n${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║      مدیریت تانل‌های سطح کرنل (GRE / IPIP / SIT + NAT)     ║${NC}"
    echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"
    echo -e "  ${GREEN}1)${NC} ساخت تانل کرنل جدید (GRE / IPIP / SIT) + فوروارد خودکار Iptables"
    echo -e "  ${GREEN}2)${NC} نمایش وضعیت اینترفیس‌های کرنلی و قوانین NAT"
    echo -e "  ${GREEN}3)${NC} حذف تانل کرنل و پاکسازی قوانین NAT"
    read -rp "انتخاب: " k_ch

    case "$k_ch" in
        1)
            echo -e "\nنوع پروتکل تونلینگ سطح کرنل را انتخاب کنید:"
            echo -e "  1) ${GREEN}gre${NC}  (استاندارد و سازگار با اکثر دیتاسنترها)"
            echo -e "  2) ${GREEN}ipip${NC} (کمترین سربار هدر برای IPv4-in-IPv4)"
            echo -e "  3) ${GREEN}sit${NC}  (تانل 6to4 / کپسوله‌سازی سبک)"
            read -rp "انتخاب [1-3]: " km_ch
            local kmode="gre"
            [[ "$km_ch" == "2" ]] && kmode="ipip"
            [[ "$km_ch" == "3" ]] && kmode="sit"

            read -rp "آدرس IPv4 عمومی سرور مقابل (Remote Public IP): " rem_ip
            if ! validate_ip "$rem_ip"; then
                echo -e "${RED}[!] آی‌پی معتبر نیست.${NC}"; return
            fi

            echo -e "نقش این سرور در تانل کرنل: 1) ایران (10.10.10.1)  2) خارج (10.10.10.2)"
            read -rp "انتخاب [1-2]: " kr_ch
            local tun_local="10.10.10.1"
            local tun_remote="10.10.10.2"
            if [[ "$kr_ch" == "2" ]]; then
                tun_local="10.10.10.2"
                tun_remote="10.10.10.1"
            fi

            local iface="nx-${kmode}"
            ip tunnel del "$iface" 2>/dev/null || true
            ip tunnel add "$iface" mode "$kmode" remote "$rem_ip" local "$PUBLIC_IP" ttl 255
            ip link set "$iface" up mtu 1420
            ip addr add "${tun_local}/30" dev "$iface"

            if [[ "$kr_ch" == "1" ]]; then
                read -rp "آیا می‌خواهید پورت‌ها با Iptables به ${tun_remote} فوروارد شوند؟ (مثال: 443,2053 یا Enter برای رد): " nat_ports
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

            echo -e "${GREEN}[✔] تانل کرنل ${iface} (${kmode}) بین ${tun_local} <---> ${tun_remote} برقرار شد.${NC}"
            ping -c 2 -W 2 "$tun_remote" || true
            ;;
        2)
            echo -e "\n${YELLOW}--- اینترفیس‌های تانل کرنل ---${NC}"
            ip addr show | grep -E "nx-gre|nx-ipip|nx-sit" -A 2 || echo "تانل کرنلی یافت نشد."
            echo -e "\n${YELLOW}--- قوانین PREROUTING NAT ---${NC}"
            iptables -t nat -L PREROUTING -n -v
            ;;
        3)
            for ifc in nx-gre nx-ipip nx-sit; do
                ip tunnel del "$ifc" 2>/dev/null || true
            done
            iptables -t nat -F PREROUTING 2>/dev/null || true
            iptables -t nat -F POSTROUTING 2>/dev/null || true
            echo -e "${GREEN}[✔] تانل‌های کرنل و قوانین NAT پاکسازی شدند.${NC}"
            ;;
    esac
}

# ۶. داشبورد مانیتورینگ زنده تمام تانل‌ها
show_dashboard() {
    echo -e "\n${CYAN}╔════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                   داشبورد وضعیت زنده تانل‌های فعال                      ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════════╝${NC}"

    local files=("${CONFIG_DIR}"/*.json)
    if [[ ! -e "${files[0]}" ]]; then
        echo -e "${YELLOW}[!] هنوز هیچ پروفایل تانلی ثبت نشده است.${NC}"
    else
        printf "%-12s | %-8s | %-12s | %-8s | %-6s | %-10s\n" "PROFILE" "ROLE" "TOPOLOGY" "TRANSP" "OBFS" "STATUS"
        echo "--------------------------------------------------------------------------"
        for f in "${files[@]}"; do
            local name role mode tr obfs st
            name=$(basename "$f" .json)
            role=$(grep -oP '"role":\s*"\K[^"]+' "$f" || echo "-")
            mode=$(grep -oP '"mode":\s*"\K[^"]+' "$f" || echo "-")
            tr=$(grep -oP '"transport":\s*"\K[^"]+' "$f" || echo "-")
            obfs=$(grep -oP '"obfs":\s*\K[a-z]+' "$f" || echo "-")
            if systemctl is-active --quiet "nexus-tunnel@${name}"; then
                st="ACTIVE"
            else
                st="STOPPED"
            fi
            printf "%-12s | %-8s | %-12s | %-8s | %-6s | %-10s\n" "$name" "$role" "$mode" "$tr" "$obfs" "$st"
        done
    fi

    echo -e "\n${YELLOW}--- پورت‌های در حال شنود (Listening Sockets) ---${NC}"
    ss -tulpn | grep "nexus-tunnel" || echo "هیچ سوکت فعالی یافت نشد."

    local estab
    estab=$(ss -tnp 2>/dev/null | grep "nexus-tunnel" | grep -c "ESTAB" || true)
    echo -e "\n${YELLOW}• مجموع کانال‌های برقرار (ESTABLISHED):${NC} ${GREEN}${estab}${NC}"

    echo -e "\n${YELLOW}--- آخرین لاگ‌های هسته تانل ---${NC}"
    journalctl -u "nexus-tunnel@*" -n 12 --no-pager 2>/dev/null || true
}

uninstall_all() {
    echo -e "${YELLOW}[*] در حال توقف و حذف کامل تمام تانل‌ها...${NC}"
    systemctl stop "nexus-tunnel@*" 2>/dev/null || true
    systemctl stop nexus-tunnel.service 2>/dev/null || true
    rm -f "${TEMPLATE_SERVICE}" /etc/systemd/system/nexus-tunnel.service
    rm -f "${BIN_PATH}" "${CLI_PATH}" /etc/sysctl.d/99-nexus-tunnel.conf
    rm -rf "${INSTALL_DIR}" "${CONFIG_DIR}"
    systemctl daemon-reload
    echo -e "${GREEN}[✔] پروژه به طور کامل حذف شد.${NC}"
}

main_menu() {
    while true; do
        echo -e "\n${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║     Nexus-Tunnel v6.0 — Multi-Transport Control Matrix       ║${NC}"
        echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
        echo -e "║  ${GREEN}1)${NC} نصب کامل زیرساخت، کامپایل هسته و ساخت تانل جدید         ║"
        echo -e "║  ${GREEN}2)${NC} افزودن پروفایل تانل جدید (اجرای چند تانل هم‌زمان)        ║"
        echo -e "║  ${GREEN}3)${NC} کنترل و ویرایش زنده تانل‌ها (تغییر ترنسپورت/پورت/تست)   ║"
        echo -e "║  ${GREEN}4)${NC} مدیریت تانل‌های سطح کرنل (GRE / IPIP / SIT + Iptables)  ║"
        echo -e "║  ${GREEN}5)${NC} داشبورد مانیتورینگ زنده، سوکت‌ها و لاگ‌ها               ║"
        echo -e "║  ${GREEN}6)${NC} بهینه‌سازی محاسباتی کرنل و BBR                            ║"
        echo -e "║  ${RED}7)${NC} حذف کامل کل پروژه و پاکسازی (Uninstall)                  ║"
        echo -e "║  ${YELLOW}0)${NC} خروج                                                     ║"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
        read -rp "گزینه مورد نظر را انتخاب کنید: " ch
        case "$ch" in
            1)
                apply_kernel_tuning
                if build_core; then
                    create_tunnel_profile
                    show_dashboard
                fi
                ;;
            2)
                [[ ! -x "${BIN_PATH}" ]] && build_core
                create_tunnel_profile
                show_dashboard
                ;;
            3) live_control_editor ;;
            4) kernel_tunnel_manager ;;
            5) show_dashboard ;;
            6) apply_kernel_tuning ;;
            7) uninstall_all; exit 0 ;;
            0) exit 0 ;;
            *) echo -e "${RED}[!] گزینه نامعتبر است.${NC}" ;;
        esac
    done
}

main_menu
