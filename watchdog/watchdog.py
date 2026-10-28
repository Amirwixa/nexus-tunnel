#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
================================================================================
  NexusTunnel - Autonomous Self-Healing Watchdog Daemon
  Monitors tunnel services, checks connection state, and triggers auto-recovery.
  100% English Output & Logs.
================================================================================
"""

import os
import sys
import time
import socket
import subprocess
import logging
from typing import List, Tuple

LOG_DIR = "/var/log/nexus-tunnel"
WATCHDOG_LOG = os.path.join(LOG_DIR, "watchdog.log")

os.makedirs(LOG_DIR, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [WATCHDOG] %(levelname)s: %(message)s",
    handlers=[
        logging.FileHandler(WATCHDOG_LOG, encoding="utf-8"),
        logging.StreamHandler(sys.stdout)
    ]
)
log = logging.getLogger("nexus-watchdog")


def is_service_active(service_name: str) -> bool:
    try:
        res = subprocess.run(
            ["systemctl", "is-active", service_name],
            capture_output=True, text=True, timeout=5
        )
        return res.stdout.strip() == "active"
    except Exception:
        return False


def restart_service(service_name: str) -> bool:
    try:
        res = subprocess.run(
            ["systemctl", "restart", service_name],
            capture_output=True, timeout=15
        )
        return res.returncode == 0
    except Exception as e:
        log.error(f"Failed to restart service {service_name}: {e}")
        return False


def check_tcp_port(host: str, port: int, timeout: float = 3.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except Exception:
        return False


class NexusWatchdog:
    def __init__(self):
        self.monitored_services = ["nexus-tunnel", "sing-box", "backhaul", "rathole"]
        self.restart_counters = {svc: 0 for svc in self.monitored_services}

    def run(self):
        log.info("NexusTunnel Autonomous Watchdog started.")
        while True:
            try:
                self.check_cycle()
            except Exception as e:
                log.error(f"Internal watchdog error: {e}")
            time.sleep(15)

    def check_cycle(self):
        for svc in self.monitored_services:
            # Check if service is enabled on this system
            chk = subprocess.run(
                ["systemctl", "is-enabled", svc],
                capture_output=True, text=True
            )
            if chk.stdout.strip() != "enabled":
                continue

            active = is_service_active(svc)
            if not active:
                self.restart_counters[svc] += 1
                log.warning(f"Service [{svc}] is inactive! Triggering restart #{self.restart_counters[svc]}...")
                if restart_service(svc):
                    time.sleep(3)
                    if is_service_active(svc):
                        log.info(f"Service [{svc}] successfully recovered and is now ACTIVE.")
                    else:
                        log.error(f"Service [{svc}] failed to recover after restart.")
                else:
                    log.error(f"Command systemctl restart {svc} failed.")


if __name__ == "__main__":
    dog = NexusWatchdog()
    dog.run()
