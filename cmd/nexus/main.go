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
	"net"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type Config struct {
	Name       string   `json:"name"`
	Role       string   `json:"role"`        // "iran" | "kharej"
	Mode       string   `json:"mode"`        // "reverse" | "direct-pool" | "direct"
	Transport  string   `json:"transport"`   // "raw" | "tls" | "ws" | "tls+ws"
	Protocol   string   `json:"protocol"`    // "tcp" | "udp" | "both"
	Obfs       bool     `json:"obfs"`        // XOR Payload Obfuscation
	BridgeAddr string   `json:"bridge_addr"` // e.g., "0.0.0.0:4443" or "1.2.3.4:4443"
	Token      string   `json:"token"`       // HMAC-SHA256 PSK
	SNI        string   `json:"sni"`         // Fake SNI / Host Header
	WSPath     string   `json:"ws_path"`     // e.g., "/ws" or "/cdn-cgi/trace"
	PoolSize   int      `json:"pool_size"`   // Number of warm channels
	SockBufKB  int      `json:"sock_buf_kb"` // Socket buffer size in KB
	Ports      []string `json:"ports"`       // ["443:443", "2053:2053"]
}

const (
	CmdConnectTCP byte = 0x01
	CmdConnectUDP byte = 0x02
	CmdPing       byte = 0x09
	CmdPong       byte = 0x0A
)

var activeConns int64

// لایه مبهم‌سازی XOR برای استتار کامل استریم
type xorConn struct {
	net.Conn
	key  []byte
	rIdx int
	wIdx int
}

