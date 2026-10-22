// HTTP/1.1 over TLS in serve_epoll and serve, with goose-tls's server TLS
// 1.3 over OpenSSL 3 (task 014). Only a program that imports this module
// needs that package, which its root file declares at the tag this file
// names:
//
//   import http from "github.com/kaitk/goose-http@<tag>";
//   import tls from "github.com/kaitk/goose-tls@v0.0.3";
//   import http.tls;
//
// The listeners with Listener.tls (or Config.tls for Config.port's) serve
// TLS, from a context the program makes once and hands each worker:
//
//   let ctx, ok = tls::server_files("server.crt", "server.key", ["http/1.1"]);
//   http::run(cfg, ctx, worker);
//   tls::free(ctx);
//
//   thread_fn worker(cfg: http::Config, ctx: tls::Context) {
//       var server = http::tls_server(ctx);
//       http::exit_on_error(http::serve_epoll(cfg, fresh, server) { ev, st, out => ... });
//       http::release(server);
//   }
namespace http;

import std;
import tls from "github.com/kaitk/goose-tls@v0.0.3";
import sys;
import epoll;

// One connection's TLS: ready once its handshake is done, and notified once
// close_notify is queued. A free slot holds the next free one.
struct TlsSlot {
    conn: tls::Conn,
    ready: bool,
    notified: bool,
    next: i32 = -1,
}

// A worker's TLS: the context its connections are accepted from, the
// buffer the socket's bytes are read into before they're fed to OpenSSL,
// and each connection's state, by the slot EpollConn.tls or RingConn.tls
// names, with the first free one.
struct TlsServer {
    ctx: tls::Context,
    free: i32 = -1,
    wire: u8[16384],
    slots: TlsSlot[>..],
}

// A worker's TlsServer, on its own reference to ctx, which release frees.
fn tls_server(ctx: tls::Context) -> TlsServer {
    return TlsServer { ctx: tls::share(ctx), .. };
}

// Frees t's reference to its context, once its loop has returned.
fn release(t: TlsServer&) {
    tls::free(t.ctx);
    t.ctx = tls::Context { .. };
}

// serve_epoll(cfg), whose listeners with tls serve it with t.
fn serve_epoll<H>(cfg: Config, t: TlsServer&) -> Error {
    return epoll_loop(cfg, false, t) { ev, st, out => whole(ev, out, H); };
}

// serve_epoll(cfg, fresh), whose listeners with tls serve it with t.
fn serve_epoll<S, H>(cfg: Config, fresh: S, t: TlsServer&) -> Error {
    return epoll_loop(cfg, fresh, t, H);
}

// serve(cfg), whose listeners with tls serve it with t. On Windows it fails
// with ENOSYS on a TLS listener.
fn serve<H>(cfg: Config, t: TlsServer&) -> Error {
    return ring_loop(cfg, false, t) { ev, st, out => whole(ev, out, H); };
}

// serve(cfg, fresh), whose listeners with tls serve it with t.
fn serve<S, H>(cfg: Config, fresh: S, t: TlsServer&) -> Error {
    return ring_loop(cfg, fresh, t, H);
}

fn tls_serves(t: TlsServer&) -> bool { tls::ok(t.ctx) }

// A connection for a socket just accepted: its slot, or -1 when OpenSSL
// can't make one.
fn tls_open(t: TlsServer&) -> i32 {
    let c = tls::accept(t.ctx);
    guard tls::ok(c) else { return -1; }
    let s = TlsSlot { conn: c, ready: false, notified: false };
    if t.free >= 0 {
        let k = t.free;
        t.free = t.slots[k].next;
        t.slots[k] = s;
        return k;
    }
    t.slots.push(s);
    return (t.slots.len - 1) as i32;
}

fn tls_ready(t: TlsServer&, k: i32) -> bool { t.slots[k].ready }

