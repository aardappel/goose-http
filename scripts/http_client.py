"""Test clients for the HTTP server, run by scripts/test-http.sh.

    http_client.py PORT tfb         TechEmpower's plaintext and JSON checks
    http_client.py PORT forms       absolute-form targets and OPTIONS *
    http_client.py PORT pipeline    pipelined requests and request bodies
    http_client.py PORT large       responses larger than the write buffer
    http_client.py PORT chunked     chunked request bodies, and HttpArena's /baseline11
    http_client.py PORT stream      bodies and responses of any size, in pieces, and Expect
    http_client.py PORT websocket   /ws, a WebSocket echo, as HttpArena's echo-ws profiles use it
    http_client.py PORT files DIR   /files/, after writing its files into DIR, the
                                    directory the server's FILES names
    http_client.py PORT dataset FILE
                                    writes a dataset for /json/{count} into FILE,
                                    which the server's DATASET names
    http_client.py PORT compress FILE
                                    compressed responses: /json/{count} from the
                                    dataset FILE, and /zstream
    http_client.py PORT keepalive   keep-alive, Connection: close, HTTP/1.0
    http_client.py PORT hostile     malformed and oversized requests
    http_client.py PORT slow        slow clients, against the server's timeouts
    http_client.py PORT many N      N connections at once, each pipelining
    http_client.py PORT emfile N    N connections to a server with fewer fds
    http_client.py PORT max-conns N one worker with MAX_CONNS=N: the next waits
    http_client.py PORT later       answers that wait: /later and /events, for a
                                    server started with MAIL_SLOTS
    http_client.py PORT later-off   /later's 503 and /delay's TIMEOUT at once, for a
                                    server without them
    http_client.py PORT listen ADDRESS [v6only]
                                    a server started with ADDRESS (and IPV6_ONLY):
                                    "::" over IPv6 and IPv4, or a Unix socket
    http_client.py PORT tls         HTTP/1.1 over TLS, PORT being the server's TLS port:
                                    the checks above that suit it, and bad handshakes
    http_client.py PORT tls-slow    handshakes that stall, against REQUEST_MS
    http_client.py PORT stop PID    a graceful stop, by SIGTERM to the server's PID
    http_client.py PORT stop-break SERVER
                                    on Windows, a graceful stop by Ctrl+Break, of a
                                    server it starts from the executable SERVER

Each check exits non-zero with a message on the first failure. SERVER_NAME
is the Server field tfb expects (goose), for checking the servers in bench/.
"""

import asyncio
import base64
import email.utils
import gzip
import hashlib
import json
import os
import signal
import socket
import ssl
import subprocess
import sys
import threading
import time
import zlib

try:
    from compression import zstd  # Python 3.14
except ImportError:
    zstd = None

HOST = "127.0.0.1"
SERVER_NAME = os.environ.get("SERVER_NAME", "goose")
# The server's request_ms, body_ms, and write_ms (http::Config, http.goose), in
# seconds: the package's defaults, or what test-http.sh gives the server for the
# slow run.
REQUEST_TIMEOUT = int(os.environ.get("REQUEST_MS", "10000")) / 1000
BODY_TIMEOUT = int(os.environ.get("BODY_MS", "10000")) / 1000
WRITE_TIMEOUT = int(os.environ.get("WRITE_MS", "10000")) / 1000
# What TechEmpower's load generator sends with each request.
TFB_HEADERS = (
    b"Host: tfb-server\r\n"
    b"Accept: text/plain,text/html;q=0.9,application/xhtml+xml;q=0.9,"
    b"application/xml;q=0.8,*/*;q=0.7\r\n"
    b"Connection: keep-alive\r\n"
)


def fail(msg):
    print(f"FAIL: {msg}")
    sys.exit(1)


# Whether Conn speaks TLS, as the tls mode's checks do: the server's
# certificate isn't verified, and ALPN offers http/1.1 alone, as HttpArena's
# clients do.
TLS = False


def tls_context(alpn=("http/1.1",), version=None):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    if alpn:
        ctx.set_alpn_protocols(list(alpn))
    if version is not None:
        ctx.minimum_version = ctx.maximum_version = version
    return ctx


def request(path, method=b"GET", extra=b"", version=b"HTTP/1.1"):
    return method + b" " + path + b" " + version + b"\r\n" + TFB_HEADERS + extra + b"\r\n"


class Response:
    def __init__(self, status, headers, body):
        self.status = status
        self.headers = headers  # lowercased names, in order
        self.body = body
        self.trailers = []  # a chunked body's, as headers

    def header(self, name):
        values = [v for n, v in self.headers if n == name]
        if len(values) != 1:
            fail(f"{len(values)} {name} fields in {self.headers}")
        return values[0]


class Conn:
    """A blocking connection that reads responses one at a time."""

    def __init__(self, port, timeout=5, rcvbuf=0, family=socket.AF_INET, addr=None):
        """A connection to HOST and port, or to addr in family: an IPv6
        address and port, or a Unix socket's path."""
        self.sock = socket.socket(family, socket.SOCK_STREAM)
        # Before connecting, so that the window starts small.
        if rcvbuf:
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
        self.sock.settimeout(timeout)
        self.sock.connect(addr if addr is not None else (HOST, port))
        if TLS:
            self.sock = tls_context().wrap_socket(self.sock, suppress_ragged_eofs=False)
        # A bytearray, which drops a prefix without copying the rest.
        self.buf = bytearray()

    def send(self, data):
        self.sock.sendall(data)

    def fill(self):
        chunk = self.sock.recv(65536)
        if not chunk:
            fail(f"connection closed with {len(self.buf)} bytes unparsed")
        self.buf += chunk

    def line(self):
        """The next line, without its CRLF."""
        while (end := self.buf.find(b"\r\n")) < 0:
            self.fill()
        line = bytes(self.buf[:end])
        del self.buf[:end + 2]
        return line

    def take(self, n):
        while len(self.buf) < n:
            self.fill()
        data = bytes(self.buf[:n])
        del self.buf[:n]
        return data

    def head(self):
        """The next response's head alone, for reading its chunks one by one
        with chunk."""
        return self.response(head_only=True)

    def chunk(self):
        """The next chunk's data, or b"" for the last chunk, which leaves its
        trailers and the blank line after them to read with line."""
        size = int(self.line().split(b";")[0], 16)
        if size == 0:
            return b""
        data = self.take(size)
        if self.take(2) != b"\r\n":
            fail("a chunk without its CRLF")
        return data

    def response(self, head_only=False):
        """The next response: a 1xx, a body framed by Content-Length or
        chunked, or one that ends when the server closes."""
        while b"\r\n\r\n" not in self.buf:
            self.fill()
        end = self.buf.find(b"\r\n\r\n")
        head = bytes(self.buf[:end])
        del self.buf[:end + 4]
        lines = head.split(b"\r\n")
        version, status, _ = lines[0].split(b" ", 2)
        if version != b"HTTP/1.1":
            fail(f"status line {lines[0]!r}")
        headers = []
        for line in lines[1:]:
            name, value = line.split(b":", 1)
            headers.append((name.decode().lower(), value.strip().decode()))
        r = Response(int(status), headers, b"")
        names = [n for n, _ in headers]
        if head_only or r.status < 200 or r.status in (204, 304):
            return r
        if "transfer-encoding" in names:
            if r.header("transfer-encoding") != "chunked" or "content-length" in names:
                fail(f"framing {headers}")
            body = bytearray()
            while (size := int(self.line().split(b";")[0], 16)) > 0:
                body += self.take(size)
                if self.take(2) != b"\r\n":
                    fail("a chunk without its CRLF")
            while line := self.line():
                name, value = line.split(b":", 1)
                r.trailers.append((name.decode().lower(), value.strip().decode()))
            r.body = bytes(body)
        elif "content-length" in names:
            r.body = self.take(int(r.header("content-length")))
        else:
            while True:
                chunk = self.sock.recv(1 << 20)
                if not chunk:
                    break
                self.buf += chunk
            r.body = bytes(self.buf)
            self.buf = bytearray()
        return r

    def closed(self):
        """Whether the server closes the connection, sending nothing more."""
        try:
            while True:
                chunk = self.sock.recv(65536)
                if not chunk:
                    return not self.buf
                self.buf += chunk
        except (socket.timeout, TimeoutError):
            return False
        except ConnectionResetError:
            return not self.buf

    def close(self):
        self.sock.close()


def check_tfb(r, ctype, now):
    """The response checks of TechEmpower's verifier for both tests."""
    if r.status != 200:
        fail(f"status {r.status}")
    if r.header("server") != SERVER_NAME:
        fail(f"Server {r.header('server')}")
    if r.header("content-type") != ctype:
        fail(f"Content-Type {r.header('content-type')}")
    if int(r.header("content-length")) != len(r.body):
        fail("Content-Length doesn't match the body")
    date = r.header("date")
    parsed = email.utils.parsedate_to_datetime(date)
    if email.utils.format_datetime(parsed, usegmt=True) != date:
        fail(f"Date isn't an IMF-fixdate: {date}")
    if abs(parsed.timestamp() - now) > 2:
        fail(f"Date is {parsed.timestamp() - now:.0f} s off: {date}")


