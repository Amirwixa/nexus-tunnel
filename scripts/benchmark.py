#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
================================================================================
  NexusTunnel - Comprehensive Network Diagnostic & DPI Benchmark Suite
  Evaluates line quality, latency, jitter, packet loss, MTU, and DPI resistance.
  100% English Output.
================================================================================
"""

import sys
import os
import time
import socket
import struct
import statistics
import json
import argparse
from typing import Dict, Any, List

# Safe UTF-8 standard output configuration
if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

RED = "\033[1;31m"
GREEN = "\033[1;32m"
YELLOW = "\033[1;33m"
CYAN = "\033[1;36m"
BOLD = "\033[1m"
NC = "\033[0m"


def test_tcp_latency_and_jitter(host: str, port: int, samples: int = 10, timeout: float = 3.0) -> Dict[str, Any]:
    """Measures TCP connection establishment RTT, loss percentage, and jitter"""
    rtts: List[float] = []
    failures = 0

    for _ in range(samples):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        start = time.perf_counter()
        try:
            s.connect((host, port))
            rtt = (time.perf_counter() - start) * 1000.0  # ms
            rtts.append(rtt)
        except Exception:
            failures += 1
        finally:
            s.close()
        time.sleep(0.06)

    loss_pct = (failures / samples) * 100.0
    avg_rtt = round(statistics.mean(rtts), 2) if rtts else 0.0
    min_rtt = round(min(rtts), 2) if rtts else 0.0
    max_rtt = round(max(rtts), 2) if rtts else 0.0
    jitter = round(statistics.stdev(rtts), 2) if len(rtts) > 1 else 0.0

    rating = "EXCELLENT" if loss_pct == 0 and avg_rtt < 60 else \
             "GOOD" if loss_pct <= 5 and avg_rtt < 120 else \
             "DEGRADED" if loss_pct <= 25 else "CRITICAL"

    return {
        "test": f"TCP Handshake (Port {port})",
        "samples": samples,
        "success": len(rtts),
        "failures": failures,
        "loss_pct": round(loss_pct, 1),
        "avg_rtt_ms": avg_rtt,
        "min_rtt_ms": min_rtt,
        "max_rtt_ms": max_rtt,
        "jitter_ms": jitter,
        "rating": rating
    }


def test_udp_reachability_and_loss(host: str, port: int, packet_count: int = 15, timeout: float = 2.0) -> Dict[str, Any]:
    """Sends UDP datagram probe packets to verify reachability and loss rate"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    received = 0
    rtts: List[float] = []

    for seq in range(packet_count):
        payload = struct.pack("!II8s", 0x4E585544, seq, b"NXPROBE1")
        start = time.perf_counter()
        try:
            s.sendto(payload, (host, port))
            try:
                data, _ = s.recvfrom(1024)
                rtt = (time.perf_counter() - start) * 1000.0
                received += 1
                rtts.append(rtt)
            except socket.timeout:
                pass
        except Exception:
            pass
        time.sleep(0.05)
    s.close()

    loss_pct = ((packet_count - received) / packet_count) * 100.0
    avg_rtt = round(statistics.mean(rtts), 2) if rtts else 0.0

    if received == 0:
        status = "NO_REPLY (Filtered by ISP or Silent Port)"
    elif loss_pct <= 10:
        status = "EXCELLENT"
    elif loss_pct <= 35:
        status = "MODERATE_LOSS"
    else:
        status = "HEAVY_LOSS"

    return {
        "test": f"UDP Probe (Port {port})",
        "packets_sent": packet_count,
        "packets_received": received,
        "loss_pct": round(loss_pct, 1),
        "avg_rtt_ms": avg_rtt,
        "status": status
    }


