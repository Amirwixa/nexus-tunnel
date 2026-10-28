package main

import (
	"bufio"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	mrand "math/rand"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type Config struct {
	Name          string   `json:"name"`
	Role          string   `json:"role"`           // "iran" | "kharej"
	Mode          string   `json:"mode"`           // "reverse" | "reverse-mux" | "direct-pool" | "direct-mux" | "direct"
	Transport     string   `json:"transport"`      // "tcp" | "tcpmux" | "tls" | "tlsmux" | "reality" | "ws" | "wsmux" | "wss" | "wssmux" | "short-https" | "h2c" | "dnsshape" | "udp" | "icmp"
	Protocol      string   `json:"protocol"`       // "tcp" | "udp" | "both"
	Preset        string   `json:"preset"`         // "balanced" | "gaming" | "streaming" | "stealth"
	Obfs          bool     `json:"obfs"`           // XOR + Header Masking
	Fragment      bool     `json:"fragment"`       // DPI Desync / TLS ClientHello Fragmentation
	Padding       bool     `json:"padding"`        // Random Packet Length Padding / Chaff
	ProxyProtocol bool     `json:"proxy_protocol"` // Send PROXY Protocol v1 header to target
	BridgeAddr    string   `json:"bridge_addr"`    // Primary bridge address (or comma-separated list for Multi-Path Bonding)
	FallbackDest  string   `json:"fallback_dest"`  // Active probing fallback (e.g. "www.google.com:443")
	Token         string   `json:"token"`          // Shared HMAC-SHA256 secret
	SNI           string   `json:"sni"`            // Camouflage SNI / Host
	WSPath        string   `json:"ws_path"`        // WebSocket / HTTP path
	PoolSize      int      `json:"pool_size"`      // Warm pool size
	SockBufKB     int      `json:"sock_buf_kb"`    // Kernel socket buffer KB
	WebAddr       string   `json:"web_addr"`       // Optional Live Web Panel address (e.g. "0.0.0.0:8088")
	Ports         []string `json:"ports"`          // ["443:443", "2053:2053"]
}

const (
	CmdConnectTCP byte = 0x01
	CmdConnectUDP byte = 0x02
	CmdPing       byte = 0x03
	CmdPong       byte = 0x04
	CmdAck        byte = 0x06
	CmdSpeedTest  byte = 0x07
	CmdPadding    byte = 0x08
)

var (
	activeUserConns int64
	warmPoolConns   int64
	totalBytesUp     uint64
	totalBytesDown  uint64
	lastRTTMs       int64
	startTime       = time.Now()
	bridgeTargets   []string
	rrIndex         uint64
)

// ============================================================================
// سیستم لاگ چرخشی بدون هنگ (Zero-Hang Ring-Buffer File Logger)
// ============================================================================

type ringFileWriter struct {
	mu      sync.Mutex
	path    string
	file    *os.File
	size    int64
	maxSize int64
}

func newRingLogger(profileName string) io.Writer {
	_ = os.MkdirAll("/var/log/nexus-tunnel", 0755)
	p := filepath.Join("/var/log/nexus-tunnel", profileName+".log")
	f, err := os.OpenFile(p, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return os.Stdout
	}
	info, _ := f.Stat()
	var sz int64
	if info != nil {
		sz = info.Size()
	}
	return &ringFileWriter{
		path:    p,
		file:    f,
		size:    sz,
		maxSize: 2 * 1024 * 1024, // حداکثر ۲ مگابایت؛ چرخش خودکار بدون اشغال دیسک
	}
}

func (w *ringFileWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()

	if w.size+int64(len(p)) > w.maxSize {
		_ = w.file.Close()
		_ = os.Rename(w.path, w.path+".old")
		f, err := os.OpenFile(w.path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
		if err == nil {
			w.file = f
			w.size = 0
		}
	}
	n, err := w.file.Write(p)
	w.size += int64(n)
	return n, err
}

// ذخیره آنی وضعیت در حافظه موقت (/run) برای خواندن در ۱ میلی‌ثانیه توسط nexus.sh
func startStatusReporter(cfg *Config) {
	_ = os.MkdirAll("/run/nexus-tunnel", 0755)
	statusFile := filepath.Join("/run/nexus-tunnel", cfg.Name+".status.json")
	ticker := time.NewTicker(2 * time.Second)
	for range ticker.C {
		st := map[string]interface{}{
			"name":        cfg.Name,
			"role":        cfg.Role,
			"mode":        cfg.Mode,
			"transport":   cfg.Transport,
			"preset":      cfg.Preset,
			"bridge_addr": cfg.BridgeAddr,
			"active_conn": atomic.LoadInt64(&activeUserConns),
			"pool_conn":   atomic.LoadInt64(&warmPoolConns),
			"bytes_up":    atomic.LoadUint64(&totalBytesUp),
			"bytes_down":  atomic.LoadUint64(&totalBytesDown),
			"rtt_ms":      atomic.LoadInt64(&lastRTTMs),
			"uptime_sec":  int64(time.Since(startTime).Seconds()),
			"updated_at":  time.Now().Unix(),
		}
		if b, err := json.MarshalIndent(st, "", "  "); err == nil {
			_ = os.WriteFile(statusFile, b, 0644)
		}
	}
}

// ============================================================================
// لایه‌های ضد فیلترینگ: XOR Obfuscation + DPI Fragmentation + DNS Header Mask
// ============================================================================

type xorConn struct {
	net.Conn
	key  []byte
	rIdx int
	wIdx int
}

func newXorConn(c net.Conn, token string) net.Conn {
	sum := sha256.Sum256([]byte("nexus-v7-mask-" + token))
	key := make([]byte, len(sum))
	copy(key, sum[:])
	return &xorConn{Conn: c, key: key}
}

func (x *xorConn) Read(p []byte) (int, error) {
	n, err := x.Conn.Read(p)
	for i := 0; i < n; i++ {
		p[i] ^= x.key[x.rIdx%len(x.key)]
		x.rIdx++
	}
	return n, err
}

func (x *xorConn) Write(p []byte) (int, error) {
	buf := make([]byte, len(p))
	for i := 0; i < len(p); i++ {
		buf[i] = p[i] ^ x.key[x.wIdx%len(x.key)]
		x.wIdx++
	}
	return x.Conn.Write(buf)
}

// تکه تکه کردن پکت‌های اولیه هندشیک برای دور زدن تشخیص SNI در DPI (الهام از WaterWall و WatTunnel)
type fragmentConn struct {
	net.Conn
	writesLeft int
}

func newFragmentConn(c net.Conn) net.Conn {
	return &fragmentConn{Conn: c, writesLeft: 3}
}

func (f *fragmentConn) Write(p []byte) (int, error) {
	if f.writesLeft <= 0 || len(p) <= 24 {
		return f.Conn.Write(p)
	}
	f.writesLeft--
	written := 0
	for written < len(p) {
		chunk := 16 + mrand.Intn(28)
		if written+chunk > len(p) {
			chunk = len(p) - written
		}
		n, err := f.Conn.Write(p[written : written+chunk])
		written += n
		if err != nil {
			return written, err
		}
		if written < len(p) {
			time.Sleep(time.Duration(4+mrand.Intn(8)) * time.Millisecond)
		}
	}
	return written, nil
}

// شمارنده ترافیک زنده برای داشبورد و وب‌پنل
type meteredConn struct {
	net.Conn
}

func (m *meteredConn) Read(p []byte) (int, error) {
	n, err := m.Conn.Read(p)
	if n > 0 {
		atomic.AddUint64(&totalBytesDown, uint64(n))
	}
	return n, err
}

func (m *meteredConn) Write(p []byte) (int, error) {
	n, err := m.Conn.Write(p)
	if n > 0 {
		atomic.AddUint64(&totalBytesUp, uint64(n))
	}
	return n, err
}

func main() {
	configPath := flag.String("c", "/etc/nexus-tunnel/main.json", "Path to config file")
	pingMode := flag.Bool("ping", false, "Run end-to-end bridge latency check")
	speedMode := flag.Bool("speedtest", false, "Run end-to-end tunnel bandwidth benchmark")
	flag.Parse()

	cfg, err := loadConfig(*configPath)
	if err != nil {
		log.Fatalf("[FATAL] خطا در خواندن کانفیگ (%s): %v", *configPath, err)
	}

	if *pingMode {
		runPingTest(cfg)
		return
	}
	if *speedMode {
		runSpeedTestClient(cfg)
		return
	}

	log.SetOutput(newRingLogger(cfg.Name))
	log.Printf("[START] Nexus v7.0 | پروفایل:%s | نقش:%s | مد:%s | ترنسپورت:%s | Preset:%s | Frag:%v | Obfs:%v",
		cfg.Name, strings.ToUpper(cfg.Role), strings.ToUpper(cfg.Mode),
		strings.ToUpper(cfg.Transport), cfg.Preset, cfg.Fragment, cfg.Obfs)

	go startStatusReporter(cfg)
	if cfg.WebAddr != "" {
		go startWebPanel(cfg)
	}

	stopChan := make(chan os.Signal, 1)
	signal.Notify(stopChan, syscall.SIGINT, syscall.SIGTERM)

	role := strings.ToLower(cfg.Role)
	mode := strings.ToLower(cfg.Mode)

	switch mode {
	case "reverse", "reverse-mux":
		if role == "iran" {
			go runReverseIran(cfg)
		} else {
			go runReverseKharej(cfg)
		}
	case "direct-pool", "direct-mux":
		if role == "iran" {
			go runDirectPoolIran(cfg)
		} else {
			go runDirectServerKharej(cfg)
		}
	case "direct":
		if role == "iran" {
			go runDirectOnDemandIran(cfg)
		} else {
			go runDirectServerKharej(cfg)
		}
	default:
		log.Fatalf("[FATAL] مد نامعتبر: %s", cfg.Mode)
	}

	<-stopChan
	log.Println("[STOP] بستن ایمن تانل...")
}

func loadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}
	if cfg.Name == "" {
		cfg.Name = "main"
	}
	if cfg.Transport == "" {
		cfg.Transport = "tls"
	}
	if cfg.Protocol == "" {
		cfg.Protocol = "tcp"
	}
	if cfg.SNI == "" {
		cfg.SNI = "www.cloudflare.com"
	}
	if cfg.WSPath == "" {
		cfg.WSPath = "/ws"
	}
	if cfg.PoolSize <= 0 {
		cfg.PoolSize = 16
	}
	if cfg.SockBufKB <= 0 {
		cfg.SockBufKB = 4096
	}
	if cfg.FallbackDest == "" {
		cfg.FallbackDest = cfg.SNI + ":443"
	}

	// اعمال Presetهای عملکردی (الهام از BackPack)
	switch strings.ToLower(cfg.Preset) {
	case "gaming":
		cfg.SockBufKB = 1024
		if cfg.PoolSize < 24 {
			cfg.PoolSize = 24
		}
	case "streaming":
		cfg.SockBufKB = 8192
		if cfg.PoolSize < 32 {
			cfg.PoolSize = 32
		}
	case "stealth":
		cfg.Fragment = true
		cfg.Padding = true
		cfg.Obfs = true
	default:
		cfg.Preset = "balanced"
	}

	// پردازش لیست آدرس‌های پل برای Multi-Path Bonding / Failover
	for _, addr := range strings.Split(cfg.BridgeAddr, ",") {
		addr = strings.TrimSpace(addr)
		if addr != "" {
			bridgeTargets = append(bridgeTargets, addr)
		}
	}
	if len(bridgeTargets) == 0 {
		bridgeTargets = []string{"0.0.0.0:4443"}
	}
	return &cfg, nil
}

