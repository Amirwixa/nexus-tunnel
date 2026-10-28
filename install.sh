#!/usr/bin/env bash
# ==============================================================================
# Nexus-Tunnel v5.0 — Intelligent Bootstrapper & Installer (install.sh)
# Supports Local (Offline-Ready) & Remote Installation | Auto-Cleans Legacy Files
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="/opt/nexus-tunnel"
CONFIG_DIR="/etc/nexus-tunnel"
BIN_PATH="/usr/local/bin/nexus-tunnel"
CLI_PATH="/usr/local/bin/nexus"
REPO_URL="${NEXUS_REPO_URL:-https://raw.githubusercontent.com/amirwixa/nexus-tunnel/main}"

# ۱. بررسی دسترسی Root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[✘] خطا: برای نصب نیازمند دسترسی root هستید (sudo bash install.sh).${NC}"
   exit 1
fi

echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║       Nexus-Tunnel v5.0 — Automated System Installer       ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"

# ۲. پاکسازی بقایای نسخه‌های قدیمی و شکسته (Python / Old Services)
cleanup_legacy() {
    echo -e "${YELLOW}[*] بررسی و پاکسازی سرویس‌ها یا اسکریپت‌های قدیمی...${NC}"
    systemctl stop nexus-tunnel.service 2>/dev/null || true
    systemctl stop nexus-watchdog.service 2>/dev/null || true
    pkill -f "nexus_core.py" 2>/dev/null || true
    pkill -f "watchdog.py" 2>/dev/null || true
    rm -rf "${INSTALL_DIR}/core" "${INSTALL_DIR}/watchdog" "${INSTALL_DIR}/internal" "${INSTALL_DIR}/config" 2>/dev/null || true
    echo -e "${GREEN}[✔] محیط سیستم برای نصب تمیز آماده شد.${NC}"
}

# ۳. نصب پیش‌نیازهای پایه سیستم‌عامل
install_base_deps() {
    echo -e "${YELLOW}[*] بررسی ابزارهای پایه شبکه و سیستم...${NC}"
    local missing_pkgs=()
    for cmd in curl tar ss openssl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            case "$cmd" in
                ss) missing_pkgs+=("iproute2") ;;
                *)  missing_pkgs+=("$cmd") ;;
            esac
        fi
    done

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        echo -e "${CYAN}[*] در حال نصب پکیج‌های مورد نیاز: ${missing_pkgs[*]}...${NC}"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_pkgs[@]}" ca-certificates >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y "${missing_pkgs[@]}" ca-certificates >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "${missing_pkgs[@]}" ca-certificates >/dev/null 2>&1
        fi
    fi
    echo -e "${GREEN}[✔] ابزارهای پایه سیستم آماده هستند.${NC}"
}

# ۴. بررسی و نصب کامپایلر Go (نسخه 1.20 به بالا)
install_golang() {
    if command -v go >/dev/null 2>&1; then
        local go_ver
        go_ver=$(go version | awk '{print $3}' | sed 's/go//')
        local major minor
        major=$(echo "$go_ver" | cut -d. -f1)
        minor=$(echo "$go_ver" | cut -d. -f2)
        if [[ "$major" -ge 1 && "$minor" -ge 18 ]]; then
            echo -e "${GREEN}[✔] کامپایلر Go نسخه ${go_ver} روی سیستم نصب است.${NC}"
            return 0
        fi
    fi

    echo -e "${YELLOW}[*] در حال نصب کامپایلر Go...${NC}"
    if command -v apt-get >/dev/null 2>&1 && apt-get install -y golang-go >/dev/null 2>&1; then
        echo -e "${GREEN}[✔] کامپایلر Go از طریق مخزن سیستم نصب شد.${NC}"
        return 0
    fi

    # دانلود مستقیم باینری رسمی در صورت عدم وجود در مخزن
    local arch
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) echo -e "${RED}[✘] معماری پردازنده $(uname -m) پشتیبانی نمی‌شود.${NC}"; exit 1 ;;
    esac

    local go_tar="go1.22.5.linux-${arch}.tar.gz"
    echo -e "${CYAN}[*] دانلود مستقیم ${go_tar}...${NC}"
    curl -fSL --connect-timeout 15 "https://go.dev/dl/${go_tar}" -o "/tmp/${go_tar}"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "/tmp/${go_tar}"
    ln -sf /usr/local/go/bin/go /usr/bin/go
    ln -sf /usr/local/go/bin/gofmt /usr/bin/gofmt
    rm -f "/tmp/${go_tar}"
    echo -e "${GREEN}[✔] کامپایلر Go با موفقیت نصب شد ($(go version)).${NC}"
}

