package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/hex"
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
	"syscall"
	"time"
)

// ساختار کانفیگ استاندارد JSON (بدون نیاز به کتابخانه خارجی TOML)
type Config struct {
	Role       string   `json:"role"`        // "iran" یا "kharej"
	Mode       string   `json:"mode"`        // "reverse" یا "direct"
	BridgeAddr string   `json:"bridge_addr"` // در reverse: روی ایران "0.0.0.0:4443" و روی خارج "IRAN_IP:4443"
	Token      string   `json:"token"`       // کلید مشترک امنیتی (PSK)
	SNI        string   `json:"sni"`         // دامنه پوششی برای TLS Handshake
	PoolSize   int      `json:"pool_size"`   // تعداد کانکشن‌های آماده در استخر اتصال
	Ports      []string `json:"ports"`       // لیست پورت‌ها: ["443:443", "2053:2053"] یا ["8443"]
}

const (
	CmdHeartbeat byte = 0x01
	CmdConnect   byte = 0x02
	SocketBufSize     = 4 * 1024 * 1024 // 4MB Socket Buffer
)

func main() {
	configPath := flag.String("c", "/etc/nexus-tunnel/config.json", "Path to configuration file")
	flag.Parse()

	cfg, err := loadConfig(*configPath)
	if err != nil {
		log.Fatalf("[FATAL] خطا در خواندن فایل کانفیگ: %v", err)
	}

	log.Printf("[INFO] راه‌اندازی Nexus-Tunnel v5.0 | نقش: %s | مد: %s | استخر اتصال: %d",
		strings.ToUpper(cfg.Role), strings.ToUpper(cfg.Mode), cfg.PoolSize)

	ctxStop := make(chan os.Signal, 1)
	signal.Notify(ctxStop, syscall.SIGINT, syscall.SIGTERM)

	switch strings.ToLower(cfg.Mode) {
	case "reverse":
		if strings.ToLower(cfg.Role) == "iran" {
			go runReverseIran(cfg)
		} else {
			go runReverseKharej(cfg)
		}
	case "direct":
		if strings.ToLower(cfg.Role) == "iran" {
			go runDirectIran(cfg)
		} else {
			go runDirectKharej(cfg)
		}
	default:
		log.Fatalf("[FATAL] مد نامعتبر در کانفیگ: %s (باید reverse یا direct باشد)", cfg.Mode)
	}

	<-ctxStop
	log.Println("[INFO] دریافت سیگنال توقف؛ بستن ایمن تانل...")
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
	if cfg.PoolSize <= 0 {
		cfg.PoolSize = 16
	}
	if cfg.SNI == "" {
		cfg.SNI = "www.cloudflare.com"
	}
	return &cfg, nil
}

// بهینه‌سازی سطح کرنل روی سوکت TCP
func optimizeSocket(conn net.Conn) {
	tcpConn, ok := conn.(*net.TCPConn)
	if !ok {
		return
	}
	_ = tcpConn.SetNoDelay(true)
	_ = tcpConn.SetKeepAlive(true)
	_ = tcpConn.SetKeepAlivePeriod(15 * time.Second)
	_ = tcpConn.SetReadBuffer(SocketBufSize)
	_ = tcpConn.SetWriteBuffer(SocketBufSize)
}

// تولید گواهی TLS 1.3 خودامضا در حافظه (بدون نیاز به فایل روی دیسک)
func generateSelfSignedTLS(sni string) (*tls.Config, error) {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serialNumber, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	template := x509.Certificate{
		SerialNumber: serialNumber,
		Subject:      pkix.Name{CommonName: sni},
		NotBefore:    time.Now().Add(-1 * time.Hour),
		NotAfter:     time.Now().Add(365 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{sni},
	}
	derBytes, err := x509.CreateCertificate(rand.Reader, &template, &template, &priv.PublicKey, priv)
	if err != nil {
		return nil, err
	}
	cert := tls.Certificate{
		Certificate: [][]byte{derBytes},
		PrivateKey:  priv,
	}
	return &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS13,
	}, nil
}

func getClientTLSConfig(sni string) *tls.Config {
	return &tls.Config{
		ServerName:         sni,
		InsecureSkipVerify: true, // احراز هویت واقعی با HMAC-SHA256 انجام می‌شود
		MinVersion:         tls.VersionTLS13,
	}
}

// تولید و بررسی امضای HMAC-SHA256 برای جلوگیری از Active Probing
func computeHMAC(token string, nonce []byte) []byte {
	mac := hmac.New(sha256.New, []byte(token))
	mac.Write(nonce)
	return mac.Sum(nil)
}

func clientHandshake(conn net.Conn, token string) error {
	_ = conn.SetDeadline(time.Now().Add(8 * time.Second))
	defer conn.SetDeadline(time.Time{})

	nonce := make([]byte, 16)
	if _, err := rand.Read(nonce); err != nil {
		return err
	}
	sig := computeHMAC(token, nonce)
	buf := append(nonce, sig...) // 16 + 32 = 48 bytes
	_, err := conn.Write(buf)
	return err
}

