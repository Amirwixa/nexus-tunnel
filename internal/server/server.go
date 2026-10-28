package server

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/nexustunnel/nexus/config"
	"github.com/nexustunnel/nexus/internal/ai"
	"github.com/nexustunnel/nexus/internal/kernel"
	"github.com/nexustunnel/nexus/internal/transport"
	log "github.com/sirupsen/logrus"
	"github.com/xtaci/smux"
)

type Server struct {
	fullCfg      *config.Config
	cfg          *config.NodeConfig
	portMappings map[uint16]string
	sessionPool  []*smux.Session
	poolMu       sync.RWMutex
	rrIndex      uint64
	healer       *ai.Healer
	hopListener  net.Listener
	hopPort      uint16
}

func NewServer(fullCfg *config.Config) (*Server, error) {
	cfg := fullCfg.Server
	mappings := make(map[uint16]string)
	for _, entry := range cfg.Ports {
		p, target, err := config.ParsePortMapping(entry)
		if err != nil {
			return nil, err
		}
		mappings[p] = target
		log.Infof("[%s] Port mapping registered: %d -> %s", fullCfg.Role, p, target)
	}

	s := &Server{
		fullCfg:      fullCfg,
		cfg:          cfg,
		portMappings: mappings,
	}
	s.healer = ai.NewHealer(fullCfg, s.ApplyAIMutation)
	return s, nil
}

func (s *Server) ApplyAIMutation(d ai.MutationDecision) {
	s.fullCfg.Mu.Lock()
	if d.NewFakeSNI != "" {
		s.cfg.FakeSNI = d.NewFakeSNI
	}
	if d.NewMuxFrameSize >= 4096 && d.NewMuxFrameSize <= 65535 {
		s.cfg.MuxFrameSize = d.NewMuxFrameSize
	}
	if d.NewMSSClamp >= 1200 && d.NewMSSClamp <= 1460 && d.NewMSSClamp != s.cfg.MSSClamp {
		s.cfg.MSSClamp = d.NewMSSClamp
		go kernel.ApplyKernelHardening(d.NewMSSClamp)
	}
	s.fullCfg.Mu.Unlock()

	log.Infof("[AI-Mutation Applied on Server] SNI=%s | FrameSize=%d | MSS=%d | Reason=%s",
		s.cfg.FakeSNI, s.cfg.MuxFrameSize, s.cfg.MSSClamp, d.AnalysisReason)
}

func (s *Server) Start() error {
	kernel.ApplyKernelHardening(s.cfg.MSSClamp)
	go s.healer.StartAutonomousLoop()

	lc := transport.ListenConfigKernel()
	listener, err := lc.Listen(context.Background(), "tcp", s.cfg.BindAddr)
	if err != nil {
		return fmt.Errorf("failed to bind primary tunnel port %s: %w", s.cfg.BindAddr, err)
	}
	defer listener.Close()

	log.Infof("[%s] Primary Tunnel listening on %s", s.fullCfg.Role, s.cfg.BindAddr)

	if s.fullCfg.Polymorph != nil && s.fullCfg.Polymorph.EnablePortHopping {
		go s.maintainHopListener()
	}

	if s.fullCfg.Role == config.ModeReverseServer {
		go s.cleanupDeadSessionsLoop()
		for port := range s.portMappings {
			go s.listenUserTCP(port)
			if s.cfg.EnableUDP {
				go s.listenUserUDP(port)
			}
		}
	}

	s.acceptLoop(listener)
	return nil
}

func (s *Server) maintainHopListener() {
	lc := transport.ListenConfigKernel()
	poly := s.fullCfg.Polymorph
	for {
		interval := poly.HopIntervalSec
		if interval <= 0 {
			interval = 300
		}
		slot := time.Now().Unix() / interval
		dynPort, dynSNI := transport.ComputeDynamicSlot(s.cfg.Token, slot, poly.HopPortMin, poly.HopPortMax, poly.SNIList)

		if dynPort != s.hopPort {
			if s.hopListener != nil {
				_ = s.hopListener.Close()
			}
			addr := fmt.Sprintf("0.0.0.0:%d", dynPort)
			ln, err := lc.Listen(context.Background(), "tcp", addr)
			if err == nil {
				s.hopListener = ln
				s.hopPort = dynPort
				log.Infof("[Polymorph-Hop] Active TOTP Hop Listener rotated to 0.0.0.0:%d (Synced SNI: %s)", dynPort, dynSNI)
				go s.acceptLoop(ln)
			}
		}
		time.Sleep(5 * time.Second)
	}
}

func (s *Server) acceptLoop(ln net.Listener) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		transport.TuneTCPConn(conn, s.cfg.Nodelay)
		go s.handleTunnelConn(conn)
	}
}