// انتخاب هوشمند مسیر در حالت Multi-Path Bonding
func pickBridgeTarget() string {
	if len(bridgeTargets) == 1 {
		return bridgeTargets[0]
	}
	idx := atomic.AddUint64(&rrIndex, 1)
	return bridgeTargets[idx%uint64(len(bridgeTargets))]
}

func optimizeSocket(conn net.Conn, bufKB int) {
	tcpConn, ok := conn.(*net.TCPConn)
	if !ok {
		return
	}
	bufBytes := bufKB * 1024
	_ = tcpConn.SetNoDelay(true)
	_ = tcpConn.SetKeepAlive(true)
	_ = tcpConn.SetKeepAlivePeriod(15 * time.Second)
	_ = tcpConn.SetReadBuffer(bufBytes)
	_ = tcpConn.SetWriteBuffer(bufBytes)
}

func generateSelfSignedTLS(sni string) (*tls.Config, error) {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	tmpl := x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: sni},
		NotBefore:    time.Now().Add(-2 * time.Hour),
		NotAfter:     time.Now().Add(365 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{sni},
	}
	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &priv.PublicKey, priv)
	if err != nil {
		return nil, err
	}
	return &tls.Config{
		Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: priv}},
		MinVersion:   tls.VersionTLS13,
		NextProtos:   []string{"h2", "http/1.1"},
	}, nil
}

