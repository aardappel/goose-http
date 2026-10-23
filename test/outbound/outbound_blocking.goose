// The blocking calls of an outbound connection (socket.goose), for a thread
// that runs no loop, against a server thread in the program: a connect and
// a round trip, a large send, a server that closes, a refused connect, a
// connect that times out against a full backlog, a name resolved, and one
// that can't be.
import std;
import http from "../../";

let LARGE = 8 << 20;

// A blocking listener on 127.0.0.1, on a port the kernel picks.
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

// Serves one connection after another on lfd, by the first byte each sends:
// p answers pong to each p, c counts the bytes until the client shuts its
// side, answers the count, and closes, x closes at once, and q ends.
thread_fn server(lfd: i32) {
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
                count = n - 1;
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

fn read_all(s: http::Socket, out: u8[>..]&) -> i64 {
    var buf: u8[>..] = [];
    buf.resize(4096, 0);
    loop {
        let n = http::recv(s, buf, 5000);
        if n <= 0 { return n; }
        out.append(buf[..n]);
    }
}

fn main() {
    let lfd, port = listener(16);
    let t = thread_spawn(server, lfd);

    // A round trip, through localhost.
    var s, e = http::connect("localhost", port, 5000);
    assert(e.code == 0);
    assert(http::send_all(s, "pp", 5000).code == 0);
    var buf: u8[>..] = [];
    buf.resize(16, 0);
    var got: u8[>..] = [];
    while got.len < 8 {
        let n = http::recv(s, buf, 5000);
        assert(n > 0);
        got.append(buf[..n]);
    }
    print("round trip: ", got);
    // Nothing more comes: the time limit passes.
    print("nothing more: ", http::recv(s, buf, 50) == -http::ETIMEDOUT);
    http::hangup(s);
    assert(s.fd == -1);

    // A send far larger than the socket's buffers, then the server's count,
    // and its close.
    s, e = http::connect("127.0.0.1", port, 5000);
    assert(e.code == 0);
    var large: u8[>..] = [];
    large.resize(LARGE, 'c');
    assert(http::send_all(s, large, 10000).code == 0);
    http::net_shutdown(s.fd, http::SHUT_WR);
    got.clear();
    let end = read_all(s, got);
    print("large: ", got, " bytes counted, then ", end);
    http::hangup(s);

    // A server that closes: recv gives 0, and a send then fails, with
    // ECONNABORTED on Windows.
    s, e = http::connect("[::ffff:127.0.0.1]", port, 5000);
    assert(e.code == 0);
    assert(http::send_all(s, "x", 5000).code == 0);
    print("closed: ", http::recv(s, buf, 5000));
    var failed = http::Error { call: "", code: 0 };
    for i in 100 {
        failed = http::send_all(s, large[..65536], 5000);
        if failed.code != 0 { break; }
    }
    print("send after the close: ", failed.code == http::EPIPE || failed.code == http::ECONNRESET ||
          failed.code == http::ECONNABORTED);
    http::hangup(s);

    // A port nothing listens on.
    let gone, gone_port = listener(1);
    http::net_close(gone);
    s, e = http::connect("127.0.0.1", gone_port, 5000);
    print("refused: ", e.call, " ", e.code == http::ECONNREFUSED, ", socket ", s.fd);

    // A listener that never accepts, its backlog full: the kernel drops the
    // next SYNs, and the connect times out.
    let full, full_port = listener(1);
    var fillers: http::Socket[>..] = [];
    for i in 8 {
        let f, fe = http::connect_start("127.0.0.1", full_port);
        assert(fe.code == 0);
        fillers.push(f);
    }
    s, e = http::connect("127.0.0.1", full_port, 300);
    print("timed out: ", e.call, " ", e.code == http::ETIMEDOUT, ", socket ", s.fd);
    for i in fillers.len { http::hangup(fillers[i]); }
    http::net_close(full);

    // A name, resolved: LOCALHOST isn't connect_start's localhost, and every
    // resolver finds it in the hosts file. ::1 may come first, where nothing
    // listens, and then 127.0.0.1 connects.
    s, e = http::connect("LOCALHOST", port, 5000);
    print("a name: code ", e.code, ", socket ", s.fd >= 0);
    if e.code == 0 {
        assert(http::send_all(s, "x", 5000).code == 0);
        http::hangup(s);
    }
    // .invalid has no address (RFC 6761); a resolver with no network fails
    // it for now instead.
    s, e = http::connect("name.invalid", 5432, 5000);
    print("no such name: ", e.call, " ", e.code == http::ENOENT || e.code == http::EAGAIN, ", socket ", s.fd);
    s, e = http::connect("LOCALHOST", 0, 5000);
    print("a name, port 0: ", e.call, " ", e.code == http::EINVAL);
    // connect_start, for a loop, takes no name.
    s, e = http::connect_start("LOCALHOST", port);
    print("a name on a loop: ", e.call, " ", e.code == http::ENOSYS);
    s, e = http::connect("127.0.0.1", 0, 5000);
    print("port 0: ", e.call, " ", e.code == http::EINVAL);

    s, e = http::connect("127.0.0.1", port, 5000);
    assert(e.code == 0);
    assert(http::send_all(s, "q", 5000).code == 0);
    thread_wait(t);
    http::hangup(s);
}
