// Outbound connections on serve_epoll's loop and serve's (socket.goose): each
// route connects to a backend thread in the program, waits with wait_socket,
// and answers with what came back: a round trip, a large send, a backend that
// closes, a refused connect, a connect that times out against a full backlog,
// and a socket hung up at TIMEOUT, which the backend must see closed before
// it takes the next connection. On io_uring, a socket that becomes readable
// after its wait timed out doesn't wake the exchange's next wait. Over h2c, a
// stream reset while it waits, and one whose handler answers in the call that
// waited, each hang up a socket that the backend must see closed, as at
// TIMEOUT. On the emulated ring, wait_socket fails with ENOSYS. The loops
// listen on Unix sockets in the TMPDIR test/run_tests.py gives each run, so
// parallel runs share no port.
import std;
import os;
import http from "../../";
import http.hpack;
import http.h2frame;

// A Unix socket's address in TMPDIR, or in the working directory without it.
// A Unix socket can't be made on every filesystem, such as WSL's /mnt/c.
fn unix_address(name: const u8[:]) -> u8[>..] {
    var dir: u8[>..] = [];
    var a: u8[>..] = [];
    if env("TMPDIR", dir) && dir.len > 0 { format(a, "unix:", dir, "/", name); }
    else { format(a, "unix:", name); }
    return a;
}

let LARGE = 4 << 20;

// Where the loops listen, and the ports a route connects to: the backend, one
// nothing listens on, and one whose backlog is full.
struct Ports { backend: i32, refused: i32, full: i32 }

fn listener(backlog: i32) -> i32, i32 {
    let a, ok = http::address("127.0.0.1");
    assert(ok);
    let fd = http::net_listen(a.ip, 0, backlog, 0);
    assert(fd >= 0);
    return fd, http::net_port(fd);
}

fn send_text(fd: i32, text: const u8[:]) {
    var at = 0;
    while at < text.len {
        let n = http::net_send(fd, text[at..]);
        assert(n > 0);
        at += n;
    }
}

// The backend, blocking, one connection after another, by the first byte
// each sends: p answers pong to each p, c counts the bytes until the client
// shuts its side and answers the count, w reads until the client closes and
// answers nothing, x closes at once, and q ends.
thread_fn backend(lfd: i32) {
    var buf: u8[>..] = [];
    buf.resize(65536, 0);
    loop {
        let fd = http::net_accept(lfd, 0);
        assert(fd >= 0);
        var quit = false;
        var counting = false;
        var count = 0;
        loop {
            let n = http::net_recv(fd, buf);
            if n <= 0 { break; }
            if counting {
                count += n;
                continue;
            }
            let cmd = buf[0];
            if cmd == 'q' { quit = true; break; }
            if cmd == 'x' { break; }
            if cmd == 'p' {
                for i in n { send_text(fd, "pong"); }
            } else if cmd == 'c' {
                counting = true;
                count = n;
            } else if cmd == 'w' {
                while http::net_recv(fd, buf) > 0 {}
                break;
            }
        }
        if counting {
            var text: u8[>..] = [];
            format(text, count);
            send_text(fd, text);
        }
        http::net_close(fd);
        if quit { break; }
    }
    http::net_close(lfd);
}

let PING: u8 = 1;
let LARGE_SEND: u8 = 2;
let CLOSES: u8 = 3;
let HANGUP: u8 = 4;
let STALE: u8 = 5;
let RESET: u8 = 6;
let ANSWERED: u8 = 7;

// A request's state: its backend socket, what it's doing, and what it got.
struct St {
    s: http::Socket = http::Socket { .. },
    route: u8 = 0,
    connecting: bool = false,
    timed_out: bool = false,
    sent: i64 = 0,
    got: u8[..32] = [],
}

fn answer(st: St&, out: http::Reply, status: i32, body: const u8[:]) {
    http::hangup(st.s);
    http::respond(out, status, "text/plain", body);
}

fn failed(st: St&, out: http::Reply, e: http::Error) {
    var text: u8[>..] = [];
    format(text, e.call, " ");
    if e.code == http::ECONNREFUSED { text.append("refused"); }
    else if e.code == http::ENOSYS { text.append("ENOSYS"); }
    else { format(text, e.code); }
    answer(st, out, 502, text);
}

