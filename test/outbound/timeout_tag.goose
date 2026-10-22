// TIMEOUT's tag on both loops: NO_ROOM for an exchange that found no room to
// wait, here a loop with no box, and 0 for one whose time limit passed. With
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

fn handle(ev: http::Event, out: http::Reply) {
    if ev.kind == http::REQUEST {
        http::later(out, 20);
    } else if ev.kind == http::TIMEOUT {
        var body: u8[>..] = [];
        format(body, if ev.tag == http::NO_ROOM { "no room" } else { "waited" }, " ", ev.tag);
        http::respond(out, 200, "text/plain", body);
    }
}

thread_fn epoll_worker(cfg: http::Config) {
    http::report(http::serve_epoll(cfg, false) { ev, st, out => handle(ev, out); });
}

thread_fn ring_worker(cfg: http::Config) {
    http::report(http::serve(cfg, false) { ev, st, out => handle(ev, out); });
}

// A request to the loop at address, and its body.
fn get(name: const u8[:], address: const u8[:]) {
    var s = http::Socket { .. };
    for i in 500 {
        let c, e = http::connect(address, 0, 1000);
        if e.code == 0 { s = c; break; }
        sleep_ms(10);
    }
    assert(s.fd >= 0);
    assert(http::send_all(s, "GET / HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n", 5000).code == 0);
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
    let w = [
        thread_spawn(epoll_worker, http::Config { address: a, workers: 1, .. }),
        thread_spawn(epoll_worker, http::Config { address: b, workers: 1, mail_slots: 16, max_waiting: 16, .. }),
        thread_spawn(ring_worker, http::Config { address: c, workers: 1, .. }),
        thread_spawn(ring_worker, http::Config { address: d, workers: 1, mail_slots: 16, max_waiting: 16, .. }),
    ];
    get("epoll, no box", a);
    get("epoll, a timer", b);
    get("serve, no box", c);
    get("serve, a timer", d);
    http::stop();
    for t in w { thread_wait(t); }
}