def tfb(port):
    c = Conn(port)
    c.send(request(b"/plaintext"))
    r = c.response()
    check_tfb(r, "text/plain", time.time())
    if r.body != b"Hello, World!":
        fail(f"plaintext body {r.body!r}")
    c.send(request(b"/json"))
    r = c.response()
    check_tfb(r, "application/json", time.time())
    if json.loads(r.body) != {"message": "Hello, World!"}:
        fail(f"json body {r.body!r}")
    # The Date field moves on with the clock.
    first = r.header("date")
    time.sleep(1.1)
    c.send(request(b"/json"))
    if c.response().header("date") == first:
        fail("Date didn't change after a second")
    c.close()
    print("tfb: ok")


def forms(port):
    """Request targets beyond origin-form, which TechEmpower doesn't send:
    absolute-form, which a server must take (RFC 9112 §3.2.2), and OPTIONS *,
    for the server as a whole (RFC 9110 §9.3.7)."""
    c = Conn(port)
    c.send(request(b"http://tfb-server/plaintext"))
    r = c.response()
    if r.status != 200 or r.body != b"Hello, World!":
        fail(f"absolute-form: {r.status} {r.body!r}")
    c.send(request(b"*", b"OPTIONS"))
    r = c.response()
    if r.status // 100 != 2:
        fail(f"OPTIONS *: {r.status}")
    c.close()
    print("forms: ok")


def pipeline(port):
    # 16 requests in one write, as TechEmpower's plaintext test sends them,
    # answered in order.
    c = Conn(port)
    paths = [b"/plaintext", b"/json", b"/nope"] * 5 + [b"/plaintext"]
    c.send(b"".join(request(p) for p in paths))
    for p in paths:
        r = c.response()
        want = {b"/plaintext": 200, b"/json": 200, b"/nope": 404}[p]
        if r.status != want:
            fail(f"{p} answered {r.status}")
    # A request split at every byte, and bodies, small and large, read and
    # dropped between pipelined requests.
    for b in request(b"/plaintext"):
        c.send(bytes([b]))
    if c.response().status != 200:
        fail("byte-at-a-time request")
    body = bytes(range(256)) * 2000
    c.send(request(b"/json", b"POST", b"Content-Length: 5\r\n") + b"hello" +
           request(b"/json", b"POST", b"Content-Length: %d\r\n" % len(body)))
    for i in range(0, len(body), 30000):
        c.send(body[i:i + 30000])
    c.send(request(b"/plaintext"))
    r = c.response()
    # Goose drains a body it answered without reading, up to max_drain, and
    # keeps the connection; RFC 9112 §9.6 lets a server close instead, after
    # a 405 that says so, as some servers in bench/ do.
    closing = [v for n, v in r.headers if n == "connection"] == ["close"]
    if r.status != 405 or (closing and SERVER_NAME == "goose"):
        fail(f"after a body: {r.status} {r.headers}, want 405 on an open connection")
    if closing:
        c.close()
        c = Conn(port)
    else:
        for want in (405, 200):
            r = c.response()
            if r.status != want:
                fail(f"after a body: {r.status}, want {want}")
    # More pipelined responses than the write buffer holds at once.
    c.send(request(b"/json") * 500)
    for i in range(500):
        if c.response().status != 200:
            fail("500 pipelined requests")
    c.close()
    # A client that sends all its requests, then reads the responses only
    # after the server's send has blocked: the server goes on once the
    # socket takes more, with no request left to wake it. Blocking it takes
    # megabytes on loopback, where the receive buffers grow, and the requests
    # must fit the server's, or the client blocks too: it starts reading
    # after 2 s either way.
    n = 20000
    c = Conn(port, rcvbuf=4096)
    sender = threading.Thread(target=c.send, args=(request(b"/json") * n,))
    sender.start()
    sender.join(2)
    for i in range(n):
        if c.response().status != 200:
            fail("a client that reads late")
    sender.join()
    c.close()
    print("pipeline: ok")