fn handle(ev: http::Event, st: St&, out: http::Reply, ports: Ports, large: const u8[:]) {
    if ev.kind == http::REQUEST {
        let path = http::path_of(ev.req.target);
        var port = ports.backend;
        if path == "/ping" { st.route = PING; }
        else if path == "/large" { st.route = LARGE_SEND; }
        else if path == "/closes" { st.route = CLOSES; }
        else if path == "/hangup" { st.route = HANGUP; }
        else if path == "/stale" { st.route = STALE; }
        else if path == "/reset" { st.route = RESET; }
        else if path == "/answered" { st.route = ANSWERED; }
        else if path == "/refused" { st.route = PING; port = ports.refused; }
        else if path == "/timeout" { st.route = PING; port = ports.full; }
        else { http::respond(out, 404, "text/plain", ""); return; }
        let s, e = http::connect_start("127.0.0.1", port);
        // A refused connect may fail at once.
        guard e.code == 0 else { failed(st, out, e); return; }
        st.s = s;
        st.connecting = true;
        let w = http::wait_socket(out, st.s, http::WRITABLE, 300);
        guard w.code == 0 else { failed(st, out, w); return; }
        return;
    }
    if ev.kind == http::CLOSED {
        http::hangup(st.s);
        return;
    }
    if ev.kind == http::TIMEOUT {
        if st.route == HANGUP && !st.connecting {
            answer(st, out, 200, "hung up");
            return;
        }
        if st.route == STALE && !st.connecting && !st.timed_out {
            // The backend answers once this side shuts, while the exchange
            // waits for something else.
            st.timed_out = true;
            http::net_shutdown(st.s.fd, http::SHUT_WR);
            http::later(out, 200);
            return;
        }
        answer(st, out, if st.timed_out { 200 } else { 504 },
               if st.timed_out { "no stale wake" } else if st.connecting { "connect timed out" } else { "timed out" });
        return;
    }
    guard ev.kind == http::WAKE && ev.tag == http::SOCKET_READY else { return; }
    if st.timed_out {
        answer(st, out, 500, "stale wake");
        return;
    }
    if st.connecting {
        let c = http::connected(st.s);
        if c.code == http::EINPROGRESS {
            http::wait_socket(out, st.s, http::WRITABLE, 300);
            return;
        }
        guard c.code == 0 else { failed(st, out, c); return; }
        st.connecting = false;
        if st.route == PING { assert(http::send(st.s, "pp") == 2); }
        if st.route == CLOSES { assert(http::send(st.s, "x") == 1); }
        if st.route == HANGUP || st.route == RESET || st.route == ANSWERED { assert(http::send(st.s, "w") == 1); }
        if st.route == STALE { assert(http::send(st.s, "c") == 1); }
        // The backend answers neither. The first sends a part of the
        // response, so the client knows to reset the stream while it waits;
        // the second answers in the call that waited, which ends the wait.
        if st.route == RESET {
            http::begin(out, 200, -1);
            http::send(out, "waiting");
            http::wait_socket(out, st.s, http::READABLE, 5000);
            return;
        }
        if st.route == ANSWERED {
            http::wait_socket(out, st.s, http::READABLE, 5000);
            answer(st, out, 200, "answered");
            return;
        }
    }
    if st.route == LARGE_SEND && st.sent < large.len {
        while st.sent < large.len {
            let n = http::send(st.s, large[st.sent..]);
            if n == -http::EAGAIN {
                http::wait_socket(out, st.s, http::WRITABLE, 5000);
                return;
            }
            guard n > 0 else { failed(st, out, http::Error { call: "send", code: -n }); return; }
            st.sent += n;
        }
        http::net_shutdown(st.s.fd, http::SHUT_WR);
    }
    var buf: u8[64] = [0; 64];
    loop {
        let n = http::recv(st.s, buf);
        if n == -http::EAGAIN {
            // The backend answers neither of these yet.
            let quiet = st.route == HANGUP || st.route == STALE;
            http::wait_socket(out, st.s, http::READABLE, if quiet { 50 } else { 5000 });
            return;
        }
        guard n >= 0 else { failed(st, out, http::Error { call: "recv", code: -n }); return; }
        if n == 0 {
            var text: u8[>..] = [];
            format(text, "closed after \"", st.got, "\"");
            answer(st, out, 200, text);
            return;
        }
        for b in buf[..n] { st.got.push(b); }
        if st.route == PING && st.got.len == 8 {
            answer(st, out, 200, st.got);
            return;
        }
    }
}

thread_fn worker(cfg: http::Config, ports: Ports) {
    var large: u8[>..] = [];
    large.resize(LARGE, 'c');
    let e = http::serve_epoll(cfg, St { .. }) { ev, st, out => handle(ev, st, out, ports, large); };
    http::report(e);
}

thread_fn ring_worker(cfg: http::Config, ports: Ports) {
    var large: u8[>..] = [];
    large.resize(LARGE, 'c');
    let e = http::serve(cfg, St { .. }) { ev, st, out => handle(ev, st, out, ports, large); };
    http::report(e);
}

