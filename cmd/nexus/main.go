package main

import (
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/nexustunnel/nexus/config"
	"github.com/nexustunnel/nexus/internal/client"
	"github.com/nexustunnel/nexus/internal/kernel"
	"github.com/nexustunnel/nexus/internal/server"
	"github.com/nexustunnel/nexus/internal/testrunner"
	"github.com/nexustunnel/nexus/internal/transport"
	log "github.com/sirupsen/logrus"
)

var version = "5.3.0-Hyperion-AI-Orchestrator"

func main() {
	configPath := flag.String("c", "/etc/nexus-tunnel/config.toml", "Path to TOML configuration file")
	showVersion := flag.Bool("v", false, "Show Nexus-Omega version")
	showTOTP := flag.Bool("totp", false, "Show current synchronized TOTP Hop Port & SNI")
	runDiag := flag.Bool("diag", false, "Run local kernel & network diagnostic checks")

	// Test Mode Flags
	testIran := flag.Bool("test-iran", false, "Run Iran AI Test Agent Responder")
	testKharej := flag.Bool("test-kharej", false, "Run Kharej AI Benchmark & Deployment Orchestrator")
	testPort := flag.Int("test-port", 3099, "Port for AI Test Agent communication")
	remoteHost := flag.String("remote", "", "Iran host/IP for Kharej test client")
	geminiKey := flag.String("gemini-key", "", "Google Gemini API Key for AI network analysis")
	userPortsFlag := flag.String("ports", "443,8443", "Comma-separated candidate user ports")
	targetUsers := flag.Int("users", 1000, "Target concurrent user capacity")

	flag.Parse()

	if *showVersion {
		fmt.Printf("Nexus-Omega v%s (Autonomous AI & Kernel-Accelerated Tunnel Suite)\n", version)
		return
	}

	if *testIran {
		log.Infof("Starting Nexus AI Test Agent on port %d...", *testPort)
		if err := testrunner.RunIranTestServer(*testPort, *configPath); err != nil {
			log.Fatalf("Iran test agent error: %v", err)
		}
		return
	}

	if *testKharej {
		if *remoteHost == "" {
			log.Fatal("Flag -remote <IRAN_IP> is required for Kharej AI test client")
		}
		ports := strings.Split(*userPortsFlag, ",")
		if err := testrunner.RunKharejAITestClient(*remoteHost, *testPort, *geminiKey, ports, *targetUsers, *configPath); err != nil {
			log.Fatalf("Kharej AI benchmark error: %v", err)
		}
		return
	}

	if *runDiag {
		cfg, _ := config.LoadConfig(*configPath)
		target := ""
		if cfg != nil && cfg.Client != nil {
			target = cfg.Client.RemoteAddr
		}
		fmt.Println(kernel.RunNetworkDiagnostics(target))
		return
	}

	cfg, err := config.LoadConfig(*configPath)
	if err != nil {
		log.Fatalf("Config load error: %v", err)
	}

	if *showTOTP {
		token := ""
		if cfg.Server != nil {
			token = cfg.Server.Token
		} else if cfg.Client != nil {
			token = cfg.Client.Token
		}
		interval := int64(300)
		minPort := uint16(30000)
		maxPort := uint16(50000)
		var sniList []string
		if cfg.Polymorph != nil {
			if cfg.Polymorph.HopIntervalSec > 0 {
				interval = cfg.Polymorph.HopIntervalSec
			}
			if cfg.Polymorph.HopPortMin > 0 {
				minPort = cfg.Polymorph.HopPortMin
			}
			if cfg.Polymorph.HopPortMax > 0 {
				maxPort = cfg.Polymorph.HopPortMax
			}
			sniList = cfg.Polymorph.SNIList
		}
		slot := time.Now().Unix() / interval
		p, sni := transport.ComputeDynamicSlot(token, slot, minPort, maxPort, sniList)
		fmt.Printf("Current TOTP Window : %d\nDynamic Hop Port    : %d\nSynchronized SNI    : %s\n", slot, p, sni)
		return
	}

	log.SetFormatter(&log.TextFormatter{
		FullTimestamp:   true,
		TimestampFormat: "2006-01-02 15:04:05",
	})
	log.SetOutput(os.Stdout)
	log.Infof("=== Nexus-Omega Core v%s ===", version)

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		sig := <-sigChan
		log.Infof("Signal %v received, shutting down cleanly...", sig)
		os.Exit(0)
	}()

	switch cfg.Role {
	case config.ModeDirectServer, config.ModeReverseServer:
		if cfg.Server == nil {
			log.Fatalf("Role '%s' requires [server] section in config.toml", cfg.Role)
		}
		srv, err := server.NewServer(cfg)
		if err != nil {
			log.Fatalf("Server initialization error: %v", err)
		}
		log.Fatal(srv.Start())

	case config.ModeDirectClient, config.ModeReverseClient:
		if cfg.Client == nil {
			log.Fatalf("Role '%s' requires [client] section in config.toml", cfg.Role)
		}
		cli, err := client.NewClient(cfg)
		if err != nil {
			log.Fatalf("Client initialization error: %v", err)
		}
		log.Fatal(cli.Start())

	default:
		log.Fatalf("Invalid role '%s'. Supported roles: reverse-server, reverse-client, server, client", cfg.Role)
	}
}
