package ai

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"time"

	"github.com/nexustunnel/nexus/config"
	"github.com/nexustunnel/nexus/internal/kernel"
	log "github.com/sirupsen/logrus"
)

type MutationDecision struct {
	Action          string `json:"action"` // "mutate" or "stable"
	NewFakeSNI      string `json:"new_fake_sni"`
	NewMuxFrameSize int    `json:"new_mux_framesize"`
	NewMSSClamp     int    `json:"new_mss_clamp"`
	NewPoolSize     int    `json:"new_pool_size"`
	ForcePortHop    bool   `json:"force_port_hop"`
	AnalysisReason  string `json:"analysis_reason"`
}

type BenchmarkTelemetry struct {
	IranIP             string   `json:"iran_ip"`
	KharejIP           string   `json:"kharej_ip"`
	MinRTTMs           float64  `json:"min_rtt_ms"`
	AvgRTTMs           float64  `json:"avg_rtt_ms"`
	MaxRTTMs           float64  `json:"max_rtt_ms"`
	JitterMs           float64  `json:"jitter_ms"`
	PacketLossPct      float64  `json:"packet_loss_percent"`
	ThroughputMbps     float64  `json:"throughput_mbps"`
	OptimalPMTU        int      `json:"optimal_pmtu"`
	CandidatePorts     []string `json:"candidate_ports"`
	ResponsivePorts    []string `json:"responsive_ports"`
	TargetUserCapacity int      `json:"target_user_capacity"`
}

type AIRecommendation struct {
	OptimalPrimaryPort uint16   `json:"optimal_primary_port"`
	OptimalFakeSNI     string   `json:"optimal_fake_sni"`
	OptimalPoolSize    int      `json:"optimal_pool_size"`
	OptimalFrameSize   int      `json:"optimal_frame_size"`
	OptimalMSSClamp    int      `json:"optimal_mss_clamp"`
	EnablePortHopping  bool     `json:"enable_port_hopping"`
	PersianAnalysis    string   `json:"persian_analysis"`
	TechnicalBullets   []string `json:"technical_bullets"`
}

type Healer struct {
	cfg           *config.Config
	httpClient    *http.Client
	onMutate      func(decision MutationDecision)
	lastErrorText string
}

func NewHealer(cfg *config.Config, onMutate func(MutationDecision)) *Healer {
	return &Healer{
		cfg: cfg,
		httpClient: &http.Client{
			Timeout: 15 * time.Second,
		},
		onMutate: onMutate,
	}
}

func (h *Healer) RecordError(errStr string) {
	h.cfg.Mu.Lock()
	h.lastErrorText = errStr
	h.cfg.Mu.Unlock()
	atomic.AddUint64(&kernel.GlobalMetrics.HandshakeFailures, 1)
}

func (h *Healer) StartAutonomousLoop() {
	if h.cfg.AI == nil || !h.cfg.AI.Enabled || h.cfg.AI.GeminiAPIKey == "" {
		log.Info("[AI-Healer] Gemini AI Healer is dormant (no API key configured).")
		return
	}

	log.Infof("[AI-Healer] Gemini Neural Self-Healing Engine ACTIVE (Model: %s, Interval: %ds)",
		h.cfg.AI.Model, h.cfg.AI.CheckInterval)

	ticker := time.NewTicker(time.Duration(h.cfg.AI.CheckInterval) * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		failures := atomic.LoadUint64(&kernel.GlobalMetrics.HandshakeFailures)
		retrans := atomic.LoadUint64(&kernel.GlobalMetrics.TotalRetransmits)
		rttUs := atomic.LoadUint32(&kernel.GlobalMetrics.LastRTTUs)

		// Trigger healing on anomalous telemetry
		if failures >= 2 || retrans > 150 || rttUs > 220000 {
			log.Warnf("[AI-Healer] Anomaly detected (Failures=%d, Retransmits=%d, RTT=%dms). Consulting Gemini AI...",
				failures, retrans, rttUs/1000)

			decision, err := h.consultGemini(failures, retrans, rttUs)
			if err != nil {
				log.Warnf("[AI-Healer] Gemini API consultation failed: %v", err)
				continue
			}

			atomic.StoreUint64(&kernel.GlobalMetrics.HandshakeFailures, 0)
			atomic.StoreUint64(&kernel.GlobalMetrics.TotalRetransmits, 0)

			log.Infof("[AI-Healer] Gemini Diagnosis: [%s] -> %s", decision.Action, decision.AnalysisReason)
			if decision.Action == "mutate" && h.onMutate != nil {
				h.onMutate(*decision)
			}
		}
	}
}