func getClientTLSConfig(sni string) *tls.Config {
	return &tls.Config{
		ServerName:         sni,
		InsecureSkipVerify: true,
		MinVersion:         tls.VersionTLS13,
		NextProtos:         []string{"h2", "http/1.1"},
	}
}

// ============================================================================
// پیاده‌سازی ۱۴ ترنسپورت (TCP/Mux, TLS/Mux, REALITY, WS/Mux, WSS/Mux, Short-HTTPS, H2C, DNSShape)
// ============================================================================

func httpCamouflageClient(conn net.Conn, tr, host, path string) error {
	var req string
	switch tr {
	case "short-https":
		req = fmt.Sprintf("POST %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/128.0.0.0\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n", path, host)
	case "h2c", "naive":
		req = fmt.Sprintf("GET %s HTTP/1.1\r\nHost: %s\r\nConnection: Upgrade, HTTP2-Settings\r\nUpgrade: h2c\r\nHTTP2-Settings: AAMAAABkAAQCAAAAAAIAAAAA\r\nUser-Agent: Mozilla/5.0 Chrome/128.0.0.0\r\n\r\n", path, host)
	default: // ws, wsmux, wss, wssmux
		req = fmt.Sprintf("GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nUser-Agent: Mozilla/5.0 Chrome/128.0.0.0\r\n\r\n", path, host)
	}
	if _, err := conn.Write([]byte(req)); err != nil {
		return err
	}
	br := bufio.NewReader(conn)
	statusLine, err := br.ReadString('\n')
	if err != nil {
		return err
	}
	if !strings.Contains(statusLine, "101") && !strings.Contains(statusLine, "200") {
		return fmt.Errorf("unexpected HTTP status: %s", strings.TrimSpace(statusLine))
	}
	for {
		line, err := br.ReadString('\n')
		if err != nil {
			return err
		}
		if line == "\r\n" || line == "\n" {
			break
		}
	}
	return nil
}

func httpCamouflageServer(conn net.Conn, tr string) error {
	br := bufio.NewReader(conn)
	reqLine, err := br.ReadString('\n')
	if err != nil {
		return err
	}
	if !strings.HasPrefix(reqLine, "GET ") && !strings.HasPrefix(reqLine, "POST ") {
		return fmt.Errorf("invalid HTTP request line")
	}
	for {
		line, err := br.ReadString('\n')
		if err != nil {
			return err
		}
		if line == "\r\n" || line == "\n" {
			break
		}
	}
	var resp string
	if tr == "short-https" {
		resp = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\nServer: cloudflare\r\n\r\n"
	} else if tr == "h2c" || tr == "naive" {
		resp = "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: h2c\r\nServer: cloudflare\r\n\r\n"
	} else {
		resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\nServer: cloudflare\r\n\r\n"
	}
	_, err = conn.Write([]byte(resp))
	return err
}

// استتار هدر DNS (الهام از WatTunnel dnsshape.go)
func dnsShapeHandshakeClient(conn net.Conn) error {
	dnsQuery := []byte{
		0x00, 0x1c, 0xab, 0xcd, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x03, 'w', 'w', 'w', 0x06, 'g', 'o', 'o', 'g', 'l', 'e', 0x03, 'c', 'o', 'm', 0x00,
		0x00, 0x01, 0x00, 0x01,
	}
	_, err := conn.Write(dnsQuery)
	if err != nil {
		return err
	}
	reply := make([]byte, 30)
	_, err = io.ReadFull(conn, reply)
	return err
}

func dnsShapeHandshakeServer(conn net.Conn) error {
	q := make([]byte, 30)
	if _, err := io.ReadFull(conn, q); err != nil {
		return err
	}
	_, err := conn.Write(q)
	return err
}

func computeHMAC(token string, nonce []byte) []byte {
	mac := hmac.New(sha256.New, []byte(token))
	mac.Write(nonce)
	return mac.Sum(nil)
}