// A request to the loop at address: its status line and body.
fn get(address: const u8[:], path: const u8[:]) -> u8[>..] {
    var s = http::Socket { .. };
    for i in 500 {
        let c, e = http::connect(address, 0, 1000);
        if e.code == 0 { s = c; break; }
        sleep_ms(10);
    }
    assert(s.fd >= 0);
    var req: u8[>..] = [];
    format(req, "GET ", path, " HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n");
    assert(http::send_all(s, req, 5000).code == 0);
    var got: u8[>..] = [];
    var buf: u8[4096] = [0; 4096];
    loop {
        let n = http::recv(s, buf, 10000);
        assert(n >= 0);
        if n == 0 { break; }
        got.append(buf[..n]);
    }
    http::hangup(s);
    let line = find(got, "\r\n");
    let head = find(got, "\r\n\r\n");
    assert(line > 0 && head >= line);
    var text: u8[>..] = [];
    format(text, got[..line], ": ", got[head + 4..]);
    return text;
}

fn on_epoll(address: const u8[:], path: const u8[:]) {
    print(path, ": ", get(address, path));
}

// A route on serve's loop: on io_uring, answered as want says; on the
// emulated ring, wait_socket's ENOSYS, or a refusal before it.
fn on_ring(address: const u8[:], path: const u8[:], want: const u8[:], native: bool) {
    let got = get(address, path);
    let ok = if native { got == want } else {
        got == "HTTP/1.1 502 Bad Gateway: wait_socket ENOSYS" || got == "HTTP/1.1 502 Bad Gateway: connect refused"
    };
    if !ok { print("serve ", path, ": ", got); }
    print("serve ", path, ": ", ok);
}

// An h2c connection to the loop at address, its preface and SETTINGS sent.
fn h2_open(address: const u8[:]) -> http::Socket {
    var s = http::Socket { .. };
    for i in 500 {
        let c, e = http::connect(address, 0, 1000);
        if e.code == 0 { s = c; break; }
        sleep_ms(10);
    }
    assert(s.fd >= 0);
    var out: u8[>..] = [];
    out.append(http::H2_PREFACE);
    http::h2_write_settings(out, http::H2Settings { .. });
    assert(http::send_all(s, out, 5000).code == 0);
    return s;
}

fn h2_get(s: http::Socket, enc: http::HpackTable&, id: i64, path: const u8[:]) {
    var fb: u8[>..] = [];
    http::hpack_encode(enc, fb, ":method", "GET");
    http::hpack_encode(enc, fb, ":scheme", "http");
    http::hpack_encode(enc, fb, ":path", path);
    http::hpack_encode(enc, fb, ":authority", "test");
    var out: u8[>..] = [];
    http::h2_write_headers(out, id, fb, true);
    assert(http::send_all(s, out, 5000).code == 0);
}

// The payload of stream id's next DATA frame, and whether it ended the
// stream. Other frames are passed over, and the server's SETTINGS
// acknowledged.
fn h2_data(s: http::Socket, pending: u8[>..]&, id: i64) -> u8[>..], bool {
    var buf: u8[4096] = [0; 4096];
    loop {
        let fr, size, err = http::h2_parse(pending, http::H2_MAX_FRAME_SIZE);
        if size > 0 {
            let mine = fr.kind == http::H2_DATA && fr.stream == id;
            var got: u8[>..] = [];
            if mine { got.append(fr.data); }
            let end = fr.flags & http::H2_END_STREAM != 0;
            let ack = fr.kind == http::H2_SETTINGS && fr.flags & http::H2_ACK == 0;
            let rest = pending.len - size;
            for i in rest { pending[i] = pending[size + i]; }
            pending.resize(rest, 0);
            if ack {
                var a: u8[>..] = [];
                http::h2_write_settings_ack(a);
                assert(http::send_all(s, a, 5000).code == 0);
            }
            if mine { return got, end; }
            continue;
        }
        let n = http::recv(s, buf, 10000);
        assert(n > 0);
        pending.append(buf[..n]);
    }
}