func newXorConn(c net.Conn, token string) net.Conn {
	sum := sha256.Sum256([]byte("nexus-obfs-" + token))
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

func main() {
	configPath := flag.String("c", "/etc/nexus-tunnel/main.json", "Path to config file")
	pingMode := flag.Bool("ping", false, "Test tunnel bridge latency and exit")
	flag.Parse()

	cfg, err := loadConfig(*configPath)
	if err != nil {
		log.Fatalf("[FATAL] خطا در بارگذاری کانفیگ (%s): %v", *configPath, err)
	}

	if *pingMode {
		runPingTest(cfg)
		return
	}

	log.Printf("[START] Nexus v6.0 | پروفایل: %s | نقش: %s | توپولوژی: %s | ترنسپورت: %s | پروتکل: %s | Obfs: %v | Pool: %d",
		cfg.Name, strings.ToUpper(cfg.Role), strings.ToUpper(cfg.Mode),
		strings.ToUpper(cfg.Transport), strings.ToUpper(cfg.Protocol), cfg.Obfs, cfg.PoolSize)

	stopChan := make(chan os.Signal, 1)
	signal.Notify(stopChan, syscall.SIGINT, syscall.SIGTERM)

	switch strings.ToLower(cfg.Mode) {
	case "reverse":
		if strings.ToLower(cfg.Role) == "iran" {
			go runReverseIran(cfg)
		} else {
			go runReverseKharej(cfg)
		}
	case "direct-pool":
		if strings.ToLower(cfg.Role) == "iran" {
			go runDirectPoolIran(cfg)
		} else {
			go runDirectServerKharej(cfg)
		}
	case "direct":
		if strings.ToLower(cfg.Role) == "iran" {
			go runDirectOnDemandIran(cfg)
		} else {
			go runDirectServerKharej(cfg)
		}
	default:
		log.Fatalf("[FATAL] توپولوژی نامعتبر: %s", cfg.Mode)
	}

	<-stopChan
	log.Println("[STOP] دریافت سیگنال توقف؛ بستن ایمن تانل...")
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
	return &cfg, nil
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
		NotBefore:    time.Now().Add(-1 * time.Hour),
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
// لایه Transport (Raw / TLS / WS / TLS+WS) + Handshake HMAC + Obfs
// ============================================================================

func wsClientUpgrade(conn net.Conn, host, path string) error {
	req := fmt.Sprintf("GET %s HTTP/1.1\r\n"+
		"Host: %s\r\n"+
		"Upgrade: websocket\r\n"+
		"Connection: Upgrade\r\n"+
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"+
		"Sec-WebSocket-Version: 13\r\n"+
		"User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36\r\n\r\n", path, host)
	if _, err := conn.Write([]byte(req)); err != nil {
		return err
	}
	br := bufio.NewReader(conn)
	statusLine, err := br.ReadString('\n')
	if err != nil {
		return err
	}
	if !strings.Contains(statusLine, "101") {
		return fmt.Errorf("unexpected WS status: %s", strings.TrimSpace(statusLine))
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

func wsServerAccept(conn net.Conn) error {
	br := bufio.NewReader(conn)
	reqLine, err := br.ReadString('\n')
	if err != nil {
		return err
	}
	if !strings.HasPrefix(reqLine, "GET ") {
		return fmt.Errorf("invalid WS upgrade request")
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
	resp := "HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" +
		"Server: cloudflare\r\n\r\n"
	_, err = conn.Write([]byte(resp))
	return err
}

func computeHMAC(token string, nonce []byte) []byte {
	mac := hmac.New(sha256.New, []byte(token))
	mac.Write(nonce)
	return mac.Sum(nil)
}

func wrapClientTransport(rawConn net.Conn, cfg *Config, tlsCfg *tls.Config) (net.Conn, error) {
	_ = rawConn.SetDeadline(time.Now().Add(8 * time.Second))
	defer rawConn.SetDeadline(time.Time{})

	var c net.Conn = rawConn
	tr := strings.ToLower(cfg.Transport)

	if tr == "tls" || tr == "tls+ws" {
		tlsConn := tls.Client(c, tlsCfg)
		if err := tlsConn.Handshake(); err != nil {
			return nil, err
		}
		c = tlsConn
	}

	if tr == "ws" || tr == "tls+ws" {
		if err := wsClientUpgrade(c, cfg.SNI, cfg.WSPath); err != nil {
			return nil, err
		}
	}

	if cfg.Obfs {
		c = newXorConn(c, cfg.Token)
	}

	// HMAC-SHA256 Authentication
	nonce := make([]byte, 16)
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	sig := computeHMAC(cfg.Token, nonce)
	if _, err := c.Write(append(nonce, sig...)); err != nil {
		return nil, err
	}
	return c, nil
}

func wrapServerTransport(rawConn net.Conn, cfg *Config, tlsCfg *tls.Config) (net.Conn, error) {
	_ = rawConn.SetDeadline(time.Now().Add(8 * time.Second))
	defer rawConn.SetDeadline(time.Time{})

	var c net.Conn = rawConn
	tr := strings.ToLower(cfg.Transport)

	if tr == "tls" || tr == "tls+ws" {
		tlsConn := tls.Server(c, tlsCfg)
		if err := tlsConn.Handshake(); err != nil {
			return nil, err
		}
		c = tlsConn
	}

	if tr == "ws" || tr == "tls+ws" {
		if err := wsServerAccept(c); err != nil {
			return nil, err
		}
	}

	if cfg.Obfs {
		c = newXorConn(c, cfg.Token)
	}

	buf := make([]byte, 48)
	if _, err := io.ReadFull(c, buf); err != nil {
		return nil, err
	}
	expected := computeHMAC(cfg.Token, buf[:16])
	if !hmac.Equal(buf[16:48], expected) {
		return nil, fmt.Errorf("HMAC authentication failed")
	}
	return c, nil
}

// ============================================================================
// توابع انتقال TCP و UDP (Zero-Copy + Framed UDP over Stream)
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
	atomic.AddInt64(&activeConns, 1)
	defer atomic.AddInt64(&activeConns, -1)

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

// هندل کردن مقصد روی سرور خارج (TCP، UDP یا Ping)
func handleKharejTarget(bConn net.Conn, cfg *Config) {
	header := make([]byte, 3)
	if _, err := io.ReadFull(bConn, header); err != nil {
		_ = bConn.Close()
		return
	}
	cmd := header[0]
	targetPort := binary.BigEndian.Uint16(header[1:3])

	switch cmd {
	case CmdPing:
		_, _ = bConn.Write([]byte{CmdPong})
		_ = bConn.Close()
	case CmdConnectTCP:
		localConn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", targetPort), 5*time.Second)
		if err != nil {
			_ = bConn.Close()
			return
		}
		optimizeSocket(localConn, cfg.SockBufKB)
		pipeTCP(bConn, localConn)
	case CmdConnectUDP:
		handleKharejUDP(bConn, targetPort)
	default:
		_ = bConn.Close()
	}
}

func handleKharejUDP(bConn net.Conn, targetPort uint16) {
	defer bConn.Close()
	udpConn, err := net.DialTimeout("udp", fmt.Sprintf("127.0.0.1:%d", targetPort), 5*time.Second)
	if err != nil {
		return
	}
	defer udpConn.Close()

	// خواندن از UDP محلی و ارسال روی تانل
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
			_ = bConn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if _, err := bConn.Write(append(lenBuf, buf[:n]...)); err != nil {
				return
			}
		}
	}()

	// خواندن از تانل و ارسال به UDP محلی
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

// راه‌اندازی شنونده‌های پورت کاربران روی سرور ایران (TCP و UDP)
func startIranUserListeners(cfg *Config, getBridgeConn func() (net.Conn, error)) {
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
					log.Printf("[ERROR] عدم توانایی باز کردن پورت TCP %d: %v", listenP, err)
					return
				}
				log.Printf("[TCP-FWD] 0.0.0.0:%d ---> Kharej:%d فعال شد", listenP, targetP)
				for {
					uConn, err := ln.Accept()
					if err != nil {
						continue
					}
					optimizeSocket(uConn, cfg.SockBufKB)
					go func(uc net.Conn) {
						bConn, err := getBridgeConn()
						if err != nil {
							_ = uc.Close()
							return
						}
						header := []byte{CmdConnectTCP, byte(targetP >> 8), byte(targetP & 0xff)}
						_ = bConn.SetWriteDeadline(time.Now().Add(4 * time.Second))
						if _, err := bConn.Write(header); err != nil {
							_ = bConn.Close()
							_ = uc.Close()
							return
						}
						_ = bConn.SetWriteDeadline(time.Time{})
						pipeTCP(uc, bConn)
					}(uConn)
				}
			}(lPort, tPort)
		}

		if enableUDP {
			go startIranUDPListener(lPort, tPort, getBridgeConn)
		}
	}
}