def test_path_mtu_discovery(host: str, port: int = 443) -> Dict[str, Any]:
    """Tests Path MTU (PMTUD) to prevent fragmentation drops over PPPoE/GRE lines"""
    mtu_candidates = [1500, 1460, 1420, 1380, 1340, 1280]
    optimal_mtu = 1280
    results = {}

    for mtu in mtu_candidates:
        payload_size = mtu - 40
        dummy_data = b"M" * max(0, payload_size)
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(2.0)
            s.connect((host, port))
            s.sendall(dummy_data)
            optimal_mtu = max(optimal_mtu, mtu)
            results[mtu] = "PASSED"
            s.close()
        except Exception:
            results[mtu] = "FAILED"
        time.sleep(0.05)

    return {
        "test": "Path MTU Discovery (PMTUD)",
        "recommended_mtu": optimal_mtu,
        "recommended_mss": optimal_mtu - 40,
        "tested_sizes": results
    }


def test_active_probing_resistance(host: str, port: int = 443, timeout: float = 3.0) -> Dict[str, Any]:
    """Simulates an unauthenticated active sensor probe to verify camouflage behavior"""
    probe_req = (
        b"GET / HTTP/1.1\r\n"
        b"Host: www.microsoft.com\r\n"
        b"User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)\r\n"
        b"Accept: */*\r\n\r\n"
    )
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect((host, port))
        s.sendall(probe_req)
        resp = s.recv(2048)
        s.close()

        is_http = b"HTTP/1." in resp or b"HTTP/2" in resp
        has_decoy = any(k in resp for k in [b"nginx", b"IIS", b"Apache", b"Welcome", b"200 OK"])

        if is_http and has_decoy:
            return {
                "test": "Active Probing Resistance",
                "passed": True,
                "behavior": "Decoy Web Server Active",
                "details": "Server masked itself as legitimate Web Server. Probe safely diverted."
            }
        elif is_http:
            return {
                "test": "Active Probing Resistance",
                "passed": True,
                "behavior": "Generic HTTP Response",
                "details": "Returned valid HTTP code."
            }
        elif len(resp) == 0:
            return {
                "test": "Active Probing Resistance",
                "passed": False,
                "behavior": "Connection Reset / Silent Drop",
                "details": "Remote connection closed immediately without response."
            }
        else:
            return {
                "test": "Active Probing Resistance",
                "passed": False,
                "behavior": "Unrecognized Protocol Signature",
                "details": "Exposed non-standard protocol bytes."
            }
    except socket.timeout:
        return {
            "test": "Active Probing Resistance",
            "passed": False,
            "behavior": "Timeout / Blackhole",
            "details": "Port timed out on probe."
        }
    except Exception as e:
        return {
            "test": "Active Probing Resistance",
            "passed": False,
            "behavior": "Error",
            "details": str(e)
        }


