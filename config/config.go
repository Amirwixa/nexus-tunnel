package config

import (
	"fmt"
	"os"
	"strings"
	"sync"

	"github.com/BurntSushi/toml"
)

type ModeType string

const (
	ModeReverseServer ModeType = "reverse-server" // Iran Node in Reverse Mode (Listens for Kharej + Users)
	ModeReverseClient ModeType = "reverse-client" // Kharej Node in Reverse Mode (Connects to Iran + Forwards to Local Xray)
	ModeDirectServer  ModeType = "server"         // Kharej Node in Direct Mode
	ModeDirectClient  ModeType = "client"         // Iran Node in Direct Mode
)

type AIConfig struct {
	Enabled       bool   `toml:"enabled"`
	GeminiAPIKey  string `toml:"gemini_api_key"`
	Model         string `toml:"model"`
	APIEndpoint   string `toml:"api_endpoint"`
	CheckInterval int    `toml:"check_interval"`
}

type PolymorphConfig struct {
	EnablePortHopping bool     `toml:"enable_port_hopping"`
	HopPortMin        uint16   `toml:"hop_port_min"`
	HopPortMax        uint16   `toml:"hop_port_max"`
	HopIntervalSec    int64    `toml:"hop_interval"`
	SNIList           []string `toml:"sni_list"`
}

type NodeConfig struct {
	BindAddr       string   `toml:"bind_addr"`
	RemoteAddr     string   `toml:"remote_addr"`
	Token          string   `toml:"token"`
	FakeSNI        string   `toml:"fake_sni"`
	ConnectionPool int      `toml:"connection_pool"`
	Heartbeat      int      `toml:"heartbeat"`
	RetryInterval  int      `toml:"retry_interval"`
	Nodelay        bool     `toml:"nodelay"`
	EnableUDP      bool     `toml:"enable_udp"`
	MuxFrameSize   int      `toml:"mux_framesize"`
	MSSClamp       int      `toml:"mss_clamp"`
	Ports          []string `toml:"ports"`
}

type Config struct {
	Mu        sync.RWMutex     `toml:"-"`
	Role      ModeType         `toml:"role"`
	Server    *NodeConfig      `toml:"server"`
	Client    *NodeConfig      `toml:"client"`
	AI        *AIConfig        `toml:"ai"`
	Polymorph *PolymorphConfig `toml:"polymorph"`
}

func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read config file: %w", err)
	}

	var cfg Config
	if err := toml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("failed to parse TOML config: %w", err)
	}

	applyNodeDefaults(cfg.Server)
	applyNodeDefaults(cfg.Client)

	if cfg.AI == nil {
		cfg.AI = &AIConfig{}
	}
	if cfg.AI.Model == "" {
		cfg.AI.Model = "gemini-flash-lite-latest"
	}
	if cfg.AI.APIEndpoint == "" {
		cfg.AI.APIEndpoint = "https://generativelanguage.googleapis.com"
	}
	if cfg.AI.CheckInterval <= 0 {
		cfg.AI.CheckInterval = 30
	}

	if cfg.Polymorph == nil {
		cfg.Polymorph = &PolymorphConfig{}
	}
	if len(cfg.Polymorph.SNIList) == 0 {
		cfg.Polymorph.SNIList = []string{
			"speed.cloudflare.com",
			"dl.google.com",
			"www.microsoft.com",
			"cdn.jsdelivr.net",
			"gateway.icloud.com",
		}
	}
	if cfg.Polymorph.HopPortMin == 0 {
		cfg.Polymorph.HopPortMin = 30000
	}
	if cfg.Polymorph.HopPortMax == 0 {
		cfg.Polymorph.HopPortMax = 50000
	}
	if cfg.Polymorph.HopIntervalSec <= 0 {
		cfg.Polymorph.HopIntervalSec = 300
	}

	return &cfg, nil
}

func applyNodeDefaults(n *NodeConfig) {
	if n == nil {
		return
	}
	if n.FakeSNI == "" {
		n.FakeSNI = "speed.cloudflare.com"
	}
	if n.ConnectionPool <= 0 {
		n.ConnectionPool = 8
	}
	if n.Heartbeat <= 0 {
		n.Heartbeat = 12
	}
	if n.RetryInterval <= 0 {
		n.RetryInterval = 2
	}
	if n.MuxFrameSize <= 0 {
		n.MuxFrameSize = 32768
	}
	if n.MSSClamp <= 0 {
		n.MSSClamp = 1360
	}
}

func ParsePortMapping(entry string) (listenPort uint16, targetAddr string, err error) {
	entry = strings.TrimSpace(entry)
	var lPortStr string
	if strings.Contains(entry, "=") {
		parts := strings.SplitN(entry, "=", 2)
		lPortStr = strings.TrimSpace(parts[0])
		targetAddr = strings.TrimSpace(parts[1])
	} else {
		lPortStr = entry
		targetAddr = fmt.Sprintf("127.0.0.1:%s", entry)
	}

	var p uint16
	if _, err := fmt.Sscanf(lPortStr, "%d", &p); err != nil {
		return 0, "", fmt.Errorf("invalid port '%s': %w", lPortStr, err)
	}
	return p, targetAddr, nil
}
