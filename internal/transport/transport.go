package transport

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"sync"
	"syscall"
	"time"

	"github.com/xtaci/smux"
	"golang.org/x/sys/unix"
)

const (
	ProtoTCP         byte = 0x01
	ProtoUDP         byte = 0x02
	ProtoControlSync byte = 0xFF
	DefaultBufLen         = 64 * 1024
)

var BufferPool = sync.Pool{
	New: func() interface{} {
		b := make([]byte, DefaultBufLen)
		return &b
	},
}

// ComputeDynamicSlot deterministically calculates a dynamic port and SNI based on time window
func ComputeDynamicSlot(token string, timeStep int64, minPort, maxPort uint16, sniList []string) (uint16, string) {
	var buf [8]byte
	binary.BigEndian.PutUint64(buf[:], uint64(timeStep))
	mac := hmac.New(sha256.New, []byte(token))
	mac.Write(buf[:])
	sum := mac.Sum(nil)

	portRange := uint32(maxPort - minPort + 1)
	if portRange == 0 {
		portRange = 1000
	}
	val := binary.BigEndian.Uint32(sum[:4])
	dynPort := minPort + uint16(val%portRange)

	dynSNI := "speed.cloudflare.com"
	if len(sniList) > 0 {
		sniIdx := int(sum[4]) % len(sniList)
		dynSNI = sniList[sniIdx]
	}
	return dynPort, dynSNI
}

// ListenConfigKernel configures Linux kernel socket parameters for high throughput
func ListenConfigKernel() net.ListenConfig {
	return net.ListenConfig{
		Control: func(network, address string, c syscall.RawConn) error {
			return c.Control(func(fd uintptr) {
				_ = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_REUSEADDR, 1)
				_ = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_REUSEPORT, 1)
				_ = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_RCVBUF, 8*1024*1024)
				_ = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_SNDBUF, 8*1024*1024)
				_ = unix.SetsockoptInt(int(fd), unix.IPPROTO_TCP, unix.TCP_NODELAY, 1)
			})
		},
	}
}

// TuneTCPConn tunes active TCP connections for low latency & fast ACK
func TuneTCPConn(conn net.Conn, nodelay bool) {
	if tcpConn, ok := conn.(*net.TCPConn); ok {
		_ = tcpConn.SetNoDelay(nodelay)
		_ = tcpConn.SetKeepAlive(true)
		_ = tcpConn.SetKeepAlivePeriod(12 * time.Second)
		_ = tcpConn.SetReadBuffer(8 * 1024 * 1024)
		_ = tcpConn.SetWriteBuffer(8 * 1024 * 1024)
		if rawConn, err := tcpConn.SyscallConn(); err == nil {
			_ = rawConn.Control(func(fd uintptr) {
				_ = unix.SetsockoptInt(int(fd), unix.IPPROTO_TCP, unix.TCP_QUICKACK, 1)
			})
		}
	}
}

// DialKernel connects with optimized socket options
func DialKernel(addr string, timeout time.Duration, nodelay bool) (net.Conn, error) {
	dialer := &net.Dialer{
		Timeout:   timeout,
		KeepAlive: 12 * time.Second,
		Control: func(network, address string, c syscall.RawConn) error {
			return c.Control(func(fd uintptr) {
				_ = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_RCVBUF, 8*1024*1024)
				_ = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_SNDBUF, 8*1024*1024)
			})
		},
	}
	conn, err := dialer.DialContext(context.Background(), "tcp", addr)
	if err != nil {
		return nil, err
	}
	TuneTCPConn(conn, nodelay)
	return conn, nil
}

// ObfuscatedConn wraps a connection with high-speed stream obfuscation
type ObfuscatedConn struct {
	net.Conn
	rKey []byte
	wKey []byte
	rPos int
	wPos int
}

func NewObfuscatedConn(c net.Conn, token string, nonce []byte) *ObfuscatedConn {
	h := hmac.New(sha256.New, []byte(token))
	h.Write(nonce)
	baseKey := h.Sum(nil)

	streamKey := make([]byte, 256)
	for i := 0; i < 8; i++ {
		sh := sha256.Sum256(append(baseKey, byte(i)))
		copy(streamKey[i*32:(i+1)*32], sh[:])
	}

	return &ObfuscatedConn{
		Conn: c,
		rKey: streamKey,
		wKey: streamKey,
	}
}

func (o *ObfuscatedConn) Read(p []byte) (int, error) {
	n, err := o.Conn.Read(p)
	for i := 0; i < n; i++ {
		p[i] ^= o.rKey[(o.rPos+i)&0xFF]
	}
	o.rPos = (o.rPos + n) & 0xFF
	return n, err
}

func (o *ObfuscatedConn) Write(p []byte) (int, error) {
	bufPtr := BufferPool.Get().(*[]byte)
	buf := *bufPtr
	defer BufferPool.Put(bufPtr)

	if len(p) > len(buf) {
		buf = make([]byte, len(p))
	}
	for i := 0; i < len(p); i++ {
		buf[i] = p[i] ^ o.wKey[(o.wPos+i)&0xFF]
	}
	o.wPos = (o.wPos + len(p)) & 0xFF
	return o.Conn.Write(buf[:len(p)])
}

