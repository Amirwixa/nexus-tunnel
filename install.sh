#!/usr/bin/env bash
# ==============================================================================
# Nexus-Tunnel v7.0 — Production Bootstrapper & Installer (install.sh)
# Zero-Hang Log Setup | Prebuilt Binary + Local Go Build Fallback | L3 Ready
# ==============================================================================

umask 022

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="/opt/nexus-tunnel"
CONFIG_DIR="/etc/nexus-tunnel"
LOG_DIR="/var/log/nexus-tunnel"
RUN_DIR="/run/nexus-tunnel"
BIN_PATH="/usr/local/bin/nexus-tunnel"
CLI_PATH="/usr/local/bin/nexus"
TEMPLATE_SERVICE="/etc/systemd/system/nexus-tunnel@.service"

GITHUB_REPO="${NEXUS_GITHUB_REPO:-Amirwixa/nexus-tunnel}"
RAW_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/main"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[✘] Error: Please run as root (sudo bash install.sh).${NC}"
   exit 1
fi

echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     ⚡ Nexus-Tunnel v7.0 — Unified System Installer          ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

# 1. Cleanup legacy background tasks and outdated files
cleanup_legacy() {
    echo -e "${YELLOW}[*] Cleaning legacy services and temp files...${NC}"
    systemctl stop nexus-tunnel.service 2>/dev/null || true
    systemctl disable nexus-tunnel.service 2>/dev/null || true
    systemctl stop nexus-watchdog.service 2>/dev/null || true
    pkill -f "nexus_core.py" 2>/dev/null || true
    pkill -f "watchdog.py" 2>/dev/null || true
    rm -f /etc/systemd/system/nexus-tunnel.service
    rm -rf "${INSTALL_DIR}/core" "${INSTALL_DIR}/watchdog" "${INSTALL_DIR}/internal" "${INSTALL_DIR}/config" "${INSTALL_DIR}/scripts" 2>/dev/null || true
    mkdir -p "${INSTALL_DIR}/cmd/nexus" "${CONFIG_DIR}" "${LOG_DIR}" "${RUN_DIR}"
}

# 2. Install essential system and networking dependencies
install_deps() {
    echo -e "${YELLOW}[*] Checking required system packages...${NC}"
    local pkgs=()
    for cmd in curl tar ss ip iptables openssl jq base64; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            case "$cmd" in
                ss|ip)    pkgs+=("iproute2") ;;
                iptables) pkgs+=("iptables") ;;
                base64)   pkgs+=("coreutils") ;;
                *)        pkgs+=("$cmd") ;;
            esac
        fi
    done

    if [[ ${#pkgs[@]} -gt 0 ]]; then
        echo -e "${CYAN}[*] Installing packages: ${pkgs[*]}...${NC}"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" ca-certificates >/dev/null 2>&1 || true
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y "${pkgs[@]}" ca-certificates >/dev/null 2>&1 || true
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "${pkgs[@]}" ca-certificates >/dev/null 2>&1 || true
        fi
    fi
}

# 3. Stage source and manager files
stage_files() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    cat > "${INSTALL_DIR}/go.mod" <<'EOF'
module nexus-tunnel

go 1.20
EOF
    rm -f "${INSTALL_DIR}/go.sum"

    if [[ -f "${script_dir}/cmd/nexus/main.go" && -f "${script_dir}/nexus.sh" ]]; then
        echo -e "${GREEN}[✔] Staging local source files to ${INSTALL_DIR}...${NC}"
        local src_main dst_main src_sh dst_sh
        src_main=$(realpath "${script_dir}/cmd/nexus/main.go" 2>/dev/null || echo "")
        dst_main=$(realpath "${INSTALL_DIR}/cmd/nexus/main.go" 2>/dev/null || echo "")
        if [[ -n "$src_main" && "$src_main" != "$dst_main" ]]; then
            cp -f "${script_dir}/cmd/nexus/main.go" "${INSTALL_DIR}/cmd/nexus/main.go"
        fi

        src_sh=$(realpath "${script_dir}/nexus.sh" 2>/dev/null || echo "")
        dst_sh=$(realpath "${INSTALL_DIR}/nexus.sh" 2>/dev/null || echo "")
        if [[ -n "$src_sh" && "$src_sh" != "$dst_sh" ]]; then
            cp -f "${script_dir}/nexus.sh" "${INSTALL_DIR}/nexus.sh"
        fi
    else
        echo -e "${CYAN}[*] Fetching latest components from GitHub (${GITHUB_REPO})...${NC}"
        curl -fSL --connect-timeout 10 "${RAW_URL}/cmd/nexus/main.go" -o "${INSTALL_DIR}/cmd/nexus/main.go" 2>/dev/null
        curl -fSL --connect-timeout 10 "${RAW_URL}/nexus.sh" -o "${INSTALL_DIR}/nexus.sh" 2>/dev/null
    fi

    chmod +x "${INSTALL_DIR}/nexus.sh"
    ln -sf "${INSTALL_DIR}/nexus.sh" "${CLI_PATH}"
}

# 4. Install precompiled binary or build locally
install_or_build_binary() {
    local arch="amd64"
    [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]] && arch="arm64"

    local release_url="https://github.com/${GITHUB_REPO}/releases/latest/download/nexus-tunnel-linux-${arch}"
    if curl -fSL --connect-timeout 6 "$release_url" -o "${BIN_PATH}" 2>/dev/null; then
        chmod +x "${BIN_PATH}"
        echo -e "${GREEN}[✔] Official precompiled kernel binary installed at ${BIN_PATH}.${NC}"
        return 0
    fi

    echo -e "${YELLOW}[*] Precompiled binary not found on release endpoint; compiling natively...${NC}"
    if ! command -v go >/dev/null 2>&1; then
        echo -e "${CYAN}[*] Installing Go compiler toolchain...${NC}"
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

    echo -e "${CYAN}[*] Compiling offline Nexus-Tunnel v7.0 kernel...${NC}"
    if (cd "${INSTALL_DIR}" && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o "${BIN_PATH}" ./cmd/nexus/main.go); then
        chmod +x "${BIN_PATH}"
        echo -e "${GREEN}[✔] Native kernel binary successfully built at ${BIN_PATH}.${NC}"
    else
        echo -e "${RED}[✘] Build failed! Please verify internet connectivity or Go compiler.${NC}"
        exit 1
    fi
}

# 5. Register Multi-Profile Systemd Template
register_systemd_template() {
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
    echo -e "${GREEN}[✔] Systemd service template nexus-tunnel@.service registered.${NC}"
}

cleanup_legacy
install_deps
stage_files
install_or_build_binary
register_systemd_template

echo -e "\n${GREEN}================================================================${NC}"
echo -e "${GREEN}[✔] Nexus-Tunnel v7.0 Installation Complete! CLI Command: ${YELLOW}nexus${NC}"
echo -e "${GREEN}================================================================${NC}\n"

exec "${CLI_PATH}"