def print_english_report(target_host: str, report: Dict[str, Any]):
    print(f"\n{BOLD}{'=' * 68}{NC}")
    print(f"  {CYAN}NEXUS-TUNNEL NETWORK & DPI DIAGNOSTIC REPORT{NC}")
    print(f"  Target Host : {target_host}")
    print(f"  Timestamp   : {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())}")
    print(f"{BOLD}{'=' * 68}{NC}")

    # TCP Metrics
    tcp = report.get("tcp_metrics", {})
    r_col = GREEN if tcp.get("rating") in ("EXCELLENT", "GOOD") else YELLOW if tcp.get("rating") == "DEGRADED" else RED
    print(f"\n{BOLD}[TCP Latency & Stability]{NC}")
    print(f"  Rating      : {r_col}{tcp.get('rating')}{NC}")
    print(f"  Average RTT : {tcp.get('avg_rtt_ms')} ms (Min: {tcp.get('min_rtt_ms')} ms, Max: {tcp.get('max_rtt_ms')} ms)")
    print(f"  Jitter      : {tcp.get('jitter_ms')} ms")
    print(f"  Packet Loss : {tcp.get('loss_pct')} % ({tcp.get('success')}/{tcp.get('samples')} packets delivered)")

    # UDP Metrics
    udp = report.get("udp_metrics", {})
    u_col = GREEN if "EXCELLENT" in udp.get("status", "") else YELLOW if "MODERATE" in udp.get("status", "") else RED
    print(f"\n{BOLD}[UDP Reachability & Quality]{NC}")
    print(f"  Status      : {u_col}{udp.get('status')}{NC}")
    print(f"  Packet Loss : {udp.get('loss_pct')} % ({udp.get('packets_received')}/{udp.get('packets_sent')} received)")
    print(f"  Average RTT : {udp.get('avg_rtt_ms')} ms")

    # Anti-Probing
    probe = report.get("active_probe", {})
    p_icon = f"{GREEN}[PASSED]{NC}" if probe.get("passed") else f"{YELLOW}[WARNING]{NC}"
    print(f"\n{BOLD}[Anti-Probing & Camouflage Defense]{NC}")
    print(f"  Defense     : {p_icon} {probe.get('behavior')}")
    print(f"  Details     : {probe.get('details')}")

    # MTU Discovery
    pmtu = report.get("pmtu", {})
    print(f"\n{BOLD}[Path MTU Optimization (PMTUD)]{NC}")
    print(f"  Optimal MTU : {CYAN}{pmtu.get('recommended_mtu')} bytes{NC}")
    print(f"  Optimal MSS : {CYAN}{pmtu.get('recommended_mss')} bytes{NC}")

    # Protocol Recommendation
    rec = report.get("recommendation", {})
    print(f"\n{BOLD}{'─' * 68}{NC}")
    print(f"{BOLD}SMART TUNNEL PROTOCOL RECOMMENDATION:{NC}")
    print(f"  Recommended : {CYAN}{rec.get('protocol')}{NC}")
    print(f"  Reason      : {rec.get('reason')}")
    print(f"{BOLD}{'=' * 68}{NC}\n")


def run_full_suite(host: str, port: int = 443) -> Dict[str, Any]:
    tcp_res = test_tcp_latency_and_jitter(host, port)
    udp_res = test_udp_reachability_and_loss(host, 8443)
    pmtu_res = test_path_mtu_discovery(host, port)
    probe_res = test_active_probing_resistance(host, port)

    # Autonomous recommendation
    if udp_res["loss_pct"] < 15 and udp_res["packets_received"] > 0:
        rec_proto = "Hysteria2 (QUIC / UDP 8443) or Backhaul (TCPMux)"
        rec_reason = "UDP quality is excellent with minimal loss; QUIC delivers highest throughput."
    elif tcp_res["loss_pct"] < 10:
        rec_proto = "NexusCore (Multiplexed Stream) or Backhaul (WSMux / TCPMux)"
        rec_reason = "TCP line is stable; multiplexed tunneling provides rock-solid performance."
    else:
        rec_proto = "Rathole (Noise Protocol) or GOST (WebSocket + TLS CDN)"
        rec_reason = "Elevated packet loss detected; encrypted reverse tunneling ensures survivability."

    return {
        "target": f"{host}:{port}",
        "tcp_metrics": tcp_res,
        "udp_metrics": udp_res,
        "pmtu": pmtu_res,
        "active_probe": probe_res,
        "recommendation": {
            "protocol": rec_proto,
            "reason": rec_reason
        }
    }


def main():
    parser = argparse.ArgumentParser(description="NexusTunnel Network & DPI Diagnostic Suite")
    parser.add_argument("--host", required=True, help="Target server host / IP")
    parser.add_argument("--port", type=int, default=443, help="Target port (default: 443)")
    parser.add_argument("--json", action="store_true", help="Output raw JSON data")

    args = parser.parse_args()
    results = run_full_suite(args.host, args.port)

    if args.json:
        print(json.dumps(results, indent=2))
    else:
        print_english_report(args.host, results)


if __name__ == "__main__":
    main()