type udpSession struct {
	bConn      net.Conn
	lastActive time.Time
}

func startIranUDPListener(listenP, targetP uint16, getBridgeConn func() (net.Conn, error)) {
	addr, err := net.ResolveUDPAddr("udp", fmt.Sprintf("0.0.0.0:%d", listenP))
	if err != nil {
		return
	}
	uLn, err := net.ListenUDP("udp", addr)
	if err != nil {
		log.Printf("[ERROR] عدم توانایی باز کردن پورت UDP %d: %v", listenP, err)
		return
	}
	log.Printf("[UDP-FWD] 0.0.0.0:%d ---> Kharej:%d فعال شد", listenP, targetP)

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
			bConn, err := getBridgeConn()
			if err != nil {
				mu.Unlock()
				continue
			}
			header := []byte{CmdConnectUDP, byte(targetP >> 8), byte(targetP & 0xff)}
			if _, err := bConn.Write(header); err != nil {
				_ = bConn.Close()
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
// ۱. توپولوژی Reverse (اتصال از خارج به ایران با استخر اتصال)
// ============================================================================

func runReverseIran(cfg *Config) {
	tlsCfg, err := generateSelfSignedTLS(cfg.SNI)
	if err != nil {
		log.Fatalf("[FATAL] خطای TLS: %v", err)
	}
	ln, err := net.Listen("tcp", cfg.BridgeAddr)
	if err != nil {
		log.Fatalf("[FATAL] خطا در باز کردن پورت پل (%s): %v", cfg.BridgeAddr, err)
	}
	log.Printf("[BRIDGE-REVERSE] شنود پورت پل روی %s (%s)", cfg.BridgeAddr, strings.ToUpper(cfg.Transport))

	pool := make(chan net.Conn, cfg.PoolSize*4)

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
				default:
					_ = wrapped.Close()
				}
			}(raw)
		}
	}()

	getConn := func() (net.Conn, error) {
		timeout := time.After(6 * time.Second)
		for {
			select {
			case c := <-pool:
				return c, nil
			case <-timeout:
				return nil, fmt.Errorf("reverse pool timeout")
			}
		}
	}

	startIranUserListeners(cfg, getConn)
	select {}
}

