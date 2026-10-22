// The benchmark server's handler: TechEmpower's plaintext and JSON tests,
// HttpArena's endpoints (bench/httparena), and for the tests, /bytes and
// /stream, which send a response of any size in pieces, /upload and /echo,
// which take a body of any size in pieces, /upgrade, which switches to a
// protocol that echoes bytes, and with delay, waits for the backend
// meanwhile, /files/NAME and /static/NAME, the files of the directory that
// FILES names, /client, the peer's address and port and the client's,
// trusting proxies on loopback, /later and /events, answers that wait
// for the backend thread (backend.goose): one reply, or Server-Sent Events,
// and /delay/MS, an answer after a timer, and /ws, a WebSocket that echoes
// each message, as HttpArena's echo-ws profiles ask.
// With ACCESS_LOG set, each response is logged to stdout (logged).
import std;
import os;
import http;
import http.compression;
import http.websocket;
import backend;
import dataset;

// The backend lane, which app.goose opens before it spawns the workers,
// which copy it; none while waiting is off (MAIL_SLOTS).
var backend_lane: http::Lane;

// The most bytes /bytes and /stream send.
let MAX_BYTES = 1000000000;
// The most bytes /bytes and /stream send for one MORE.
let PIECE = 16384;
// What /bytes and /stream send: the digits over and over, from any offset.
let DIGITS = digits();

fn digits() -> u8[PIECE + 10] {
    var d: u8[PIECE + 10] = [0; PIECE + 10];
    for i in d.len { d[i] = ('0' + i % 10) as! u8; }
    return d;
}

// A request's state, between the handler's calls for it.
struct Transfer {
    route: u8 = NONE,
    count: i64 = 0,     // /upload: body bytes so far; /bytes, /stream: bytes sent
    left: i64 = 0,      // /bytes, /stream: bytes still to send; /delay: 1 for an open response
    sum: u64 = 0,       // /upload: the sum of the body's bytes
    file: http::FileBody = http::FileBody { .. },   // /files/
    coded: http::Compressed = http::Compressed { .. },  // /zstream, /events: the encoder, if compressed
    ws: i64 = -1,       // /ws: its WebSocket's index in sockets
}

// Each worker's WebSockets, one for each open /ws connection, which keeps its
// index: a WebSocket in Transfer would lengthen the state every request starts
// with (task 055). A closed connection's index goes to free_sockets, whose
// first free_count are free; it never shrinks, as the loops may hold
// references Goose can't tell from one into it (spec §5.1).
var sockets: http::WebSocket[>..] = [];
var free_sockets: i64[>..] = [];
var free_count: i64 = 0;

let NONE: u8 = 0;
let UPLOAD: u8 = 1;
let ECHO: u8 = 2;
let SEND: u8 = 3;
let FILE: u8 = 4;
let LATER: u8 = 5;
let EVENTS: u8 = 6;
let DELAY: u8 = 7;
let WS: u8 = 8;

// The handler: routes each request, and carries on with those that take or
// send their bodies in pieces. Inline, so that http::start and http::finish
// fold into each route.
inline fn handle(ev: http::Event, st: Transfer&, out: http::Reply) {
    if ev.kind == http::REQUEST {
        route(ev.req, ev.data, ev.whole, ev.trailers, st, out);
    } else if ev.kind == http::DONE {
        logged(ev, out);
    } else if ev.kind == http::CLOSED && st.coded.slot >= 0 {
        http::release_compressed(st.coded);
    } else if st.route == WS {
        echo_frames(ev, st, out);
    } else if st.route == UPLOAD {
        if ev.kind == http::BODY { take(st, ev.data); }
        else if ev.kind == http::END { uploaded(st, out); }
    } else if st.route == ECHO {
        // WAKE and TIMEOUT come only to /upgrade with delay.
        if ev.kind == http::BODY || ev.kind == http::WAKE { http::send(out, ev.data); }
        else if ev.kind == http::END { http::end(out, ev.trailers); }
        else if ev.kind == http::TIMEOUT { http::send(out, "timeout"); }
    } else if st.route == FILE {
        if ev.kind == http::MORE {
            if !http::send_file(out, st.file) { http::end(out); }
        } else if ev.kind == http::CLOSED {
            http::close_body(st.file);
        }
    } else if st.route == LATER {
        if ev.kind == http::WAKE { http::respond(out, 200, "text/plain", ev.data); }
        else if ev.kind == http::TIMEOUT { http::respond(out, 504, "text/plain", "timeout"); }
    } else if st.route == DELAY {
        if ev.kind == http::TIMEOUT {
            var text: u8[..24] = [];
            format(text, st.count);
            if st.left == 1 {
                http::send(out, text);
                http::end(out);
            } else {
                http::start(out, 200);
                http::finish(out, http::TEXT,text);
            }
        }
    } else if st.route == EVENTS {
        if ev.kind == http::WAKE {
            // One piece per event, which a compressed stream flushes whole.
            var text: u8[>..] = [];
            text.append("data: ");
            text.append(ev.data);
            text.append("\n\n");
            http::send_compressed(out, st.coded, text);
            if ev.tag == REPLY_LAST { http::end_compressed(out, st.coded); } else { http::later(out, st.left); }
        } else if ev.kind == http::TIMEOUT {
            http::send_compressed(out, st.coded, ": timeout\n\n");
            http::end_compressed(out, st.coded);
        }
    } else if st.route == SEND && ev.kind == http::MORE {
        let k = min(st.left, PIECE);
        let at = st.count % 10;
        http::send_compressed(out, st.coded, DIGITS[at..at + k]);
        st.count += k;
        st.left -= k;
        if st.left == 0 { http::end_compressed(out, st.coded); }
    }
}