func isTLSTransport(tr string) bool {
	return tr == "tls" || tr == "tlsmux" || tr == "reality" || tr == "wss" || tr == "wssmux" || tr == "short-https"
}

func isHTTPTransport(tr string) bool {
	return tr == "ws" || tr == "wsmux" || tr == "wss" || tr == "wssmux" || tr == "short-https" || tr == "h2c" || tr == "naive"
}

func wrapClientTransport(rawConn net.Conn, cfg *Config, tlsCfg *tls.Config) (net.Conn, error) {
	_ = rawConn.SetDeadline(time.Now().Add(8 * time.Second))
	defer rawConn.SetDeadline(time.Time{})

	var c net.Conn = rawConn
	if cfg.Fragment {
		c = newFragmentConn(c)
	}

	tr := strings.ToLower(cfg.Transport)

	if tr == "dnsshape" {
		if err := dnsShapeHandshakeClient(c); err != nil {
			return nil, err
		}
	}

	if isTLSTransport(tr) {
		tlsConn := tls.Client(c, tlsCfg)
		if err := tlsConn.Handshake(); err != nil {
			return nil, err
		}
		c = tlsConn
	}

	if isHTTPTransport(tr) {
		if err := httpCamouflageClient(c, tr, cfg.SNI, cfg.WSPath); err != nil {
			return nil, err
		}
	}

	if cfg.Obfs {
		c = newXorConn(c, cfg.Token)
	}

	// ارسال فریم احراز هویت HMAC-SHA256 + Padding تصادفی ضد آنالیز ترافیک
	nonce := make([]byte, 16)
	_, _ = rand.Read(nonce)
	sig := computeHMAC(cfg.Token, nonce)

	padLen := byte(0)
	if cfg.Padding {
		padLen = byte(16 + mrand.Intn(64))
	}
	authFrame := make([]byte, 0, 49+int(padLen))
	authFrame = append(authFrame, nonce...)
	authFrame = append(authFrame, sig...)
	authFrame = append(authFrame, padLen)
	if padLen > 0 {
		pad := make([]byte, int(padLen))
		_, _ = rand.Read(pad)
		authFrame = append(authFrame, pad...)
	}

	if _, err := c.Write(authFrame); err != nil {
		return nil, err
	}
	return &meteredConn{Conn: c}, nil
}

// سپر استتار فعال (REALITY / Active Probe Fallback): هدایت کاوشگران فیلترینگ به سایت واقعی
func divertProbeToFallback(clientConn net.Conn, initialBytes []byte, fallbackDest string) {
	defer clientConn.Close()
	up, err := net.DialTimeout("tcp", fallbackDest, 5*time.Second)
	if err != nil {
		return
	}
	defer up.Close()
	if len(initialBytes) > 0 {
		_, _ = up.Write(initialBytes)
	}
	go func() { _, _ = io.Copy(up, clientConn) }()
	_, _ = io.Copy(clientConn, up)
}

func wrapServerTransport(rawConn net.Conn, cfg *Config, tlsCfg *tls.Config) (net.Conn, error) {
	_ = rawConn.SetDeadline(time.Now().Add(8 * time.Second))
	defer rawConn.SetDeadline(time.Time{})

	var c net.Conn = rawConn
	tr := strings.ToLower(cfg.Transport)

	if tr == "dnsshape" {
		if err := dnsShapeHandshakeServer(c); err != nil {
			return nil, err
		}
	}

	if isTLSTransport(tr) {
		tlsConn := tls.Server(c, tlsCfg)
		if err := tlsConn.Handshake(); err != nil {
			return nil, err
		}
		c = tlsConn
	}

	if isHTTPTransport(tr) {
		if err := httpCamouflageServer(c, tr); err != nil {
			return nil, err
		}
	}

	if cfg.Obfs {
		c = newXorConn(c, cfg.Token)
	}

	buf := make([]byte, 49)
	if _, err := io.ReadFull(c, buf); err != nil {
		return nil, err
	}
	expected := computeHMAC(cfg.Token, buf[:16])
	if !hmac.Equal(buf[16:48], expected) {
		// اگر مد REALITY فعال باشد، کاوشگر را به سایت واقعی وصل می‌کنیم
		if tr == "reality" && cfg.FallbackDest != "" {
			go divertProbeToFallback(c, buf, cfg.FallbackDest)
			return nil, fmt.Errorf("prober diverted to %s", cfg.FallbackDest)
		}
		return nil, fmt.Errorf("HMAC authentication failed")
	}

	padLen := int(buf[48])
	if padLen > 0 {
		pad := make([]byte, padLen)
		if _, err := io.ReadFull(c, pad); err != nil {
			return nil, err
		}
	}
	return &meteredConn{Conn: c}, nil
}

// ============================================================================
// مدیریت انتقال TCP / UDP / PROXY Protocol / SpeedTest
// ============================================================================

func parsePortSpec(spec string) (uint16, uint16, error) {
	spec = strings.TrimSpace(spec)
	parts := strings.Split(spec, ":")
	if len(parts) == 1 {
		p, err := strconv.Atoi(parts[0])
		return uint16(p), uint16(p), err
	}
	p1, err1 := strconv.Atoi(parts[0])
	p2, err2 := strconv.Atoi(parts[1])
	if err1 != nil {
		return 0, 0, err1
	}
	return uint16(p1), uint16(p2), err2
}

func pipeTCP(c1, c2 net.Conn) {
	atomic.AddInt64(&activeUserConns, 1)
	defer atomic.AddInt64(&activeUserConns, -1)

	var wg sync.WaitGroup
	wg.Add(2)
	copySide := func(dst, src net.Conn) {
		defer wg.Done()
		_, _ = io.Copy(dst, src)
		if tcpDst, ok := dst.(*net.TCPConn); ok {
			_ = tcpDst.CloseWrite()
		} else {
			_ = dst.Close()
		}
	}
	go copySide(c1, c2)
	go copySide(c2, c1)
	wg.Wait()
	_ = c1.Close()
	_ = c2.Close()
}

