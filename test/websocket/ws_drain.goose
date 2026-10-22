import std;
import http from "../../";
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import http.websocket;

fn main() {
    var buf: u8[>..] = [];
    var keep = true;
    var stream = http::Stream { .. };
    let out = http::Reply { buf: buf, common: "", keep_alive: keep,
                            minor: 1, head: false, stream: stream };
    assert(!http::after_drain(out));
    stream.open = true;
    stream.framing = http::Framing.Raw;
    assert(!http::after_drain(out));
    http::ws_send(out, http::WS_TEXT, "abc");
    assert(http::after_drain(out));
    assert(!http::after_drain(out));
    http::ws_send(out, http::WS_TEXT, "def");
    assert(http::after_drain(out));
    assert(buf.len == 10 && buf[0] == 0x81 && buf[5] == 0x81);
    http::end(out);
    assert(!stream.open && !http::after_drain(out));
    print("raw drain: bounded batches, coalescing, and close");
}
