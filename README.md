# ⚡ Nexus-Tunnel v7.0

[![Go Version](https://img.shields.io/badge/Go-1.20%2B-blue?logo=go)](https://go.dev/)
[![Platform](https://img.shields.io/badge/Platform-Linux%20(amd64%20%7C%20arm64)-orange?logo=linux)](https://github.com/Amirwixa/nexus-tunnel)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Zero Dependencies](https://img.shields.io/badge/Dependencies-Standard%20Library%20Only-brightgreen)](#)

**Unified Anti-Censorship Reverse Tunnel & AI Orchestration Suite**

Nexus-Tunnel v7.0 is a carrier-grade cross-border tunneling matrix engineered specifically to defeat sophisticated Deep Packet Inspection (DPI), connection resets, and traffic shaping between Iran and foreign servers.

It harmonizes the world's most resilient tunneling methodologies (**Backhaul**, **WaterWall**, **WatTunnel**, **BackPack**) into a single, high-performance, native Go kernel with **Google Gemini AI** autonomous orchestration.

```
                      ┌───────────────────────────────────────────────┐
                      │              Google Gemini AI                 │
                      │   (Link Diagnostics, Evasion & Healing)       │
                      └──────────────────────▲────────────────────────┘
                                             │
      ┌──────────────────────────────────────┴──────────────────────────────────────┐
      │                                                                             │
┌─────┴──────────────────┐      Encrypted Multi-Carrier Bridge       ┌──────────────▼─────────┐
│     🇮🇷 IRAN NODE       │ ◄───────────────────────────────────────► │    🌍 KHAREJ NODE      │
│  (Relay / Entrypoint)  │      • WSS-MUX / REALITY / DNS-Shape      │  (Xray / VLESS Core)   │
│                        │      • TLS ClientHello Fragmentation      │                        │
│ Listening: 443, 80     │      • XOR Masking & Random Padding       │ Inbound: 127.0.0.1:443 │
└─────▲──────────────────┘      • Raw Socket NOTRACK Bypass          └────────────────────────┘
      │
┌─────┴──────────────────┐
│  📱 User Client Apps   │
│ (v2rayN, Clash, etc.)  │
└────────────────────────┘
```

---

## 🚀 One-Line Installation

On both your **Iran** and **Kharej** servers, run as `root`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Amirwixa/nexus-tunnel/main/install.sh)
```

Once installed, access the interactive manager anytime by running:
```bash
nexus
```

---

## ⚡ 2-Step Autonomous AI Pairing Handshake

Connecting your servers takes less than 30 seconds:

### Step 1: On the Iran Server
1. Run `nexus` and select **Option 1**: `🇮🇷 Initialize Iran Node (Generate AI Pairing Key)`.
2. Enter your desired bridge port (default: `4443`) and client ports to forward (default: `443, 80`).
3. The standby daemon is started under `systemd`, and a compact pairing token is displayed:
   ```
   NEXUS://eyJpcCI6IjE5OC41MS4xMDAuMSIsInBvcnQiOjQ0NDMsInRva2VuIjoiNzlmZzg1...
   ```

### Step 2: On the Kharej Server
1. Run `nexus` and select **Option 2**: `🌍 Connect Kharej Node (Paste Key & AI Auto-Setup)`.
2. Paste the `NEXUS://...` token when prompted.
3. If a Gemini API Key is provided (optional), the embedded AI link specialist analyzes latency, MTU, and DPI resistance to automatically recommend the optimal carrier (`wssmux` + TLS Fragmentation).
4. The background reverse service is launched, verified with an immediate end-to-end ping, and confirmed active!

---

## 📱 Connecting Your VPN Clients (VLESS / VMess / Trojan)

Once the tunnel is established:
1. In your client configuration (v2rayN, v2rayNG, Streisand, Nekoray, Clash, etc.), change the **Server Address (Host/IP)** to your **Iran Server Public IP**.
2. Keep your UUID, Path, and Port as configured on your Kharej inbound.
3. Your client connects to the Iran relay, and all traffic is forwarded through the encrypted, obfuscated reverse tunnel to Kharej.

---

## 🌟 Key Capabilities

### 1. 14 Carrier Transports
- **`wssmux`**: WebSocket multiplexing wrapped in TLS 1.3 (Highest DPI resistance).
- **`wsmux`**: High-concurrency HTTP/1.1 WebSocket multiplexing (Backhaul style).
- **`reality`**: Active Probing Camouflage: Diverts censorship probes to authentic host SNIs.
- **`tlsmux` / `tls`**: Direct TLS 1.3 tunnels with fake SNI and ALPN negotiation.
- **`short-https`**: HTTP/1.1 chunked POST stream mimicking legitimate web browsing.
- **`h2c`**: HTTP/2 cleartext naive framing.
- **`dnsshape`**: Binary stream encapsulated inside standard DNS query/response structures.
- **`tcp` / `tcpmux`**: Raw TCP connection pools with HMAC-SHA256 authentication.
- **`udp`**: Full two-way UDP datagram tunneling for VoIP and gaming.

### 2. Multi-Layer DPI Evasion
- **TLS ClientHello Fragmentation**: Splits initial TLS handshake packets across random byte boundaries with millisecond jitter to prevent SNI filtering.
- **XOR Stream Obfuscation**: Mask stream headers using session keys to eliminate protocol fingerprints.
- **Random Length Padding**: Injects variable chaff packets to defeat machine learning traffic analysis.

### 3. High-Performance L3 Kernel Tunnels
- Native Linux kernel tunneling: **GRE**, **IPIP**, **SIT (6to4)**, and **VXLAN (UDP 4789)**.
- **Automatic TCP MSS Clamping**: Clamps MSS to PMTU to prevent packet fragmentation inside tunnels.
- **Raw Socket NOTRACK Accelerator**: Exempts bridge traffic from Linux `nf_conntrack` overhead for maximum throughput.

### 4. Zero-Hang Logging Architecture
- Unlike conventional tools that hang when querying heavy systemd journals, Nexus-Tunnel writes to lightweight **2MB ring-buffer file logs** (`/var/log/nexus-tunnel/*.log`) and updates live telemetry in memory (`/run/nexus-tunnel/*.status.json`) in under 1 millisecond.

### 5. Multi-Path Bonding & Failover
- Specify comma-separated bridge destinations (e.g. `198.51.100.1:4443, 198.51.100.1:8443`) for round-robin load distribution and instant link failover.

### 6. Gemini AI Doctor & Healer
- Autonomous diagnostic agent that inspects listening sockets, service logs, network drop rates, and firewall rules to provide root-cause explanations and 1-click self-healing.

---

## 🛠️ Interactive Menu Overview

```
╔══════════════════════════════════════════════════════════════════╗
║     ⚡ Nexus-Tunnel v7.0 — Unified Carrier Tunnel Suite         ║
║     Backhaul + WaterWall + WatTunnel + BackPack + Gemini AI      ║
╠══════════════════════════════════════════════════════════════════╣
║  1) 🇮🇷 Initialize Iran Node (Generate AI Pairing Key)            ║
║  2) 🌍 Connect Kharej Node (Paste Key & AI Auto-Setup)          ║
║  3) 🛠️  Manual Node / Tunnel Profile Wizard                       ║
║  4) ⚡ Live Telemetry & Control Panel (Hot-Reload / Ping)         ║
║  5) 🛡️  L3 Kernel Tunnels (GRE/IPIP/SIT/VXLAN + MSS + NOTRACK)    ║
║  6) 🧠 Gemini AI Doctor & Network Healer                          ║
║  7) 🚀 Linux Kernel & BBR Performance Optimizer                   ║
║  8) 🗑️  Complete Uninstall & Network Reset                        ║
║  0) Exit                                                         ║
╚══════════════════════════════════════════════════════════════════╝
```

---

## 🔒 Privacy & Zero Personal Data Guarantee

- **Zero Hardcoded Secrets**: No server IPs, passwords, private tokens, or credentials are hardcoded into the codebase.
- **Local Persistence**: User configurations are stored strictly on the user's servers under `/etc/nexus-tunnel/` with restricted `0600` permissions.
- **No Telemetry**: No third-party analytical tracking or centralized logging.

---

## 📄 License

Distributed under the [MIT License](LICENSE).
