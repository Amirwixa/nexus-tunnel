package transport

import (
	"encoding/binary"
	"io"
	"net"
	"sync"
	"time"

	"github.com/xtaci/smux"
)

type UDPRelaySession struct {
	stream     *smux.Stream
	lastActive time.Time
	isClosed   bool
	mu         sync.Mutex
}

type UDPRelayManager struct {
	sessions map[string]*UDPRelaySession
	mu       sync.Mutex
	getSess  func() (*smux.Session, error)
	port     uint16
}

func NewUDPRelayManager(port uint16, getSess func() (*smux.Session, error)) *UDPRelayManager {
	mgr := &UDPRelayManager{
		sessions: make(map[string]*UDPRelaySession),
		getSess:  getSess,
		port:     port,
	}
	go mgr.cleanupLoop()
	return mgr
}

func (m *UDPRelayManager) cleanupLoop() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		m.mu.Lock()
		now := time.Now()
		for k, s := range m.sessions {
			s.mu.Lock()
			if now.Sub(s.lastActive) > 60*time.Second || s.isClosed {
				s.isClosed = true
				_ = s.stream.Close()
				delete(m.sessions, k)
			}
			s.mu.Unlock()
		}
		m.mu.Unlock()
	}
}

func (m *UDPRelayManager) HandlePacket(uConn *net.UDPConn, clientAddr *net.UDPAddr, data []byte) {
	key := clientAddr.String()

	m.mu.Lock()
	sess, exists := m.sessions[key]
	if !exists || sess.isClosed {
		muxSess, err := m.getSess()
		if err != nil {
			m.mu.Unlock()
			return
		}
		stream, err := muxSess.OpenStream()
		if err != nil {
			m.mu.Unlock()
			return
		}
		if err := WriteStreamHeader(stream, ProtoUDP, m.port); err != nil {
			_ = stream.Close()
			m.mu.Unlock()
			return
		}

		sess = &UDPRelaySession{
			stream:     stream,
			lastActive: time.Now(),
			isClosed:   false,
		}
		m.sessions[key] = sess

		go func(s *UDPRelaySession, addr *net.UDPAddr) {
			defer func() {
				s.mu.Lock()
				s.isClosed = true
				s.mu.Unlock()
				_ = s.stream.Close()
				m.mu.Lock()
				delete(m.sessions, key)
				m.mu.Unlock()
			}()

			var lenBuf [2]byte
			buf := make([]byte, 65535)
			for {
				_ = s.stream.SetReadDeadline(time.Now().Add(60 * time.Second))
				if _, err := io.ReadFull(s.stream, lenBuf[:]); err != nil {
					return
				}
				pktLen := int(binary.BigEndian.Uint16(lenBuf[:]))
				if pktLen <= 0 || pktLen > len(buf) {
					return
				}
				if _, err := io.ReadFull(s.stream, buf[:pktLen]); err != nil {
					return
				}
				s.mu.Lock()
				s.lastActive = time.Now()
				s.mu.Unlock()
				_, _ = uConn.WriteToUDP(buf[:pktLen], addr)
			}
		}(sess, clientAddr)
	}
	m.mu.Unlock()

	sess.mu.Lock()
	defer sess.mu.Unlock()
	sess.lastActive = time.Now()

	var lenBuf [2]byte
	binary.BigEndian.PutUint16(lenBuf[:], uint16(len(data)))
	_ = sess.stream.SetWriteDeadline(time.Now().Add(10 * time.Second))
	if _, err := sess.stream.Write(lenBuf[:]); err != nil {
		sess.isClosed = true
		_ = sess.stream.Close()
		return
	}
	if _, err := sess.stream.Write(data); err != nil {
		sess.isClosed = true
		_ = sess.stream.Close()
		return
	}
}

func HandleUDPServerStream(stream *smux.Stream, targetAddr string) {
	defer stream.Close()

	uConn, err := net.Dial("udp", targetAddr)
	if err != nil {
		return
	}
	defer uConn.Close()

	var wg sync.WaitGroup
	wg.Add(2)

	go func() {
		defer wg.Done()
		var lenBuf [2]byte
		buf := make([]byte, 65535)
		for {
			_ = stream.SetReadDeadline(time.Now().Add(60 * time.Second))
			if _, err := io.ReadFull(stream, lenBuf[:]); err != nil {
				return
			}
			pktLen := int(binary.BigEndian.Uint16(lenBuf[:]))
			if pktLen <= 0 || pktLen > len(buf) {
				return
			}
			if _, err := io.ReadFull(stream, buf[:pktLen]); err != nil {
				return
			}
			_ = uConn.SetWriteDeadline(time.Now().Add(5 * time.Second))
			if _, err := uConn.Write(buf[:pktLen]); err != nil {
				return
			}
		}
	}()

	go func() {
		defer wg.Done()
		var lenBuf [2]byte
		buf := make([]byte, 65535)
		for {
			_ = uConn.SetReadDeadline(time.Now().Add(60 * time.Second))
			n, err := uConn.Read(buf)
			if err != nil || n == 0 {
				return
			}
			binary.BigEndian.PutUint16(lenBuf[:], uint16(n))
			_ = stream.SetWriteDeadline(time.Now().Add(5 * time.Second))
			if _, err := stream.Write(lenBuf[:]); err != nil {
				return
			}
			if _, err := stream.Write(buf[:n]); err != nil {
				return
			}
		}
	}()

	wg.Wait()
}