// Answers req, or starts to. body is its body, and trailers its trailers,
// when whole is set, or empty.
// TechEmpower's routes go first, where most requests go, before the other
// paths are compared: as lets ahead of the first branch, the comparisons cost
// about 20 instructions per request.
inline fn route(req: http::Request, body: const u8[:], whole: bool, trailers: const u8[:], st: Transfer&,
                 out: http::Reply) {
    let path = http::path_of(req.target);
    let get = out.head || req.method == "GET";
    if get && path == "/plaintext" {
        http::start(out, 200);
        http::finish(out, http::TEXT,"Hello, World!");
    } else if get && path == "/json" {
        var text: u8[..64] = [];
        json_object(text, Message { message: "Hello, World!" });
        http::start(out, 200);
        http::finish(out, http::JSON, text);
    } else {
        route_rest(req, path, get, body, whole, trailers, st, out);
    }
}

// route's routes past TechEmpower's.
inline fn route_rest(req: http::Request, path: const u8[:], get: bool, body: const u8[:], whole: bool,
                     trailers: const u8[:], st: Transfer&, out: http::Reply) {
    let plaintext = path == "/plaintext";
    let json = path == "/json";
    // HttpArena's h2 and h2c profiles name it /baseline2.
    let baseline = path == "/baseline11" || path == "/baseline2";
    let pipeline = path == "/pipeline";
    // n bytes, with a Content-Length, and chunked: responses larger than the
    // write buffer, sent as the client takes them.
    let bytes = path == "/bytes";
    let stream = path == "/stream";
    // /stream's text, compressed as the request takes, each piece flushed.
    let zstream = path == "/zstream";
    // A body of any size: its length and the sum of its bytes, and the body
    // itself.
    let upload = path == "/upload";
    let echo = path == "/echo";
    // Upgrade: echo switches the connection to echoing what comes, as it is.
    let raw = path == "/upgrade";
    let ws = path == "/ws";
    // HttpArena's static profiles name it /static/.
    let files = starts_with(path, "/files/") || starts_with(path, "/static/");
    let post = req.method == "POST";
    if !get && !post && !http::known_method(req.method) {
        http::start(out, 501);
        http::finish(out, http::NO_TYPE, "");
    } else if !get && (plaintext || json || pipeline || bytes || stream || zstream || raw || ws || files ||
                       baseline && !post) ||
              !post && (upload || echo) {
        http::start(out, 405);
        out.buf.append(if baseline { "Allow: GET, HEAD, POST\r\n" }
                       else if upload || echo { "Allow: POST\r\n" }
                       else { "Allow: GET, HEAD\r\n" });
        http::finish(out, http::NO_TYPE, "");
    } else if baseline {
        // A body too long for the read buffer counts as empty.
        let a, _ = http::query_int(req.target, "a");
        let b, _ = http::query_int(req.target, "b");
        var sum = a + b;
        if post {
            let n, ok = parse_int(trim(body));
            if ok { sum += n; }
        }
        var text: u8[..24] = [];
        format(text, sum);
        http::start(out, 200);
        http::finish(out, http::TEXT,text);
    } else if pipeline {
        http::start(out, 200);
        http::finish(out, http::TEXT,"ok");
    } else if bytes || stream || zstream {
        let asked, _ = http::query_int(req.target, "n");
        let n = min(max(asked, 0), MAX_BYTES);
        if zstream {
            http::begin_compressed(out, req, 200, "text/plain", st.coded);
        } else {
            http::begin(out, 200, if bytes { n } else { -1 });
            http::field(out, "Content-Type", "application/octet-stream");
        }
        st.route = SEND;
        st.left = n;
        if n == 0 || out.head { http::end_compressed(out, st.coded); }
    } else if upload {
        st.route = UPLOAD;
        take(st, body);
        if whole { uploaded(st, out); }
    } else if echo {
        http::begin(out, 200, if req.chunked { -1 } else { req.body });
        http::field(out, "Content-Type", "application/octet-stream");
        http::send(out, body);
        // A chunked body's trailers go back as the response's.
        if whole { http::end(out, trailers); } else { st.route = ECHO; }
    } else if files {
        serve_static(req, path[if path[1] == 'f' { 7 } else { 8 }..], st, out);
    } else if raw {
        if http::upgrade_of(req) == "echo" {
            http::upgrade(out, "echo");
            st.route = ECHO;
            let _, delayed = http::query_of(req.target, "delay");
            if delayed { upgraded_later(req, out); }
        } else {
            http::start(out, 426);
            http::field(out, "Upgrade", "echo");
            http::finish(out, http::NO_TYPE, "");
        }
    } else if ws {
        upgrade_ws(req, st, out);
    } else if get && path == "/client" {
        client(req, out);
    } else if get && (path == "/later" || path == "/events") {
        wait_for_backend(req, path == "/events", st, out);
    } else if get && starts_with(path, "/delay/") {
        delay(req, path[7..], st, out);
    } else if get && starts_with(path, "/json/") {
        json_items(req, path[6..], out);
    } else if req.target == "*" {
        // OPTIONS *, the only method parse lets "*" through with: what the
        // server as a whole allows (RFC 9110 §9.3.7).
        http::start(out, 200);
        http::finish(out, "Allow: GET, HEAD, POST, OPTIONS\r\nContent-Length: ", "");
    } else {
        http::start(out, 404);
        http::finish(out, http::NO_TYPE, "");
    }
}