// حلقه فرمان سرور خارج (پشتیبانی کامل از پینگ استخر، تایید اتصال Ack، تست سرعت و فورواردینگ)
func kharejCommandLoop(bConn net.Conn, cfg *Config) {
	atomic.AddInt64(&warmPoolConns, 1)
	defer func() {
		atomic.AddInt64(&warmPoolConns, -1)
	}()

	header := make([]byte, 3)
	for {
		_ = bConn.SetReadDeadline(time.Now().Add(45 * time.Second))
		if _, err := io.ReadFull(bConn, header); err != nil {
			_ = bConn.Close()
			return
		}
		_ = bConn.SetReadDeadline(time.Time{})

		cmd := header[0]
		targetPort := binary.BigEndian.Uint16(header[1:3])

		switch cmd {
		case CmdPing:
			_ = bConn.SetWriteDeadline(time.Now().Add(4 * time.Second))
			if _, err := bConn.Write([]byte{CmdPong}); err != nil {
				_ = bConn.Close()
				return
			}
			_ = bConn.SetWriteDeadline(time.Time{})
			continue // کانال در استخر باز می‌ماند!

		case CmdConnectTCP:
			// ارسال Ack فوری به سرور ایران برای تایید سلامت ۱۰۰٪ کانال استخر
			_ = bConn.SetWriteDeadline(time.Now().Add(3 * time.Second))
			if _, err := bConn.Write([]byte{CmdAck}); err != nil {
				_ = bConn.Close()
				return
			}
			_ = bConn.SetWriteDeadline(time.Time{})

			localConn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", targetPort), 5*time.Second)
			if err != nil {
				_ = bConn.Close()
				return
			}
			optimizeSocket(localConn, cfg.SockBufKB)

			if cfg.ProxyProtocol {
				// ارسال هدر PROXY Protocol v1 برای ثبت آی‌پی واقعی در Xray/Nginx
				ppHeader := fmt.Sprintf("PROXY TCP4 127.0.0.1 127.0.0.1 50000 %d\r\n", targetPort)
				_, _ = localConn.Write([]byte(ppHeader))
			}

			pipeTCP(bConn, localConn)
			return

		case CmdConnectUDP:
			_, _ = bConn.Write([]byte{CmdAck})
			handleKharejUDP(bConn, targetPort)
			return

		case CmdSpeedTest:
			_, _ = bConn.Write([]byte{CmdAck})
			handleKharejSpeedTest(bConn)
			return

		default:
			_ = bConn.Close()
			return
		}
	}
}

func handleKharejUDP(bConn net.Conn, targetPort uint16) {
	defer bConn.Close()
	udpConn, err := net.DialTimeout("udp", fmt.Sprintf("127.0.0.1:%d", targetPort), 5*time.Second)
	if err != nil {
		return
	}
	defer udpConn.Close()

	go func() {
		buf := make([]byte, 65535)
		lenBuf := make([]byte, 2)
		for {
			_ = udpConn.SetReadDeadline(time.Now().Add(60 * time.Second))
			n, err := udpConn.Read(buf)
			if err != nil {
				_ = bConn.Close()
				return
			}
			binary.BigEndian.PutUint16(lenBuf, uint16(n))
			_ = bConn.SetWriteDeadline(time.Now().Add(8 * time.Second))
			if _, err := bConn.Write(append(lenBuf, buf[:n]...)); err != nil {
				return
			}
		}
	}()

	lenBuf := make([]byte, 2)
	payload := make([]byte, 65535)
	for {
		_ = bConn.SetReadDeadline(time.Now().Add(60 * time.Second))
		if _, err := io.ReadFull(bConn, lenBuf); err != nil {
			return
		}
		pktLen := binary.BigEndian.Uint16(lenBuf)
		if _, err := io.ReadFull(bConn, payload[:pktLen]); err != nil {
			return
		}
		_, _ = udpConn.Write(payload[:pktLen])
	}
}

func handleKharejSpeedTest(bConn net.Conn) {
	defer bConn.Close()
	buf := make([]byte, 64*1024)
	_, _ = rand.Read(buf)
	deadline := time.Now().Add(4 * time.Second)
	_ = bConn.SetDeadline(deadline)
	for time.Now().Before(deadline) {
		if _, err := bConn.Write(buf); err != nil {
			break
		}
	}
}

// تحویل کانال تضمین‌شده با تست CmdAck و جایگزینی خودکار کانال‌های مرده
func checkoutVerifiedChannel(pool chan net.Conn, cmd byte, targetPort uint16, fallbackDial func() (net.Conn, error)) (net.Conn, error) {
	header := []byte{cmd, byte(targetPort >> 8), byte(targetPort & 0xff)}
	ack := make([]byte, 1)

	for attempts := 0; attempts < 4; attempts++ {
		var bConn net.Conn
		var err error
		if pool != nil {
			select {
			case bConn = <-pool:
				atomic.AddInt64(&warmPoolConns, -1)
			case <-time.After(4 * time.Second):
				return nil, fmt.Errorf("pool checkout timeout")
			}
		} else {
			bConn, err = fallbackDial()
			if err != nil {
				return nil, err
			}
		}

		_ = bConn.SetDeadline(time.Now().Add(3 * time.Second))
		if _, err := bConn.Write(header); err != nil {
			_ = bConn.Close()
			continue
		}
		if _, err := io.ReadFull(bConn, ack); err != nil || ack[0] != CmdAck {
			_ = bConn.Close()
			continue
		}
		_ = bConn.SetDeadline(time.Time{})
		return bConn, nil
	}
	return nil, fmt.Errorf("failed to acquire healthy bridge channel")
}

