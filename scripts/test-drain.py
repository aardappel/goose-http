#!/usr/bin/env python3
"""Stall and resume a WebSocket reader; check every frame and bounded memory."""
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time


def rss(pid):
    for line in Path(f"/proc/{pid}/status").read_text().splitlines():
        if line.startswith("VmRSS:"):
            return int(line.split()[1]) * 1024
    raise AssertionError("no RSS sample")


def connect():
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16384)
    sock.settimeout(10)
    sock.connect(("127.0.0.1", 27893))
    sock.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                 b"Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                 b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n")
    head = b""
    while not head.endswith(b"\r\n\r\n"):
        part = sock.recv(1)
        assert part, head
        head += part
    assert head.startswith(b"HTTP/1.1 101"), head
    return sock


def take(sock, count):
    result = bytearray()
    while len(result) < count:
        part = sock.recv(count - len(result))
        assert part, "unexpected EOF"
        result.extend(part)
    return result


for loop in ("uring", "epoll"):
    with tempfile.TemporaryFile(mode="w+") as log:
        proc = subprocess.Popen([str(Path(sys.argv[1]).resolve())],
                                env={**os.environ, "LOOP": loop}, stdout=log, stderr=log)
        try:
            for _ in range(100):
                try:
                    # Readiness without beginning an output stream.
                    with socket.create_connection(("127.0.0.1", 27893), timeout=.1):
                        break
                except OSError:
                    assert proc.poll() is None
                    time.sleep(.05)
            baseline = rss(proc.pid)
            with connect() as sock:
                peak = baseline
                for _ in range(40):
                    time.sleep(.05)
                    peak = max(peak, rss(proc.pid))
                log.seek(0)
                assert "Delivered" not in log.read(), "publisher ignored slow reader"
                assert peak - baseline < 8 * 1024 * 1024, (baseline, peak)
                for sequence in range(4096):
                    assert take(sock, 4) == b"\x82\x7e\x20\x00"
                    payload = take(sock, 8192)
                    assert struct.unpack("<Q", payload[:8])[0] == sequence
                    assert payload[8:] == b"x" * 8184
                sock.settimeout(.1)
                try:
                    assert not sock.recv(1), "unexpected duplicate frame"
                except socket.timeout:
                    pass
            # A disconnected slow consumer must release its connection slot.
            for _ in range(16):
                with connect():
                    pass
            assert proc.poll() is None
            print(json.dumps({"loop": loop, "frames": 4096, "payload_bytes": 33554432,
                              "rss_before": baseline, "rss_stalled_peak": peak,
                              "rss_growth": peak - baseline, "ordered_delivery": True,
                              "disconnect_reuse": True}), flush=True)
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