// /files/NAME and /static/NAME: the file NAME, percent-decoded, in the directory FILES names,
// or a precompressed copy of it.
fn serve_static(req: http::Request, name: const u8[:], st: Transfer&, out: http::Reply) {
    var dir: u8[>..] = [];
    var full: u8[>..] = [];
    var status: i32 = 404;
    if env("FILES", dir) && dir.len > 0 && http::file_path(dir, name, full) {
        let f, s = http::open_precompressed(req, full);
        if s == 200 {
            st.route = FILE;
            http::serve_file(req, out, f, http::content_type_of(full), st.file);
            return;
        }
        status = s;
    }
    http::start(out, status);
    http::finish(out, http::NO_TYPE, "");
}

// /later?id=ID&delay=D&ms=M: "ID 1" from the backend after D milliseconds,
// or 504 if M milliseconds pass first. /events?id=ID&delay=D&n=N&ms=M: N
// Server-Sent Events, "ID 1" to "ID N", D milliseconds apart, each within M
// of the one before. 503 when the backend's box is full, or waiting is off.
fn wait_for_backend(req: http::Request, events: bool, st: Transfer&, out: http::Reply) {
    let ms = query_or(req.target, "ms", 5000);
    var j = Job { delay: query_or(req.target, "delay", 0), count: if events { query_or(req.target, "n", 1) } else { 1 },
                  .. };
    let id, has = http::query_of(req.target, "id");
    if has && id.len <= 32 { j.id.append(id); }
    if events {
        st.route = EVENTS;
        st.left = ms;
        http::begin_compressed(out, req, 200, "text/event-stream", st.coded);
        http::field(out, "Cache-Control", "no-cache");
        http::send(out, "");
    } else {
        st.route = LATER;
    }
    j.reply = http::later(out, ms);
    guard http::lane_send_value(backend_lane, if events { JOB_EVENTS } else { JOB_LATER }, j) == http::SENT else {
        if events { http::end_compressed(out, st.coded); } else { http::respond(out, 503, "text/plain", "busy"); }
        return;
    };
}

// /upgrade?id=ID&delay=D&ms=M, upgraded: "ID 1" from the backend after D
// milliseconds, or "timeout" if M milliseconds pass first, among the bytes
// echoed meanwhile. The connection closes when the backend's box is full,
// or waiting is off.
fn upgraded_later(req: http::Request, out: http::Reply) {
    var j = Job { delay: query_or(req.target, "delay", 0), count: 1, .. };
    let id, has = http::query_of(req.target, "id");
    if has && id.len <= 32 { j.id.append(id); }
    j.reply = http::later(out, query_or(req.target, "ms", 5000));
    if http::lane_send_value(backend_lane, JOB_LATER, j) != http::SENT { http::end(out); }
}