// PerformHandshakeClient executes TLS 1.3 disguise handshake from client to server
func PerformHandshakeClient(conn net.Conn, token string, timeout time.Duration) (net.Conn, error) {
	_ = conn.SetDeadline(time.Now().Add(timeout))
	defer conn.SetDeadline(time.Time{})

	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}

	var padRand [1]byte
	_, _ = rand.Read(padRand[:])
	padLen := int(padRand[0]%64) + 16
	padding := make([]byte, padLen)
	_, _ = rand.Read(padding)

	mac := hmac.New(sha256.New, []byte(token))
	mac.Write(nonce)
	mac.Write([]byte{byte(padLen)})
	mac.Write(padding)
	sig := mac.Sum(nil)

	bodyLen := uint16(32 + 1 + padLen + 32)
	var pkt bytes.Buffer
	pkt.Write([]byte{0x16, 0x03, 0x03}) // TLS 1.3 Handshake Record
	_ = binary.Write(&pkt, binary.BigEndian, bodyLen)
	pkt.Write(nonce)
	pkt.WriteByte(byte(padLen))
	pkt.Write(padding)
	pkt.Write(sig)

	if _, err := conn.Write(pkt.Bytes()); err != nil {
		return nil, fmt.Errorf("write polymorphic TLS handshake failed: %w", err)
	}

	// Server replies with 5 bytes TLS header (0x17 0x03 0x03 0x00 0x20) + 32 bytes HMAC
	resp := make([]byte, 37)
	if _, err := io.ReadFull(conn, resp); err != nil {
		return nil, fmt.Errorf("read TLS handshake response failed: %w", err)
	}

	if resp[0] != 0x17 || resp[1] != 0x03 || resp[2] != 0x03 {
		return nil, fmt.Errorf("invalid TLS record type in server response")
	}

	ackMac := hmac.New(sha256.New, []byte(token))
	ackMac.Write(sig)
	if !hmac.Equal(resp[5:], ackMac.Sum(nil)) {
		return nil, fmt.Errorf("server HMAC verification failed")
	}

	return NewObfuscatedConn(conn, token, nonce), nil
}

// PerformHandshakeServer authenticates client TLS 1.3 disguise handshake
func PerformHandshakeServer(conn net.Conn, token string, timeout time.Duration) (net.Conn, error) {
	_ = conn.SetDeadline(time.Now().Add(timeout))
	defer conn.SetDeadline(time.Time{})

	var tlsHdr [5]byte
	if _, err := io.ReadFull(conn, tlsHdr[:]); err != nil {
		return nil, err
	}
	if tlsHdr[0] != 0x16 || tlsHdr[1] != 0x03 || tlsHdr[2] != 0x03 {
		return nil, fmt.Errorf("invalid TLS record magic")
	}

	bodyLen := binary.BigEndian.Uint16(tlsHdr[3:5])
	if bodyLen < 65 || bodyLen > 512 {
		return nil, fmt.Errorf("invalid handshake body length: %d", bodyLen)
	}

	body := make([]byte, bodyLen)
	if _, err := io.ReadFull(conn, body); err != nil {
		return nil, err
	}

	nonce := body[:32]
	padLen := int(body[32])
	if 33+padLen+32 != int(bodyLen) {
		return nil, fmt.Errorf("corrupted padding length")
	}
	padding := body[33 : 33+padLen]
	clientSig := body[33+padLen:]

	mac := hmac.New(sha256.New, []byte(token))
	mac.Write(nonce)
	mac.Write([]byte{byte(padLen)})
	mac.Write(padding)
	expectedSig := mac.Sum(nil)

	if !hmac.Equal(clientSig, expectedSig) {
		return nil, fmt.Errorf("authentication token mismatch")
	}

	ackMac := hmac.New(sha256.New, []byte(token))
	ackMac.Write(expectedSig)

	var resp bytes.Buffer
	resp.Write([]byte{0x17, 0x03, 0x03, 0x00, 0x20}) // TLS 1.3 AppData header, 32 bytes length
	resp.Write(ackMac.Sum(nil))

	if _, err := conn.Write(resp.Bytes()); err != nil {
		return nil, err
	}

	return NewObfuscatedConn(conn, token, nonce), nil
}

// DefaultSmuxConfig returns an optimized smux config
func DefaultSmuxConfig(frameSize int, heartbeat int) *smux.Config {
	cfg := smux.DefaultConfig()
	cfg.Version = 2
	cfg.MaxFrameSize = frameSize
	cfg.MaxReceiveBuffer = 8 * 1024 * 1024
	cfg.MaxStreamBuffer = 4 * 1024 * 1024
	cfg.KeepAliveInterval = time.Duration(heartbeat) * time.Second
	cfg.KeepAliveTimeout = time.Duration(heartbeat*3) * time.Second
	return cfg
}

func WriteStreamHeader(w io.Writer, proto byte, port uint16) error {
	var hdr [3]byte
	hdr[0] = proto
	binary.BigEndian.PutUint16(hdr[1:3], port)
	_, err := w.Write(hdr[:])
	return err
}

func ReadStreamHeader(r io.Reader) (byte, uint16, error) {
	var hdr [3]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return 0, 0, err
	}
	return hdr[0], binary.BigEndian.Uint16(hdr[1:3]), nil
}

// PipeBidirectional pipes between two streams using pooled buffers with TCP half-close preservation
func PipeBidirectional(c1 io.ReadWriteCloser, c2 io.ReadWriteCloser) {
	var wg sync.WaitGroup
	wg.Add(2)

	closeWrite := func(c io.Closer) {
		if cw, ok := c.(interface{ CloseWrite() error }); ok {
			_ = cw.CloseWrite()
		} else {
			_ = c.Close()
		}
	}

	pipe := func(dst io.ReadWriteCloser, src io.Reader) {
		defer wg.Done()
		bufPtr := BufferPool.Get().(*[]byte)
		buf := *bufPtr
		defer BufferPool.Put(bufPtr)

		_, _ = io.CopyBuffer(dst, src, buf)
		closeWrite(dst)
	}

	go pipe(c1, c2)
	go pipe(c2, c1)
	wg.Wait()
	_ = c1.Close()
	_ = c2.Close()
}
