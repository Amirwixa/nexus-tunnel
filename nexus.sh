#!/usr/bin/env bash
# ==============================================================================
# Nexus-Tunnel v5.0 — Production-Grade Server-to-Server Tunnel Manager
# Zero Hardcoded IPs | Dynamic Kernel Math | Zero-Dependency Go Core
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="/opt/nexus-tunnel"
CONFIG_DIR="/etc/nexus-tunnel"
CONFIG_FILE="${CONFIG_DIR}/config.json"
BIN_PATH="/usr/local/bin/nexus-tunnel"
SERVICE_FILE="/etc/systemd/system/nexus-tunnel.service"

# بررسی دسترسی روت
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[✘] خطا: این اسکریپت باید با دسترسی root اجرا شود (sudo bash nexus.sh).${NC}"
   exit 1
fi

# تشخیص خودکار مشخصات سخت‌افزاری و شبکه سرور فعلی
detect_server_specs() {
    PUBLIC_IP=$(curl -s4m 4 https://icanhazip.com || curl -s4m 4 https://api.ipify.org || hostname -I | awk '{print $1}')
    DEFAULT_IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    CPU_CORES=$(nproc 2>/dev/null || echo 2)
}

# اعتبارسنجی دقیق آدرس IPv4
validate_ip() {
    local ip=$1
    local stat=1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
        stat=$?
    fi
    return $stat
}

# اعتبارسنجی شماره پورت
validate_port() {
    local port=$1
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    fi
    return 1
}

# بررسی اشغال نبودن پورت روی سرور
is_port_occupied() {
    local port=$1
    if ss -tulpn | grep -qE ":${port}\b"; then
        return 0 # اشغال است
    fi
    return 1 # آزاد است
}

# محاسبه و اعمال تنظیمات کرنل بر اساس مقدار واقعی RAM و هسته‌های پردازنده
apply_calculated_kernel_tuning() {
    detect_server_specs
    echo -e "${CYAN}[*] در حال محاسبه پارامترهای شبکه کرنل بر اساس سخت‌افزار سرور شما...${NC}"
    echo -e "    - حافظه رم: ${TOTAL_RAM_MB} MB | هسته پردازنده: ${CPU_CORES} | کارت شبکه: ${DEFAULT_IFACE:-eth0}"

    # محاسبه سقف بافر TCP بر اساس رم سرور
    local max_buf=16777216 # 16MB برای سرورهای زیر 2 گیگ
    if [ "$TOTAL_RAM_MB" -ge 8192 ]; then
        max_buf=67108864   # 64MB برای سرورهای 8 گیگ به بالا
    elif [ "$TOTAL_RAM_MB" -ge 4096 ]; then
        max_buf=33554432   # 32MB برای سرورهای 4 گیگ
    fi

    local somaxconn=$(( CPU_CORES * 16384 ))
    [ "$somaxconn" -gt 65535 ] && somaxconn=65535

    cat > /etc/sysctl.d/99-nexus-tunnel.conf <<EOF
# Calculated Kernel Parameters by Nexus-Tunnel v5.0
fs.file-max = 2097152
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = ${somaxconn}
net.core.netdev_max_backlog = ${somaxconn}
net.core.rmem_max = ${max_buf}
net.core.wmem_max = ${max_buf}
net.ipv4.tcp_rmem = 4096 87380 ${max_buf}
net.ipv4.tcp_wmem = 4096 65536 ${max_buf}
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.ip_local_port_range = 1024 65535
EOF

    sysctl --system >/dev/null 2>&1 || true
    echo -e "${GREEN}[✔] بهینه‌سازی کرنل (BBR + Dynamic Buffers: $((max_buf / 1048576))MB) با موفقیت اعمال شد.${NC}"
}

# نصب کامپایلر Go در صورت عدم وجود
ensure_golang() {
    if command -v go >/dev/null 2>&1; then
        local ver
        ver=$(go version | awk '{print $3}')
        echo -e "${GREEN}[✔] کامپایلر Go موجود است (${ver}).${NC}"
        return 0
    fi

    echo -e "${YELLOW}[*] در حال نصب کامپایلر Go...${NC}"
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y curl tar git golang-go >/dev/null 2>&1 || {
        # دانلود مستقیم در صورت قدیمی بودن مخازن apt
        local arch="amd64"
        [[ "$(uname -m)" == "aarch64" ]] && arch="arm64"
        curl -L "https://go.dev/dl/go1.22.5.linux-${arch}.tar.gz" -o /tmp/go.tar.gz
        rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tar.gz
        ln -sf /usr/local/go/bin/go /usr/bin/go
        rm -f /tmp/go.tar.gz
    }
    echo -e "${GREEN}[✔] کامپایلر Go با موفقیت نصب شد.${NC}"
}

# کامپایل هسته تانل بدون هیچ وابستگی خارجی
build_core() {
    ensure_golang
    mkdir -p "${INSTALL_DIR}/cmd/nexus"

    cat > "${INSTALL_DIR}/go.mod" <<'EOF'
module nexus-tunnel

go 1.20
EOF

    # بررسی وجود فایل main.go در مسیر فعلی یا ساخت آن
    if [[ -f "./cmd/nexus/main.go" ]]; then
        cp -f "./cmd/nexus/main.go" "${INSTALL_DIR}/cmd/nexus/main.go"
    fi

    if [[ ! -f "${INSTALL_DIR}/cmd/nexus/main.go" ]]; then
        echo -e "${RED}[✘] فایل cmd/nexus/main.go یافت نشد! لطفاً فایل main.go را در پوشه cmd/nexus قرار دهید.${NC}"
        exit 1
    fi

    echo -e "${CYAN}[*] در حال کامپایل هسته بومی Go (بدون نیاز به اینترنت)...${NC}"
    cd "${INSTALL_DIR}"
    CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o "${BIN_PATH}" ./cmd/nexus/main.go
    chmod +x "${BIN_PATH}"
    echo -e "${GREEN}[✔] باینری هسته با موفقیت در ${BIN_PATH} کامپایل شد.${NC}"
}

# ویزارد تعاملی و هوشمند تنظیمات (بدون مقادیر پیش‌فرض هاردکد شده)
configure_tunnel() {
    detect_server_specs
    mkdir -p "${CONFIG_DIR}"

    echo -e "\n${CYAN}======================================================${NC}"
    echo -e "${CYAN}       پیکربندی مهندسی‌شده تانل سرور به سرور          ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo -e "آی‌پی شناسایی‌شده این سرور: ${YELLOW}${PUBLIC_IP}${NC}\n"

    # ۱. انتخاب نقش سرور
    local role=""
    while true; do
        echo -e "نقش این سرور چیست؟"
        echo -e "  ${GREEN}1)${NC} سرور ایران (Iran - دریافت‌کننده ترافیک کاربران)"
        echo -e "  ${GREEN}2)${NC} سرور خارج (Kharej - سرور مقصد / پنل Xray)"
        read -rp "انتخاب شما [1-2]: " role_choice
        case "$role_choice" in
            1) role="iran"; break ;;
            2) role="kharej"; break ;;
            *) echo -e "${RED}[!] لطفاً فقط عدد 1 یا 2 را وارد کنید.${NC}" ;;
        esac
    done

    # ۲. انتخاب معماری تانل
    local mode=""
    while true; do
        echo -e "\nمعماری تانل را انتخاب کنید:"
        echo -e "  ${GREEN}1)${NC} Reverse (تانل معکوس - پیشنهادی: اتصال از خارج به ایران بدون ارتباط خروجی از ایران)"
        echo -e "  ${GREEN}2)${NC} Direct  (تانل مستقیم: اتصال مستقیم از ایران به خارج)"
        read -rp "انتخاب شما [1-2]: " mode_choice
        case "$mode_choice" in
            1) mode="reverse"; break ;;
            2) mode="direct"; break ;;
            *) echo -e "${RED}[!] لطفاً فقط عدد 1 یا 2 را وارد کنید.${NC}" ;;
        esac
    done

    # ۳. دریافت IP و پورت پل ارتباطی (Bridge)
    local bridge_addr=""
    local bridge_port=""
    local remote_ip=""

    if [[ "$ (echo "$mode-$role")" == "reverse-iran" ]] || [[ "$ (echo "$mode-$role")" == "direct-kharej" ]]; then
        while true; do
            read -rp $'\nپورت پل ارتباطی (Bridge Port) بین دو سرور را وارد کنید (مثال: 4443): ' bridge_port
            if ! validate_port "$bridge_port"; then
                echo -e "${RED}[!] شماره پورت نامعتبر است (باید بین 1 تا 65535 باشد).${NC}"
                continue
            fi
            if is_port_occupied "$bridge_port"; then
                echo -e "${YELLOW}[!] هشدار: پورت ${bridge_port} در حال حاضر توسط سرویس دیگری اشغال است!${NC}"
                read -rp "آیا مطمئن هستید که می‌خواهید از همین پورت استفاده کنید؟ [y/N]: " confirm_p
                [[ "$confirm_p" =~ ^[Yy]$ ]] || continue
            fi
            bridge_addr="0.0.0.0:${bridge_port}"
            break
        done
    else
        local target_label="ایران"
        [[ "$role" == "iran" ]] && target_label="خارج"
        while true; do
            read -rp $'\nآدرس IPv4 سرور '"${target_label}"$' را وارد کنید: ' remote_ip
            if validate_ip "$remote_ip"; then
                break
            else
                echo -e "${RED}[!] فرمت آدرس IP وارد شده معتبر نیست! دوباره تلاش کنید.${NC}"
            fi
        done

        while true; do
            read -rp "پورت پل ارتباطی (Bridge Port) که روی سرور مقابل تنظیم کرده‌اید: " bridge_port
            if validate_port "$bridge_port"; then
                bridge_addr="${remote_ip}:${bridge_port}"
                break
            else
                echo -e "${RED}[!] شماره پورت نامعتبر است.${NC}"
            fi
        done
    fi

    # ۴. توکن امنیتی مشترک (HMAC Token)
    local token=""
    echo -e "\n${CYAN}[*] توکن امنیتی (PSK) باید در هر دو سرور ایران و خارج یکسان باشد.${NC}"
    local auto_token
    auto_token=$(head -c 16 /dev/urandom | xxd -p 2>/dev/null || openssl rand -hex 16)
    read -rp "توکن امنیتی را وارد کنید (برای استفاده از توکن تصادفی [${auto_token}] کلید Enter را بزنید): " input_token
    token="${input_token:-$auto_token}"

    # ۵. دامنه پوششی TLS (SNI)
    read -rp $'\nدامنه SNI برای هدر TLS 1.3 (پیش‌فرض با Enter: www.cloudflare.com): ' input_sni
    local sni="${input_sni:-www.cloudflare.com}"

    # ۶. تعداد کانال‌های هم‌زمان (Pool Size)
    local default_pool=$(( CPU_CORES * 8 ))
    [ "$default_pool" -lt 16 ] && default_pool=16
    read -rp "تعداد کانال‌های آماده در استخر اتصال (پیشنهاد محاسبه‌شده برای CPU شما [${default_pool}]): " input_pool
    local pool_size="${input_pool:-$default_pool}"

    # ۷. پورت‌های فورواردینگ (فقط روی سرور ایران نیاز به تعریف دارد)
    local ports_json="[]"
    if [[ "$role" == "iran" ]]; then
        echo -e "\n${CYAN}[*] پورت‌هایی که می‌خواهید از ایران به خارج تانل شوند را با کاما جدا کنید.${NC}"
        echo -e "    مثال ۱ (پورت یکسان): ${YELLOW}443, 2053, 8443${NC}"
        echo -e "    مثال ۲ (پورت متفاوت): ${YELLOW}443:443, 8080:2083${NC}"
        while true; do
            read -rp "لیست پورت‌ها: " raw_ports
            if [[ -z "$raw_ports" ]]; then
                echo -e "${RED}[!] حداقل یک پورت باید وارد شود.${NC}"
                continue
            fi
            # تبدیل به آرایه JSON
            IFS=',' read -ra ADDR <<< "$raw_ports"
            local json_items=()
            local valid_all=true
            for item in "${ADDR[@]}"; do
                item=$(echo "$item" | xargs)
                local p_check="${item%%:*}"
                if ! validate_port "$p_check"; then
                    echo -e "${RED}[!] پورت '${item}' معتبر نیست!${NC}"
                    valid_all=false
                    break
                fi
                json_items+=("\"${item}\"")
            done
            if $valid_all; then
                ports_json="[$(IFS=,; echo "${json_items[*]}")]"
                break
            fi
        done
    fi

    # ذخیره فایل کانفیگ استاندارد JSON
    cat > "${CONFIG_FILE}" <<EOF
{
  "role": "${role}",
  "mode": "${mode}",
  "bridge_addr": "${bridge_addr}",
  "token": "${token}",
  "sni": "${sni}",
  "pool_size": ${pool_size},
  "ports": ${ports_json}
}
EOF

    echo -e "\n${GREEN}[✔] فایل کانفیگ با موفقیت در ${CONFIG_FILE} ساخته شد:${NC}"
    echo -e "    - نقش سرور: ${YELLOW}${role}${NC}"
    echo -e "    - مد تانل:  ${YELLOW}${mode}${NC}"
    echo -e "    - آدرس پل:  ${YELLOW}${bridge_addr}${NC}"
    echo -e "    - توکن:     ${YELLOW}${token}${NC} (این توکن را در سرور مقابل وارد کنید)"
}