// Reads plaintext into buf from what slot k holds, through its handshake
// first, until buf is full or OpenSSL wants more input. Returns the count,
// and whether the connection is done after it: the client sent
// close_notify, or the handshake or a record failed.
fn tls_plain(s: TlsSlot&, buf: u8[:]) -> i64, bool {
    if !s.ready {
        let h = tls::handshake(s.conn);
        if h == 0 { s.ready = true; }
        else if h != tls::WANT_INPUT { return 0, true; }
    }
    var got = 0;
    if s.ready {
        while got < buf.len {
            let r = tls::read(s.conn, buf[got..]);
            if r > 0 {
                got += r;
                continue;
            }
            if r == tls::WANT_INPUT { break; }
            return got, true;   // CLOSED or FAILED
        }
    }
    return got, false;
}

// Reads plaintext into buf from slot k's socket fd, through its handshake
// first. Returns the count, with whether the socket was emptied and every
// whole record read; 0 when the handshake has bytes to send before it can
// go on; -EAGAIN once the socket is empty; or another value below 0 when
// the connection is done: the client closed it, sent close_notify, or failed
// the handshake. What came before a close_notify is returned first, and the
// next call returns the close.
fn tls_recv(t: TlsServer&, k: i32, fd: i32, buf: u8[:]) -> i64, bool {
    let s .= t.slots[k];
    guard buf.len > 0 else { return -1, false; }
    var empty = false;
    loop {
        let got, done = tls_plain(s, buf);
        if got > 0 { return got, !done && empty && got < buf.len; }
        guard !done else { return -1, false; }
        if tls::pending(s.conn) > 0 { return 0, false; }
        if empty { return -EAGAIN, true; }
        let n = net_recv(fd, t.wire);
        if n == -EINTR { continue; }
        if n == -EAGAIN { return -EAGAIN, true; }
        guard n > 0 else { return -1, false; }
        guard tls::feed(s.conn, t.wire[..n]) == n else { return -1, false; }
        empty = n < t.wire.len;
    }
}

// tls_recv for bytes already received, as the ring delivers them: feeds
// them to slot k, and appends to out the plaintext they complete. False once
// the connection is done, after what came before; its alert, if any, waits
// for tls_seal.
fn tls_take(t: TlsServer&, k: i32, bytes: const u8[:], out: u8[>..]&) -> bool {
    let s .= t.slots[k];
    guard tls::feed(s.conn, bytes) == bytes.len else { return false; }
    loop {
        let end = out.len;
        out.resize(end + t.wire.len, 0);
        let got, done = tls_plain(s, out[end..]);
        out.resize(end + got, 0);
        guard !done else { return false; }
        if got < t.wire.len { return true; }
    }
}

// Seals w[from..] for slot k, in its place, followed by close_notify if
// last: w ends with the bytes OpenSSL has waiting to send, the handshake's
// too. False when OpenSSL fails.
fn tls_seal(t: TlsServer&, k: i32, w: u8[>..]&, from: i64, last: bool) -> bool {
    let c = t.slots[k].conn;
    if from < w.len {
        guard tls::write(c, w[from..]) == w.len - from else { return false; }
    }
    if last { tls_notify(t, k); }
    var end = from;
    w.resize(end, 0);
    loop {
        let p = tls::pending(c);
        guard p > 0 else { break; }
        w.resize(end + p, 0);
        let n = tls::drain(c, w[end..]);
        guard n > 0 else { break; }
        end += n;
        w.resize(end, 0);
    }
    return true;
}

// Queues close_notify for slot k, once, after its handshake.
fn tls_notify(t: TlsServer&, k: i32) {
    guard t.slots[k].ready && !t.slots[k].notified else { return; }
    t.slots[k].notified = true;
    tls::shutdown(t.slots[k].conn);
}

// Frees slot k, after sending, when clean, close_notify, or the alert of a
// handshake that failed, in one send that may not take it all.
fn tls_close(t: TlsServer&, k: i32, fd: i32, clean: bool) {
    let c = t.slots[k].conn;
    if clean {
        tls_notify(t, k);
        var bye: u8[256] = [0; 256];
        let n = tls::drain(c, bye);
        if n > 0 { net_send(fd, bye[..n]); }
    }
    tls::free(c);
    t.slots[k] = TlsSlot { conn: tls::Conn { .. }, ready: false, notified: false, next: t.free };
    t.free = k;
}
