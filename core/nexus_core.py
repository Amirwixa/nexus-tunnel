#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
================================================================================
  NexusCore - Dedicated High-Performance Multiplexed Relay Engine
  Designed specifically for high-censorship, high-packet-loss national borders.
  Zero-Dependency (Pure Python 3.8+ Standard Library).
================================================================================
"""

import sys
import os
import time
import socket
import asyncio
import struct
import argparse
import secrets
import hashlib
import hmac
from typing import Dict, Tuple, Optional, List

# Ensure clean UTF-8 standard output
if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

VERSION = "3.2.0-Core"
MAGIC_HEADER = b"\x4E\x58\x43\x31"  # NXC1

# Frame Types
FRAME_AUTH = 0x01
FRAME_OPEN_STREAM = 0x02
FRAME_DATA = 0x03
FRAME_CLOSE_STREAM = 0x04
FRAME_HEARTBEAT = 0x05
FRAME_HEARTBEAT_ACK = 0x06


class NexusProtocol:
    """Handles binary frame serialization, encryption, and padding"""
    def __init__(self, token: str):
        self.key = hashlib.sha256(token.encode("utf-8")).digest()

    def pack_frame(self, frame_type: int, stream_id: int, payload: bytes = b"", add_padding: bool = True) -> bytes:
        pad_len = 0
        padding = b""
        if add_padding:
            # Dynamic random padding (16 - 64 bytes) to distort packet length signatures
            pad_len = secrets.randbelow(48) + 16
            padding = secrets.token_bytes(pad_len)

        raw_body = payload + padding
        # Lightweight XOR keystream based on HMAC-SHA256 of nonce
        nonce = secrets.token_bytes(8)
        keystream = hmac.new(self.key, nonce, hashlib.sha256).digest()
        
        # Stream cipher for raw_body
        enc_body = bytearray(len(raw_body))
        for i in range(len(raw_body)):
            enc_body[i] = raw_body[i] ^ keystream[i % len(keystream)]

        # Header: Magic (4B) + Type (1B) + StreamID (4B) + Nonce (8B) + DataLen (4B) + PadLen (1B)
        hdr = struct.pack("!4sBI8sIB", MAGIC_HEADER, frame_type, stream_id, nonce, len(payload), pad_len)
        auth_tag = hmac.new(self.key, hdr + enc_body, hashlib.sha256).digest()[:8]
        return hdr + bytes(enc_body) + auth_tag

    def unpack_frame(self, data: bytes) -> Tuple[Optional[int], int, Optional[bytes], int]:
        """
        Returns (frame_type, stream_id, payload, consumed_bytes)
        If frame incomplete or invalid, returns (None, 0, None, 0)
        """
        # Min frame: 4 + 1 + 4 + 8 + 4 + 1 + 8(tag) = 30 bytes
        if len(data) < 30:
            return None, 0, None, 0

        magic, f_type, stream_id, nonce, data_len, pad_len = struct.unpack("!4sBI8sIB", data[:22])
        if magic != MAGIC_HEADER:
            return None, 0, None, 0

        total_enc_len = data_len + pad_len
        total_frame_len = 22 + total_enc_len + 8
        if len(data) < total_frame_len:
            return None, 0, None, 0

        enc_body = data[22:22 + total_enc_len]
        tag = data[22 + total_enc_len:total_frame_len]

        # Verify authentication tag
        hdr = data[:22]
        expected_tag = hmac.new(self.key, hdr + enc_body, hashlib.sha256).digest()[:8]
        if not hmac.compare_digest(tag, expected_tag):
            return None, 0, None, 0

        # Decrypt
        keystream = hmac.new(self.key, nonce, hashlib.sha256).digest()
        dec_body = bytearray(total_enc_len)
        for i in range(total_enc_len):
            dec_body[i] = enc_body[i] ^ keystream[i % len(keystream)]

        payload = bytes(dec_body[:data_len])
        return f_type, stream_id, payload, total_frame_len


class NexusCoreServer:
    """
    Runs on the Foreign Server (Kharej / Exit Point).
    Listens for the persistent tunnel connection from Iran Server.
    Multiplexes streams and forwards them to local targets (e.g. 127.0.0.1:443).
    """
    def __init__(self, bind_host: str, bind_port: int, token: str, port_mappings: Dict[int, str]):
        self.bind_host = bind_host
        self.bind_port = bind_port
        self.proto = NexusProtocol(token)
        self.port_mappings = port_mappings  # incoming_port -> target_address (e.g. 443 -> "127.0.0.1:443")
        self.active_streams: Dict[int, asyncio.StreamWriter] = {}

    async def handle_tunnel_client(self, tunnel_reader: asyncio.StreamReader, tunnel_writer: asyncio.StreamWriter):
        peer = tunnel_writer.get_extra_info("peername")
        print(f"[*] [NexusCore] New tunnel connection from Iran server: {peer}")

        buffer = b""
        authenticated = False

        try:
            while True:
                chunk = await tunnel_reader.read(16384)
                if not chunk:
                    break
                buffer += chunk

                while buffer:
                    f_type, stream_id, payload, consumed = self.proto.unpack_frame(buffer)
                    if f_type is None:
                        break
                    buffer = buffer[consumed:]

                    # 1. Authentication Frame
                    if f_type == FRAME_AUTH:
                        authenticated = True
                        print(f"[+] [NexusCore] Iran server successfully authenticated.")
                        continue

                    if not authenticated:
                        print("[-] [NexusCore] Unauthenticated frame. Terminating connection.")
                        tunnel_writer.close()
                        return

                    # 2. Heartbeat Ping
                    if f_type == FRAME_HEARTBEAT:
                        ack = self.proto.pack_frame(FRAME_HEARTBEAT_ACK, 0, b"PONG", add_padding=False)
                        tunnel_writer.write(ack)
                        await tunnel_writer.drain()
                        continue

                    # 3. Open Stream
                    if f_type == FRAME_OPEN_STREAM:
                        # Payload contains target port (2 bytes)
                        if len(payload) >= 2:
                            dst_port = struct.unpack("!H", payload[:2])[0]
                            target = self.port_mappings.get(dst_port, f"127.0.0.1:{dst_port}")
                            thost, tport = target.split(":")
                            
                            asyncio.create_task(self.spawn_local_connection(
                                stream_id, thost, int(tport), tunnel_writer
                            ))
                        continue

                    # 4. Stream Data
                    if f_type == FRAME_DATA:
                        if stream_id in self.active_streams:
                            writer = self.active_streams[stream_id]
                            writer.write(payload)
                            await writer.drain()
                        continue

                    # 5. Close Stream
                    if f_type == FRAME_CLOSE_STREAM:
                        if stream_id in self.active_streams:
                            writer = self.active_streams.pop(stream_id)
                            try:
                                writer.close()
                            except Exception:
                                pass
                        continue

        except Exception as e:
            print(f"[!] [NexusCore] Tunnel error: {e}")
        finally:
            print(f"[-] [NexusCore] Iran server disconnected: {peer}")
            tunnel_writer.close()
            # Clean up all streams
            for s_id, writer in list(self.active_streams.items()):
                try:
                    writer.close()
                except Exception:
                    pass
            self.active_streams.clear()

    async def spawn_local_connection(self, stream_id: int, host: str, port: int, tunnel_writer: asyncio.StreamWriter):
        try:
            reader, writer = await asyncio.open_connection(host, port)
            self.active_streams[stream_id] = writer
            
            while True:
                data = await reader.read(8192)
                if not data:
                    break
                frame = self.proto.pack_frame(FRAME_DATA, stream_id, data, add_padding=False)
                tunnel_writer.write(frame)
                await tunnel_writer.drain()
        except Exception:
            pass
        finally:
            self.active_streams.pop(stream_id, None)
            try:
                writer.close()
            except Exception:
                pass
            # Notify client that stream closed
            try:
                close_frame = self.proto.pack_frame(FRAME_CLOSE_STREAM, stream_id, b"", add_padding=False)
                tunnel_writer.write(close_frame)
                await tunnel_writer.drain()
            except Exception:
                pass

    async def start(self):
        server = await asyncio.start_server(self.handle_tunnel_client, self.bind_host, self.bind_port)
        print(f"[✓] NexusCore Server running on {self.bind_host}:{self.bind_port}")
        print(f"[✓] Configured Port Mappings: {self.port_mappings}")
        async with server:
            await server.serve_forever()


class NexusCoreClient:
    """
    Runs on the Domestic Server (Iran Relay / Entry Point).
    Listens on public ports (e.g. 0.0.0.0:443).
    Connects to Foreign Server and transparently multiplexes all inbound user connections.
    """
    def __init__(self, remote_host: str, remote_port: int, token: str, forward_ports: List[int]):
        self.remote_host = remote_host
        self.remote_port = remote_port
        self.proto = NexusProtocol(token)
        self.forward_ports = forward_ports
        self.tunnel_writer: Optional[asyncio.StreamWriter] = None
        self.tunnel_reader: Optional[asyncio.StreamReader] = None
        self.stream_counter = 1
        self.active_streams: Dict[int, asyncio.StreamWriter] = {}
        self.tunnel_lock = asyncio.Lock()
        self.running = False

    async def maintain_tunnel(self):
        """Persistent connection manager with automatic reconnect and keep-alive"""
        while self.running:
            try:
                print(f"[*] [NexusCore] Establishing tunnel to Foreign Server: {self.remote_host}:{self.remote_port}...")
                reader, writer = await asyncio.open_connection(self.remote_host, self.remote_port)
                
                # Send AUTH frame
                auth_frame = self.proto.pack_frame(FRAME_AUTH, 0, b"AUTH_OK", add_padding=True)
                writer.write(auth_frame)
                await writer.drain()

                self.tunnel_reader = reader
                self.tunnel_writer = writer
                print(f"[✓] [NexusCore] Tunnel connected and authenticated successfully!")

                # Start heartbeat and packet reader
                read_task = asyncio.create_task(self.read_tunnel_loop())
                ping_task = asyncio.create_task(self.heartbeat_loop())
                
                done, pending = await asyncio.wait(
                    [read_task, ping_task],
                    return_when=asyncio.FIRST_COMPLETED
                )
                for task in pending:
                    task.cancel()

            except Exception as e:
                print(f"[!] [NexusCore] Tunnel connection error: {e}")
            finally:
                if self.tunnel_writer:
                    try:
                        self.tunnel_writer.close()
                    except Exception:
                        pass
                self.tunnel_writer = None
                self.tunnel_reader = None
                print("[*] Reconnecting in 3 seconds...")
                await asyncio.sleep(3)

    async def heartbeat_loop(self):
        while self.tunnel_writer:
            await asyncio.sleep(5)
            try:
                ping = self.proto.pack_frame(FRAME_HEARTBEAT, 0, b"PING", add_padding=False)
                self.tunnel_writer.write(ping)
                await self.tunnel_writer.drain()
            except Exception:
                break

    async def read_tunnel_loop(self):
        buffer = b""
        while self.tunnel_reader:
            chunk = await self.tunnel_reader.read(16384)
            if not chunk:
                break
            buffer += chunk

            while buffer:
                f_type, stream_id, payload, consumed = self.proto.unpack_frame(buffer)
                if f_type is None:
                    break
                buffer = buffer[consumed:]

                if f_type == FRAME_DATA:
                    if stream_id in self.active_streams:
                        u_writer = self.active_streams[stream_id]
                        u_writer.write(payload)
                        await u_writer.drain()

                elif f_type == FRAME_CLOSE_STREAM:
                    if stream_id in self.active_streams:
                        u_writer = self.active_streams.pop(stream_id)
                        try:
                            u_writer.close()
                        except Exception:
                            pass

    async def handle_user_connection(self, listen_port: int, u_reader: asyncio.StreamReader, u_writer: asyncio.StreamWriter):
        if not self.tunnel_writer:
            u_writer.close()
            return

        stream_id = self.stream_counter
        self.stream_counter = (self.stream_counter + 1) % 0x7FFFFFFF
        self.active_streams[stream_id] = u_writer

        try:
            # Send open stream frame with target port
            target_payload = struct.pack("!H", listen_port)
            open_frame = self.proto.pack_frame(FRAME_OPEN_STREAM, stream_id, target_payload, add_padding=True)
            self.tunnel_writer.write(open_frame)
            await self.tunnel_writer.drain()

            while True:
                data = await u_reader.read(8192)
                if not data:
                    break
                if not self.tunnel_writer:
                    break
                data_frame = self.proto.pack_frame(FRAME_DATA, stream_id, data, add_padding=False)
                self.tunnel_writer.write(data_frame)
                await self.tunnel_writer.drain()

        except Exception:
            pass
        finally:
            self.active_streams.pop(stream_id, None)
            try:
                u_writer.close()
            except Exception:
                pass
            if self.tunnel_writer:
                try:
                    close_frame = self.proto.pack_frame(FRAME_CLOSE_STREAM, stream_id, b"", add_padding=False)
                    self.tunnel_writer.write(close_frame)
                    await self.tunnel_writer.drain()
                except Exception:
                    pass

    async def start(self):
        self.running = True
        # Start tunnel maintenance loop in background
        asyncio.create_task(self.maintain_tunnel())

        # Bind listeners for each user-facing port
        servers = []
        for port in self.forward_ports:
            # Create a closure binding current port
            def make_handler(p):
                return lambda r, w: self.handle_user_connection(p, r, w)
            
            srv = await asyncio.start_server(make_handler(port), "0.0.0.0", port)
            servers.append(srv)
            print(f"[✓] [NexusCore] Listening on Iran Relay port: 0.0.0.0:{port} -> Tunnel -> Foreign Server:{port}")

        await asyncio.gather(*[s.serve_forever() for s in servers])


def parse_mappings(mapping_strings: List[str]) -> Dict[int, str]:
    """Parses port strings e.g. ['443=127.0.0.1:443', '8443=127.0.0.1:8443'] or ['443', '8443']"""
    res = {}
    for item in mapping_strings:
        if "=" in item:
            src, dst = item.split("=", 1)
            res[int(src.strip())] = dst.strip()
        else:
            p = int(item.strip())
            res[p] = f"127.0.0.1:{p}"
    return res


def main():
    parser = argparse.ArgumentParser(description="NexusCore - High-Performance Multiplexed Relay Engine")
    parser.add_argument("--mode", choices=["server", "client"], required=True, help="Operating mode")
    parser.add_argument("--bind", type=str, default="0.0.0.0", help="Bind IP address (default: 0.0.0.0)")
    parser.add_argument("--port", type=int, default=3080, help="Tunnel control port (default: 3080)")
    parser.add_argument("--remote-host", type=str, default="127.0.0.1", help="Foreign Server IP/Domain (client mode)")
    parser.add_argument("--remote-port", type=int, default=3080, help="Foreign Server Port (client mode)")
    parser.add_argument("--token", type=str, default="NexusTunnelSecurePsk2026", help="Authentication token")
    parser.add_argument("--forward-ports", nargs="+", default=["443", "8443"],
                        help="Ports to forward, e.g. 443 8443 or 443=127.0.0.1:443")

    args = parser.parse_args()

    if args.mode == "server":
        mappings = parse_mappings(args.forward_ports)
        server = NexusCoreServer(args.bind, args.port, args.token, mappings)
        asyncio.run(server.start())

    elif args.mode == "client":
        ports = [int(p.split("=")[0]) for p in args.forward_ports]
        client = NexusCoreClient(args.remote_host, args.remote_port, args.token, ports)
        asyncio.run(client.start())


if __name__ == "__main__":
    main()