func (h *Healer) consultGemini(failures, retrans uint64, rttUs uint32) (*MutationDecision, error) {
	h.cfg.Mu.RLock()
	activeNode := h.cfg.Client
	if activeNode == nil {
		activeNode = h.cfg.Server
	}
	currentSNI := "speed.cloudflare.com"
	currentFrame := 32768
	currentMSS := 1360
	if activeNode != nil {
		currentSNI = activeNode.FakeSNI
		currentFrame = activeNode.MuxFrameSize
		currentMSS = activeNode.MSSClamp
	}
	tel := kernel.Telemetry{
		ActiveStreams:     atomic.LoadInt64(&kernel.GlobalMetrics.ActiveStreams),
		HandshakeFailures: failures,
		TotalRetransmits:  retrans,
		KernelRTTMicros:   rttUs,
		KernelJitterUs:    atomic.LoadUint32(&kernel.GlobalMetrics.LastJitterUs),
		PathMTU:           atomic.LoadUint32(&kernel.GlobalMetrics.LastPMTU),
		CurrentSNI:        currentSNI,
		CurrentFrameSize:  currentFrame,
		CurrentMSSClamp:   currentMSS,
		LastError:         h.lastErrorText,
	}
	sniCandidates := h.cfg.Polymorph.SNIList
	apiKey := h.cfg.AI.GeminiAPIKey
	apiEndpoint := h.cfg.AI.APIEndpoint
	model := h.cfg.AI.Model
	h.cfg.Mu.RUnlock()

	telJSON, _ := json.Marshal(tel)

	prompt := fmt.Sprintf(`You are the Autonomous Kernel Network Healer for Nexus-Omega, an anti-censorship cross-border server-to-server tunnel between Iran and a Foreign server.
Analyze this real-time Linux kernel telemetry JSON:
%s
Available Camouflage SNI Candidates: %v

Censorship & Performance Rules:
1. If HandshakeFailures > 0 or LastError indicates reset/timeout, DPI is fingerprinting the current SNI or port. Set action="mutate", select a DIFFERENT new_fake_sni from candidates, and if failures >= 3 set force_port_hop=true.
2. If TotalRetransmits > 100 or KernelJitterUs > 30000, packet fragmentation or throttling is occurring. Reduce new_mux_framesize (e.g. 16384 or 8192) and lower new_mss_clamp (e.g. 1320 or 1280).
3. If line is healthy, action="stable".
4. Output MUST be ONLY valid JSON matching this schema:
{"action":"mutate","new_fake_sni":"string","new_mux_framesize":16384,"new_mss_clamp":1320,"new_pool_size":8,"force_port_hop":false,"analysis_reason":"short explanation in Persian or English"}`, string(telJSON), sniCandidates)

	reqBody := map[string]interface{}{
		"contents": []map[string]interface{}{
			{
				"parts": []map[string]string{
					{"text": prompt},
				},
			},
		},
		"generationConfig": map[string]interface{}{
			"temperature":      0.2,
			"responseMimeType": "application/json",
		},
	}

	payload, _ := json.Marshal(reqBody)
	modelsToTry := []string{"gemini-flash-lite-latest", "gemini-2.0-flash", "gemini-1.5-flash", "gemini-2.5-flash"}
	if model != "" {
		modelsToTry = append([]string{model}, modelsToTry...)
	}
	var lastErr error

	for _, mod := range modelsToTry {
		if mod == "" {
			continue
		}
		endpoint := fmt.Sprintf("%s/v1beta/models/%s:generateContent?key=%s",
			strings.TrimRight(apiEndpoint, "/"), mod, apiKey)

		resp, err := h.httpClient.Post(endpoint, "application/json", bytes.NewReader(payload))
		if err != nil {
			lastErr = err
			continue
		}

		bodyBytes, err := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		if err != nil {
			lastErr = err
			continue
		}

		if resp.StatusCode != http.StatusOK {
			lastErr = fmt.Errorf("HTTP %d: %s", resp.StatusCode, string(bodyBytes))
			continue
		}

		var geminiResp struct {
			Candidates []struct {
				Content struct {
					Parts []struct {
						Text string `json:"text"`
					} `json:"parts"`
				} `json:"content"`
			} `json:"candidates"`
		}

		if err := json.Unmarshal(bodyBytes, &geminiResp); err != nil {
			lastErr = err
			continue
		}
		if len(geminiResp.Candidates) == 0 || len(geminiResp.Candidates[0].Content.Parts) == 0 {
			lastErr = fmt.Errorf("empty candidates in Gemini response")
			continue
		}

		rawText := strings.TrimSpace(geminiResp.Candidates[0].Content.Parts[0].Text)
		rawText = strings.TrimPrefix(rawText, "```json")
		rawText = strings.TrimPrefix(rawText, "```")
		rawText = strings.TrimSuffix(rawText, "```")

		var decision MutationDecision
		if err := json.Unmarshal([]byte(strings.TrimSpace(rawText)), &decision); err != nil {
			lastErr = fmt.Errorf("failed to parse Gemini JSON decision: %w", err)
			continue
		}
		return &decision, nil
	}

	return nil, lastErr
}