# ایجاد و فعال‌سازی سرویس Systemd
setup_systemd() {
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Nexus-Tunnel v5.0 High-Performance Server-to-Server Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${BIN_PATH} -c ${CONFIG_FILE}
Restart=always
RestartSec=2
LimitNOFILE=1048576
LimitNPROC=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable nexus-tunnel.service >/dev/null 2>&1
    systemctl restart nexus-tunnel.service
    echo -e "${GREEN}[✔] سرویس nexus-tunnel فعال و اجرا شد.${NC}"
}

# نمایش داشبورد وضعیت زنده
show_status() {
    echo -e "\n${CYAN}================ وضعیت سرویس Nexus-Tunnel ================${NC}"
    if systemctl is-active --quiet nexus-tunnel; then
        echo -e "وضعیت سرویس: ${GREEN}● فعال (Running)${NC}"
    else
        echo -e "وضعیت سرویس: ${RED}● متوقف (Stopped/Failed)${NC}"
    fi

    if [[ -f "${CONFIG_FILE}" ]]; then
        echo -e "\n${YELLOW}--- تنظیمات فعلی (${CONFIG_FILE}) ---${NC}"
        cat "${CONFIG_FILE}"
    fi

    echo -e "\n${YELLOW}--- پورت‌های در حال شنود (Listening Sockets) ---${NC}"
    ss -tulpn | grep "nexus-tunnel" || echo "هیچ پورتی در حال شنود یافت نشد."

    echo -e "\n${YELLOW}--- تعداد کانکشن‌های فعال تانل (ESTABLISHED) ---${NC}"
    local est_count
    est_count=$(ss -tnp | grep "nexus-tunnel" | grep -c "ESTAB" || true)
    echo -e "تعداد کانال‌های برقرار: ${GREEN}${est_count}${NC}"

    echo -e "\n${YELLOW}--- ۱۰ خط آخر لاگ سرویس ---${NC}"
    journalctl -u nexus-tunnel -n 10 --no-pager
}