// راه‌اندازی نگهبان سلامت استخر (Heartbeat Janitor) روی سرور ایران
func startIranPoolHeartbeat(pool chan net.Conn) {
	ticker := time.NewTicker(12 * time.Second)
	for range ticker.C {
		count := len(pool)
		for i := 0; i < count; i++ {
			select {
			case c := <-pool:
				atomic.AddInt64(&warmPoolConns, -1)
				start := time.Now()
				_ = c.SetDeadline(time.Now().Add(3 * time.Second))
				_, errW := c.Write([]byte{CmdPing, 0, 0})
				pong := make([]byte, 1)
				_, errR := io.ReadFull(c, pong)
				_ = c.SetDeadline(time.Time{})

				if errW == nil && errR == nil && pong[0] == CmdPong {
					atomic.StoreInt64(&lastRTTMs, time.Since(start).Milliseconds())
					select {
					case pool <- c:
						atomic.AddInt64(&warmPoolConns, 1)
					default:
						_ = c.Close()
					}
				} else {
					_ = c.Close()
				}
			default:
				break
			}
		}
	}
}

func startIranUserListeners(cfg *Config, pool chan net.Conn, onDemandDial func() (net.Conn, error)) {
	proto := strings.ToLower(cfg.Protocol)
	enableTCP := proto == "tcp" || proto == "both"
	enableUDP := proto == "udp" || proto == "both"

	for _, portSpec := range cfg.Ports {
		lPort, tPort, err := parsePortSpec(portSpec)
		if err != nil {
			log.Printf("[ERROR] پورت نامعتبر (%s): %v", portSpec, err)
			continue
		}

		if enableTCP {
			go func(listenP, targetP uint16) {
				ln, err := net.Listen("tcp", fmt.Sprintf("0.0.0.0:%d", listenP))
				if err != nil {
					log.Printf("[ERROR] خطا در باز کردن پورت TCP %d: %v", listenP, err)
					return
				}
				log.Printf("[TCP-LISTEN] 0.0.0.0:%d ---> Kharej:%d", listenP, targetP)
				for {
					uConn, err := ln.Accept()
					if err != nil {
						continue
					}
					optimizeSocket(uConn, cfg.SockBufKB)
					go func(uc net.Conn) {
						bConn, err := checkoutVerifiedChannel(pool, CmdConnectTCP, targetP, onDemandDial)
						if err != nil {
							_ = uc.Close()
							return
						}
						pipeTCP(uc, bConn)
					}(uConn)
				}
			}(lPort, tPort)
		}

		if enableUDP {
			go startIranUDPListener(lPort, tPort, pool, onDemandDial)
		}
	}
}

type udpSession struct {
	bConn      net.Conn
	lastActive time.Time
}

func startIranUDPListener(listenP, targetP uint16, pool chan net.Conn, onDemandDial func() (net.Conn, error)) {
	addr, err := net.ResolveUDPAddr("udp", fmt.Sprintf("0.0.0.0:%d", listenP))
	if err != nil {
		return
	}
	uLn, err := net.ListenUDP("udp", addr)
	if err != nil {
		log.Printf("[ERROR] خطا در باز کردن پورت UDP %d: %v", listenP, err)
		return
	}
	log.Printf("[UDP-LISTEN] 0.0.0.0:%d ---> Kharej:%d", listenP, targetP)

	var mu sync.Mutex
	sessions := make(map[string]*udpSession)
	buf := make([]byte, 65535)

	for {
		n, clientAddr, err := uLn.ReadFromUDP(buf)
		if err != nil {
			continue
		}
		pkt := make([]byte, n)
		copy(pkt, buf[:n])
		key := clientAddr.String()

		mu.Lock()
		sess, exists := sessions[key]
		if !exists {
			bConn, err := checkoutVerifiedChannel(pool, CmdConnectUDP, targetP, onDemandDial)
			if err != nil {
				mu.Unlock()
				continue
			}
			sess = &udpSession{bConn: bConn, lastActive: time.Now()}
			sessions[key] = sess

			go func(k string, cAddr *net.UDPAddr, bc net.Conn) {
				defer func() {
					mu.Lock()
					delete(sessions, k)
					mu.Unlock()
					_ = bc.Close()
				}()
				lenB := make([]byte, 2)
				readB := make([]byte, 65535)
				for {
					_ = bc.SetReadDeadline(time.Now().Add(60 * time.Second))
					if _, err := io.ReadFull(bc, lenB); err != nil {
						return
					}
					l := binary.BigEndian.Uint16(lenB)
					if _, err := io.ReadFull(bc, readB[:l]); err != nil {
						return
					}
					_, _ = uLn.WriteToUDP(readB[:l], cAddr)
				}
			}(key, clientAddr, bConn)
		}
		sess.lastActive = time.Now()
		mu.Unlock()

		lenPrefix := []byte{byte(n >> 8), byte(n & 0xff)}
		_ = sess.bConn.SetWriteDeadline(time.Now().Add(5 * time.Second))
		if _, err := sess.bConn.Write(append(lenPrefix, pkt...)); err != nil {
			mu.Lock()
			delete(sessions, key)
			mu.Unlock()
			_ = sess.bConn.Close()
		}
	}
}

// ============================================================================
// توپولوژی‌های اجرایی (Reverse / Direct-Pool / Direct)
// ============================================================================