// ConsultGeminiForBenchmark evaluates pre-deployment cross-server test metrics and generates optimal settings
func ConsultGeminiForBenchmark(apiKey string, b BenchmarkTelemetry) (*AIRecommendation, error) {
	bJSON, _ := json.Marshal(b)

	prompt := fmt.Sprintf(`You are the Principal Network Architect specializing in high-throughput Iranian anti-censorship tunnels.
Analyze these real-time network benchmark measurements between an Iran Node and a Kharej (Foreign) Node:
%s

Network Context:
- The user requires extreme concurrency supporting at least %d simultaneous users connecting via V2Ray/Sing-box on Iran ports to Kharej.
- The route between Iran and Kharej suffers from ISP DPI filtering, periodic packet fragmentation, and TCP throttling.
- Iran Node cannot directly connect to Google Gemini; only Kharej has direct AI API access.

Your Task:
1. Analyze latency (Min/Avg/Max RTT, Jitter), packet loss, bandwidth capacity, PMTU boundary, and port reachability.
2. Formulate optimal settings for:
   - optimal_primary_port: Best port for the tunnel control plane (from responsive ports or 3080/8443).
   - optimal_fake_sni: Best SNI from ["speed.cloudflare.com", "dl.google.com", "gateway.icloud.com", "cdn.jsdelivr.net", "www.microsoft.com"].
   - optimal_pool_size: Multiplexed worker pool (recommended 16-32 for %d users to avoid Head-of-Line blocking).
   - optimal_frame_size: smux frame size (between 16384 and 65536).
   - optimal_mss_clamp: TCP MSS clamp derived from optimal_pmtu - 40 (e.g. 1320-1360).
   - enable_port_hopping: true if jitter > 10ms or loss > 1%% or responsive ports < candidate ports.
   - persian_analysis: Comprehensive, clear explanation in Persian summarizing the line quality, filtering state, and why these settings were chosen.
   - technical_bullets: 3-5 concise technical Persian bullet points explaining key optimization highlights.

Return ONLY a valid JSON object matching this schema:
{
  "optimal_primary_port": 3080,
  "optimal_fake_sni": "speed.cloudflare.com",
  "optimal_pool_size": 16,
  "optimal_frame_size": 32768,
  "optimal_mss_clamp": 1360,
  "enable_port_hopping": true,
  "persian_analysis": "تحلیل کامل خط...",
  "technical_bullets": ["نکته ۱", "نکته ۲", "نکته ۳"]
}`, string(bJSON), b.TargetUserCapacity, b.TargetUserCapacity)

	reqBody := map[string]interface{}{
		"contents": []map[string]interface{}{
			{
				"parts": []map[string]string{
					{"text": prompt},
				},
			},
		},
		"generationConfig": map[string]interface{}{
			"temperature":      0.2,
			"responseMimeType": "application/json",
		},
	}

	payload, _ := json.Marshal(reqBody)
	models := []string{"gemini-flash-lite-latest", "gemini-2.0-flash", "gemini-1.5-flash"}
	client := &http.Client{Timeout: 25 * time.Second}

	var lastErr error
	for _, mod := range models {
		endpoint := fmt.Sprintf("https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s",
			mod, apiKey)

		resp, err := client.Post(endpoint, "application/json", bytes.NewReader(payload))
		if err != nil {
			lastErr = err
			continue
		}

		bodyBytes, err := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		if err != nil {
			lastErr = err
			continue
		}

		if resp.StatusCode != http.StatusOK {
			lastErr = fmt.Errorf("HTTP %d: %s", resp.StatusCode, string(bodyBytes))
			continue
		}

		var geminiResp struct {
			Candidates []struct {
				Content struct {
					Parts []struct {
						Text string `json:"text"`
					} `json:"parts"`
				} `json:"content"`
			} `json:"candidates"`
		}

		if err := json.Unmarshal(bodyBytes, &geminiResp); err != nil {
			lastErr = err
			continue
		}
		if len(geminiResp.Candidates) == 0 || len(geminiResp.Candidates[0].Content.Parts) == 0 {
			lastErr = fmt.Errorf("empty candidates in Gemini response")
			continue
		}

		rawText := strings.TrimSpace(geminiResp.Candidates[0].Content.Parts[0].Text)
		rawText = strings.TrimPrefix(rawText, "```json")
		rawText = strings.TrimPrefix(rawText, "```")
		rawText = strings.TrimSuffix(rawText, "```")

		var rec AIRecommendation
		if err := json.Unmarshal([]byte(strings.TrimSpace(rawText)), &rec); err != nil {
			lastErr = fmt.Errorf("failed to parse AI JSON recommendation: %w", err)
			continue
		}
		return &rec, nil
	}

	return nil, lastErr
}