# حذف کامل تانل و پاکسازی فایل‌های قبلی
uninstall_all() {
    echo -e "${YELLOW}[*] در حال توقف و حذف کامل Nexus-Tunnel...${NC}"
    systemctl stop nexus-tunnel.service 2>/dev/null || true
    systemctl disable nexus-tunnel.service 2>/dev/null || true
    rm -f "${SERVICE_FILE}" "${BIN_PATH}" /etc/sysctl.d/99-nexus-tunnel.conf
    rm -rf "${INSTALL_DIR}" "${CONFIG_DIR}"
    systemctl daemon-reload
    echo -e "${GREEN}[✔] تمامی فایل‌ها، سرویس‌ها و تنظیمات با موفقیت پاک شدند.${NC}"
}

# منوی اصلی
main_menu() {
    while true; do
        echo -e "\n${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║         Nexus-Tunnel v5.0 — Enterprise Manager         ║${NC}"
        echo -e "${CYAN}╠════════════════════════════════════════════════════════╣${NC}"
        echo -e "║  ${GREEN}1)${NC} نصب کامل، کامپایل هسته و پیکربندی تانل جدید        ║"
        echo -e "║  ${GREEN}2)${NC} تغییر تنظیمات تانل (IP / پورت‌ها / توکن)           ║"
        echo -e "║  ${GREEN}3)${NC} مشاهده وضعیت زنده، پورت‌ها و لاگ تانل              ║"
        echo -e "║  ${GREEN}4)${NC} ری‌استارت سرویس تانل                               ║"
        echo -e "║  ${GREEN}5)${NC} بهینه‌سازی محاسباتی کرنل و BBR                      ║"
        echo -e "║  ${RED}6)${NC} حذف کامل تانل و پاکسازی (Uninstall)                ║"
        echo -e "║  ${YELLOW}0)${NC} خروج                                               ║"
        echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
        read -rp "گزینه مورد نظر را انتخاب کنید: " opt
        case "$opt" in
            1)
                apply_calculated_kernel_tuning
                build_core
                configure_tunnel
                setup_systemd
                show_status
                ;;
            2)
                configure_tunnel
                systemctl restart nexus-tunnel.service
                show_status
                ;;
            3) show_status ;;
            4)
                systemctl restart nexus-tunnel.service
                echo -e "${GREEN}[✔] سرویس ری‌استارت شد.${NC}"
                show_status
                ;;
            5) apply_calculated_kernel_tuning ;;
            6) uninstall_all ;;
            0) exit 0 ;;
            *) echo -e "${RED}[!] گزینه نامعتبر است.${NC}" ;;
        esac
    done
}

main_menu
