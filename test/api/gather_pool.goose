// The worker's gather pool and its budget: a promise made at admission and
// refused there, runs that grow only within their promise, and gather's 503
// at a body's head where the budget can't promise it.
import std;
import http from "../../";
import check from "../";

// The parts: what a budget of 100 bytes promises, and what a run takes.
fn test_parts() {
    http::gather_budget(100);
    var a = http::Gather { .. };
    var b = http::Gather { .. };
    assert(http::gather_promise(a, 60));
    assert(!http::gather_promise(b, 50) && b.most == 0 && http::gather_promised == 60);
    // A run never passes its promise, so the budget is never passed.
    assert(http::gather_piece(a, "0123456789"));
    assert(a.cap == 60 && a.len == 10);
    var fifty: u8[>..] = [];
    for i in 50 { fifty.push('x'); }
    assert(http::gather_piece(a, fifty) && a.len == 60);
    assert(!http::gather_piece(a, "y") && a.len == 60);
    check::same(http::gathered[a.at..a.at + 10], "0123456789");
    // gather_clear frees the run and keeps the promise; release_gather gives
    // both back.
    http::gather_clear(a);
    assert(a.cap == 0 && a.len == 0 && a.most == 60 && http::gather_promised == 60);
    assert(!http::gather_promise(b, 50));
    http::release_gather(a);
    assert(a.most == 0 && http::gather_promised == 0);
    assert(http::gather_promise(b, 50));
    http::release_gather(b);
    http::release_gather(b);
    assert(http::gather_promised == 0);
    // A run that starts at 16 KB, doubling, stops at its promise.
    http::gather_budget(http::GATHER_BUDGET);
    assert(http::gather_promise(a, 20000));
    assert(http::gather_piece(a, "z") && a.cap == 16384);
    var more: u8[>..] = [];
    for i in 16384 { more.push('m'); }
    assert(http::gather_piece(a, more) && a.cap == 20000);
    http::release_gather(a);
    print("parts: promised at admission, refused there, runs within their promise");
}

// gather_head's runs: a Content-Length body's, of the head and the body's
// exact size, placed at the head, and a chunked body's, promised limit
// bytes and grown within them.
fn test_heads() {
    var buf: u8[>..] = [];
    let req = check::request("POST", "Content-Length: 10\r\n", buf);
    var g = http::Gather { .. };
    assert(http::gather_head(g, req, 100));
    assert(g.most == g.head + 10 && g.cap == g.most && http::gather_promised == g.most);
    let at = g.at;
    assert(http::gather_piece(g, "abcdefghij") && g.at == at && g.cap == g.most);
    http::release_gather(g);
    let chunked = check::request("POST", "Transfer-Encoding: chunked\r\n", buf);
    assert(http::gather_head(g, chunked, 100));
    assert(g.most == g.head + 100 && g.cap == g.most);
    http::release_gather(g);
    assert(http::gather_head(g, chunked, 1 << 20));
    assert(g.most == g.head + (1 << 20) && g.cap == 16384);
    http::release_gather(g);
    assert(http::gather_promised == 0);
    print("gather_head: an exact run for a Content-Length, a promise of the limit for chunked");
}

// gather with a body of 10 bytes in pieces, its run St.body, under the
// worker's budget: what the handler got, and the responses.
struct St { body: http::Gather = http::Gather { .. } }

fn upload(st: St&, out: u8[>..]&, kinds: const u8[:]) -> u8[>..] {
    var buf: u8[>..] = [];
    let req = check::request("POST", "Content-Length: 10\r\n", buf);
    let none = http::Request { .. };
    var keep = true;
    var stream = http::Stream { .. };
    var log: u8[>..] = [];
    let reply = http::Reply { buf: out, common: "", keep_alive: keep, minor: 1, head: false, stream: stream };
    for kind in kinds {
        http::gather(http::Event { kind: kind, req: if kind == http::REQUEST { req } else { none },
                                   data: if kind == http::BODY { "abcdefghij" } else { "" }, whole: false,
                                   trailers: "" }, st.body, reply, 100) { q, body, o =>
            format(log, "[", body, "]");
            http::respond(o, 200, "text/plain", body);
        };
    }
    if !keep { log.append(" close"); }
    return log;
}

fn test_gather() {
    var first = St { .. };
    var second = St { .. };
    var out: u8[>..] = [];
    // A budget that holds one such body: the second is refused at its head.
    var probe: u8[>..] = [];
    let req = check::request("POST", "Content-Length: 10\r\n", probe);
    var g = http::Gather { .. };
    assert(http::gather_head(g, req, 100));
    let one = g.most;
    http::release_gather(g);
    http::gather_budget(one + one / 2);
    check::same(upload(first, out, [http::REQUEST]), "");
    out.clear();
    check::same(upload(second, out, [http::REQUEST, http::BODY, http::END]), " close");
    check::same(out, "HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nRetry-After: 1\r\nContent-Length: 0\r\n\r\n");
    assert(second.body.most == 0 && http::gather_promised == one);
    print("gather past the budget: 503 at the head, and close");
    // The first's END gives its promise back, and the next body fits.
    out.clear();
    check::same(upload(first, out, [http::BODY, http::END]), "[abcdefghij]");
    assert(http::gather_promised == 0);
    var third = St { .. };
    check::same(upload(third, out, [http::REQUEST, http::BODY, http::END]), "[abcdefghij]");
    assert(http::gather_promised == 0);
    http::gather_budget(http::GATHER_BUDGET);
    print("gather after a body's END: its promise given back, the next admitted");
}

fn main() {
    test_parts();
    test_heads();
    test_gather();
}