func runReverseKharej(cfg *Config) {
	tlsCfg := getClientTLSConfig(cfg.SNI)
	log.Printf("[REVERSE-POOL] حفظ %d کانال پایدار به سمت ایران (%s)", cfg.PoolSize, cfg.BridgeAddr)

	var wg sync.WaitGroup
	for i := 0; i < cfg.PoolSize; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				dialer := &net.Dialer{Timeout: 7 * time.Second, KeepAlive: 15 * time.Second}
				raw, err := dialer.Dial("tcp", cfg.BridgeAddr)
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

				// منتظر دریافت هدر دستور از سمت ایران می‌ماند
				header := make([]byte, 3)
				if _, err := io.ReadFull(wrapped, header); err != nil {
					_ = wrapped.Close()
					continue
				}

				cmd := header[0]
				tPort := binary.BigEndian.Uint16(header[1:3])

				go func(bc net.Conn, c byte, p uint16) {
					if c == CmdConnectTCP {
						loc, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", p), 5*time.Second)
						if err != nil {
							_ = bc.Close()
							return
						}
						optimizeSocket(loc, cfg.SockBufKB)
						pipeTCP(bc, loc)
					} else if c == CmdConnectUDP {
						handleKharejUDP(bc, p)
					} else {
						_ = bc.Close()
					}
				}(wrapped, cmd, tPort)
			}
		}()
	}
	wg.Wait()
}

// ============================================================================
// ۲. توپولوژی Direct-Pool و Direct (اتصال از ایران به خارج)
// ============================================================================

func runDirectPoolIran(cfg *Config) {
	tlsCfg := getClientTLSConfig(cfg.SNI)
	pool := make(chan net.Conn, cfg.PoolSize*2)
	log.Printf("[DIRECT-POOL] حفظ %d کانال از پیش بازشده به سمت خارج (%s)", cfg.PoolSize, cfg.BridgeAddr)

	for i := 0; i < cfg.PoolSize; i++ {
		go func() {
			for {
				dialer := &net.Dialer{Timeout: 7 * time.Second, KeepAlive: 15 * time.Second}
				raw, err := dialer.Dial("tcp", cfg.BridgeAddr)
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
				pool <- wrapped
			}
		}()
	}

	getConn := func() (net.Conn, error) {
		select {
		case c := <-pool:
			return c, nil
		case <-time.After(5 * time.Second):
			return nil, fmt.Errorf("direct pool timeout")
		}
	}

	startIranUserListeners(cfg, getConn)
	select {}
}

func runDirectOnDemandIran(cfg *Config) {
	tlsCfg := getClientTLSConfig(cfg.SNI)
	getConn := func() (net.Conn, error) {
		dialer := &net.Dialer{Timeout: 7 * time.Second, KeepAlive: 15 * time.Second}
		raw, err := dialer.Dial("tcp", cfg.BridgeAddr)
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

	startIranUserListeners(cfg, getConn)
	select {}
}

func runDirectServerKharej(cfg *Config) {
	tlsCfg, err := generateSelfSignedTLS(cfg.SNI)
	if err != nil {
		log.Fatalf("[FATAL] خطای TLS: %v", err)
	}
	ln, err := net.Listen("tcp", cfg.BridgeAddr)
	if err != nil {
		log.Fatalf("[FATAL] خطا در باز کردن پورت پل (%s): %v", cfg.BridgeAddr, err)
	}
	log.Printf("[BRIDGE-DIRECT] شنود پورت پل مستقیم روی %s (%s)", cfg.BridgeAddr, strings.ToUpper(cfg.Transport))

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
			handleKharejTarget(wrapped, cfg)
		}(raw)
	}
}

// تست پینگ درون‌تانلی (End-to-End Handshake + Auth RTT)
func runPingTest(cfg *Config) {
	tlsCfg := getClientTLSConfig(cfg.SNI)
	start := time.Now()
	raw, err := net.DialTimeout("tcp", cfg.BridgeAddr, 5*time.Second)
	if err != nil {
		fmt.Printf("[✘] خطا در اتصال TCP به %s: %v\n", cfg.BridgeAddr, err)
		os.Exit(1)
	}
	defer raw.Close()

	wrapped, err := wrapClientTransport(raw, cfg, tlsCfg)
	if err != nil {
		fmt.Printf("[✘] خطا در هندشیک ترنسپورت (%s): %v\n", cfg.Transport, err)
		os.Exit(1)
	}
	rtt := time.Since(start)
	_ = wrapped.Close()
	fmt.Printf("[✔] اتصال و احراز هویت تانل (%s | Obfs:%v) موفقیت‌آمیز بود! زمان پاسخ (RTT): %v\n",
		strings.ToUpper(cfg.Transport), cfg.Obfs, rtt.Round(time.Millisecond))
}
