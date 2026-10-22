#!/usr/bin/env python3
"""A DRAINED publisher must yield to other sockets and refresh its deadline."""
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time


for loop in ("uring", "epoll"):
    with tempfile.TemporaryFile(mode="w+") as log:
        proc = subprocess.Popen([str(Path(sys.argv[1]).resolve())],
                                env={**os.environ, "LOOP": loop}, stdout=log, stderr=log)
        sock = None
        reader = None
        stopping = threading.Event()
        errors = []
        frames = [0]
        try:
            for _ in range(100):
                try:
                    sock = socket.create_connection(("127.0.0.1", 27894), timeout=.1)
                    break
                except OSError:
                    assert proc.poll() is None
                    time.sleep(.05)
            assert sock is not None
            sock.settimeout(2)
            sock.sendall(b"GET /stream HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                         b"Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                         b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n")
            head = b""
            while not head.endswith(b"\r\n\r\n"):
                part = sock.recv(1)
                assert part, head
                head += part
            assert head.startswith(b"HTTP/1.1 101"), head

            def read_frames():
                try:
                    frame = b"\x82\x7e\x20\x00" + b"x" * 8192
                    while not stopping.is_set():
                        data = bytearray()
                        while len(data) < len(frame):
                            part = sock.recv(len(frame) - len(data))
                            assert part, "active publisher closed at an old deadline"
                            data.extend(part)
                        assert data == frame
                        frames[0] += 1
                except Exception as error:
                    if not stopping.is_set():
                        errors.append(str(error))

            reader = threading.Thread(target=read_frames)
            reader.start()
            latencies = []
            # Three sweep intervals, with no input or later() on the publisher.
            until = time.monotonic() + 3.2
            while time.monotonic() < until:
                started = time.monotonic()
                conn = http.client.HTTPConnection("127.0.0.1", 27894, timeout=.75)
                try:
                    conn.request("GET", "/health")
                    response = conn.getresponse()
                    assert response.status == 200 and response.read() == b"ok"
                finally:
                    conn.close()
                latencies.append(time.monotonic() - started)
                assert not errors, errors
                time.sleep(.1)
            assert reader.is_alive() and frames[0] > 100 and not errors, (frames, errors)
            print(json.dumps({"loop": loop, "frames": frames[0],
                              "health_requests": len(latencies),
                              "health_max_seconds": max(latencies),
                              "active_past_deadline": True}), flush=True)
        finally:
            stopping.set()
            if sock is not None:
                sock.close()
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            if reader is not None:
                reader.join(timeout=3)
