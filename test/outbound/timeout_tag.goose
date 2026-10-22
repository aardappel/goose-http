// TIMEOUT's tag on both loops: NO_ROOM for an exchange that found no room to
// wait, a loop with no box or one whose max_waiting is taken, and 0 for one
// whose time limit passed, again after a wait made at TIMEOUT. With
// outbound_loop's setup: the loops listen on Unix sockets in TMPDIR.
import std;
import os;
import http from "../../";

fn unix_address(name: const u8[:]) -> u8[>..] {
    var dir: u8[>..] = [];
    var a: u8[>..] = [];
    if env("TMPDIR", dir) && dir.len > 0 { format(a, "unix:", dir, "/", name); }
    else { format(a, "unix:", name); }
    return a;
}

// /again waits twice, the second time from its first TIMEOUT; /long waits
// 300 ms, holding a worker's one waiting exchange.
struct St { waits: i64 = 0, tags: u8[..16] = "" }

fn handle(ev: http::Event, st: St&, out: http::Reply) {
    if ev.kind == http::REQUEST {
        st.waits = if ev.req.target == "/again" { 2 } else { 1 };
        st.tags.clear();
        http::later(out, if ev.req.target == "/long" { 300 } else { 20 });
    } else if ev.kind == http::TIMEOUT {
        if st.tags.len > 0 { st.tags.push(' '); }
        format(st.tags, ev.tag);
        st.waits--;
        if st.waits > 0 {
            http::later(out, 20);
            return;
        }
        var body: u8[>..] = [];
        format(body, if ev.tag == http::NO_ROOM { "no room" } else { "waited" }, " ", st.tags);
        http::respond(out, 200, "text/plain", body);
    }
}

thread_fn epoll_worker(cfg: http::Config) {
    http::report(http::serve_epoll(cfg, St { .. }) { ev, st, out => handle(ev, st, out); });
}

thread_fn ring_worker(cfg: http::Config) {
    http::report(http::serve(cfg, St { .. }) { ev, st, out => handle(ev, st, out); });
}

thread_fn long_get(name: u8[..32], address: u8[..128]) { get(name, address, "/long"); }

// A request for path to the loop at address, and its body.
fn get(name: const u8[:], address: const u8[:], path: const u8[:] = "/") {
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
    let head = find(got, "\r\n\r\n");
    assert(head > 0);
    print(name, ": ", got[head + 4..]);
}

fn main() {
    let a = unix_address("t1.sock");
    let b = unix_address("t2.sock");
    let c = unix_address("t3.sock");
    let d = unix_address("t4.sock");
    let e = unix_address("t5.sock");
    let f = unix_address("t6.sock");
    let w = [
        thread_spawn(epoll_worker, http::Config { address: a, workers: 1, .. }),
        thread_spawn(epoll_worker, http::Config { address: b, workers: 1, mail_slots: 16, max_waiting: 16, .. }),
        thread_spawn(epoll_worker, http::Config { address: e, workers: 1, mail_slots: 16, max_waiting: 1, .. }),
        thread_spawn(ring_worker, http::Config { address: c, workers: 1, .. }),
        thread_spawn(ring_worker, http::Config { address: d, workers: 1, mail_slots: 16, max_waiting: 16, .. }),
        thread_spawn(ring_worker, http::Config { address: f, workers: 1, mail_slots: 16, max_waiting: 1, .. }),
    ];
    get("epoll, no box", a);
    get("epoll, a timer", b);
    get("epoll, twice", b, "/again");
    full("epoll, max_waiting taken", e);
    get("serve, no box", c);
    get("serve, a timer", d);
    get("serve, twice", d, "/again");
    full("serve, max_waiting taken", f);
    http::stop();
    for t in w { thread_wait(t); }
}

// A request to a loop whose one waiting exchange /long holds.
fn full(name: const u8[:], address: const u8[:]) {
    var n: u8[..32] = "";
    n.append(name[..min(name.len, 26)]);
    n.append(", long");
    var at: u8[..128] = "";
    at.append(address);
    let t = thread_spawn(long_get, n, at);
    sleep_ms(100);
    get(name, address);
    thread_wait(t);
}
