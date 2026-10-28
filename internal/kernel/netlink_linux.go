package kernel

import (
	"fmt"
	"net"
	"os/exec"
	"strings"
	"sync/atomic"
	"time"

	log "github.com/sirupsen/logrus"
	"golang.org/x/sys/unix"
)

type Telemetry struct {
	ActiveStreams     int64  `json:"active_streams"`
	HandshakeFailures uint64 `json:"handshake_failures"`
	TotalRetransmits  uint64 `json:"total_retransmits"`
	KernelRTTMicros   uint32 `json:"kernel_rtt_us"`
	KernelJitterUs    uint32 `json:"kernel_jitter_us"`
	PathMTU           uint32 `json:"path_mtu"`
	CurrentSNI        string `json:"current_sni"`
	CurrentFrameSize  int    `json:"current_frame_size"`
	CurrentMSSClamp   int    `json:"current_mss_clamp"`
	LastError         string `json:"last_error"`
}

var GlobalMetrics struct {
	ActiveStreams     int64
	HandshakeFailures uint64
	TotalRetransmits  uint64
	LastRTTUs         uint32
	LastJitterUs      uint32
	LastPMTU          uint32
}

func InspectSocketKernel(conn net.Conn) {
	tcpConn, ok := conn.(*net.TCPConn)
	if !ok {
		return
	}
	raw, err := tcpConn.SyscallConn()
	if err != nil {
		return
	}
	_ = raw.Control(func(fd uintptr) {
		info, err := unix.GetsockoptTCPInfo(int(fd), unix.IPPROTO_TCP, unix.TCP_INFO)
		if err == nil && info != nil {
			atomic.StoreUint32(&GlobalMetrics.LastRTTUs, info.Rtt)
			atomic.StoreUint32(&GlobalMetrics.LastJitterUs, info.Rttvar)
			atomic.StoreUint32(&GlobalMetrics.LastPMTU, info.Pmtu)
			atomic.AddUint64(&GlobalMetrics.TotalRetransmits, uint64(info.Total_retrans))
		}
	})
}

func ApplyKernelHardening(mssClamp int) {
	sysctls := map[string]string{
		"net.core.default_qdisc":               "fq",
		"net.ipv4.tcp_congestion_control":      "bbr",
		"net.ipv4.ip_forward":                  "1",
		"net.ipv4.conf.all.route_localnet":     "1",
		"net.ipv4.conf.default.route_localnet": "1",
		"net.ipv4.tcp_fastopen":                "3",
		"net.ipv4.tcp_slow_start_after_idle":   "0",
		"net.ipv4.tcp_mtu_probing":             "1",
		"net.core.rmem_max":                    "67108864",
		"net.core.wmem_max":                    "67108864",
		"net.core.netdev_max_backlog":          "250000",
		"net.core.somaxconn":                   "65535",
		"net.ipv4.tcp_max_syn_backlog":         "65535",
		"net.ipv4.tcp_tw_reuse":                "1",
		"net.ipv4.tcp_fin_timeout":             "15",
		"net.ipv4.tcp_rmem":                    "4096 87380 67108864",
		"net.ipv4.tcp_wmem":                    "4096 65536 67108864",
		"fs.file-max":                          "2097152",
	}

	for k, v := range sysctls {
		_ = exec.Command("sysctl", "-w", fmt.Sprintf("%s=%s", k, v)).Run()
	}

	if mssClamp >= 1200 && mssClamp <= 1460 {
		_ = exec.Command("iptables", "-t", "mangle", "-D", "FORWARD", "-p", "tcp", "--tcp-flags", "SYN,RST", "SYN", "-j", "TCPMSS", "--set-mss", fmt.Sprintf("%d", mssClamp)).Run()
		_ = exec.Command("iptables", "-t", "mangle", "-A", "FORWARD", "-p", "tcp", "--tcp-flags", "SYN,RST", "SYN", "-j", "TCPMSS", "--set-mss", fmt.Sprintf("%d", mssClamp)).Run()
		_ = exec.Command("iptables", "-t", "mangle", "-D", "OUTPUT", "-p", "tcp", "--tcp-flags", "SYN,RST", "SYN", "-j", "TCPMSS", "--set-mss", fmt.Sprintf("%d", mssClamp)).Run()
		_ = exec.Command("iptables", "-t", "mangle", "-A", "OUTPUT", "-p", "tcp", "--tcp-flags", "SYN,RST", "SYN", "-j", "TCPMSS", "--set-mss", fmt.Sprintf("%d", mssClamp)).Run()
		log.Infof("[Kernel-Engine] High-concurrency stack applied: BBR, somaxconn=65535, TCPMSS Clamping=%d bytes", mssClamp)
	}
}

func RunNetworkDiagnostics(remoteAddr string) string {
	var b strings.Builder
	b.WriteString("=== Linux Kernel & Network Diagnostics ===\n")

	cc, err := exec.Command("sysctl", "-n", "net.ipv4.tcp_congestion_control").Output()
	if err == nil {
		b.WriteString(fmt.Sprintf("TCP Congestion Control: %s", string(cc)))
	}

	rln, err := exec.Command("sysctl", "-n", "net.ipv4.conf.all.route_localnet").Output()
	if err == nil {
		b.WriteString(fmt.Sprintf("route_localnet: %s", string(rln)))
	}

	smx, err := exec.Command("sysctl", "-n", "net.core.somaxconn").Output()
	if err == nil {
		b.WriteString(fmt.Sprintf("somaxconn (Max backlog): %s", string(smx)))
	}

	if remoteAddr != "" {
		host, _, err := net.SplitHostPort(remoteAddr)
		if err != nil {
			host = remoteAddr
		}
		b.WriteString(fmt.Sprintf("\nTarget Host: %s\n", host))

		start := time.Now()
		c, err := net.DialTimeout("tcp", remoteAddr, 3*time.Second)
		if err != nil {
			b.WriteString(fmt.Sprintf("TCP Connect to %s: FAILED (%v)\n", remoteAddr, err))
		} else {
			duration := time.Since(start)
			_ = c.Close()
			b.WriteString(fmt.Sprintf("TCP Connect to %s: SUCCESS (Latency: %v)\n", remoteAddr, duration))
		}
	}

	return b.String()
}
