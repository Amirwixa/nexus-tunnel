package client

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/nexustunnel/nexus/config"
	"github.com/nexustunnel/nexus/internal/ai"
	"github.com/nexustunnel/nexus/internal/kernel"
	"github.com/nexustunnel/nexus/internal/server"
	"github.com/nexustunnel/nexus/internal/transport"
	log "github.com/sirupsen/logrus"
	"github.com/xtaci/smux"
)

type Client struct {
	fullCfg      *config.Config
	cfg          *config.NodeConfig
	portMappings map[uint16]string
	sessionPool  []*smux.Session
	poolMu       sync.RWMutex
	rrIndex      uint64
	healer       *ai.Healer
	useHopPort   uint32
}

func NewClient(fullCfg *config.Config) (*Client, error) {
	cfg := fullCfg.Client
	mappings := make(map[uint16]string)
	for _, entry := range cfg.Ports {
		p, target, err := config.ParsePortMapping(entry)
		if err != nil {
			return nil, err
		}
		mappings[p] = target
	}
	c := &Client{
		fullCfg:      fullCfg,
		cfg:          cfg,
		portMappings: mappings,
	}
	c.healer = ai.NewHealer(fullCfg, c.ApplyAIMutation)
	return c, nil
}

func (c *Client) ApplyAIMutation(d ai.MutationDecision) {
	c.fullCfg.Mu.Lock()
	if d.NewFakeSNI != "" {
		c.cfg.FakeSNI = d.NewFakeSNI
	}
	if d.NewMuxFrameSize >= 4096 && d.NewMuxFrameSize <= 65535 {
		c.cfg.MuxFrameSize = d.NewMuxFrameSize
	}
	if d.NewMSSClamp >= 1200 && d.NewMSSClamp <= 1460 && d.NewMSSClamp != c.cfg.MSSClamp {
		c.cfg.MSSClamp = d.NewMSSClamp
		go kernel.ApplyKernelHardening(d.NewMSSClamp)
	}
	if d.ForcePortHop {
		atomic.StoreUint32(&c.useHopPort, 1)
	}
	c.fullCfg.Mu.Unlock()

	log.Infof("[AI-Mutation Applied on Client] SNI=%s | FrameSize=%d | MSS=%d | PortHop=%v | Reason=%s",
		c.cfg.FakeSNI, c.cfg.MuxFrameSize, c.cfg.MSSClamp, d.ForcePortHop, d.AnalysisReason)

	// Broadcast the mutation decision to the remote peer so both sides adapt simultaneously
	go c.broadcastMutation(d)
}

func (c *Client) broadcastMutation(d ai.MutationDecision) {
	sess, err := c.getSession()
	if err != nil {
		return
	}
	stream, err := sess.OpenStream()
	if err != nil {
		return
	}
	defer stream.Close()

	if err := transport.WriteStreamHeader(stream, transport.ProtoControlSync, 0); err != nil {
		return
	}
	data, _ := json.Marshal(d)
	_, _ = stream.Write(data)
	log.Infof("[AI-Mutation] Synchronized mutation decision with remote peer.")
}

func (c *Client) resolveTargetAddr(consecutiveFails int) string {
	poly := c.fullCfg.Polymorph
	if poly != nil && poly.EnablePortHopping && (consecutiveFails >= 2 || atomic.LoadUint32(&c.useHopPort) == 1) {
		host, _, err := net.SplitHostPort(c.cfg.RemoteAddr)
		if err == nil {
			interval := poly.HopIntervalSec
			if interval <= 0 {
				interval = 300
			}
			slot := time.Now().Unix() / interval
			dynPort, dynSNI := transport.ComputeDynamicSlot(c.cfg.Token, slot, poly.HopPortMin, poly.HopPortMax, poly.SNIList)
			c.fullCfg.Mu.Lock()
			c.cfg.FakeSNI = dynSNI
			c.fullCfg.Mu.Unlock()
			return fmt.Sprintf("%s:%d", host, dynPort)
		}
	}
	return c.cfg.RemoteAddr
}

func (c *Client) Start() error {
	kernel.ApplyKernelHardening(c.cfg.MSSClamp)
	go c.healer.StartAutonomousLoop()

	log.Infof("[%s] Starting Nexus-Omega Connector -> %s (Pool: %d)",
		c.fullCfg.Role, c.cfg.RemoteAddr, c.cfg.ConnectionPool)

	if c.fullCfg.Role == config.ModeReverseClient {
		var wg sync.WaitGroup
		for i := 0; i < c.cfg.ConnectionPool; i++ {
			wg.Add(1)
			go c.reverseWorker(i + 1)
		}
		wg.Wait()
		return nil
	}

	go c.maintainDirectPool()
	for port := range c.portMappings {
		go c.listenDirectUserTCP(port)
		if c.cfg.EnableUDP {
			go c.listenDirectUserUDP(port)
		}
	}
	select {}
}