def large(port):
    def check(r, n):
        if r.status != 200:
            fail(f"/bytes?n={n} answered {r.status}")
        want = (b"0123456789" * (n // 10 + 1))[:n]
        if r.body != want:
            fail(f"/bytes?n={n}: {len(r.body)} bytes, not the ones sent")

    # Responses larger than the server's 8 KB write buffer: alone, and
    # pipelined between small ones, answered in order.
    c = Conn(port)
    for n in (5000, 8192, 8193, 100000):
        c.send(request(b"/bytes?n=%d" % n))
        check(c.response(), n)
    sizes = [None, 6000, None, 300000, 20000, None]
    c.send(b"".join(request(b"/plaintext") if n is None else request(b"/bytes?n=%d" % n)
                    for n in sizes))
    for n in sizes:
        r = c.response()
        if n is None:
            if r.status != 200 or r.body != b"Hello, World!":
                fail(f"/plaintext between large responses: {r.status} {r.body!r}")
        else:
            check(r, n)
    c.close()
    # 4 MB to a client that starts reading only after the server's send has
    # blocked, and a request after it on the same connection.
    c = Conn(port, rcvbuf=4096)
    c.send(request(b"/bytes?n=4000000") + request(b"/json"))
    time.sleep(1)
    check(c.response(), 4000000)
    if c.response().status != 200:
        fail("a request after a 4 MB response")
    c.close()
    print("large: ok")


def chunked(port):
    def te(body):
        return request(b"/json", b"POST", b"Transfer-Encoding: chunked\r\n") + body

    # Chunked bodies, with an extension and a trailer field, dropped between
    # pipelined requests, and one sent a byte at a time.
    c = Conn(port)
    c.send(te(b"5\r\nhello\r\n0\r\n\r\n") +
           te(b"3;x=y\r\nabc\r\nA\r\n0123456789\r\n0\r\nT: v\r\n\r\n") +
           request(b"/plaintext"))
    for want in (405, 405, 200):
        r = c.response()
        if r.status != want:
            fail(f"after a chunked body: {r.status}, want {want}")
    for b in te(b"2\r\nhi\r\n0\r\n\r\n"):
        c.send(bytes([b]))
    if c.response().status != 405:
        fail("byte-at-a-time chunked body")
    # HttpArena's baseline: a + b, plus the body of a POST, whichever framing.
    for req, want in (
        (request(b"/baseline11?a=13&b=42"), b"55"),
        (request(b"/baseline11?b=-2&a=5&c=9"), b"3"),
        (request(b"/baseline11?a=13&b=42", b"POST", b"Content-Length: 2\r\n") + b"20", b"75"),
        (request(b"/baseline11?a=13&b=42", b"POST", b"Transfer-Encoding: chunked\r\n") +
         b"1\r\n2\r\n1\r\n0\r\n0\r\n\r\n", b"75"),
        # Too long for the read buffer: dropped as it arrives, and answered as
        # an empty body.
        (request(b"/baseline11?a=13&b=42", b"POST", b"Content-Length: 20000\r\n") +
         b"1" * 20000, b"55"),
    ):
        c.send(req)
        r = c.response()
        if r.status != 200 or r.body != want:
            fail(f"{req!r}: {r.status} {r.body!r}, want {want!r}")
    c.close()
    print("chunked: ok")


def digits(n, at=0):
    """What /bytes and /stream send: n of the digits, from the at'th."""
    return (b"0123456789" * ((at + n) // 10 + 1))[at:at + n]


def stream(port):
    block = bytes(range(256)) * 4096
    total = len(block) * 100
    want = b"%d %d" % (total, sum(block) * 100)

    def check(r, status, body, what):
        if r.status != status or (body is not None and r.body != body):
            fail(f"{what}: {r.status} {r.body[:60]!r}, want {status} {(body or b'')[:60]!r}")

    # 100 MB with a Content-Length, and chunked in chunks of many sizes, read
    # by /upload in pieces, with requests after them on the connection.
    c = Conn(port, timeout=30)
    c.send(request(b"/upload", b"POST", b"Content-Length: %d\r\n" % total))
    for _ in range(100):
        c.send(block)
    check(c.response(), 200, want, "100 MB upload")
    c.send(request(b"/upload", b"POST", b"Transfer-Encoding: chunked\r\n"))
    sizes = [1, 7, 4096, 8191, 8192, 70000, 300000]
    for _ in range(100):
        pieces, at, i = [], 0, 0
        while at < len(block):
            n = min(sizes[i % len(sizes)], len(block) - at)
            ext = b";n=%d" % i if i % 3 == 0 else b""
            pieces.append(b"%x%s\r\n" % (n, ext) + block[at:at + n] + b"\r\n")
            at += n
            i += 1
        c.send(b"".join(pieces))
    c.send(b"0\r\nX-Trailer: y\r\n\r\n" + request(b"/plaintext"))
    check(c.response(), 200, want, "100 MB chunked upload")
    check(c.response(), 200, b"Hello, World!", "a request after an upload")

    # Bodies a route answers without reading: dropped, up to the server's
    # max_drain, 1 MB, and the connection goes on; past it, it closes.
    c.send(request(b"/json", b"POST", b"Content-Length: 600000\r\n") + b"x" * 600000 +
           request(b"/json", b"POST", b"Transfer-Encoding: chunked\r\n") +
           b"4000\r\n" + b"x" * 0x4000 + b"\r\n0\r\n\r\n" + request(b"/plaintext"))
    for status in (405, 405, 200):
        check(c.response(), status, None, "after a dropped body")
    c.send(request(b"/json", b"POST", b"Content-Length: 5000000\r\n") + b"x" * 1000)
    check(c.response(), 405, None, "a body past max_drain")
    if not c.closed():
        fail("a body past max_drain left the connection open")

    # Expect: 100-continue, for a long body and a short one, and a final
    # status instead of 100 Continue, which closes the connection.
    c = Conn(port)
    c.send(request(b"/upload", b"POST", b"Content-Length: 100000\r\nExpect: 100-continue\r\n"))
    check(c.response(), 100, None, "Expect, long body")
    c.send(b"y" * 100000)
    check(c.response(), 200, b"100000 12100000", "Expect, long body")
    c.send(request(b"/upload", b"POST", b"Content-Length: 5\r\nExpect: 100-continue\r\n"))
    check(c.response(), 100, None, "Expect, short body")
    c.send(b"hello")
    check(c.response(), 200, b"5 532", "Expect, short body")
    c.send(request(b"/json", b"POST", b"Content-Length: 100000\r\nExpect: 100-continue\r\n"))
    check(c.response(), 405, None, "Expect, refused")
    if not c.closed():
        fail("a refused Expect left the connection open")

    # /echo sends a 10 MB body back as it arrives, with its Content-Length
    # and chunked; the client sends from a thread, as the server stops
    # reading while the client doesn't.
    body = block * 10
    for framing, data in ((b"Content-Length: %d\r\n" % len(body), body),
                          (b"Transfer-Encoding: chunked\r\n",
                           b"".join(b"%x\r\n" % len(body[i:i + 65536]) + body[i:i + 65536] + b"\r\n"
                                    for i in range(0, len(body), 65536)) + b"0\r\nX-Check: 42\r\n\r\n")):
        c = Conn(port, timeout=30)
        sender = threading.Thread(target=c.send, args=(request(b"/echo", b"POST", framing) + data,))
        sender.start()
        r = c.response()
        check(r, 200, body, f"/echo, {framing!r}")
        sender.join()
        c.close()
        # A chunked body's trailers come back as the response's.
        if r.trailers != ([("x-check", "42")] if b"chunked" in framing else []):
            fail(f"/echo's trailers: {r.trailers}")
    # The trailers of a body that comes whole too.
    c = Conn(port)
    c.send(request(b"/echo", b"POST", b"Transfer-Encoding: chunked\r\n") + b"2\r\nhi\r\n0\r\nA: b\r\n\r\n")
    r = c.response()
    check(r, 200, b"hi", "/echo, a whole chunked body")
    if r.trailers != [("a", "b")]:
        fail(f"/echo's trailers for a whole body: {r.trailers}")
    c.close()

    # 10 MB with a Content-Length, 100 MB chunked, and to HTTP/1.0, a body
    # that ends at the close.
    c = Conn(port, timeout=30)
    c.send(request(b"/bytes?n=10000000") + request(b"/stream?n=100000000") + request(b"/plaintext"))
    check(c.response(), 200, digits(10000000), "/bytes, 10 MB")
    check(c.response(), 200, digits(100000000), "/stream, 100 MB")
    check(c.response(), 200, b"Hello, World!", "a request after /stream")
    c.send(b"GET /stream?n=50000 HTTP/1.0\r\n\r\n")
    r = c.response()
    check(r, 200, digits(50000), "/stream to HTTP/1.0")
    if r.header("connection") != "close":
        fail("/stream to HTTP/1.0 without Connection: close")
    # An upgrade: 101, and then the connection echoes bytes as they are,
    # those that came with the request among them, until the client closes.
    c = Conn(port)
    c.send(b"GET /upgrade HTTP/1.1\r\nHost: x\r\nConnection: keep-alive, Upgrade\r\n"
           b"Upgrade: echo\r\n\r\nhello")
    r = c.response()
    if r.status != 101 or r.header("upgrade") != "echo" or r.header("connection") != "Upgrade":
        fail(f"upgrade: {r.status} {r.headers}")
    if c.take(5) != b"hello":
        fail("upgrade: the bytes after the request weren't echoed")
    for data in (b"GET / HTTP/1.1\r\n\r\n", b"x" * 100000):
        c.send(data)
        if c.take(len(data)) != data:
            fail("upgrade: bytes weren't echoed as they are")
    c.close()
    c = Conn(port)
    c.send(request(b"/upgrade"))
    r = c.response()
    if r.status != 426 or r.header("upgrade") != "echo":
        fail(f"a request to /upgrade without Upgrade: {r.status}")
    print("stream: ok")


def keepalive(port):
    c = Conn(port)
    c.send(b"GET /plaintext HTTP/1.0\r\n\r\n")
    r = c.response()
    if r.status != 200 or r.header("connection") != "close" or not c.closed():
        fail("HTTP/1.0 without keep-alive stayed open")
    c = Conn(port)
    for _ in range(2):
        c.send(b"GET /plaintext HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")
        r = c.response()
        if r.status != 200 or r.header("connection") != "keep-alive":
            fail("HTTP/1.0 keep-alive")
    c.close()
    c = Conn(port)
    c.send(request(b"/plaintext") + request(b"/json", extra=b"Connection: close\r\n") +
           request(b"/plaintext"))
    c.response()
    if c.response().header("connection") != "close" or not c.closed():
        fail("Connection: close left the connection open, or answered past it")
    c = Conn(port)
    c.send(b"HEAD /plaintext HTTP/1.1\r\nHost: x\r\n\r\n")
    r = c.response(head_only=True)
    if r.status != 200 or r.header("content-length") != "13":
        fail("HEAD")
    c.send(request(b"/json"))
    if c.response().status != 200:
        fail("a request after HEAD")
    print("keepalive: ok")


def hostile(port):
    big = b"x" * 20000
    cases = [
        ("bare LF", b"GET /plaintext HTTP/1.1\nHost: x\n\n", 400),
        ("bare LF after the headers", b"GET /plaintext HTTP/1.1\r\nHost: x\r\n\n", 400),
        ("missing version", b"GET /plaintext\r\n\r\n", 400),
        ("missing target", b"GET HTTP/1.1\r\nHost: x\r\n\r\n", 400),
        ("no Host", b"GET /plaintext HTTP/1.1\r\n\r\n", 400),
        ("NUL in a value", b"GET / HTTP/1.1\r\nHost: x\r\nX: a\x00b\r\n\r\n", 400),
        ("space before a colon", b"GET / HTTP/1.1\r\nHost : x\r\n\r\n", 400),
        ("folded line", b"GET / HTTP/1.1\r\nHost: x\r\nX: a\r\n b\r\n\r\n", 400),
        ("bad Content-Length", b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1a\r\n\r\n", 400),
        ("two Content-Lengths",
         b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab", 400),
        ("binary", bytes(range(256)), 400),
        ("TLS hello", b"\x16\x03\x01\x02\x00\x01\x00\x01\xfc\x03\x03" + b"\x00" * 40, 400),
        ("HTTP/2 preface", b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", 505),
        ("gzip coding", b"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\n\r\n"
                        b"5\r\nhello\r\n0\r\n\r\n", 501),
        ("chunked not last", b"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked, gzip\r\n\r\n"
                             b"0\r\n\r\n", 400),
        ("chunked and Content-Length",
         b"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n"
         b"0\r\n\r\n", 400),
        ("bad chunk size", b"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
                           b"5x\r\nhello\r\n0\r\n\r\n", 400),
        ("chunk size line past the buffer",
         b"POST /upload HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
         b"4000\r\n" + b"x" * 0x4000 + b"\r\n1;x=" + b"a" * 9000 + b"\r\n", 400),
        ("unknown expectation", b"POST / HTTP/1.1\r\nHost: x\r\nExpect: magic\r\n\r\n", 417),
        ("huge body", b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 2000000000\r\n\r\n", 413),
        ("huge chunk", b"POST /upload HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
                       b"80000000\r\n" + b"x" * 1000, 413),
        ("long target", b"GET /" + big + b" HTTP/1.1\r\nHost: x\r\n\r\n", 414),
        ("huge header", b"GET / HTTP/1.1\r\nHost: x\r\nX: " + big + b"\r\n\r\n", 431),
        ("huge header count",
         b"GET / HTTP/1.1\r\nHost: x\r\n" + b"X: y\r\n" * 5000 + b"\r\n", 431),
        ("endless empty lines", b"\r\n" * 10000, 431),
    ]
    for name, data, want in cases:
        c = Conn(port)
        c.send(data)
        r = c.response()
        if r.status != want:
            fail(f"{name}: {r.status}, want {want}")
        if r.header("connection") != "close" or not c.closed():
            fail(f"{name}: the connection stayed open")
        c.close()
        print(f"hostile: {name}: {want}")
    # A refused request after good ones still gets the good ones answered.
    c = Conn(port)
    c.send(request(b"/plaintext") + b"GET /\r\n\r\n" + request(b"/plaintext"))
    if c.response().status != 200 or c.response().status != 400 or not c.closed():
        fail("a refusal in a pipeline")
    print("hostile: ok")


def slow(port):
    """Runs the slow clients at once, so the run takes one timeout."""
    errors = []
    t0 = time.time()

    def slowloris():
        # The first bytes of a request, then nothing: 408 once the request
        # timeout has passed since the first byte, however the bytes trickle.
        c = Conn(port, timeout=REQUEST_TIMEOUT + 5)
        c.send(b"GET /plaintext HTTP/1.1\r\n")
        for _ in range(3):
            time.sleep(REQUEST_TIMEOUT / 5)
            c.send(b"X: y\r\n")
        r = c.response()
        took = time.time() - t0
        if r.status != 408 or not c.closed() or not REQUEST_TIMEOUT - 1 < took < REQUEST_TIMEOUT + 3:
            errors.append(f"slowloris: {r.status} after {took:.1f} s")

    def silent():
        # A connection that sends nothing is closed after the request timeout.
        c = Conn(port, timeout=REQUEST_TIMEOUT + 5)
        if not c.closed():
            errors.append("silent connection left open")
        took = time.time() - t0
        if not REQUEST_TIMEOUT - 1 < took < REQUEST_TIMEOUT + 3:
            errors.append(f"silent connection closed after {took:.1f} s")

    def slow_body():
        # A body that stops arriving: 408 once the body timeout has passed
        # since its last piece.
        c = Conn(port, timeout=BODY_TIMEOUT + 5)
        c.send(request(b"/upload", b"POST", b"Content-Length: 100000\r\n") + b"x" * 20000)
        t1 = time.time()
        r = c.response()
        took = time.time() - t1
        if r.status != 408 or not c.closed() or not BODY_TIMEOUT - 1 < took < BODY_TIMEOUT + 2:
            errors.append(f"slow body: {r.status} after {took:.1f} s")

    def steady():
        # A slow client that finishes a request every 3 s is never cut off.
        c = Conn(port)
        for _ in range(5):
            c.send(request(b"/plaintext"))
            if c.response().status != 200:
                errors.append("steady client refused")
            time.sleep(3)

    def no_reader():
        # Pipelines without reading. The server stops reading once its
        # buffers and the socket's are full, and closes it after the write
        # timeout.
        c = Conn(port, timeout=WRITE_TIMEOUT + 5)
        sent = 0
        try:
            while time.time() - t0 < WRITE_TIMEOUT + 4:
                sent += c.sock.send(request(b"/plaintext") * 1000)
            errors.append(f"no-reader still open after {sent} bytes")
        except (socket.timeout, TimeoutError):
            errors.append(f"no-reader still open after {sent} bytes")
        except (BrokenPipeError, ConnectionResetError):
            pass

    def counted(f):
        # A client that dies before its checks is a failure too.
        def run():
            try:
                f()
            except (Exception, SystemExit) as e:
                errors.append(f"{f.__name__}: {e!r}")
        return run

    threads = [threading.Thread(target=counted(f)) for f in (slowloris, silent, slow_body, steady, no_reader)]
    for t in threads:
        t.start()
    # Others are served meanwhile.
    time.sleep(1)
    c = Conn(port)
    c.send(request(b"/json"))
    if c.response().status != 200:
        fail("a client during the slow ones")
    for t in threads:
        t.join()
    if errors:
        fail("; ".join(errors))
    print("slow: ok")


def stop(port, pid):
    """SIGTERM: the server closes its listener and its idle connections,
    answers a request in progress with Connection: close, finishes a response
    in progress, and then exits, which test-http.sh checks."""
    graceful_stop(port, lambda: os.kill(pid, signal.SIGTERM))


def stop_break(port, server):
    """stop's checks on Windows, by Ctrl+Break. It reaches only the processes
    of a console process group, so the client starts the server in its own,
    and checks the exit status itself: 0, where the console's default handler
    would give 0xC000013A."""
    p = subprocess.Popen([server, "http", str(port)], creationflags=subprocess.CREATE_NEW_PROCESS_GROUP)
    try:
        for _ in range(100):
            try:
                socket.create_connection((HOST, port), 1).close()
                break
            except OSError:
                time.sleep(0.1)
        else:
            fail("the server isn't listening after 10 s")
        graceful_stop(port, lambda: os.kill(p.pid, signal.CTRL_BREAK_EVENT))
        try:
            status = p.wait(5)
        except subprocess.TimeoutExpired:
            fail("the server was still running 5 s after its connections closed")
        if status != 0:
            fail(f"the server exited with status {status:#x} after the stop")
    finally:
        if p.poll() is None:
            p.kill()


def graceful_stop(port, send):
    idle = Conn(port)
    partial = Conn(port)
    partial.send(b"GET /plaintext HTTP/1.1\r\nHost: x\r\n")
    big = Conn(port, timeout=30, rcvbuf=4096)
    big.send(request(b"/stream?n=20000000"))
    # An idle h2c connection, where the server serves h2c on port + 2 (the
    # epoll loop's default), which the stop sends a GOAWAY and closes.
    ports = [port]
    h2 = None
    try:
        h2 = socket.create_connection((HOST, port + 2), 1)
        ports.append(port + 2)
        h2.sendall(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" + bytes([0, 0, 0, 4, 0, 0, 0, 0, 0]))
    except OSError:
        pass
    # An idle TLS connection, where the server serves TLS on port + 1 (TLS_PORT's
    # default), which the stop closes with close_notify.
    secure = None
    try:
        sock = socket.create_connection((HOST, port + 1), 1)
        secure = tls_context().wrap_socket(sock, suppress_ragged_eofs=False)
        ports.append(port + 1)
    except OSError:
        pass
    # Long enough for the server to accept them, and to fill big's socket.
    time.sleep(0.5)
    send()
    t0 = time.time()
    if not idle.closed():
        fail("an idle connection stayed open after the stop")
    # Each loop's waker ends its wait at the stop (http::stop).
    if time.time() - t0 > 0.5:
        fail(f"the idle connection closed {time.time() - t0:.2f} s after the stop")
    if h2 is not None:
        got = b""
        h2.settimeout(2)
        try:
            while True:
                b = h2.recv(65536)
                if not b:
                    break
                got += b
        except OSError:
            fail("an idle h2c connection stayed open after the stop")
        # The frames: 9 bytes of head each, type at 3; GOAWAY is type 7, its
        # error code the payload's second word.
        goaway = False
        at = 0
        while at + 9 <= len(got):
            n = int.from_bytes(got[at:at + 3], "big")
            if got[at + 3] == 7 and got[at + 13:at + 17] == b"\0\0\0\0":
                goaway = True
            at += 9 + n
        if not goaway:
            fail("an idle h2c connection closed at the stop without a GOAWAY of NO_ERROR")
        h2.close()
    if secure is not None:
        secure.settimeout(2)
        try:
            if secure.recv(1) != b"":
                fail("an idle TLS connection got bytes at the stop")
        except ssl.SSLEOFError:
            fail("an idle TLS connection closed at the stop without close_notify")
        except OSError:
            fail("an idle TLS connection stayed open after the stop")
        secure.close()
    # Every worker's listeners close within a second or so. Windows refuses a
    # connection to a closed port only after retrying for about 2 s, so a
    # timeout counts as refused, and on Linux a connection queued on a
    # listener as it closes is reset.
    for p in ports:
        while True:
            try:
                socket.create_connection((HOST, p), 1).close()
            except (ConnectionRefusedError, ConnectionResetError, TimeoutError):
                break
            if time.time() - t0 > 3:
                fail(f"the server still accepts on port {p} 3 s after the stop")
            time.sleep(0.1)
    partial.send(b"\r\n")
    r = partial.response()
    if r.status != 200 or r.header("connection") != "close" or not partial.closed():
        fail("a request in progress at the stop wasn't answered and closed")
    r = big.response()
    if r.status != 200 or r.body != digits(20000000) or not big.closed():
        fail("a response in progress at the stop didn't finish")
    print("stop: ok")


def tls_checks(port):
    """HTTP/1.1 over TLS, on the port the server serves it on: TLS 1.3 with
    ALPN http/1.1; tfb, pipeline, large, keepalive, and websocket over it, each close
    after Connection: close with close_notify; a client that offers TLS 1.2
    alone, refused with an alert; and plaintext sent to the port, closed
    unanswered. Not stream, whose threads send and receive on one connection
    at once, which Python's TLS sockets don't take; test-http.sh echoes a
    large body through curl instead."""
    global TLS
    TLS = True
    c = Conn(port)
    if c.sock.version() != "TLSv1.3" or c.sock.selected_alpn_protocol() != "http/1.1":
        fail(f"tls: {c.sock.version()} with ALPN {c.sock.selected_alpn_protocol()}")
    c.close()
    for check in (tfb, pipeline, large, keepalive, websocket):
        check(port)
    TLS = False
    sock = socket.create_connection((HOST, port), 5)
    try:
        tls_context(version=ssl.TLSVersion.TLSv1_2).wrap_socket(sock)
        fail("tls: a TLS 1.2 client was served")
    except ssl.SSLError as e:
        if "PROTOCOL_VERSION" not in str(e).upper():
            fail(f"tls: a TLS 1.2 client was refused with {e}, not protocol_version")
    sock.close()
    sock = socket.create_connection((HOST, port), 5)
    sock.sendall(request(b"/plaintext"))
    got = b""
    try:
        while chunk := sock.recv(65536):
            got += chunk
    except ConnectionResetError:
        pass
    if got.startswith(b"HTTP"):
        fail("tls: plaintext on the TLS port was answered")
    sock.close()
    print("tls: ok")


def client_hello():
    """A ClientHello, as Python's TLS client makes one."""
    incoming, outgoing = ssl.MemoryBIO(), ssl.MemoryBIO()
    c = tls_context().wrap_bio(incoming, outgoing)
    try:
        c.do_handshake()
    except ssl.SSLWantReadError:
        pass
    return outgoing.read()


def tls_slow(port):
    """Handshakes that stall, against a server with REQUEST_MS: a ClientHello
    cut short, and a whole one followed by nothing. The server closes each
    within request_ms of the accept, and serves the next client meanwhile."""
    hello = client_hello()
    for name, data in (("a ClientHello cut short", hello[:20]), ("a handshake without Finished", hello)):
        sock = socket.create_connection((HOST, port), 5)
        t0 = time.time()
        sock.sendall(data)
        sock.settimeout(REQUEST_TIMEOUT + 3)
        global TLS
        TLS = True
        c = Conn(port)
        c.send(request(b"/plaintext"))
        if c.response().status != 200:
            fail(f"tls: no answer beside {name}")
        c.close()
        TLS = False
        try:
            while sock.recv(65536):
                pass
        except (socket.timeout, TimeoutError):
            fail(f"tls: {name} stayed open past request_ms")
        except ConnectionResetError:
            pass
        took = time.time() - t0
        if took < REQUEST_TIMEOUT - 0.5 or took > REQUEST_TIMEOUT + 2:
            fail(f"tls: {name} closed after {took:.1f} s, with request_ms {REQUEST_TIMEOUT} s")
        sock.close()
    print("tls slow: ok")


def files(port, root):
    """/files/NAME, the server's static files: whole, by HEAD, conditional, one
    range, larger than the write buffer, pipelined, to a client that leaves
    halfway, after which test-http.sh checks the server holds no file open,
    and precompressed copies by Accept-Encoding."""
    small = b"hello, file\n"
    big = bytes(range(256)) * 20000 + b"end"
    small_gz = gzip.compress(small)
    small_br = b"stands in for brotli"
    os.makedirs(os.path.join(root, "sub"), exist_ok=True)
    for name, data in (("a.txt", small), ("sub/big.bin", big), ("sp ace.html", b"<p>"),
                       ("a.txt.gz", small_gz), ("a.txt.br", small_br), ("sub/big.bin.gz", b"stale")):
        with open(os.path.join(root, name), "wb") as f:
            f.write(data)
    # A copy older than its file, as one left behind when the file changed.
    stale = os.path.join(root, "sub/big.bin.gz")
    then = os.stat(os.path.join(root, "sub/big.bin")).st_mtime - 100
    os.utime(stale, (then, then))

    def get(path, extra=b"", method=b"GET"):
        c = Conn(port, timeout=30)
        c.send(request(path, method, extra))
        r = c.response(head_only=method == b"HEAD")
        c.close()
        return r

    def check(r, status, body, what):
        if r.status != status or (body is not None and r.body != body):
            fail(f"{what}: {r.status} {r.body[:60]!r}, want {status} {(body or b'')[:60]!r}")

    r = get(b"/files/a.txt")
    check(r, 200, small, "/files/a.txt")
    if r.header("content-type") != "text/plain; charset=utf-8" or r.header("accept-ranges") != "bytes":
        fail(f"/files/a.txt's fields: {r.headers}")
    etag, modified = r.header("etag"), r.header("last-modified")
    if not etag.startswith('"') or email.utils.parsedate_to_datetime(modified) is None:
        fail(f"/files/a.txt's ETag {etag} or Last-Modified {modified}")
    r = get(b"/files/a.txt", method=b"HEAD")
    check(r, 200, b"", "HEAD /files/a.txt")
    if r.header("content-length") != str(len(small)):
        fail(f"HEAD /files/a.txt's Content-Length: {r.headers}")
    check(get(b"/files/a.txt", b"If-None-Match: " + etag.encode() + b"\r\n"), 304, b"", "If-None-Match")
    check(get(b"/files/a.txt", b"If-Modified-Since: " + modified.encode() + b"\r\n"), 304, b"",
          "If-Modified-Since")
    check(get(b"/files/a.txt", b'If-None-Match: "other"\r\n'), 200, small, "another If-None-Match")
    check(get(b"/files/sp%20ace.html"), 200, b"<p>", "an escaped name")

    r = get(b"/files/sub/big.bin", b"Range: bytes=100-199\r\n")
    check(r, 206, big[100:200], "a range")
    if r.header("content-range") != f"bytes 100-199/{len(big)}":
        fail(f"a range's Content-Range: {r.headers}")
    check(get(b"/files/sub/big.bin", b"Range: bytes=-3\r\n"), 206, b"end", "a suffix range")
    r = get(b"/files/sub/big.bin", b"Range: bytes=%d-\r\n" % len(big))
    check(r, 416, b"", "a range past the end")
    if r.header("content-range") != f"bytes */{len(big)}":
        fail(f"416's Content-Range: {r.headers}")

    for path, status in ((b"/files/missing", 404), (b"/files/sub", 404), (b"/files/../a.txt", 404),
                         (b"/files/sub/%2e%2e/a.txt", 404), (b"/files/a.txt%00", 404)):
        check(get(path), status, None, path.decode())
    check(get(b"/files/a.txt", method=b"POST"), 405, None, "POST /files/a.txt")

    # Larger than the write buffer, twice pipelined on one connection.
    c = Conn(port, timeout=30)
    c.send(request(b"/files/sub/big.bin") * 2 + request(b"/files/a.txt"))
    for want in (big, big, small):
        check(c.response(), 200, want, "pipelined /files/")
    c.close()

    # A client that leaves with most of a response unread.
    for _ in range(4):
        c = Conn(port, rcvbuf=4096)
        c.send(request(b"/files/sub/big.bin"))
        c.sock.recv(1000)
        c.close()
    check(get(b"/files/a.txt"), 200, small, "/files/ after clients left")

    def coded(r):
        return [v for n, v in r.headers if n == "content-encoding"]

    r = get(b"/files/a.txt")
    if coded(r) or r.header("vary") != "Accept-Encoding":
        fail(f"/files/a.txt without Accept-Encoding: {r.headers}")
    r = get(b"/files/a.txt", b"Accept-Encoding: gzip, deflate\r\n")
    check(r, 200, small_gz, "a gzip copy")
    if gzip.decompress(r.body) != small or coded(r) != ["gzip"] or r.header("vary") != "Accept-Encoding":
        fail(f"a gzip copy's fields: {r.headers}")
    if r.header("content-type") != "text/plain; charset=utf-8":
        fail(f"a gzip copy's Content-Type: {r.headers}")
    gz_tag = r.header("etag")
    if gz_tag == etag or not gz_tag.endswith('-gzip"'):
        fail(f"a gzip copy's ETag {gz_tag}, the file's {etag}")
    r = get(b"/files/a.txt", b"Accept-Encoding: br;q=1, gzip;q=0.8\r\n")
    check(r, 200, small_br, "a br copy")
    if coded(r) != ["br"]:
        fail(f"a br copy's fields: {r.headers}")
    r = get(b"/files/a.txt", b"Accept-Encoding: br;q=0, gzip\r\nRange: bytes=0-1\r\n")
    check(r, 206, b"\x1f\x8b", "a range of a gzip copy")
    if r.header("content-range") != f"bytes 0-1/{len(small_gz)}":
        fail(f"a range of a gzip copy's Content-Range: {r.headers}")
    r = get(b"/files/a.txt", b"Accept-Encoding: gzip\r\nIf-None-Match: " + gz_tag.encode() + b"\r\n")
    check(r, 304, b"", "If-None-Match with a gzip copy's ETag")
    if r.header("vary") != "Accept-Encoding":
        fail(f"304 for a gzip copy: {r.headers}")
    check(get(b"/files/a.txt", b"Accept-Encoding: gzip\r\nIf-None-Match: " + etag.encode() + b"\r\n"), 200,
          small_gz, "If-None-Match with the file's ETag, for a gzip copy")
    check(get(b"/files/a.txt", b"Accept-Encoding: zstd, identity\r\n"), 200, small, "no copy taken")
    r = get(b"/files/sub/big.bin", b"Accept-Encoding: gzip\r\n")
    check(r, 200, big, "a copy older than its file")
    if coded(r):
        fail(f"a copy older than its file was sent: {r.headers}")
    print("files: ok")


def emfile(port, n):
    """For a server with a low fd limit: n clients, more than it can hold.
    Those past the limit wait in the listen backlog until others close."""
    conns = [Conn(port, timeout=1) for _ in range(n)]
    for c in conns:
        c.send(request(b"/plaintext"))
    served = 0
    try:
        for c in conns:
            c.response()
            served += 1
    except (socket.timeout, TimeoutError):
        pass
    if not 0 < served < n:
        fail(f"{served} of {n} served before any closed")
    for c in conns[:served]:
        c.close()
    for c in conns[served:]:
        c.sock.settimeout(5)
        if c.response().status != 200:
            fail("a client from the backlog")
        c.close()
    print(f"emfile: {served} served at the fd limit, then the other {n - served}")


def many(port, n):
    async def client(i):
        reader, writer = await asyncio.open_connection(HOST, port)
        path = b"/json" if i % 2 else b"/plaintext"
        writer.write(request(path) * 4)
        await writer.drain()
        for _ in range(4):
            head = await reader.readuntil(b"\r\n\r\n")
            # The reason phrase means nothing (RFC 9112 §4), and servers differ in it.
            if head.split(b" ", 2)[:2] != [b"HTTP/1.1", b"200"]:
                fail(f"client {i}: {head[:40]!r}")
            length = [l for l in head.split(b"\r\n") if l.lower().startswith(b"content-length:")]
            await reader.readexactly(int(length[0].split(b":")[1]))
        return writer

    async def run():
        # All connections open at once before any closes.
        writers = await asyncio.gather(*(client(i) for i in range(n)))
        for w in writers:
            w.close()

    asyncio.run(run())
    print(f"many: {n} connections ok")


def requests(port):
    """Against a server started with MAX_REQUESTS=3: a connection's third response
    closes it, pipelined or not, and HTTP/1.0 keep-alive counts the same."""
    c = Conn(port)
    c.send(request(b"/plaintext") * 5)
    for i in range(3):
        r = c.response()
        closing = [v for n, v in r.headers if n == "connection"] == ["close"]
        if r.status != 200 or closing != (i == 2):
            fail(f"pipelined request {i + 1} of a cap of 3: {r.headers}")
    if not c.closed():
        fail("the connection stayed open past its third request")
    c = Conn(port)
    for i in range(3):
        c.send(b"GET /json HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")
        r = c.response()
        want = "close" if i == 2 else "keep-alive"
        if r.status != 200 or r.header("connection") != want:
            fail(f"HTTP/1.0 request {i + 1} of a cap of 3: {r.headers}")
    if not c.closed():
        fail("the HTTP/1.0 connection stayed open past its third request")
    print("requests: ok")


def client(port):
    """/client: the peer's address and port are the connection's, and the
    client is the nearest untrusted hop a loopback proxy forwarded for."""
    c = Conn(port)
    own = c.sock.getsockname()
    cases = [
        (b"", HOST),
        (b"X-Forwarded-For: 198.51.100.1, 203.0.113.5\r\n", "203.0.113.5"),
        (b"X-Forwarded-For: 203.0.113.5, 127.0.0.2\r\n", "203.0.113.5"),
        (b'Forwarded: for="[2001:db8::1]:4711";proto=https\r\n', "2001:db8::1"),
        (b"X-Forwarded-For: junk\r\n", HOST),
    ]
    for extra, want in cases:
        c.send(request(b"/client", extra=extra))
        r = c.response()
        if r.status != 200 or r.body != f"peer {own[0]} {own[1]}\nclient {want}\n".encode():
            fail(f"/client with {extra!r}: {r.status} {r.body!r}")
    c.close()
    print("client: ok")


def max_conns(port, n):
    """Against one worker started with MAX_CONNS=n: n connections are served,
    the next waits in the backlog unanswered, and is served once one of the n
    closes."""
    held = [Conn(port) for _ in range(n)]
    for c in held:
        c.send(request(b"/plaintext"))
        if c.response().status != 200:
            fail("a connection within max_conns wasn't served")
    extra = Conn(port, timeout=1)
    extra.send(request(b"/plaintext"))
    try:
        extra.response()
        fail(f"connection {n + 1} was served past max_conns={n}")
    except (socket.timeout, TimeoutError):
        pass
    held.pop().close()
    extra.sock.settimeout(5)
    if extra.response().status != 200:
        fail("the waiting connection wasn't served after one closed")
    for c in held + [extra]:
        c.close()
    print("max-conns: ok")


def later(port):
    """Against a server started with MAIL_SLOTS: /later's answer comes from
    the backend thread after its delay, and 504 when the time limit passes
    first, after which the backend's late reply is dropped; requests pipelined
    behind a waiting one wait for it, in order; a reply to a connection that
    closed while it waited doesn't reach the next connection in its slot;
    /events sends its events as they come, or ends at its time limit; and an
    upgraded connection keeps echoing while it waits."""
    def timed(c, path):
        t0 = time.time()
        c.send(request(path))
        r = c.response()
        return r, time.time() - t0

    c = Conn(port)
    r, took = timed(c, b"/later?id=a&delay=200")
    if r.status != 200 or r.body != b"a 1" or not 0.19 <= took < 1:
        fail(f"/later: {r.status} {r.body!r} after {took:.2f} s")

    for _ in range(20):
        r, _ = timed(c, b"/later?id=now&delay=0")
        if r.status != 200 or r.body != b"now 1":
            fail(f"an immediate reply was rejected: {r.status} {r.body!r}")

    # The time limit, then the late reply dropped: the next request on the
    # connection gets its own answer.
    r, took = timed(c, b"/later?id=expired&delay=500&ms=100")
    if r.status != 504 or not 0.09 <= took < 0.45:
        fail(f"/later past its limit: {r.status} {r.body!r} after {took:.2f} s")
    time.sleep(0.6)
    r, _ = timed(c, b"/plaintext")
    if r.status != 200 or r.body != b"Hello, World!":
        fail(f"after a timeout and a late reply: {r.status} {r.body!r}")

    # Pipelined behind a waiting exchange, answered in order after it.
    t0 = time.time()
    c.send(request(b"/later?id=p&delay=300") + request(b"/plaintext") + request(b"/later?id=q&delay=50"))
    bodies = []
    for _ in range(3):
        bodies.append(c.response().body)
        if len(bodies) == 2 and time.time() - t0 < 0.29:
            fail(f"a request pipelined behind a waiting one was answered after {time.time() - t0:.2f} s")
    if bodies != [b"p 1", b"Hello, World!", b"q 1"]:
        fail(f"pipelined behind a waiting exchange: {bodies}")
    c.close()

    # A stale reply: a's connection closes while it waits, and eight others,
    # one likely in its worker and slot, wait across the time a's reply comes.
    a = Conn(port)
    a.send(request(b"/later?id=gone&delay=300"))
    time.sleep(0.05)
    a.close()
    time.sleep(0.05)
    others = [Conn(port) for _ in range(8)]
    for i, b in enumerate(others):
        b.send(request(b"/later?id=b%d&delay=500" % i))
    for i, b in enumerate(others):
        r = b.response()
        if r.status != 200 or r.body != b"b%d 1" % i:
            fail(f"a stale reply reached another connection: {r.status} {r.body!r}")
        b.close()

    # Server-Sent Events, and their time limit.
    c = Conn(port)
    r, took = timed(c, b"/events?id=e&delay=50&n=5")
    want = b"".join(b"data: e %d\n\n" % i for i in range(1, 6))
    if r.status != 200 or r.header("content-type") != "text/event-stream" or r.body != want or took < 0.24:
        fail(f"/events: {r.status} {r.body!r} after {took:.2f} s")
    r, took = timed(c, b"/events?id=s&delay=300&n=2&ms=100")
    if r.status != 200 or r.body != b": timeout\n\n" or took > 0.45:
        fail(f"/events past its limit: {r.status} {r.body!r} after {took:.2f} s")

    # Pieces sent back to back, which the backend retries while the box is
    # full: every one arrives, none finding the exchange stale between WAKEs.
    for _ in range(5):
        r, _ = timed(c, b"/events?id=burst&delay=0&n=500&ms=2000")
        want = b"".join(b"data: burst %d\n\n" % i for i in range(1, 501))
        if r.status != 200 or r.body != want:
            fail(f"/events in a burst: {r.status}, {r.body.count(b'data:')} of 500 events")

    # Compressed, each event arrives whole: its chunk decompresses to it alone.
    c.send(request(b"/events?id=z&delay=50&n=3", extra=b"Accept-Encoding: gzip\r\n"))
    r = c.head()
    if r.header("content-encoding") != "gzip" or r.header("vary") != "Accept-Encoding":
        fail(f"/events compressed: {r.headers}")
    d = zlib.decompressobj(wbits=31)
    for i in range(1, 4):
        got = d.decompress(c.chunk())
        if got != b"data: z %d\n\n" % i:
            fail(f"/events compressed: event {i} came as {got!r}")
    rest = b""
    while piece := c.chunk():
        rest += d.decompress(piece)
    c.line()
    if rest or not d.eof:
        fail(f"/events compressed: {rest!r} after the events, eof {d.eof}")
    c.close()

    # An upgraded connection that waits for the backend still echoes what
    # comes meanwhile; the reply comes among the echoes, or "timeout" at its
    # limit, and echoing goes on after either.
    def upgraded(query):
        c = Conn(port)
        t0 = time.time()
        c.send(b"GET /upgrade?" + query + b" HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\n"
               b"Upgrade: echo\r\n\r\nping")
        r = c.response()
        if r.status != 101 or c.take(4) != b"ping":
            fail(f"/upgrade?{query.decode()}: {r.status} {r.headers}")
        return c, t0

    c, t0 = upgraded(b"id=u&delay=400")
    c.send(b"pong")
    if c.take(4) != b"pong" or time.time() - t0 >= 0.35:
        fail(f"an upgraded connection's bytes were echoed only after {time.time() - t0:.2f} s, "
             "behind the reply it waited for")
    got = c.take(3)
    if got != b"u 1" or time.time() - t0 < 0.39:
        fail(f"an upgraded connection's reply: {got!r} after {time.time() - t0:.2f} s")
    c.send(b"after")
    if c.take(5) != b"after":
        fail("an upgraded connection stopped echoing after its reply")
    c.close()
    c, t0 = upgraded(b"id=expired&delay=500&ms=100")
    c.send(b"pong")
    got = c.take(11)
    if got != b"pongtimeout" or not 0.09 <= time.time() - t0 < 0.45:
        fail(f"an upgraded connection past its limit: {got!r} after {time.time() - t0:.2f} s")
    c.send(b"after")
    if c.take(5) != b"after":
        fail("an upgraded connection stopped echoing after its timeout")
    c.close()
    # Closed while it waits: the reply finds the exchange gone (STALE).
    c, _ = upgraded(b"id=gone&delay=300")
    c.close()
    time.sleep(0.4)
    print("later: ok")


def write_dataset(path):
    """A dataset of HttpArena's shape, 50 items, for /json/{count}."""
    names = ["Alpha Widget", "Pro Valve", "Core Relay", "Quantum \"Gear\"", "Mini Pump"]
    items = []
    for i in range(1, 51):
        items.append({
            "id": i, "name": names[i % len(names)] + " " + str(i), "category": ["tools", "electronics"][i % 2],
            "price": 17 * i % 500 + 1, "quantity": 31 * i % 100, "active": i % 3 != 0,
            "tags": ["sale", "new", "heavy-duty", "wireless"][:i % 5],
            "rating": {"score": i % 50, "count": 7 * i},
        })
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(items, f, indent=2)


def decode(coding, body):
    if coding == "gzip":
        return gzip.decompress(body)
    if coding == "deflate":
        return zlib.decompress(body)
    if coding == "zstd":
        return zstd.decompress(body)
    fail(f"Content-Encoding {coding}")


def compress(port, dataset):
    """/json/{count}?m=, HttpArena's json-comp, and /zstream, against a server
    started with DATASET: each coding decompresses to the right items, what
    is left alone is, and a stream's pieces each decompress as they come."""
    with open(dataset, encoding="utf-8") as f:
        source = json.load(f)

    def check_items(body, n, m):
        d = json.loads(body)
        want = [dict(it, total=it["price"] * it["quantity"] * m) for it in source[:n]]
        if d != {"items": want, "count": n}:
            fail(f"/json/{n}?m={m}: {body[:200]!r}")

    codings = [("gzip, br", "gzip"), ("deflate", "deflate"), ("gzip;q=0.5, deflate", "deflate"),
               ("br", None), ("identity", None)]
    if zstd:
        codings += [("gzip, deflate, br, zstd", "zstd")]
    else:
        print("compress: no zstd module in this Python; zstd responses not checked")
    c = Conn(port)
    for accept, want in codings:
        c.send(request(b"/json/50?m=3", extra=b"Accept-Encoding: " + accept.encode() + b"\r\n"))
        r = c.response()
        names = [n for n, _ in r.headers]
        coding = r.header("content-encoding") if "content-encoding" in names else None
        if r.status != 200 or coding != want or r.header("vary") != "Accept-Encoding":
            fail(f"/json/50 with Accept-Encoding: {accept}: {r.status} {r.headers}")
        check_items(decode(coding, r.body) if coding else r.body, 50, 3)
        if coding and len(r.body) * 3 > len(decode(coding, r.body)):
            fail(f"{coding}: {len(r.body)} bytes compressed")

    # Without Accept-Encoding, a short body, HEAD, and no m.
    c.send(request(b"/json/50?m=2"))
    r = c.response()
    if "content-encoding" in [n for n, _ in r.headers] or r.header("content-type") != "application/json":
        fail(f"/json/50 without Accept-Encoding: {r.headers}")
    check_items(r.body, 50, 2)
    plain = len(r.body)
    c.send(request(b"/json/1?m=5", extra=b"Accept-Encoding: gzip\r\n"))
    r = c.response()
    if "content-encoding" in [n for n, _ in r.headers]:
        fail(f"/json/1 compressed: {r.headers}")
    check_items(r.body, 1, 5)
    c.send(request(b"/json/50?m=2", b"HEAD", b"Accept-Encoding: gzip\r\n"))
    r = c.response(head_only=True)
    if "content-encoding" in [n for n, _ in r.headers] or int(r.header("content-length")) != plain:
        fail(f"HEAD /json/50: {r.headers}")
    c.send(request(b"/json/7", extra=b"Accept-Encoding: gzip\r\n"))
    check_items(gzip.decompress(c.response().body), 7, 1)
    for bad in (b"/json/0", b"/json/51", b"/json/x"):
        c.send(request(bad))
        if c.response().status != 400:
            fail(f"{bad!r} wasn't refused")

    # Pipelined, each compressed whole.
    c.send(b"".join(request(b"/json/%d?m=%d" % (n, n), extra=b"Accept-Encoding: gzip\r\n") for n in range(10, 51, 10)))
    for n in range(10, 51, 10):
        check_items(gzip.decompress(c.response().body), n, n)

    # A stream: each piece the server sends decompresses as it comes, and
    # the whole to /stream's digits.
    for accept, coding in (("gzip", "gzip"), ("deflate", "deflate")) + ((("zstd", "zstd"),) if zstd else ()):
        n = 3 * 16384 + 100
        c.send(request(b"/zstream?n=%d" % n, extra=b"Accept-Encoding: " + accept.encode() + b"\r\n"))
        r = c.head()
        if r.header("content-encoding") != coding or r.header("transfer-encoding") != "chunked":
            fail(f"/zstream with {accept}: {r.headers}")
        d = {"gzip": lambda: zlib.decompressobj(wbits=31), "deflate": zlib.decompressobj,
             "zstd": lambda: zstd.ZstdDecompressor()}[coding]()
        got = b""
        while piece := c.chunk():
            out = d.decompress(piece)
            if len(out) not in (16384, 100, 0):
                fail(f"/zstream with {accept}: a piece decompressed to {len(out)} bytes")
            got += out
        c.line()
        if got != digits(n):
            fail(f"/zstream with {accept}: {len(got)} bytes, not /stream's {n}")
    c.send(request(b"/zstream?n=10"))
    r = c.response()
    if "content-encoding" in [n for n, _ in r.headers] or r.body != digits(10):
        fail(f"/zstream without Accept-Encoding: {r.headers} {r.body!r}")
    # Connections that leave mid-stream, and a stream after them.
    for _ in range(40):
        k = Conn(port)
        k.send(request(b"/zstream?n=100000000", extra=b"Accept-Encoding: gzip\r\n"))
        k.head()
        k.chunk()
        k.close()
    c.send(request(b"/zstream?n=1000", extra=b"Accept-Encoding: gzip\r\n"))
    if gzip.decompress(c.response().body) != digits(1000):
        fail("/zstream after streams that were cut")
    c.close()
    print("compress: ok")


def listen_where(port, address, v6only):
    """Against a server started with ADDRESS set to address: on "::", IPv6
    and IPv4 clients, or IPv6 only with IPV6_ONLY; on "unix:PATH", clients of
    the Unix socket at PATH. Each gets its answers, pipelined too, and /client
    says who the peer is: the connection's own address, or 500 for a Unix
    socket's peer, which has none."""
    def check(c, peer):
        c.send(request(b"/plaintext") * 3)
        for _ in range(3):
            r = c.response()
            if r.status != 200 or r.body != b"Hello, World!":
                fail(f"listening at {address}: {r.status} {r.body!r}")
        c.send(request(b"/client"))
        r = c.response()
        want = f"peer {peer[0]} {peer[1]}\nclient {peer[0]}\n".encode() if peer else None
        if (r.status, r.body) != ((200, want) if peer else (500, b"")):
            fail(f"/client listening at {address}: {r.status} {r.body!r}")
        c.close()

    if address.startswith("unix:"):
        check(Conn(0, family=socket.AF_UNIX, addr=address[5:]), None)
        print("unix: ok")
        return
    c = Conn(port, family=socket.AF_INET6, addr=("::1", port))
    check(c, c.sock.getsockname()[:2])
    try:
        c = Conn(port)
    except OSError:
        if not v6only:
            fail("a dual-stack listener refused an IPv4 client")
    else:
        if v6only:
            fail("an IPV6_ONLY listener took an IPv4 client")
        check(c, c.sock.getsockname())
    print("v6only: ok" if v6only else "dual-stack: ok")


def later_off(port):
    """Against a server without MAIL_SLOTS: /later can't hand its job on, and
    answers 503 at once; /delay's TIMEOUT comes at once to each connection
    that asks, at REQUEST or on an open response, and to no other, with more
    connections than workers."""
    c = Conn(port)
    c.send(request(b"/later?id=x&delay=100"))
    r = c.response()
    if r.status != 503:
        fail(f"/later without waiting: {r.status} {r.body!r}")
    c.close()

    idle = [Conn(port, timeout=2) for _ in range(8)]
    asking = [Conn(port, timeout=2) for _ in range(24)]
    for k, a in enumerate(asking):
        a.send(request(b"/delay/%d%s" % (1000 + k, b"?open=1" if k % 2 else b"")))
    for k, a in enumerate(asking):
        try:
            r = a.response()
        except socket.timeout:
            fail(f"/delay without waiting: connection {k} got no TIMEOUT")
        if r.status != 200 or r.body != b"%d" % (1000 + k):
            fail(f"/delay without waiting, connection {k}: {r.status} {r.body!r}")
    for k, c in enumerate(idle + asking):
        c.send(request(b"/plaintext"))
        r = c.response()
        if r.status != 200 or r.body != b"Hello, World!":
            fail(f"after /delay without waiting, connection {k}: {r.status} {r.body!r}")
        c.close()
    print("later-off: ok")


def ws_frame(op, payload, fin=True):
    """A client's frame: masked, as RFC 6455 §5.3 requires."""
    n = len(payload)
    head = bytes([(0x80 if fin else 0) | op])
    if n < 126:
        head += bytes([0x80 | n])
    elif n < 65536:
        head += bytes([0x80 | 126]) + n.to_bytes(2, "big")
    else:
        head += bytes([0x80 | 127]) + n.to_bytes(8, "big")
    key = os.urandom(4)
    return head + key + bytes(b ^ key[i & 3] for i, b in enumerate(payload))


def ws_read(c):
    """The server's next frame, which must be unmasked and whole: its opcode
    and payload."""
    b0, b1 = c.take(2)
    if b0 & 0x70 or not b0 & 0x80 or b1 & 0x80:
        fail(f"a server frame's head: {b0:#x} {b1:#x}")
    n = b1 & 0x7F
    if n == 126:
        n = int.from_bytes(c.take(2), "big")
    elif n == 127:
        n = int.from_bytes(c.take(8), "big")
    return b0 & 0x0F, c.take(n)


def ws_open(port, frames=b""):
    """A connection upgraded at /ws, with frames sent along with the request,
    and the accept value checked."""
    key = base64.b64encode(os.urandom(16))
    c = Conn(port)
    c.send(b"GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           b"Sec-WebSocket-Key: " + key + b"\r\nSec-WebSocket-Version: 13\r\n\r\n" + frames)
    r = c.response(head_only=True)
    accept = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest()).decode()
    if r.status != 101 or r.header("sec-websocket-accept") != accept or r.header("upgrade") != "websocket":
        fail(f"/ws upgrade: {r.status} {r.headers}")
    return c


def ws_close(c, code=1000):
    """The close handshake: the server answers with the same code, then closes."""
    c.send(ws_frame(8, code.to_bytes(2, "big")))
    op, payload = ws_read(c)
    if op != 8 or payload != code.to_bytes(2, "big"):
        fail(f"/ws close: {op} {payload!r}")
    if not c.closed():
        fail("/ws: the connection stayed open after the close")
    c.close()


def websocket(port):
    """/ws, an echo, as HttpArena's echo-ws profiles use it: one message at a
    time, 16 back to back, and 10 per connection before a new one upgrades;
    and frames sent with the upgrade, fragments, a ping, a large message, and
    one past the limit.
    RFC 6455's frame rules are tested in test/websocket/, and Autobahn's suite
    by scripts/test-autobahn.sh."""
    c = ws_open(port)
    for i in range(100):
        msg = b"hello %d" % i
        c.send(ws_frame(1, msg))
        if ws_read(c) != (1, msg):
            fail(f"/ws echo of {msg!r}")
    c.send(b"".join(ws_frame(1, b"hello") for _ in range(16)))
    for i in range(16):
        if ws_read(c) != (1, b"hello"):
            fail(f"/ws pipelined, message {i}")
    ws_close(c)

    for n in range(20):
        c = ws_open(port)
        for i in range(10):
            c.send(ws_frame(1, b"hello"))
            if ws_read(c) != (1, b"hello"):
                fail(f"/ws, connection {n}, message {i}")
        ws_close(c)

    c = ws_open(port, ws_frame(1, b"early") + ws_frame(9, b"ping"))
    if ws_read(c) != (1, b"early") or ws_read(c) != (10, b"ping"):
        fail("/ws: frames sent with the upgrade")
    big = os.urandom(60 << 10)
    third = len(big) // 3
    c.send(ws_frame(2, big[:third], fin=False) + ws_frame(0, big[third:2 * third], fin=False) +
           ws_frame(0, big[2 * third:]))
    if ws_read(c) != (2, big):
        fail("/ws: a fragmented 60 KiB message")
    ws_close(c, 4000)

    # Past /ws's limit, 64 KiB by default (WS_LIMIT): a Close with 1009 from
    # the frame's head alone.
    c = ws_open(port)
    c.send(ws_frame(2, os.urandom(65 << 10))[:14])
    if ws_read(c) != (8, (1009).to_bytes(2, "big")):
        fail("/ws: a message past the limit")
    c.close()

    c = Conn(port)
    c.send(request(b"/ws"))
    r = c.response()
    if r.status != 426 or r.header("upgrade") != "websocket":
        fail(f"/ws without Upgrade: {r.status} {r.headers}")
    c.close()
    print("websocket: ok")


def raw_exchange(port, data, pause=0.0):
    """Sends data, its first byte alone first when pause is set, on a new
    connection, and returns every byte back until the server closes."""
    sock = socket.create_connection((HOST, port), 5)
    if pause:
        sock.sendall(data[:1])
        time.sleep(pause)
        data = data[1:]
    sock.sendall(data)
    got = bytearray()
    while chunk := sock.recv(65536):
        got += chunk
    sock.close()
    return bytes(got)


def access_log(port, path):
    """Against a server started with ACCESS_LOG: a line for each response,
    with its status, its bytes as the client got them, and its time from the
    head's first byte, whole at REQUEST or after it."""
    close = b"Connection: close\r\n"
    upload = b"x" * 100000
    cases = [
        (request(b"/plaintext", extra=close), 0.0, 200, "/plaintext"),
        (request(b"/nowhere", extra=close), 0.0, 404, "/nowhere"),
        (request(b"/bytes?n=300000", extra=close), 0.0, 200, "-"),
        (request(b"/upload", b"POST", close + b"Content-Length: %d\r\n" % len(upload)) + upload,
         0.0, 200, "-"),
        (request(b"/plaintext", extra=close), 0.3, 200, "/plaintext"),
    ]
    want = []
    for data, pause, status, target in cases:
        got = raw_exchange(port, data, pause)
        if not got.startswith(b"HTTP/1.1 %d " % status):
            fail(f"access log: {got[:40]!r} for {data[:30]!r}")
        want.append((status, len(got), pause, target))
    deadline = time.time() + 5
    while True:
        with open(path) as f:
            lines = [l.split() for l in f if l.startswith(HOST + " ")]
        if len(lines) >= len(want) or time.time() > deadline:
            break
        time.sleep(0.1)
    if len(lines) != len(want):
        fail(f"access log: {len(lines)} lines for {len(want)} responses")
    for line, (status, sent, pause, target) in zip(lines, want):
        _, s, n, ms, t = line
        if int(s) != status or int(n) != sent or t != target or not pause * 1000 - 20 <= int(ms) < 1000 * pause + 1000:
            fail(f"access log: {line}, want {status} {sent} {target} after {pause} s")
    print("access log: ok")


def main():
    port = int(sys.argv[1])
    mode = sys.argv[2]
    if mode in ("many", "emfile", "stop", "max-conns"):
        {"many": many, "emfile": emfile, "stop": stop, "max-conns": max_conns}[mode](port, int(sys.argv[3]))
    elif mode == "files":
        files(port, sys.argv[3])
    elif mode == "dataset":
        write_dataset(sys.argv[3])
    elif mode == "compress":
        compress(port, sys.argv[3])
    elif mode == "log":
        access_log(port, sys.argv[3])
    elif mode == "listen":
        listen_where(port, sys.argv[3], len(sys.argv) > 4 and sys.argv[4] == "v6only")
    elif mode == "stop-break":
        stop_break(port, sys.argv[3])
    else:
        {"tfb": tfb, "pipeline": pipeline, "large": large, "chunked": chunked, "keepalive": keepalive,
         "hostile": hostile, "slow": slow, "stream": stream, "requests": requests,
         "client": client, "later": later, "later-off": later_off, "forms": forms,
         "tls": tls_checks, "tls-slow": tls_slow, "websocket": websocket}[mode](port)


if __name__ == "__main__":
    main()