func serverVerifyHandshake(conn net.Conn, token string) error {
	_ = conn.SetDeadline(time.Now().Add(8 * time.Second))
	defer conn.SetDeadline(time.Time{})

	buf := make([]byte, 48)
	if _, err := io.ReadFull(conn, buf); err != nil {
		return err
	}
	nonce := buf[:16]
	receivedSig := buf[16:48]
	expectedSig := computeHMAC(token, nonce)
	if !hmac.Equal(receivedSig, expectedSig) {
		return fmt.Errorf("invalid HMAC token signature")
	}
	return nil
}

// استخراج پورت مبدا و مقصد از فرمت "8443:443" یا "443"
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

// انتقال دوطرفه Zero-Copy
func pipeConnections(c1, c2 net.Conn) {
	var wg sync.WaitGroup
	wg.Add(2)

	copyStream := func(dst, src net.Conn) {
		defer wg.Done()
		_, _ = io.Copy(dst, src)
		if tcpDst, ok := dst.(*net.TCPConn); ok {
			_ = tcpDst.CloseWrite()
		} else {
			_ = dst.Close()
		}
	}

	go copyStream(c1, c2)
	go copyStream(c2, c1)
	wg.Wait()
	_ = c1.Close()
	_ = c2.Close()
}

// ============================================================================
// ۱. حالت تانل معکوس (Reverse Mode)
// ============================================================================

func runReverseIran(cfg *Config) {
	tlsCfg, err := generateSelfSignedTLS(cfg.SNI)
	if err != nil {
		log.Fatalf("[FATAL] خطا در تولید گواهی TLS: %v", err)
	}

	bridgeLn, err := net.Listen("tcp", cfg.BridgeAddr)
	if err != nil {
		log.Fatalf("[FATAL] خطا در باز کردن پورت پل (%s): %v", cfg.BridgeAddr, err)
	}
	log.Printf("[BRIDGE] پورت پل معکوس روی %s فعال شد (منتظر اتصال سرور خارج...)", cfg.BridgeAddr)

	pool := make(chan net.Conn, cfg.PoolSize*4)

	// پذیرش کانکشن‌های استخر از سمت سرور خارج
	go func() {
		for {
			rawConn, err := bridgeLn.Accept()
			if err != nil {
				continue
			}
			optimizeSocket(rawConn)
			go func(c net.Conn) {
				tlsConn := tls.Server(c, tlsCfg)
				if err := serverVerifyHandshake(tlsConn, cfg.Token); err != nil {
					_ = tlsConn.Close()
					return
				}
				select {
				case pool <- tlsConn:
				default:
					_ = tlsConn.Close()
				}
			}(rawConn)
		}
	}()

	// باز کردن پورت‌های ورودی کاربران روی سرور ایران
	for _, portSpec := range cfg.Ports {
		listenPort, targetPort, err := parsePortSpec(portSpec)
		if err != nil {
			log.Printf("[ERROR] فرمت پورت نامعتبر (%s): %v", portSpec, err)
			continue
		}
		go func(lPort, tPort uint16) {
			ln, err := net.Listen("tcp", fmt.Sprintf("0.0.0.0:%d", lPort))
			if err != nil {
				log.Printf("[ERROR] عدم توانایی در باز کردن پورت ورودی %d: %v", lPort, err)
				return
			}
			log.Printf("[FORWARD] پورت ورودی %d (ایران) ---> پورت مقصد %d (خارج) فعال شد", lPort, tPort)

			for {
				userConn, err := ln.Accept()
				if err != nil {
					continue
				}
				optimizeSocket(userConn)

				go func(uConn net.Conn) {
					var bridgeConn net.Conn
					timeout := time.After(6 * time.Second)

					// دریافت یک کانکشن سالم از استخر
					for bridgeConn == nil {
						select {
						case c := <-pool:
							// ارسال هدر ۵ بایتی: [CmdConnect, PortHigh, PortLow]
							header := []byte{CmdConnect, byte(tPort >> 8), byte(tPort & 0xff)}
							_ = c.SetWriteDeadline(time.Now().Add(3 * time.Second))
							if _, err := c.Write(header); err != nil {
								_ = c.Close()
								continue
							}
							_ = c.SetWriteDeadline(time.Time{})
							bridgeConn = c
						case <-timeout:
							log.Printf("[WARN] استخر اتصال خالی است! اتصال کاربر روی پورت %d رد شد", lPort)
							_ = uConn.Close()
							return
						}
					}
					pipeConnections(uConn, bridgeConn)
				}(userConn)
			}
		}(listenPort, targetPort)
	}
}

