# ⚡ Nexus Tunnel Suite v6.0

**Universal Anti-Censorship Reverse Tunnel Manager (Backhaul + WatTunnel + WaterWall + Gemini AI)**

Nexus Tunnel is a carrier-grade cross-border tunneling suite designed specifically to bypass sophisticated Deep Packet Inspection (DPI), connection resets, and traffic shaping between Iran and foreign servers.

It harmonizes the world's most resilient tunneling engines (**Backhaul v0.7.2**, **WatTunnel v3.1.1**, **WaterWall v1.5.2**) under a single unified, intelligent interactive CLI/TUI powered by **Google Gemini AI**.

---

## 🚀 One-Line Installation

On both your **Iran** and **Kharej** servers, run as `root`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Amirwixa/nexus-tunnel/main/install.sh)
```

Or clone the repository and run:
```bash
sudo bash install.sh
```

Once installed, reopen the management interface anytime by typing:
```bash
nexus
```

---

## 🌟 Key Capabilities

- **Autonomous AI Setup**: Powered by an embedded Gemini AI agent with hardcoded credentials (zero prompting). Measures jitter, latency, and packet loss to automatically choose the optimal carrier (`wsmux`, `tcpmux`, `wssmux`) and launch background `systemd` daemons.
- **Granular Port Forwarding Manager**: Add, edit, or delete forwarding rules (e.g., `443=127.0.0.1:443`, `80=127.0.0.1:80`, `8443=127.0.0.1:8443`, `2083=127.0.0.1:2083`) with instant hot-reloads.
- **Multi-Engine Switching**: Seamlessly toggle between:
  1. **Backhaul Core (v0.7.2)** (High-concurrency Go reverse multiplexer)
  2. **WatTunnel Core (v3.1.1)** (Anti-censorship Swiss Army knife with ICMP/Fake-SNI/desync)
  3. **WaterWall Core (v1.5.2)** (Modular low-overhead C++ networking pipeline)
- **Extensive Transport Protocols**:
  - `tcpmux` (Smux over TCP)
  - `wsmux` (Multiplexed WebSocket)
  - `wssmux` (Multiplexed TLS 1.3 WebSocket)
  - `ws` / `wss` (Standard WebSockets)
  - `tcp` (Direct TCP connection pool)
  - `grpc` (HTTP/2 framing)
  - `icmp` (Ping tunnel for national intranet shutdowns)
- **Gemini AI Doctor & Healer**: Probes journal logs, network drops, and DPI resets. Explains root causes in clear Persian and offers 1-click self-healing.
- **Linux Kernel & BBR Optimizer**: Tunes `fq + bbr`, socket memory buffers up to 64MB, and raises file descriptor limits to 1,048,576.

---

## 📖 Persian Documentation
For complete Persian instructions, please refer to [README_FA.md](README_FA.md).

---

## 📄 License
MIT License.