# ۵. استقرار فایل‌های پروژه (لوکال یا دانلود از گیت‌هاب)
deploy_project_files() {
    mkdir -p "${INSTALL_DIR}/cmd/nexus" "${CONFIG_DIR}"

    # ساخت فایل go.mod استاندارد و بدون وابستگی خارجی
    cat > "${INSTALL_DIR}/go.mod" <<'EOF'
module nexus-tunnel

go 1.20
EOF

    # بررسی اینکه آیا فایل‌ها در پوشه فعلی وجود دارند (اجرای لوکال) یا باید دانلود شوند
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [[ -f "${script_dir}/cmd/nexus/main.go" && -f "${script_dir}/nexus.sh" ]]; then
        echo -e "${CYAN}[*] فایل‌های پروژه در مسیر لوکال شناسایی شدند؛ کپی مستقیم بدون نیاز به دانلود...${NC}"
        if [[ "${script_dir}" != "${INSTALL_DIR}" ]]; then
            cp -f "${script_dir}/cmd/nexus/main.go" "${INSTALL_DIR}/cmd/nexus/main.go"
            cp -f "${script_dir}/nexus.sh" "${INSTALL_DIR}/nexus.sh"
        fi
    else
        echo -e "${CYAN}[*] دریافت فایل‌های هسته و منوی مدیریت از مخزن...${NC}"
        curl -fSL --connect-timeout 10 "${REPO_URL}/cmd/nexus/main.go" -o "${INSTALL_DIR}/cmd/nexus/main.go"
        curl -fSL --connect-timeout 10 "${REPO_URL}/nexus.sh" -o "${INSTALL_DIR}/nexus.sh"
    fi

    chmod +x "${INSTALL_DIR}/nexus.sh"
    ln -sf "${INSTALL_DIR}/nexus.sh" "${CLI_PATH}"
    echo -e "${GREEN}[✔] فایل‌های پروژه در ${INSTALL_DIR} مستقر شدند.${NC}"
}

# ۶. کامپایل هسته Go به صورت استاتیک و آفلاین
compile_binary() {
    echo -e "${CYAN}[*] در حال کامپایل هسته بومی Go (CGO_ENABLED=0)...${NC}"
    cd "${INSTALL_DIR}"
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o "${BIN_PATH}" ./cmd/nexus/main.go
    chmod +x "${BIN_PATH}"
    echo -e "${GREEN}[✔] هسته تانل با موفقیت کامپایل و در ${BIN_PATH} نصب شد.${NC}"
}

# اجرای ترتیبی مراحل نصب
cleanup_legacy
install_base_deps
install_golang
deploy_project_files
compile_binary

echo -e "\n${GREEN}==============================================================${NC}"
echo -e "${GREEN}[✔] نصب زیرساخت Nexus-Tunnel v5.0 با موفقیت به پایان رسید!${NC}"
echo -e "    از این پس در هر جای ترمینال با دستور ${YELLOW}nexus${NC} می‌توانید وارد منو شوید."
echo -e "${GREEN}==============================================================${NC}\n"

# ورود خودکار به منوی مدیریت برای پیکربندی اولیه
exec "${CLI_PATH}"