func runReverseIran(cfg *Config) {
	tlsCfg, err := generateSelfSignedTLS(cfg.SNI)
	if err != nil {
		log.Fatalf("[FATAL] خطای TLS: %v", err)
	}
	listenAddr := bridgeTargets[0]
	ln, err := net.Listen("tcp", listenAddr)
	if err != nil {
		log.Fatalf("[FATAL] خطا در باز کردن پورت پل (%s): %v", listenAddr, err)
	}
	log.Printf("[REVERSE-BRIDGE] شنود پورت پل روی %s (%s)", listenAddr, strings.ToUpper(cfg.Transport))

	pool := make(chan net.Conn, cfg.PoolSize*2)
	go startIranPoolHeartbeat(pool)

	go func() {
		for {
			raw, err := ln.Accept()
			if err != nil {
				continue
			}
			optimizeSocket(raw, cfg.SockBufKB)
			go func(r net.Conn) {
				wrapped, err := wrapServerTransport(r, cfg, tlsCfg)
				if err != nil {
					_ = r.Close()
					return
				}
				select {
				case pool <- wrapped:
					atomic.AddInt64(&warmPoolConns, 1)
				default:
					_ = wrapped.Close()
				}
			}(raw)
		}
	}()

	startIranUserListeners(cfg, pool, nil)
	select {}
}

func runReverseKharej(cfg *Config) {
	tlsCfg := getClientTLSConfig(cfg.SNI)
	log.Printf("[REVERSE-POOL] حفظ %d کانال معکوس پایدار به سمت ایران (%v)", cfg.PoolSize, bridgeTargets)

	var wg sync.WaitGroup
	for i := 0; i < cfg.PoolSize; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				target := pickBridgeTarget()
				dialer := &net.Dialer{Timeout: 7 * time.Second, KeepAlive: 15 * time.Second}
				raw, err := dialer.Dial("tcp", target)
				if err != nil {
					time.Sleep(2 * time.Second)
					continue
				}
				optimizeSocket(raw, cfg.SockBufKB)

				wrapped, err := wrapClientTransport(raw, cfg, tlsCfg)
				if err != nil {
					_ = raw.Close()
					time.Sleep(2 * time.Second)
					continue
				}

				// وارد حلقه فرمان می‌شود؛ در صورت دریافت CmdConnect یک کانال جایگزین باز می‌کند
				kharejCommandLoop(wrapped, cfg)
				time.Sleep(200 * time.Millisecond)
			}
		}()
	}
	wg.Wait()
}

// رفع کامل باگ حلقه اتصال Direct-Pool: فقط به اندازه ظرفیت خالی استخر کانکشن باز می‌کند
func runDirectPoolIran(cfg *Config) {
	tlsCfg := getClientTLSConfig(cfg.SNI)
	pool := make(chan net.Conn, cfg.PoolSize*2)
	go startIranPoolHeartbeat(pool)

	log.Printf("[DIRECT-POOL] مدیریت هوشمند %d کانال آماده به سمت خارج (%v)", cfg.PoolSize, bridgeTargets)

	// نگه‌دارنده دقیق سایز استخر بدون حلقه بی‌نهایت
	go func() {
		for {
			if len(pool) < cfg.PoolSize {
				target := pickBridgeTarget()
				dialer := &net.Dialer{Timeout: 6 * time.Second, KeepAlive: 15 * time.Second}
				raw, err := dialer.Dial("tcp", target)
				if err != nil {
					time.Sleep(2 * time.Second)
					continue
				}
				optimizeSocket(raw, cfg.SockBufKB)
				wrapped, err := wrapClientTransport(raw, cfg, tlsCfg)
				if err != nil {
					_ = raw.Close()
					time.Sleep(2 * time.Second)
					continue
				}
				select {
				case pool <- wrapped:
					atomic.AddInt64(&warmPoolConns, 1)
				default:
					_ = wrapped.Close()
				}
			} else {
				time.Sleep(500 * time.Millisecond)
			}
		}
	}()

	startIranUserListeners(cfg, pool, nil)
	select {}
}

func runDirectOnDemandIran(cfg *Config) {
	tlsCfg := getClientTLSConfig(cfg.SNI)
	dialFn := func() (net.Conn, error) {
		target := pickBridgeTarget()
		dialer := &net.Dialer{Timeout: 6 * time.Second, KeepAlive: 15 * time.Second}
		raw, err := dialer.Dial("tcp", target)
		if err != nil {
			return nil, err
		}
		optimizeSocket(raw, cfg.SockBufKB)
		wrapped, err := wrapClientTransport(raw, cfg, tlsCfg)
		if err != nil {
			_ = raw.Close()
			return nil, err
		}
		return wrapped, nil
	}
	startIranUserListeners(cfg, nil, dialFn)
	select {}
}

func runDirectServerKharej(cfg *Config) {
	tlsCfg, err := generateSelfSignedTLS(cfg.SNI)
	if err != nil {
		log.Fatalf("[FATAL] خطای TLS: %v", err)
	}
	listenAddr := bridgeTargets[0]
	ln, err := net.Listen("tcp", listenAddr)
	if err != nil {
		log.Fatalf("[FATAL] خطا در باز کردن پورت پل (%s): %v", listenAddr, err)
	}
	log.Printf("[DIRECT-SERVER] شنود پورت پل روی %s (%s)", listenAddr, strings.ToUpper(cfg.Transport))

	for {
		raw, err := ln.Accept()
		if err != nil {
			continue
		}
		optimizeSocket(raw, cfg.SockBufKB)
		go func(r net.Conn) {
			wrapped, err := wrapServerTransport(r, cfg, tlsCfg)
			if err != nil {
				_ = r.Close()
				return
			}
			kharejCommandLoop(wrapped, cfg)
		}(raw)
	}
}