func (s *Server) handleTunnelConn(rawConn net.Conn) {
	remote := rawConn.RemoteAddr().String()
	obfConn, err := transport.PerformHandshakeServer(rawConn, s.cfg.Token, 8*time.Second)
	if err != nil {
		s.healer.RecordError(err.Error())
		_ = rawConn.Close()
		return
	}

	kernel.InspectSocketKernel(rawConn)
	smuxCfg := transport.DefaultSmuxConfig(s.cfg.MuxFrameSize, s.cfg.Heartbeat)

	if s.fullCfg.Role == config.ModeReverseServer {
		sess, err := smux.Client(obfConn, smuxCfg)
		if err != nil {
			_ = obfConn.Close()
			return
		}
		s.poolMu.Lock()
		s.sessionPool = append(s.sessionPool, sess)
		total := len(s.sessionPool)
		s.poolMu.Unlock()
		log.Infof("[Reverse-Server] Kharej worker joined pool from %s (Active Pool: %d)", remote, total)

		// Listen for control streams from Kharej on this session
		go func(sess *smux.Session) {
			for {
				stream, err := sess.AcceptStream()
				if err != nil {
					break
				}
				go HandleExitStream(stream, s.portMappings, s.cfg.Nodelay, s.ApplyAIMutation)
			}
		}(sess)
		return
	}

	sess, err := smux.Server(obfConn, smuxCfg)
	if err != nil {
		_ = obfConn.Close()
		return
	}
	defer sess.Close()

	for {
		stream, err := sess.AcceptStream()
		if err != nil {
			break
		}
		go HandleExitStream(stream, s.portMappings, s.cfg.Nodelay, s.ApplyAIMutation)
	}
}

func (s *Server) getSession() (*smux.Session, error) {
	s.poolMu.RLock()
	defer s.poolMu.RUnlock()
	n := len(s.sessionPool)
	if n == 0 {
		return nil, fmt.Errorf("no active reverse sessions in pool")
	}
	for i := 0; i < n; i++ {
		idx := atomic.AddUint64(&s.rrIndex, 1) % uint64(n)
		sess := s.sessionPool[idx]
		if !sess.IsClosed() {
			return sess, nil
		}
	}
	return nil, fmt.Errorf("all reverse sessions closed")
}

func (s *Server) cleanupDeadSessionsLoop() {
	for {
		time.Sleep(2 * time.Second)
		s.poolMu.Lock()
		var alive []*smux.Session
		for _, sess := range s.sessionPool {
			if !sess.IsClosed() {
				alive = append(alive, sess)
			}
		}
		s.sessionPool = alive
		s.poolMu.Unlock()
	}
}

func (s *Server) listenUserTCP(port uint16) {
	lc := transport.ListenConfigKernel()
	addr := fmt.Sprintf("0.0.0.0:%d", port)
	ln, err := lc.Listen(context.Background(), "tcp", addr)
	if err != nil {
		log.Errorf("[Reverse-Server] Failed to bind user TCP port %d: %v", port, err)
		return
	}
	log.Infof("[Reverse-Server] Listening for user TCP on %s", addr)
	for {
		uConn, err := ln.Accept()
		if err != nil {
			continue
		}
		transport.TuneTCPConn(uConn, s.cfg.Nodelay)
		go func(c net.Conn) {
			defer c.Close()
			sess, err := s.getSession()
			if err != nil {
				return
			}
			stream, err := sess.OpenStream()
			if err != nil {
				return
			}
			defer stream.Close()
			atomic.AddInt64(&kernel.GlobalMetrics.ActiveStreams, 1)
			defer atomic.AddInt64(&kernel.GlobalMetrics.ActiveStreams, -1)

			if err := transport.WriteStreamHeader(stream, transport.ProtoTCP, port); err != nil {
				return
			}
			transport.PipeBidirectional(c, stream)
		}(uConn)
	}
}

func (s *Server) listenUserUDP(port uint16) {
	addr := &net.UDPAddr{IP: net.IPv4zero, Port: int(port)}
	uConn, err := net.ListenUDP("udp", addr)
	if err != nil {
		log.Errorf("[Reverse-Server] Failed to bind user UDP port %d: %v", port, err)
		return
	}
	log.Infof("[Reverse-Server] Listening for user UDP on 0.0.0.0:%d", port)

	mgr := transport.NewUDPRelayManager(port, s.getSession)
	buf := make([]byte, 65535)
	for {
		n, clientAddr, err := uConn.ReadFromUDP(buf)
		if err != nil || n == 0 {
			continue
		}
		payload := make([]byte, n)
		copy(payload, buf[:n])
		go mgr.HandlePacket(uConn, clientAddr, payload)
	}
}

func HandleExitStream(stream *smux.Stream, mappings map[uint16]string, nodelay bool, onMutate func(ai.MutationDecision)) {
	defer stream.Close()
	proto, targetPort, err := transport.ReadStreamHeader(stream)
	if err != nil {
		return
	}

	// Handle cross-server AI control synchronization
	if proto == transport.ProtoControlSync {
		data, err := io.ReadAll(stream)
		if err == nil && onMutate != nil {
			var decision ai.MutationDecision
			if json.Unmarshal(data, &decision) == nil {
				onMutate(decision)
			}
		}
		return
	}

	atomic.AddInt64(&kernel.GlobalMetrics.ActiveStreams, 1)
	defer atomic.AddInt64(&kernel.GlobalMetrics.ActiveStreams, -1)

	targetAddr, ok := mappings[targetPort]
	if !ok {
		targetAddr = fmt.Sprintf("127.0.0.1:%d", targetPort)
	}

	if proto == transport.ProtoUDP {
		transport.HandleUDPServerStream(stream, targetAddr)
		return
	}

	destConn, err := transport.DialKernel(targetAddr, 5*time.Second, nodelay)
	if err != nil {
		return
	}
	defer destConn.Close()
	transport.PipeBidirectional(stream, destConn)
}