func runReverseKharej(cfg *Config) {
	tlsCfg := getClientTLSConfig(cfg.SNI)
	log.Printf("[POOL] شروع حفظ %d کانال معکوس هم‌زمان به سمت %s", cfg.PoolSize, cfg.BridgeAddr)

	var wg sync.WaitGroup
	for i := 0; i < cfg.PoolSize; i++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			for {
				dialer := &net.Dialer{Timeout: 8 * time.Second, KeepAlive: 15 * time.Second}
				rawConn, err := dialer.Dial("tcp", cfg.BridgeAddr)
				if err != nil {
					time.Sleep(2 * time.Second)
					continue
				}
				optimizeSocket(rawConn)

				tlsConn := tls.Client(rawConn, tlsCfg)
				if err := clientHandshake(tlsConn, cfg.Token); err != nil {
					_ = tlsConn.Close()
					time.Sleep(2 * time.Second)
					continue
				}

				// منتظر دستور اتصال از سمت سرور ایران می‌ماند
				header := make([]byte, 3)
				if _, err := io.ReadFull(tlsConn, header); err != nil {
					_ = tlsConn.Close()
					continue
				}

				if header[0] != CmdConnect {
					_ = tlsConn.Close()
					continue
				}

				targetPort := binary.BigEndian.Uint16(header[1:3])

				// باز کردن فوری یک کانال جایگزین در استخر و هندل کردن اتصال فعلی در گوروتین مجزا
				go func(bConn net.Conn, port uint16) {
					localConn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 5*time.Second)
					if err != nil {
						_ = bConn.Close()
						return
					}
					optimizeSocket(localConn)
					pipeConnections(bConn, localConn)
				}(tlsConn, targetPort)
			}
		}(i)
	}
	wg.Wait()
}

// ============================================================================
// ۲. حالت تانل مستقیم (Direct Mode)
// ============================================================================

func runDirectIran(cfg *Config) {
	tlsCfg := getClientTLSConfig(cfg.SNI)

	for _, portSpec := range cfg.Ports {
		listenPort, targetPort, err := parsePortSpec(portSpec)
		if err != nil {
			log.Printf("[ERROR] فرمت پورت نامعتبر (%s): %v", portSpec, err)
			continue
		}
		go func(lPort, tPort uint16) {
			ln, err := net.Listen("tcp", fmt.Sprintf("0.0.0.0:%d", lPort))
			if err != nil {
				log.Printf("[ERROR] خطا در باز کردن پورت %d: %v", lPort, err)
				return
			}
			log.Printf("[DIRECT] پورت %d (ایران) ---> %s (پورت مقصد %d خارج)", lPort, cfg.BridgeAddr, tPort)

			for {
				userConn, err := ln.Accept()
				if err != nil {
					continue
				}
				optimizeSocket(userConn)

				go func(uConn net.Conn) {
					dialer := &net.Dialer{Timeout: 8 * time.Second, KeepAlive: 15 * time.Second}
					rawConn, err := dialer.Dial("tcp", cfg.BridgeAddr)
					if err != nil {
						_ = uConn.Close()
						return
					}
					optimizeSocket(rawConn)

					tlsConn := tls.Client(rawConn, tlsCfg)
					if err := clientHandshake(tlsConn, cfg.Token); err != nil {
						_ = tlsConn.Close()
						_ = uConn.Close()
						return
					}

					header := []byte{CmdConnect, byte(tPort >> 8), byte(tPort & 0xff)}
					if _, err := tlsConn.Write(header); err != nil {
						_ = tlsConn.Close()
						_ = uConn.Close()
						return
					}
					pipeConnections(uConn, tlsConn)
				}(userConn)
			}
		}(listenPort, targetPort)
	}
	select {}
}

func runDirectKharej(cfg *Config) {
	tlsCfg, err := generateSelfSignedTLS(cfg.SNI)
	if err != nil {
		log.Fatalf("[FATAL] خطا در تولید گواهی TLS: %v", err)
	}

	ln, err := net.Listen("tcp", cfg.BridgeAddr)
	if err != nil {
		log.Fatalf("[FATAL] خطا در باز کردن پورت پل مستقیم (%s): %v", cfg.BridgeAddr, err)
	}
	log.Printf("[DIRECT-SERVER] پورت پل مستقیم روی %s فعال شد", cfg.BridgeAddr)

	for {
		rawConn, err := ln.Accept()
		if err != nil {
			continue
		}
		optimizeSocket(rawConn)

		go func(c net.Conn) {
			tlsConn := tls.Server(c, tlsCfg)
			if err := serverVerifyHandshake(tlsConn, cfg.Token); err != nil {
				_ = tlsConn.Close()
				return
			}

			header := make([]byte, 3)
			if _, err := io.ReadFull(tlsConn, header); err != nil || header[0] != CmdConnect {
				_ = tlsConn.Close()
				return
			}

			targetPort := binary.BigEndian.Uint16(header[1:3])
			localConn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", targetPort), 5*time.Second)
			if err != nil {
				_ = tlsConn.Close()
				return
			}
			optimizeSocket(localConn)
			pipeConnections(tlsConn, localConn)
		}(rawConn)
	}
}

// تابع کمکی برای تولید توکن تصادفی در صورت نیاز
func generateRandomToken() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