// Over h2c, on one connection: a stream reset while it waits, one answered
// in the call that waited, each followed by a /ping, which the backend
// serves only once it has seen the stream's socket closed. Each stream's
// path and body, a line each.
fn on_h2(address: const u8[:]) -> u8[>..] {
    let s = h2_open(address);
    var enc = http::hpack_table();
    var pending: u8[>..] = [];
    h2_get(s, enc, 1, "/reset");
    let part, ended = h2_data(s, pending, 1);
    if !ended {
        var rst: u8[>..] = [];
        http::h2_write_rst_stream(rst, 1, http::H2_CANCEL);
        assert(http::send_all(s, rst, 5000).code == 0);
    }
    var lines: u8[>..] = [];
    format(lines, "h2 /reset: ", part, "\n");
    h2_whole(s, enc, pending, 3, "/ping", lines);
    h2_whole(s, enc, pending, 5, "/answered", lines);
    h2_whole(s, enc, pending, 7, "/ping", lines);
    http::hangup(s);
    return lines;
}

// Requests path on stream id, and adds a line of its body to lines.
fn h2_whole(s: http::Socket, enc: http::HpackTable&, pending: u8[>..]&, id: i64, path: const u8[:],
            lines: u8[>..]&) {
    h2_get(s, enc, id, path);
    var body: u8[>..] = [];
    loop {
        let got, end = h2_data(s, pending, id);
        body.append(got);
        if end { break; }
    }
    format(lines, "h2 ", path, ": ", body, "\n");
}

let H2_WANT = "h2 /reset: waiting\nh2 /ping: pongpong\nh2 /answered: answered\nh2 /ping: pongpong\n";

fn main() {
    let lfd, port = listener(16);
    let gone, gone_port = listener(1);
    http::net_close(gone);
    let full, full_port = listener(1);
    var fillers: http::Socket[>..] = [];
    for i in 8 {
        let f, fe = http::connect_start("127.0.0.1", full_port);
        assert(fe.code == 0);
        fillers.push(f);
    }
    let ports = Ports { backend: port, refused: gone_port, full: full_port };
    let b = thread_spawn(backend, lfd);
    let epoll = unix_address("epoll.sock");
    let cfg = http::Config { address: epoll, workers: 1, mail_slots: 16, max_waiting: 16, .. };
    let w = thread_spawn(worker, cfg, ports);
    on_epoll(epoll, "/ping");
    on_epoll(epoll, "/large");
    on_epoll(epoll, "/closes");
    on_epoll(epoll, "/refused");
    on_epoll(epoll, "/timeout");
    // A socket still open would keep the backend from the next connection.
    on_epoll(epoll, "/hangup");
    on_epoll(epoll, "/ping");
    let epoll_h2 = unix_address("epoll_h2.sock");
    let w2 = thread_spawn(worker, http::Config { address: epoll_h2, h2c: true, workers: 1, mail_slots: 16,
                                                 max_waiting: 16, .. }, ports);
    let h2_got = on_h2(epoll_h2);
    print(h2_got[..h2_got.len - 1]);
    let ring = unix_address("ring.sock");
    let rcfg = http::Config { address: ring, workers: 1, mail_slots: 16, max_waiting: 16, .. };
    let r = thread_spawn(ring_worker, rcfg, ports);
    let native = http::ring_probe() == 0;
    on_ring(ring, "/ping", "HTTP/1.1 200 OK: pongpong", native);
    on_ring(ring, "/large", "HTTP/1.1 200 OK: closed after \"4194304\"", native);
    on_ring(ring, "/closes", "HTTP/1.1 200 OK: closed after \"\"", native);
    on_ring(ring, "/refused", "HTTP/1.1 502 Bad Gateway: connect refused", native);
    on_ring(ring, "/timeout", "HTTP/1.1 504 Gateway Timeout: connect timed out", native);
    on_ring(ring, "/stale", "HTTP/1.1 200 OK: no stale wake", native);
    on_ring(ring, "/hangup", "HTTP/1.1 200 OK: hung up", native);
    on_ring(ring, "/ping", "HTTP/1.1 200 OK: pongpong", native);
    let ring_h2 = unix_address("ring_h2.sock");
    let r2 = thread_spawn(ring_worker, http::Config { address: ring_h2, h2c: true, workers: 1, mail_slots: 16,
                                                      max_waiting: 16, .. }, ports);
    let ring_got = on_h2(ring_h2);
    let h2_ok = if native { ring_got == H2_WANT } else { find(ring_got, "ENOSYS") >= 0 };
    if !h2_ok { print(ring_got); }
    print("serve h2: ", h2_ok);
    http::stop();
    thread_wait(w);
    thread_wait(w2);
    thread_wait(r);
    thread_wait(r2);
    for i in fillers.len { http::hangup(fillers[i]); }
    http::net_close(full);
    var q, e = http::connect("127.0.0.1", port, 5000);
    assert(e.code == 0);
    assert(http::send_all(q, "q", 5000).code == 0);
    thread_wait(b);
    http::hangup(q);
}