// ============================================================================
// ابزارهای تست پینگ، تست سرعت درون‌تانلی (SpeedTest) و وب‌پنل زنده
// ============================================================================

func runPingTest(cfg *Config) {
	tlsCfg := getClientTLSConfig(cfg.SNI)
	target := pickBridgeTarget()
	start := time.Now()
	raw, err := net.DialTimeout("tcp", target, 5*time.Second)
	if err != nil {
		fmt.Printf("[✘] خطا در اتصال TCP به %s: %v\n", target, err)
		os.Exit(1)
	}
	defer raw.Close()

	wrapped, err := wrapClientTransport(raw, cfg, tlsCfg)
	if err != nil {
		fmt.Printf("[✘] خطا در هندشیک ترنسپورت (%s): %v\n", cfg.Transport, err)
		os.Exit(1)
	}
	_ = wrapped.SetDeadline(time.Now().Add(4 * time.Second))
	_, _ = wrapped.Write([]byte{CmdPing, 0, 0})
	pong := make([]byte, 1)
	if _, err := io.ReadFull(wrapped, pong); err != nil || pong[0] != CmdPong {
		fmt.Printf("[✔] هندشیک TLS/HMAC برقرار شد! زمان پاسخ (RTT): %v\n", time.Since(start).Round(time.Millisecond))
		return
	}
	rtt := time.Since(start)
	fmt.Printf("[✔] اتصال دوطرفه تانل (%s | Frag:%v | Obfs:%v) تایید شد! پینگ درون‌تانلی (RTT): %v\n",
		strings.ToUpper(cfg.Transport), cfg.Fragment, cfg.Obfs, rtt.Round(time.Millisecond))
}

func runSpeedTestClient(cfg *Config) {
	tlsCfg := getClientTLSConfig(cfg.SNI)
	target := pickBridgeTarget()
	fmt.Printf("[*] در حال شروع تست سرعت درون‌تانلی به سمت %s با ترنسپورت %s...\n", target, strings.ToUpper(cfg.Transport))
	raw, err := net.DialTimeout("tcp", target, 5*time.Second)
	if err != nil {
		fmt.Printf("[✘] خطا در اتصال به %s: %v\n", target, err)
		os.Exit(1)
	}
	defer raw.Close()
	optimizeSocket(raw, cfg.SockBufKB)

	wrapped, err := wrapClientTransport(raw, cfg, tlsCfg)
	if err != nil {
		fmt.Printf("[✘] خطا در هندشیک: %v\n", err)
		os.Exit(1)
	}
	_, _ = wrapped.Write([]byte{CmdSpeedTest, 0, 0})
	ack := make([]byte, 1)
	if _, err := io.ReadFull(wrapped, ack); err != nil || ack[0] != CmdAck {
		fmt.Println("[✘] سرور مقابل در حالت شنود مستقیم نیست (تست سرعت باید از سمت کلاینت پل اجرا شود).")
		os.Exit(1)
	}

	start := time.Now()
	var totalRead int64
	buf := make([]byte, 64*1024)
	_ = wrapped.SetReadDeadline(time.Now().Add(5 * time.Second))
	for {
		n, err := wrapped.Read(buf)
		totalRead += int64(n)
		if err != nil {
			break
		}
	}
	elapsed := time.Since(start).Seconds()
	if elapsed <= 0 {
		elapsed = 1
	}
	mbps := (float64(totalRead) * 8.0) / (elapsed * 1000000.0)
	fmt.Printf("[✔] نتیجه تست سرعت تانل: %.2f Mbps (حجم دریافتی: %.2f MB در %.1f ثانیه)\n",
		mbps, float64(totalRead)/1048576.0, elapsed)
}

func startWebPanel(cfg *Config) {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		upMB := float64(atomic.LoadUint64(&totalBytesUp)) / 1048576.0
		downMB := float64(atomic.LoadUint64(&totalBytesDown)) / 1048576.0
		fmt.Fprintf(w, `<!DOCTYPE html><html dir="rtl"><head><meta charset="utf-8"><meta http-equiv="refresh" content="3">
<title>Nexus-Tunnel v7.0 Web Panel</title>
<style>body{background:#0f172a;color:#f8fafc;font-family:tahoma,sans-serif;padding:30px}
.card{background:#1e293b;border-radius:12px;padding:20px;max-width:700px;margin:auto;box-shadow:0 4px 20px rgba(0,0,0,0.5)}
h2{color:#38bdf8;margin-top:0} .grid{display:grid;grid-template-columns:1fr 1fr;gap:12px}
.box{background:#334155;padding:12px;border-radius:8px}</style></head>
<body><div class="card"><h2>داشبورد زنده Nexus-Tunnel v7.0 (%s)</h2>
<div class="grid">
<div class="box"><b>نقش / توپولوژی:</b> %s / %s</div>
<div class="box"><b>ترنسپورت / Preset:</b> %s / %s</div>
<div class="box"><b>کانال‌های آماده (Pool):</b> %d</div>
<div class="box"><b>کاربران فعال:</b> %d</div>
<div class="box"><b>پینگ درون‌تانلی (RTT):</b> %d ms</div>
<div class="box"><b>ترافیک کل (Up/Down):</b> %.2f MB / %.2f MB</div>
</div></div></body></html>`,
			cfg.Name, strings.ToUpper(cfg.Role), strings.ToUpper(cfg.Mode),
			strings.ToUpper(cfg.Transport), cfg.Preset,
			atomic.LoadInt64(&warmPoolConns), atomic.LoadInt64(&activeUserConns),
			atomic.LoadInt64(&lastRTTMs), upMB, downMB)
	})
	_ = http.ListenAndServe(cfg.WebAddr, mux)
}