func (c *Client) reverseWorker(workerID int) {
	consecutiveFails := 0
	for {
		targetAddr := c.resolveTargetAddr(consecutiveFails)
		rawConn, err := transport.DialKernel(targetAddr, 8*time.Second, c.cfg.Nodelay)
		if err != nil {
			consecutiveFails++
			c.healer.RecordError(err.Error())
			log.Warnf("[Reverse-Worker #%d] Dial %s failed (fail #%d): %v", workerID, targetAddr, consecutiveFails, err)
			time.Sleep(time.Duration(c.cfg.RetryInterval) * time.Second)
			continue
		}

		obfConn, err := transport.PerformHandshakeClient(rawConn, c.cfg.Token, 8*time.Second)
		if err != nil {
			consecutiveFails++
			c.healer.RecordError(err.Error())
			_ = rawConn.Close()
			time.Sleep(time.Duration(c.cfg.RetryInterval) * time.Second)
			continue
		}

		consecutiveFails = 0
		atomic.StoreUint32(&c.useHopPort, 0)
		kernel.InspectSocketKernel(rawConn)

		c.fullCfg.Mu.RLock()
		frameSize := c.cfg.MuxFrameSize
		hb := c.cfg.Heartbeat
		c.fullCfg.Mu.RUnlock()

		smuxCfg := transport.DefaultSmuxConfig(frameSize, hb)
		sess, err := smux.Server(obfConn, smuxCfg)
		if err != nil {
			_ = obfConn.Close()
			time.Sleep(time.Duration(c.cfg.RetryInterval) * time.Second)
			continue
		}

		c.poolMu.Lock()
		c.sessionPool = append(c.sessionPool, sess)
		c.poolMu.Unlock()

		log.Infof("[Reverse-Worker #%d] Connected to Iran Relay via %s (Encrypted TLS 1.3)", workerID, targetAddr)

		doneChan := make(chan struct{})
		go func() {
			ticker := time.NewTicker(10 * time.Second)
			defer ticker.Stop()
			for {
				select {
				case <-ticker.C:
					kernel.InspectSocketKernel(rawConn)
				case <-doneChan:
					return
				}
			}
		}()

		for {
			stream, err := sess.AcceptStream()
			if err != nil {
				break
			}
			go server.HandleExitStream(stream, c.portMappings, c.cfg.Nodelay, c.ApplyAIMutation)
		}

		close(doneChan)
		_ = sess.Close()

		c.poolMu.Lock()
		var alive []*smux.Session
		for _, s := range c.sessionPool {
			if s != sess && !s.IsClosed() {
				alive = append(alive, s)
			}
		}
		c.sessionPool = alive
		c.poolMu.Unlock()

		time.Sleep(time.Duration(c.cfg.RetryInterval) * time.Second)
	}
}

func (c *Client) maintainDirectPool() {
	consecutiveFails := 0
	for {
		c.poolMu.Lock()
		var alive []*smux.Session
		for _, s := range c.sessionPool {
			if !s.IsClosed() {
				alive = append(alive, s)
			}
		}
		c.sessionPool = alive
		needed := c.cfg.ConnectionPool - len(c.sessionPool)
		c.poolMu.Unlock()

		for i := 0; i < needed; i++ {
			targetAddr := c.resolveTargetAddr(consecutiveFails)
			rawConn, err := transport.DialKernel(targetAddr, 8*time.Second, c.cfg.Nodelay)
			if err != nil {
				consecutiveFails++
				c.healer.RecordError(err.Error())
				break
			}
			obfConn, err := transport.PerformHandshakeClient(rawConn, c.cfg.Token, 8*time.Second)
			if err != nil {
				consecutiveFails++
				c.healer.RecordError(err.Error())
				_ = rawConn.Close()
				break
			}
			consecutiveFails = 0
			atomic.StoreUint32(&c.useHopPort, 0)
			kernel.InspectSocketKernel(rawConn)

			smuxCfg := transport.DefaultSmuxConfig(c.cfg.MuxFrameSize, c.cfg.Heartbeat)
			sess, err := smux.Client(obfConn, smuxCfg)
			if err != nil {
				_ = obfConn.Close()
				break
			}
			c.poolMu.Lock()
			c.sessionPool = append(c.sessionPool, sess)
			c.poolMu.Unlock()
		}
		time.Sleep(time.Duration(c.cfg.RetryInterval) * time.Second)
	}
}

func (c *Client) getSession() (*smux.Session, error) {
	c.poolMu.RLock()
	defer c.poolMu.RUnlock()
	n := len(c.sessionPool)
	if n == 0 {
		return nil, fmt.Errorf("no active tunnel sessions")
	}
	for i := 0; i < n; i++ {
		idx := atomic.AddUint64(&c.rrIndex, 1) % uint64(n)
		sess := c.sessionPool[idx]
		if !sess.IsClosed() {
			return sess, nil
		}
	}
	return nil, fmt.Errorf("all tunnel sessions closed")
}

func (c *Client) listenDirectUserTCP(port uint16) {
	lc := transport.ListenConfigKernel()
	addr := fmt.Sprintf("0.0.0.0:%d", port)
	ln, err := lc.Listen(context.Background(), "tcp", addr)
	if err != nil {
		log.Errorf("[Direct-Client] Failed to bind user TCP port %d: %v", port, err)
		return
	}
	log.Infof("[Direct-Client] Listening for user TCP on %s", addr)
	for {
		uConn, err := ln.Accept()
		if err != nil {
			continue
		}
		transport.TuneTCPConn(uConn, c.cfg.Nodelay)
		go func(conn net.Conn) {
			defer conn.Close()
			sess, err := c.getSession()
			if err != nil {
				return
			}
			stream, err := sess.OpenStream()
			if err != nil {
				return
			}
			defer stream.Close()
			if err := transport.WriteStreamHeader(stream, transport.ProtoTCP, port); err != nil {
				return
			}
			transport.PipeBidirectional(conn, stream)
		}(uConn)
	}
}

func (c *Client) listenDirectUserUDP(port uint16) {
	addr := &net.UDPAddr{IP: net.IPv4zero, Port: int(port)}
	uConn, err := net.ListenUDP("udp", addr)
	if err != nil {
		log.Errorf("[Direct-Client] Failed to bind user UDP port %d: %v", port, err)
		return
	}
	log.Infof("[Direct-Client] Listening for user UDP on 0.0.0.0:%d", port)

	mgr := transport.NewUDPRelayManager(port, c.getSession)
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