// /delay/MS, HttpArena's async profile: MS, as text, after MS milliseconds
// on the worker's timer table, with no other thread. Needs waiting on
// (MAIL_SLOTS); without it the timer runs out at once. With open, the
// response begins at once, chunked, and MS comes as its body.
fn delay(req: http::Request, ms: const u8[:], st: Transfer&, out: http::Reply) {
    let n, ok = parse_int(ms);
    guard ok && n >= 0 && n <= 3600000 else {
        http::start(out, 404);
        http::finish(out, http::NO_TYPE, "");
        return;
    }
    st.route = DELAY;
    st.count = n;
    let _, open = http::query_of(req.target, "open");
    if open {
        st.left = 1;
        http::begin(out, 200, -1);
        http::field(out, "Content-Type", "text/plain");
        http::send(out, "");
    }
    http::later(out, n);
}

fn query_or(target: const u8[:], key: const u8[:], otherwise: i64) -> i64 {
    let v, has = http::query_of(target, key);
    guard has else { return otherwise; }
    let n, ok = parse_int(v);
    return if ok { n } else { otherwise };
}

fn client(req: http::Request, out: http::Reply) {
    var text: u8[>..] = [];
    let p, known = http::peer(out);
    let loopback, ok = http::network("127.0.0.0/8");
    let c, found = http::client(req, out, [loopback]);
    if known && found {
        text.append("peer ");
        http::format_address(text, p);
        format(text, " ", p.port, "\nclient ");
        http::format_address(text, c);
        text.push('\n');
    }
    http::respond(out, if known && found { 200 } else { 500 }, "text/plain", text);
}

// /ws: echoes each message of the WebSocket, and frees it at CLOSED. A
// function, not in handle: a call with a block in the inlined handler changes
// how Goose inlines the loop's call of it, which cost every request about 117
// instructions (task 055).
fn echo_frames(ev: http::Event, st: Transfer&, out: http::Reply) {
    http::ws_read(ev, sockets[st.ws], out) { op, data, o => http::ws_send(o, op, data); };
    if ev.kind == http::CLOSED {
        if free_count < free_sockets.len { free_sockets[free_count] = st.ws; } else { free_sockets.push(st.ws); }
        free_count++;
    }
}

// /ws's upgrade. A function, not in handle: written there, it cost each
// plaintext request 12 instructions (gcc on arm64, counted with valgrind).
fn upgrade_ws(req: const http::Request&, st: Transfer&, out: http::Reply) {
    guard http::ws_upgrade(req, spare, out) else { return; }
    st.route = WS;
    st.ws = open_socket();
}

// The WebSocket the next /ws upgrade is admitted into (ws_upgrade), which
// open_socket then moves into sockets. app.goose sets its limit from
// WS_LIMIT before it spawns the workers: HttpArena's echo profiles send 5
// bytes, and Autobahn's test suite up to 16 MiB.
var spare = http::WebSocket { .. };

// The WebSocket ws_upgrade admitted in spare, moved to sockets, and its index
// there.
fn open_socket() -> i64 {
    let taken = spare;
    spare = http::WebSocket { limit: taken.limit, .. };
    if free_count > 0 {
        free_count--;
        let i = free_sockets[free_count];
        sockets[i] = taken;
        return i;
    }
    sockets.push(taken);
    return sockets.len - 1;
}

// A response's line of the access log: the peer, the status, the bytes
// sent, the milliseconds taken, and the target, or "-" for a response that
// ended after REQUEST.
fn logged(ev: http::Event, out: http::Reply) {
    var line: u8[>..] = [];
    let p, known = http::peer(out);
    if known { http::format_address(line, p); } else { line.push('-'); }
    format(line, " ", ev.status, " ", ev.sent, " ", ev.ms, " ");
    line.append(if ev.req.target.len > 0 { ev.req.target } else { "-" });
    print(line);
}

fn take(st: Transfer&, data: const u8[:]) {
    st.count += data.len;
    for b in data { st.sum += b; }
}

// /upload's response: the body's length and the sum of its bytes.
fn uploaded(st: Transfer&, out: http::Reply) {
    var text: u8[..48] = [];
    format(text, st.count, " ", st.sum);
    http::start(out, 200);
    http::finish(out, http::TEXT,text);
}

// The object /json serializes for each request, as TechEmpower's JSON test
// asks.
struct Message { message: const u8[:] }

fn json_object<A>(out: A&, m: Message) {
    out.append("{\"message\":");
    http::json_string(out, m.message);
    out.push('}');
}
