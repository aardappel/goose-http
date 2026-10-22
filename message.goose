// HTTP/1.1 on bytes alone: the request parser, the Date header, and the
// responses. Nothing here makes a system call, and of the package's files it
// needs only mail.goose's MailAddress, so bench/parse.sh builds it with those.
namespace http;

import std;
import mail;

// The longest request head (the request line, the header fields, and the
// blank line), unless parse's caller sets another. The server's read buffer
// is this size, so a head always fits whole; one that doesn't is refused
// with 431.
let MAX_HEAD = 8192;
// Longer request lines are refused with 414, longer methods with 400. RFC
// 9112 §3 recommends taking request lines of 8000 octets.
let MAX_LINE = 8000;
let MAX_METHOD = 16;
// More header fields than this are refused with 431.
let MAX_FIELDS = 100;
// A Content-Length body longer than this, unless parse's caller sets another
// limit, is refused with 413. The server answers a body that fits in its read
// buffer with the head once it's whole, and drops a longer one as it arrives.
// A chunked body must fit, or it's refused with 413 too.
let MAX_BODY = 1048576;

// parse's status for a buffer that holds only the start of a request.
let INCOMPLETE = 0;

// Where find_any stops a field value: a byte below ' ', DEL, or above. Being
// the complement of one range, the set is searched 16 bytes at a time
// (docs/stdlib.md, "Byte sets"); parse's byte loop then takes a tab or
// obs-text and goes on.
let VALUE_END = value_end_set();

fn value_end_set() -> ByteSet {
    var m = [false; 256];
    for i in 256 { m[i] = i < 32 || i >= 127; }
    return byte_set(m);
}

// Where find_any stops a request target: a byte that isn't visible ASCII,
// or a '%', so that parse checks the escapes only of a target that has one.
let TARGET_END = target_end_set();

fn target_end_set() -> ByteSet {
    var m = [false; 256];
    for i in 256 { m[i] = i <= 32 || i >= 127 || i == '%'; }
    return byte_set(m);
}

// A parsed request head. The slices point into the buffer it was parsed from.
struct Request {
    method: const u8[:],
    target: const u8[:],     // as sent: the path and any query
    minor: i32,              // the x of HTTP/1.x
    keep_alive: bool,
    body: i64,               // Content-Length, 0 without one
    chunked: bool,           // Transfer-Encoding: chunked
    expect: bool,            // Expect: 100-continue, in HTTP/1.1
    len: i64,                // bytes of the head, the blank line included
    fields: const u8[:],     // the header field lines, each with its CRLF
}

// Parses the request head at the start of buf, which may hold max_head bytes
// of it and announce a body of max_body. Returns the request and 200 once the
// whole head is there, INCOMPLETE until then, or the status to refuse it with. Lines end in CRLF only: a bare LF is 400, which
// RFC 9112 §2.2 allows. Inline: each loop's answer calls it, and gcc keeps a
// call to a function this size with several callers, about 90 instructions
// per request.
inline fn parse(buf: const u8[:], max_head: i64 = MAX_HEAD, max_body: i64 = MAX_BODY,
                max_line: i64 = MAX_LINE, max_fields: i64 = MAX_FIELDS) -> Request, i32 {
    // Empty lines before the request line are skipped (RFC 9112 §2.2).
    var pos = 0;
    while pos < buf.len && buf[pos] == '\r' {
        guard pos + 1 < buf.len else { return Request { .. }, short(buf, max_head); }
        guard buf[pos + 1] == '\n' else { return Request { .. }, 400; }
        pos += 2;
    }

    // The method, a token, and one space.
    let m0 = pos;
    while pos < buf.len && is_tchar(buf[pos]) { pos++; }
    guard pos - m0 <= MAX_METHOD else { return Request { .. }, 400; }
    guard pos < buf.len else { return Request { .. }, short(buf, max_head); }
    guard pos > m0 && buf[pos] == ' ' else { return Request { .. }, 400; }
    let method = buf[m0..pos];
    pos++;

    // The target, visible ASCII, and one space.
    let t0 = pos;
    let kt = find_any(buf[pos..], TARGET_END);
    if kt > 0 && kt <= buf.len - pos { pos = pos + kt; }
    let escaped = pos < buf.len && buf[pos] == '%';
    while pos < buf.len && buf[pos] > ' ' && buf[pos] < 0x7f { pos++; }
    guard pos - m0 <= max_line else { return Request { .. }, 414; }
    guard pos < buf.len else { return Request { .. }, short(buf, max_head); }
    guard pos > t0 && buf[pos] == ' ' else { return Request { .. }, 400; }
    let target = buf[t0..pos];
    pos++;
    // A '%' starts an escape of two hex digits (RFC 3986 §2.1), so that
    // decode can't fail on a target the handler gets.
    guard !escaped || escapes_ok(target) else { return Request { .. }, 400; }

    // The version, HTTP/d.d, and CRLF: ten bytes. Waiting for them would
    // hang a client that ended the line early, so a line end is checked first.
    let rest = buf[pos..];
    if rest.len < 10 {
        guard position(rest, '\n') < 0 else { return Request { .. }, 400; }
        return Request { .. }, short(buf, max_head);
    }
    guard rest[..5] == "HTTP/" && is_digit(rest[5]) && rest[6] == '.' && is_digit(rest[7]) else {
        return Request { .. }, 400;
    }
    guard rest[5] == '1' else { return Request { .. }, 505; }
    guard rest[8] == '\r' && rest[9] == '\n' else { return Request { .. }, 400; }
    let minor: i32 = rest[7] - '0';
    pos += 10;
    guard target[0] == '/' || other_form(method, target) else { return Request { .. }, 400; }

    // The header fields, up to the blank line.
    var r = Request { method: method, target: target, minor: minor, .. };
    let f0 = pos;
    // Counted down, so that max_fields doesn't hold a register through the
    // loop: counted up, the fields cost 7 more instructions per request.
    var fields_left = max_fields;
    var hosts = 0;
    var has_length = false;
    var close = false;
    var keep = false;
    loop {
        guard pos < buf.len else { return Request { .. }, short(buf, max_head); }
        if buf[pos] == '\r' {
            guard pos + 1 < buf.len else { return Request { .. }, short(buf, max_head); }
            guard buf[pos + 1] == '\n' else { return Request { .. }, 400; }
            pos += 2;
            break;
        }
        fields_left--;
        guard fields_left >= 0 else { return Request { .. }, 431; }

        // The name, a token, and a colon right after it. This refuses
        // whitespace before the colon and obsolete line folding (§5.1, §5.2).
        let n0 = pos;
        let kn = find_any(buf[pos..], NAME_END);
        if kn > 0 && kn <= buf.len - pos { pos = pos + kn; }
        while pos < buf.len && is_tchar(buf[pos]) { pos++; }
        guard pos < buf.len else { return Request { .. }, short(buf, max_head); }
        guard pos > n0 && buf[pos] == ':' else { return Request { .. }, 400; }
        let name = buf[n0..pos];
        pos++;

        // The value, without the whitespace around it. Control bytes other
        // than tab aren't allowed in it.
        while pos < buf.len && (buf[pos] == ' ' || buf[pos] == '\t') { pos++; }
        let v0 = pos;
        // Values are most of a request's bytes, so find_any skips to the
        // first byte of VALUE_END. The guard on k is what lets the
        // bounds-check analysis keep pos proven; without it, the write
        // would lose every check on pos in parse.
        let k = find_any(buf[pos..], VALUE_END);
        if k > 0 && k <= buf.len - pos { pos += k; }
        while pos < buf.len && ((buf[pos] >= ' ' && buf[pos] != 0x7f) || buf[pos] == '\t') { pos++; }
        guard pos < buf.len else { return Request { .. }, short(buf, max_head); }
        guard buf[pos] == '\r' else { return Request { .. }, 400; }
        guard pos + 1 < buf.len else { return Request { .. }, short(buf, max_head); }
        guard buf[pos + 1] == '\n' else { return Request { .. }, 400; }
        var v1 = pos;
        while v1 > v0 && (buf[v1 - 1] == ' ' || buf[v1 - 1] == '\t') { v1--; }
        let value = buf[v0..v1];
        pos += 2;

        if eq_fold(name, "content-length") {
            guard value.len > 0 && value.len <= 18 else { return Request { .. }, 400; }
            var n = 0;
            for c in value {
                guard is_digit(c) else { return Request { .. }, 400; }
                n = n * 10 + (c - '0');
            }
            guard !has_length || n == r.body else { return Request { .. }, 400; }
            guard n <= max_body else { return Request { .. }, 413; }
            has_length = true;
            r.body = n;
        } else if eq_fold(name, "transfer-encoding") {
            // Chunked alone, in HTTP/1.1 (RFC 9112 §6.1). A coding after
            // chunked, in this field or another, leaves the body's end
            // unknown, which is 400 (§6.3).
            guard minor > 0 && !r.chunked else { return Request { .. }, 400; }
            if !eq_fold(value, "chunked") { return Request { .. }, codings_status(value); }
            r.chunked = true;
        } else if eq_fold(name, "connection") {
            // A single option, as clients almost always send, skips the split.
            if eq_fold(value, "keep-alive") { keep = true; }
            else if eq_fold(value, "close") { close = true; }
            else {
                each_split(value, ',') {
                    let opt = trim(it);
                    if eq_fold(opt, "close") { close = true; }
                    else if eq_fold(opt, "keep-alive") { keep = true; }
                };
            }
        } else if eq_fold(name, "host") {
            guard is_host(value) else { return Request { .. }, 400; }
            hosts++;
        } else if eq_fold(name, "expect") && minor > 0 {
            // 100-continue is the only expectation (RFC 9110 §10.1.1). An
            // HTTP/1.0 client can't have meant it, so it's ignored there.
            guard eq_fold(value, "100-continue") else { return Request { .. }, 417; }
            r.expect = true;
        }
    }
    // HTTP/1.1 requires exactly one Host (RFC 9112 §3.2).
    guard hosts == 1 || (hosts == 0 && minor == 0) else { return Request { .. }, 400; }
    // Both framings at once are refused, as §6.3 allows, so that no two
    // parsers on the way can disagree on where the message ends.
    guard !(r.chunked && has_length) else { return Request { .. }, 400; }
    r.keep_alive = !close && (minor > 0 || keep);
    r.len = pos;
    r.fields = buf[f0..pos - 2];
    return r, 200;
}

// The value of req's header field name, compared ignoring ASCII case, and
// whether req has it; the first, if it repeats. The value has no whitespace
// around it, and points into the read buffer, so it lasts until the handler
// returns.
fn field_of(req: const Request&, name: const u8[:]) -> const u8[:], bool {
    return field_in(req.fields, name);
}

// The value of field name in fields, field lines that parse or read_body
// checked, each ending in CRLF, as a request's or its trailers (Event).
fn field_in(fields: const u8[:], name: const u8[:]) -> const u8[:], bool {
    var pos = 0;
    while pos < fields.len {
        let n, v, next = field_at(fields, pos);
        if same_name(n, name) { return v, true; }
        pos = next;
    }
    return "", false;
}

// Calls F(name, value) for each of req's header fields, in order, repeated
// ones included: the name as sent, and the value as field_of gives it.
fn each_field<F>(req: const Request&) {
    var pos = 0;
    while pos < req.fields.len {
        let n, v, next = field_at(req.fields, pos);
        F(n, v);
        pos = next;
    }
}

// Where a field line ends, for find_any.
let LINE_END = byte_set("\r");

// The field line at fields[pos..], which parse checked: its name, its value
// without the whitespace around it, and where the next line starts. The
// name's first byte that isn't a token character is its colon. find_any
// scans 16 bytes at a time, where a byte loop over tier C's long lines, a
// bearer token among them, took a fifth of a request's instructions.
fn field_at(fields: const u8[:], pos: i64) -> const u8[:], const u8[:], i64 {
    let line = fields[pos..];
    let colon = find_any(line, NAME_END);
    let end = find_any(line, LINE_END);
    var v0 = colon + 1;
    while v0 < end && (line[v0] == ' ' || line[v0] == '\t') { v0++; }
    var v1 = end;
    while v1 > v0 && (line[v1 - 1] == ' ' || line[v1 - 1] == '\t') { v1--; }
    return line[..colon], line[v0..v1], pos + end + 2;
}

// Whether a and b are the same field name, ignoring the case of ASCII letters.
fn same_name(a: const u8[:], b: const u8[:]) -> bool {
    guard a.len == b.len else { return false; }
    for c, i in a {
        let d = b[i];
        let lc = if c >= 'A' && c <= 'Z' { c + 32 } else { c };
        let ld = if d >= 'A' && d <= 'Z' { d + 32 } else { d };
        guard lc == ld else { return false; }
    }
    return true;
}

// Whether target, which doesn't start with '/', is a form other than
// origin-form that method may take (RFC 9112 §3.2): absolute-form, or "*"
// for OPTIONS. Authority-form, for CONNECT, is refused, as is any other.
fn other_form(method: const u8[:], target: const u8[:]) -> bool {
    if target == "*" { return method == "OPTIONS"; }
    let s = position(target, ':');
    guard s > 0 && target[s..].len > 3 && target[s..s + 3] == "://" else { return false; }
    for c in target[..s] {
        guard c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || is_digit(c) || c == '+' || c == '-' || c == '.' else {
            return false;
        }
    }
    return true;
}

// Whether value is a Host field's: uri-host and an optional port (RFC 9110
// §7.2), with uri-host's bytes (RFC 3986 §3.2.2) and nothing that would end
// it as a URI's authority, such as '@' or '/'. Brackets enclose an IP
// literal, which starts the value. Empty is allowed: a client sends that for
// a URI without an authority (RFC 9112 §3.2). Each request has a Host, so
// a value without brackets is settled by one search.
fn is_host(value: const u8[:]) -> bool {
    guard find_any(value, HOST_STOP) >= 0 else { return true; }
    guard value.len > 0 && value[0] == '[' else { return false; }
    let close = position(value, ']');
    return close > 0 && find_any(value[1..close], HOST_STOP) < 0 &&
        find_any(value[close + 1..], HOST_STOP) < 0 &&
        (close + 1 == value.len || value[close + 1] == ':');
}

// Where find_any stops a Host value: a bracket, or a byte that's neither
// uri-host's nor a port's.
let HOST_STOP = host_stop_set();

fn host_stop_set() -> ByteSet {
    var m = [false; 256];
    for i in 256 {
        let c = i as u8;
        m[i] = !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || is_digit(c) || position("-._~%!$&'()*+,;=:", c) >= 0);
    }
    return byte_set(m);
}

// The status for a Transfer-Encoding value other than chunked: 501 for a
// list of codings that ends in chunked, its only one, which would be valid
// with codings this server implements, and 400 for anything else, such as
// an empty value or element, or chunked not last (RFC 9112 §6.3).
fn codings_status(value: const u8[:]) -> i32 {
    var n = 0;
    var chunked = -1;
    var bad = value.len == 0;
    each_split(value, ',') {
        let c = trim(it);
        if c.len == 0 || chunked >= 0 { bad = true; }
        for b in c { if !is_tchar(b) { bad = true; } }
        if eq_fold(c, "chunked") { chunked = n; }
        n++;
    };
    return if !bad && chunked == n - 1 { 501 } else { 400 };
}

// Whether ext is a chunk's extensions, the bytes between its size and the
// line's end (RFC 9112 §7.1.1): each a ';', a token, and an optional '=' and
// a token or a quoted string, with optional whitespace around ';' and '='.
fn is_chunk_ext(ext: const u8[:]) -> bool {
    var i = 0;
    while i < ext.len {
        while i < ext.len && (ext[i] == ' ' || ext[i] == '\t') { i++; }
        guard i < ext.len && ext[i] == ';' else { return false; }
        i++;
        while i < ext.len && (ext[i] == ' ' || ext[i] == '\t') { i++; }
        let n0 = i;
        while i < ext.len && is_tchar(ext[i]) { i++; }
        guard i > n0 else { return false; }
        var j = i;
        while j < ext.len && (ext[j] == ' ' || ext[j] == '\t') { j++; }
        if j < ext.len && ext[j] == '=' {
            i = j + 1;
            while i < ext.len && (ext[i] == ' ' || ext[i] == '\t') { i++; }
            if i < ext.len && ext[i] == '"' {
                i++;
                while i < ext.len && ext[i] != '"' {
                    if ext[i] == '\\' { i++; }
                    i++;
                }
                guard i < ext.len else { return false; }
                i++;
            } else {
                let v0 = i;
                while i < ext.len && is_tchar(ext[i]) { i++; }
                guard i > v0 else { return false; }
            }
        }
    }
    return true;
}

// The status for a head that has only partly arrived: wait for the rest,
// unless it can't fit.
fn short(buf: const u8[:], max_head: i64) -> i32 {
    if buf.len >= max_head { 431 } else { INCOMPLETE }
}

fn is_digit(c: u8) -> bool { c >= '0' && c <= '9' }

fn is_hex(c: u8) -> bool { is_digit(c) || (c | 32) >= 'a' && (c | 32) <= 'f' }

// Frames the body of req at the start of rest, the bytes after its head,
// where a buffer of room bytes after the head must hold it whole. Returns the
// body's length on the wire and 200 once it has all arrived, INCOMPLETE until
// then, or the status to refuse the request with.
fn frame_body(rest: const u8[:], req: const Request&, room: i64) -> i64, i32 {
    if req.chunked {
        let n, status = chunked_len(rest, room);
        if status == INCOMPLETE && rest.len >= room { return 0, 413; }
        return n, status;
    }
    guard req.body <= room else { return 0, 413; }
    if rest.len < req.body { return 0, INCOMPLETE; }
    return req.body, 200;
}

// Measures the chunked body at the start of buf (RFC 9112 §7.1): its length on
// the wire and 200, INCOMPLETE, or 400, or 413 once a chunk's size shows that
// the body won't fit in room bytes. Chunk extensions and trailer fields are
// allowed and skipped, once their syntax is checked.
fn chunked_len(buf: const u8[:], room: i64 = 1 << 62) -> i64, i32 {
    var pos = 0;
    loop {
        let s0 = pos;
        while pos < buf.len && is_hex(buf[pos]) { pos++; }
        guard pos - s0 <= 15 else { return 0, 400; }
        guard pos < buf.len else { return 0, INCOMPLETE; }
        // Whitespace may come before an extension's ';' (BWS, RFC 9112 §7.1.1),
        // which is_chunk_ext checks.
        guard pos > s0 && (buf[pos] == ';' || buf[pos] == '\r' || buf[pos] == ' ' || buf[pos] == '\t')
        else { return 0, 400; }
        let size, ok = parse_int(buf[s0..pos], 16);
        let e = line_end(buf, pos);
        guard e > 0 else { return 0, if e == 0 { INCOMPLETE } else { 400 }; }
        guard is_chunk_ext(buf[pos..e - 2]) else { return 0, 400; }
        pos = e;
        guard size < room - pos else { return 0, 413; }
        if size == 0 {
            let e = trailer_end(buf, pos);
            guard e > 0 else { return 0, if e == 0 { INCOMPLETE } else { 400 }; }
            return e, 200;
        }
        guard buf.len - pos >= size + 2 else { return 0, INCOMPLETE; }
        pos += size;
        guard buf[pos] == '\r' && buf[pos + 1] == '\n' else { return 0, 400; }
        pos += 2;
    }
}

// The index after the CRLF that ends the line at pos, 0 if it hasn't arrived,
// or -1 if the line holds a control byte other than tab.
fn line_end(buf: const u8[:], pos: i64) -> i64 {
    var i = pos;
    while i < buf.len && ((buf[i] >= ' ' && buf[i] != 0x7f) || buf[i] == '\t') { i++; }
    if i + 1 >= buf.len { return if i < buf.len && buf[i] != '\r' { -1 } else { 0 }; }
    return if buf[i] == '\r' && buf[i + 1] == '\n' { i + 2 } else { -1 };
}

// The index after the blank line that ends the trailer section at pos, 0
// until it has all arrived, or -1 if a line isn't a field line: a token, a
// colon, and a value without control bytes but tab.
fn trailer_end(buf: const u8[:], pos: i64) -> i64 {
    var p = pos;
    loop {
        guard p < buf.len else { return 0; }
        if buf[p] == '\r' {
            guard p + 1 < buf.len else { return 0; }
            return if buf[p + 1] == '\n' { p + 2 } else { -1 };
        }
        var q = p;
        while q < buf.len && is_tchar(buf[q]) { q++; }
        guard q < buf.len else { return 0; }
        guard q > p && buf[q] == ':' else { return -1; }
        let e = line_end(buf, q);
        guard e > 0 else { return e; }
        p = e;
    }
}

// Decodes, in place, a chunked body that chunked_len accepted: the data moves
// to the front of buf. Returns its length, and where its trailer section
// starts, which ends 2 bytes before buf does.
fn dechunk(buf: u8[:]) -> i64, i64 {
    var pos = 0;
    var n = 0;
    loop {
        let s0 = pos;
        while is_hex(buf[pos]) { pos++; }
        let size, ok = parse_int(buf[s0..pos], 16);
        while buf[pos] != '\n' { pos++; }
        pos++;
        if size == 0 { return n, pos; }
        copy_into(buf[n..n + size], buf[pos..pos + size]);
        n += size;
        pos += size + 2;
    }
}

// What of a request body is still to arrive, between reads: nothing, the rest
// of a Content-Length body, or a chunked body's next size line, data, CRLF
// after the data, or trailer section, with the bytes of the body or the chunk
// still to come where they count.
enum BodyReader {
    None,
    Length { left: i64 },
    ChunkSize,
    ChunkData { left: i64 },
    ChunkEnd,
    ChunkTrailer,
    // After an upgrade (http::upgrade): every byte, to the end of the
    // connection.
    Raw,
}

fn raw(s: const Stream&) -> bool {
    return s.framing == Framing.Raw || s.framing == Framing.RawDrain;
}

// Requests one DRAINED after the bytes sent on this upgraded connection have
// left the loop's output queue. Call after send/ws_send and wait for DRAINED
// before accepting another bounded batch. This is socket acceptance, not an
// acknowledgement from the peer. Repeated requests coalesce; closing cancels it.
fn after_drain(out: Reply) -> bool {
    guard out.stream.open && raw(out.stream) && out.stream.moved else { return false; }
    out.stream.framing = Framing.RawDrain;
    out.stream.moved = false;
    return true;
}

// Reads the next bytes of r's body from the start of buf, up to and including
// one run of data, buf[d0..d1]. Returns d0, d1, and 200, with buf[..d1] used
// up; INCOMPLETE, with nothing used, until buf holds a whole size line or
// trailer section; or 400. r is None once the body has ended; a chunked body
// ends with buf[d0..d1] its trailer section, the blank line included, instead
// of data.
fn read_body(buf: const u8[:], r: BodyReader&) -> i64, i64, i32 {
    match r {
        Raw => { return 0, buf.len, if buf.len > 0 { 200 } else { INCOMPLETE }; },
        Length l => {
            let k = min(l.left, buf.len);
            r = if k == l.left { BodyReader.None } else { BodyReader.Length { left: l.left - k } };
            return 0, k, if k > 0 { 200 } else { INCOMPLETE };
        },
        _ => {},
    }
    var pos = 0;
    loop {
        match r {
            ChunkData d => {
                guard pos < buf.len else { break; }
                let k = min(d.left, buf.len - pos);
                r = if k == d.left { BodyReader.ChunkEnd } else { BodyReader.ChunkData { left: d.left - k } };
                return pos, pos + k, 200;
            },
            ChunkEnd => {
                guard buf.len - pos >= 2 else { break; }
                guard buf[pos] == '\r' && buf[pos + 1] == '\n' else { return 0, 0, 400; }
                pos += 2;
                r = BodyReader.ChunkSize;
            },
            ChunkSize => {
                let s0 = pos;
                var p = pos;
                while p < buf.len && is_hex(buf[p]) { p++; }
                guard p - s0 <= 15 else { return 0, 0, 400; }
                guard p < buf.len else { break; }
                guard p > s0 && (buf[p] == ';' || buf[p] == '\r' || buf[p] == ' ' || buf[p] == '\t')
                else { return 0, 0, 400; }
                let e = line_end(buf, p);
                guard e >= 0 else { return 0, 0, 400; }
                guard e > 0 else { break; }
                guard is_chunk_ext(buf[p..e - 2]) else { return 0, 0, 400; }
                let size, ok = parse_int(buf[s0..p], 16);
                pos = e;
                r = if size == 0 { BodyReader.ChunkTrailer } else { BodyReader.ChunkData { left: size } };
            },
            ChunkTrailer => {
                // The trailer section goes to the handler whole, so it waits
                // until it has all arrived.
                let e = trailer_end(buf, pos);
                guard e >= 0 else { return 0, 0, 400; }
                guard e > 0 else { break; }
                r = BodyReader.None;
                return pos, e, 200;
            },
            None, Length, Raw => { return 0, 0, 200; },
        }
    }
    // Out of bytes before any data: what was used, if anything.
    return pos, pos, if pos > 0 { 200 } else { INCOMPLETE };
}

// A token character (RFC 9110 §5.6.2): bit c of TCHAR_LO, or of TCHAR_HI
// for c from 64 to 127.
let TCHAR_LO: u64 = 0x03ff6cfa00000000;   // ! # $ % & ' * + - . 0-9
let TCHAR_HI: u64 = 0x57ffffffc7fffffe;   // A-Z ^ _ ` a-z | ~

fn is_tchar(c: u8) -> bool {
    let mask = if c < 64 { TCHAR_LO } else if c < 128 { TCHAR_HI } else { 0 };
    (mask >> (c & 63)) & 1 != 0
}

// Where find_any stops a field name: a byte that isn't a token character.
let NAME_END = name_end_set();

fn name_end_set() -> ByteSet {
    var m = [false; 256];
    for i in 256 { m[i] = !is_tchar(i as u8); }
    return byte_set(m);
}

// Whether a equals lower, ignoring the case of ASCII letters in a. lower
// must hold only lowercase letters and '-', and a no control bytes but tab:
// then c | 32 equals a byte of lower only where c does, ignoring case.
inline fn eq_fold(a: const u8[:], lower: const u8[:]) -> bool {
    guard a.len == lower.len else { return false; }
    for c, i in a {
        if c | 32 != lower[i] { return false; }
    }
    return true;
}

// The writers below take out as A&, a growable or limited u8 array. A
// limited array is a fixed-size value, so an untyped parameter would get a
// copy of it.

// The target's path, without its query, and in absolute-form without its
// scheme and authority, or "/" when it has no path (RFC 9112 §3.2.2).
fn path_of(target: const u8[:]) -> const u8[:] {
    var t = target;
    if t.len > 0 && t[0] != '/' {
        let s = position(t, ':');
        guard s >= 0 && t.len - s >= 3 else { return t; }
        t = t[s + 3..];
        var p = 0;
        while p < t.len && t[p] != '/' && t[p] != '?' { p++; }
        t = t[p..];
        guard t.len > 0 && t[0] == '/' else { return "/"; }
    }
    let q = position(t, '?');
    return if q >= 0 { t[..q] } else { t };
}

// The request's authority, host and port: an absolute-form target's, which
// a server uses instead of Host (RFC 9112 §3.2.2), or else Host's, or "".
fn authority(req: const Request&) -> const u8[:] {
    let t = req.target;
    if t.len > 0 && t[0] != '/' && t != "*" {
        let s = position(t, ':');
        if s >= 0 && t.len - s >= 3 {
            let rest = t[s + 3..];
            var p = 0;
            while p < rest.len && rest[p] != '/' && rest[p] != '?' { p++; }
            return rest[..p];
        }
    }
    let host, has = field_of(req, "host");
    return if has { host } else { t[..0] };
}

// Whether method is one that RFC 9110 §9 defines, or PATCH (RFC 5789). A
// server answers a method it doesn't recognize with 501 (§9.1).
fn known_method(method: const u8[:]) -> bool {
    return method == "GET" || method == "HEAD" || method == "POST" || method == "PUT" ||
        method == "DELETE" || method == "CONNECT" || method == "OPTIONS" || method == "TRACE" ||
        method == "PATCH";
}

// The integer value of key in target's query, and whether the query has it
// as an integer: 0 and false when it's missing or isn't one.
fn query_int(target: const u8[:], key: const u8[:]) -> i64, bool {
    let v, found = query_of(target, key);
    guard found else { return 0, false; }
    let n, ok = parse_int(v);
    guard ok else { return 0, false; }
    return n, true;
}

// The value of key in target's query, and whether the query has it; the
// first, if it repeats. Both are compared and given as sent, still encoded:
// decode the value with plus set for a form's query. A key without '=' has
// an empty value.
fn query_of(target: const u8[:], key: const u8[:]) -> const u8[:], bool {
    let q = position(target, '?');
    guard q >= 0 else { return "", false; }
    var rest = target[q + 1..];
    loop {
        let amp = position(rest, '&');
        let pair = if amp >= 0 { rest[..amp] } else { rest };
        let eq = position(pair, '=');
        let k = if eq >= 0 { pair[..eq] } else { pair };
        if k == key && pair.len > 0 { return if eq >= 0 { pair[eq + 1..] } else { "" }, true; }
        guard amp >= 0 else { return "", false; }
        rest = rest[amp + 1..];
    }
}

// Calls F(key, value) for each pair of target's query, in order, as query_of
// splits and gives them. Empty pairs, as in "a=1&&b=2", are skipped.
fn each_query<F>(target: const u8[:]) {
    let q = position(target, '?');
    guard q >= 0 else { return; }
    each_form(target[q + 1..]) { k, v => F(k, v); };
}

// Calls F(key, value) for each pair of an application/x-www-form-urlencoded
// body, as each_query gives a query's: in order, still encoded, for decode
// with plus set. A body longer than the read buffer comes in pieces, which
// the handler joins first.
fn each_form<F>(body: const u8[:]) {
    each_split(body, '&') {
        if it.len > 0 {
            let eq = position(it, '=');
            if eq >= 0 { F(it[..eq], it[eq + 1..]); } else { F(it, ""); }
        }
    };
}

// Appends s to out with its percent-escapes decoded (RFC 3986 §2.1), and with
// '+' as a space when plus is set, as in a form's query
// (application/x-www-form-urlencoded). False, with out holding what came
// before, for a '%' without two hex digits after it, which parse refuses in
// a target. A decoded path can hold '/' and '?' that weren't separators, so
// split a path before decoding it.
fn decode(s: const u8[:], out: u8[>..]&, plus: bool = false) -> bool {
    var i = 0;
    while i < s.len {
        let c = s[i];
        if c == '%' {
            guard i + 2 < s.len && hex(s[i + 1]) >= 0 && hex(s[i + 2]) >= 0 else { return false; }
            out.push((hex(s[i + 1]) * 16 + hex(s[i + 2])) as u8);
            i += 3;
        } else {
            out.push(if plus && c == '+' { ' ' } else { c });
            i++;
        }
    }
    return true;
}

// Whether each '%' in s starts an escape of two hex digits.
fn escapes_ok(s: const u8[:]) -> bool {
    for c, i in s {
        if c == '%' && (i + 2 >= s.len || hex(s[i + 1]) < 0 || hex(s[i + 2]) < 0) { return false; }
    }
    return true;
}

// The value of hex digit c, or -1.
fn hex(c: u8) -> i32 {
    if c >= '0' && c <= '9' { return c - '0'; }
    if c >= 'a' && c <= 'f' { return c - 'a' + 10; }
    if c >= 'A' && c <= 'F' { return c - 'A' + 10; }
    return -1;
}

// What a handler writes its response into: the worker's write buffer, which
// grows to take a response of any size, and what the response's framing
// needs from the request. A handler writes one whole response, with start,
// field, and finish, or with respond; or opens one with begin, and writes its
// body in pieces with send until end.
//
// common is the fields start writes after each status line, as they are:
// Server and Date, which the loop renders once a second. A handler may set
// it to add fields to every response it writes through out: to whole field
// lines, each ending in CRLF and none empty, after the loop's, as
// "Server: goose\r\nDate: ...\r\nX-Frame-Options: DENY\r\n". out is the
// handler's copy, so the change holds for the starts given out after it, in
// the functions it calls included, until the handler returns; the next call
// gets the loop's fields again, and the responses the loop writes itself,
// such as a 400 for a request it couldn't parse, never get it. start copies
// the bytes, so they need last only until then. Check a value from the
// request with is_field first, as field would.
struct Reply {
    buf: u8[>..]&,
    common: const u8[:],
    keep_alive: bool&,      // whether the connection stays open; clear it before start to close
    minor: i32,             // the request's x of HTTP/1.x, or H2_MINOR on an HTTP/2 stream
    head: bool,             // a HEAD request: finish writes the body's fields, not the body
    stream: Stream&,        // what start and begin leave for the writers after them
    fd: i32 = -1,           // the connection's socket, for peer; -1 for none
}

// Reply.minor on an HTTP/2 stream, whose HTTP/1.1 response h2.goose turns into
// frames: begin writes no chunks, and upgrade answers 501.
let H2_MINOR: i32 = 100;

// The framing of the response being written.
// How a response's body ends: after a Content-Length, with the bytes still to
// send; with a zero-length chunk; when the connection closes, as in HTTP/1.0
// without a length; or, upgraded, with the connection, send writing bytes as
// they are.
enum Framing {
    Length { left: i64 },
    Chunked,
    Close,
    Raw,
    RawDrain,
}

struct Stream {
    bodyless: bool = false, // a status that has no body
    open: bool = false,     // begun and not yet ended
    in_head: bool = false,  // begun, without the blank line after the head yet
    moved: bool = false,    // send was given bytes, which HEAD and a bodyless status drop
    framing: Framing = Framing.Close,
    status: i32 = 0,        // what start was last given
    // later's: the exchange waits for a WAKE or its TIMEOUT, and rearm says
    // the loop has yet to start wait_ms's timer. later is the exchange's
    // address, which the loop sets when it has a box (Config.mail_slots),
    // and live says the box accepts sends to it.
    waiting: bool = false,
    rearm: bool = false,
    wait_ms: i64 = 0,
    later: MailAddress = MailAddress { .. },
    live: bool = false,
    // direct: the loop sends files itself (serve_epoll on Linux, with
    // sendfile). send_file then gives it file, open, and file_left bytes of
    // it from file_off, which follow buf; the loop answers nothing more
    // until they're sent, and closes file.
    direct: bool = false,
    file: i64 = -1,
    file_off: i64 = 0,
    file_left: i64 = 0,
}

// The writers below are inline, so that a handler's constant status picks
// its status line at compile time and its appends reach the write buffer
// directly; as calls they cost about 190 instructions per request.

// The status line and the fields every response has: Server, unless
// Config.server is empty, Date, and Connection where HTTP/1.x's default isn't
// what the connection does.
inline fn start(out: Reply, status: i32) {
    out.stream.status = status;
    out.stream.bodyless = status < 200 || status == 204 || status == 304;
    status_fields(out.buf, status, out.common, out.keep_alive, out.minor);
}

// A field of the handler's own, between start and finish, or begin and the
// first send, and whether it was written. A field that is_field refuses is
// dropped, so that a value from the request can't split the response: check
// with is_field first to answer otherwise. The fields given to finish, and
// what a handler appends to out.buf itself, are written as they are, for
// constant text.
inline fn field(out: Reply, name: const u8[:], value: const u8[:]) -> bool {
    guard is_field(name, value) else { return false; }
    out.buf.append(name);
    out.buf.append(": ");
    out.buf.append(value);
    out.buf.append("\r\n");
    return true;
}

// A field added to the response begun at mark, out.buf's length before its
// start, once the response is written: for a value known only then, such as
// Server-Timing's, by code around a handler. The field goes at the end of the
// head, before its blank line, and the bytes after it move up; while begin's
// head is open, it's a field as any other. Returns whether it was added:
// nothing is when nothing was written after mark, or for a field is_field
// refuses.
fn insert_field(out: Reply, mark: i64, name: const u8[:], value: const u8[:]) -> bool {
    guard mark >= 0 && out.buf.len > mark && is_field(name, value) else { return false; }
    let end = find(out.buf[mark..], "\r\n\r\n");
    guard end >= 0 else { return out.stream.in_head && field(out, name, value); }
    let at = mark + end + 2;
    let old = out.buf.len;
    field(out, name, value);
    // Rotates the field, appended last, to at.
    reverse(out.buf[at..old]);
    reverse(out.buf[old..]);
    reverse(out.buf[at..]);
    return true;
}

// finish's fields for the common bodies. A program with fields of its own
// writes them in one string that ends the same way:
// "Allow: GET\r\nContent-Length: ".
// Fixed arrays, in static data, so that an append of one has a length the C
// compiler knows, as a literal's; a global slice is read at run time
// (spec §11.1).
const NO_TYPE: u8[16] = "Content-Length: ";
const TEXT: u8[42] = "Content-Type: text/plain\r\nContent-Length: ";
const JSON: u8[48] = "Content-Type: application/json\r\nContent-Length: ";

// The body's fields, the blank line, and the body, unless the request was
// HEAD. fields holds every field before the length's value, ending in
// "Content-Length: " (NO_TYPE, TEXT, JSON), so that they take one append. A
// 1xx, 204, or 304 status gets neither the length nor the body, whatever they
// are (RFC 9110 §6.4.1, §8.6).
inline fn finish(out: Reply, fields: const u8[:], body: const u8[:]) {
    if out.stream.bodyless {
        out.buf.append(if ends_with(fields, NO_TYPE) { fields[..fields.len - NO_TYPE.len] } else { fields });
        out.buf.append("\r\n");
    } else {
        write_body(out.buf, fields, body, out.head);
    }
}

// A whole response: status, a Content-Type unless content_type is empty, and
// body.
inline fn respond(out: Reply, status: i32, content_type: const u8[:], body: const u8[:]) {
    start(out, status);
    if content_type.len > 0 { field(out, "Content-Type", content_type); }
    finish(out, NO_TYPE, body);
}

// Starts a response whose body the handler sends in pieces, with send, up to
// end: the status line, the fields every response has, and the body's
// framing, before the handler's own fields. length is the body's
// Content-Length, or -1 for a length not known yet, which is chunked in
// HTTP/1.1; HTTP/1.0 has no chunks, so there the body ends when the
// connection closes. A Content-Length body that end leaves short closes the
// connection too, and send drops what goes past it.
fn begin(out: Reply, status: i32, length: i64) {
    if length < 0 && out.minor == 0 { out.keep_alive = false; }
    start(out, status);
    let s .= out.stream;
    s.open = true;
    s.in_head = true;
    s.framing = if length >= 0 { Framing.Length { left: length } }
                else if out.minor > 0 && out.minor != H2_MINOR && !s.bodyless { Framing.Chunked }
                else { Framing.Close };
    if s.bodyless { return; }
    match s.framing {
        Chunked => { out.buf.append("Transfer-Encoding: chunked\r\n"); },
        Length => {
            out.buf.append("Content-Length: ");
            format(out.buf, length);
            out.buf.append("\r\n");
        },
        Close, Raw, RawDrain => {},
    }
}

// Sends the next piece of the body of the response begin started, as one
// chunk if it's chunked. The first send or end ends the head.
fn send(out: Reply, data: const u8[:]) {
    let s .= out.stream;
    guard s.open else { return; }
    if s.in_head {
        out.buf.append("\r\n");
        s.in_head = false;
    }
    guard data.len > 0 else { return; }
    s.moved = true;
    if raw(s) {
        out.buf.append(data);
        return;
    }
    guard !s.bodyless && !out.head else { return; }
    match s.framing {
        Chunked => {
            hex_size(out.buf, data.len);
            out.buf.append("\r\n");
            out.buf.append(data);
            out.buf.append("\r\n");
        },
        Length l => {
            let k = min(l.left, data.len);
            out.buf.append(data[..k]);
            s.framing = Framing.Length { left: l.left - k };
            if k < data.len { out.keep_alive = false; }
        },
        Close, Raw, RawDrain => { out.buf.append(data); },
    }
}

// Ends the response begin started, or after an upgrade, the connection. A
// chunked response ends with trailers, field lines each ending in CRLF, as
// "Digest: x\r\n" (RFC 9112 §7.1.2), less any line field would drop; any
// other response drops them all.
fn end(out: Reply, trailers: const u8[:] = "") {
    let s .= out.stream;
    guard s.open else { return; }
    if raw(s) {
        s.open = false;
        out.keep_alive = false;
        return;
    }
    send(out, "");
    s.open = false;
    guard !s.bodyless && !out.head else { return; }
    match s.framing {
        Chunked => {
            out.buf.append("0\r\n");
            each_split(trailers, "\r\n") {
                if it.len > 0 {
                    let colon = position(it, ':');
                    if colon > 0 { field(out, it[..colon], trim_ows(it[colon + 1..])); }
                }
            };
            out.buf.append("\r\n");
        },
        Length l => { if l.left > 0 { out.keep_alive = false; } },
        Close, Raw, RawDrain => {},
    }
}

// Answers a request that asked to switch to protocol (upgrade_of) with 101,
// and switches the connection to it (RFC 9110 §7.8): the bytes after the
// request go to the handler as BODY, and send writes bytes as they are,
// until end, which closes the connection, or the client closes it. The
// connection then waits idle_ms for the client, not body_ms. HTTP/2 has no
// upgrade (RFC 9113 §8.6), so on an h2 stream it answers 501.
fn upgrade(out: Reply, protocol: const u8[:]) {
    if out.minor == H2_MINOR {
        start(out, 501);
        finish(out, NO_TYPE, "");
        return;
    }
    start(out, 101);
    field(out, "Connection", "Upgrade");
    field(out, "Upgrade", protocol);
    out.buf.append("\r\n");
    switched(out);
}

// Switches out's stream to an upgraded protocol's bytes, once a 101's head is
// written whole.
fn switched(out: Reply) {
    let s .= out.stream;
    s.bodyless = false;
    s.open = true;
    s.framing = Framing.Raw;
}

// The protocols a request asks to switch to, its Upgrade field's value, when
// its Connection field lists upgrade, as RFC 9110 §7.8 requires; or "". Only
// HTTP/1.1 upgrades.
fn upgrade_of(req: const Request&) -> const u8[:] {
    guard req.minor > 0 else { return ""; }
    var asked = false;
    each_field(req) { name, value =>
        if same_name(name, "connection") {
            each_split(value, ',') { if eq_fold(trim(it), "upgrade") { asked = true; } };
        }
    };
    guard asked else { return ""; }
    let v, ok = field_of(req, "upgrade");
    return v;
}

// Appends n, not negative, in hexadecimal.
fn hex_size(out: u8[>..]&, n: i64) {
    var digits = 1;
    while digits < 16 && n >> (digits * 4) != 0 { digits++; }
    var i = digits;
    while i > 0 {
        i--;
        out.push("0123456789abcdef"[(n >> (i * 4)) & 15]);
    }
}

// Writes the response that refuses a request with status. The connection
// closes after it.
fn refuse<A>(out: A&, status: i32, common: const u8[:]) {
    status_fields(out, status, common, false, 1);
    write_body(out, "Content-Length: ", "", false);
}

inline fn status_fields<A>(out: A&, status: i32, common: const u8[:], keep_alive: bool, minor: i32) {
    let line = status_line(status);
    if line.len > 0 {
        out.append(line);
    } else {
        // A status without a reason phrase here gets an empty one (RFC 9112
        // §4).
        out.append("HTTP/1.1 ");
        format(out, status);
        out.append(" \r\n");
    }
    out.append(common);
    if !keep_alive { out.append("Connection: close\r\n"); }
    else if minor == 0 { out.append("Connection: keep-alive\r\n"); }
}

inline fn write_body<A>(out: A&, fields: const u8[:], body: const u8[:], head_only: bool) {
    out.append(fields);
    format(out, body.len);
    out.append("\r\n\r\n");
    if !head_only { out.append(body); }
}

// The status line, or "" for a status not listed here.
inline fn status_line(status: i32) -> const u8[:] {
    match status {
        200 => "HTTP/1.1 200 OK\r\n",
        101 => "HTTP/1.1 101 Switching Protocols\r\n",
        201 => "HTTP/1.1 201 Created\r\n",
        202 => "HTTP/1.1 202 Accepted\r\n",
        204 => "HTTP/1.1 204 No Content\r\n",
        206 => "HTTP/1.1 206 Partial Content\r\n",
        301 => "HTTP/1.1 301 Moved Permanently\r\n",
        302 => "HTTP/1.1 302 Found\r\n",
        303 => "HTTP/1.1 303 See Other\r\n",
        304 => "HTTP/1.1 304 Not Modified\r\n",
        307 => "HTTP/1.1 307 Temporary Redirect\r\n",
        308 => "HTTP/1.1 308 Permanent Redirect\r\n",
        400 => "HTTP/1.1 400 Bad Request\r\n",
        401 => "HTTP/1.1 401 Unauthorized\r\n",
        403 => "HTTP/1.1 403 Forbidden\r\n",
        404 => "HTTP/1.1 404 Not Found\r\n",
        405 => "HTTP/1.1 405 Method Not Allowed\r\n",
        406 => "HTTP/1.1 406 Not Acceptable\r\n",
        408 => "HTTP/1.1 408 Request Timeout\r\n",
        409 => "HTTP/1.1 409 Conflict\r\n",
        410 => "HTTP/1.1 410 Gone\r\n",
        411 => "HTTP/1.1 411 Length Required\r\n",
        413 => "HTTP/1.1 413 Content Too Large\r\n",
        414 => "HTTP/1.1 414 URI Too Long\r\n",
        415 => "HTTP/1.1 415 Unsupported Media Type\r\n",
        416 => "HTTP/1.1 416 Range Not Satisfiable\r\n",
        417 => "HTTP/1.1 417 Expectation Failed\r\n",
        422 => "HTTP/1.1 422 Unprocessable Content\r\n",
        426 => "HTTP/1.1 426 Upgrade Required\r\n",
        429 => "HTTP/1.1 429 Too Many Requests\r\n",
        431 => "HTTP/1.1 431 Request Header Fields Too Large\r\n",
        500 => "HTTP/1.1 500 Internal Server Error\r\n",
        501 => "HTTP/1.1 501 Not Implemented\r\n",
        502 => "HTTP/1.1 502 Bad Gateway\r\n",
        503 => "HTTP/1.1 503 Service Unavailable\r\n",
        504 => "HTTP/1.1 504 Gateway Timeout\r\n",
        505 => "HTTP/1.1 505 HTTP Version Not Supported\r\n",
        _ => "",
    }
}

// The bytes a JSON string escapes. find_any looks for them 16 bytes at a time,
// where json::format_string tests a byte at a time (docs/goose-findings.md).
let JSON_ESCAPES = json_escapes_set();

fn json_escapes_set() -> ByteSet {
    var m = [false; 256];
    for i in 256 { m[i] = i < 32 || i == '"' || i == '\\'; }
    return byte_set(m);
}

// A JSON string for s, quotes included, as json::format_string writes it:
// \n, \t, \r, \b, and \f in their short forms, and other control bytes as
// \u00XX.
fn json_string<A>(out: A&, s: const u8[:]) {
    out.push('"');
    var pos = 0;
    loop {
        let k = find_any(s[pos..], JSON_ESCAPES);
        if k < 0 { break; }
        let at = pos + k;
        out.append(s[pos..at]);
        let c = s[at];
        if c == '"' || c == '\\' {
            out.push('\\');
            out.push(c);
        } else if c == '\n' {
            out.append("\\n");
        } else if c == '\t' {
            out.append("\\t");
        } else if c == '\r' {
            out.append("\\r");
        } else if c == 8 {
            out.append("\\b");
        } else if c == 12 {
            out.append("\\f");
        } else {
            out.append("\\u00");
            out.push("0123456789abcdef"[c >> 4]);
            out.push("0123456789abcdef"[c & 15]);
        }
        pos = at + 1;
    }
    out.append(s[pos..]);
    out.push('"');
}

// Appends the field lines every response has, but Connection: Server, when
// server isn't empty, and Date at t. The loops render them once a second, so
// that they cost a response one append, and an HTTP/1.1 keep-alive response
// needs no other: a third append, of the CRLF alone, cost 25-30
// instructions per request.
fn common_fields<A>(out: A&, server: const u8[:], t: i64) {
    if server.len > 0 {
        out.append("Server: ");
        out.append(server);
        out.append("\r\n");
    }
    out.append("Date: ");
    format_date(out, t);
    out.append("\r\n");
}

// Whether a response can carry the field name: value. The name is a token
// (RFC 9110 §5.1), and the value as is_field_value takes it.
fn is_field(name: const u8[:], value: const u8[:]) -> bool {
    return name.len > 0 && find_any(name, NAME_END) < 0 && is_field_value(value);
}

// s without the spaces and tabs around it.
fn trim_ows(s: const u8[:]) -> const u8[:] {
    var a = 0;
    while a < s.len && (s[a] == ' ' || s[a] == '\t') { a++; }
    var b = s.len;
    while b > a && (s[b - 1] == ' ' || s[b - 1] == '\t') { b--; }
    return s[a..b];
}

// Whether s can be a field's value: visible bytes, spaces, and tabs, with
// none at its ends (RFC 9110 §5.5).
fn is_field_value(s: const u8[:]) -> bool {
    for c in s {
        guard (c >= ' ' && c != 0x7f) || c == '\t' else { return false; }
    }
    return s.len == 0 || (s[0] > ' ' && s[s.len - 1] > ' ');
}

// Appends t, in seconds since the epoch and not negative, as an HTTP date
// (RFC 9110 §5.6.7): "Sat, 10 Oct 2026 12:00:00 GMT", 29 bytes.
fn format_date<A>(out: A&, t: i64) {
    let days = t / 86400;
    let secs = t % 86400;
    // The civil date of a day count, by Howard Hinnant's days_from_civil
    // inverse: a 400-year era, then March-based years, so leap days fall last.
    let z = days + 719468;
    let era = z / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + (if month <= 2 { 1 } else { 0 });

    // 1970-01-01 was a Thursday.
    let w = (days + 4) % 7 * 3;
    out.append("SunMonTueWedThuFriSat"[w..w + 3]);
    out.append(", ");
    two_digits(out, day);
    out.push(' ');
    let m = (month - 1) * 3;
    out.append("JanFebMarAprMayJunJulAugSepOctNovDec"[m..m + 3]);
    out.push(' ');
    two_digits(out, year / 100);
    two_digits(out, year % 100);
    out.push(' ');
    two_digits(out, secs / 3600);
    out.push(':');
    two_digits(out, secs / 60 % 60);
    out.push(':');
    two_digits(out, secs % 60);
    out.append(" GMT");
}

fn two_digits<A>(out: A&, v: i64) {
    out.push(('0' + v / 10) as u8);
    out.push(('0' + v % 10) as u8);
}

// Whether a GET or HEAD for a representation with entity tag etag (quotes
// included, as in "\"v1\"", or "" for none) and last modified at modified
// (seconds since the epoch, or -1 for unknown) is answered with 304 (RFC 9110
// §13.1.2, §13.1.3, §13.2.2): If-None-Match lists etag, by the weak
// comparison, or is "*"; or, only without If-None-Match, If-Modified-Since
// is a date at or after modified.
fn not_modified(req: const Request&, etag: const u8[:], modified: i64) -> bool {
    let tags, has_tags = field_of(req, "if-none-match");
    if has_tags {
        guard etag.len > 0 else { return false; }
        if trim(tags) == "*" { return true; }
        var hit = false;
        each_split(tags, ',') {
            if weak_eq(trim(it), etag) { hit = true; }
        };
        return hit;
    }
    let since, has_since = field_of(req, "if-modified-since");
    guard has_since && modified >= 0 else { return false; }
    let t, ok = parse_date(since);
    return ok && modified <= t;
}

// Whether entity tags a and b are the same, ignoring a W/ before either
// (RFC 9110 §8.8.3.2, the weak comparison).
fn weak_eq(a: const u8[:], b: const u8[:]) -> bool {
    let x = if starts_with(a, "W/") { a[2..] } else { a };
    let y = if starts_with(b, "W/") { b[2..] } else { b };
    return x.len >= 2 && x == y;
}

// The bytes of a representation of size bytes that req's Range field asks
// for, as start and end (exclusive), and the status to answer with: 206 for
// one satisfiable range, 416 for a range past the end, and 200 for the whole,
// when there's no Range, it isn't one range of bytes, or If-Range names
// another entity tag than etag (RFC 9110 §14.2, §14.4, §13.1.5). A 206 gets
// a Content-Range field: content_range writes it.
fn range_of(req: const Request&, size: i64, etag: const u8[:]) -> i64, i64, i32 {
    let spec, has = field_of(req, "range");
    guard has && starts_with(spec, "bytes=") else { return 0, size, 200; }
    let cond, has_cond = field_of(req, "if-range");
    // The strong comparison, which If-Range asks for: a weak tag never matches.
    guard !has_cond || (etag.len >= 2 && !starts_with(etag, "W/") && cond == etag) else {
        return 0, size, 200;
    }
    let r = trim(spec[6..]);
    let dash = position(r, '-');
    guard dash >= 0 && position(r, ',') < 0 else { return 0, size, 200; }
    let first = r[..dash];
    let last = r[dash + 1..];
    guard digits_only(first) && digits_only(last) && (first.len > 0 || last.len > 0) else {
        return 0, size, 200;
    }
    if first.len == 0 {
        // The last n bytes.
        let n, ok = parse_int(last);
        guard ok && n > 0 && size > 0 else { return 0, 0, 416; }
        return max(size - n, 0), size, 206;
    }
    let a, ok_a = parse_int(first);
    guard ok_a && a < size else { return 0, 0, 416; }
    if last.len == 0 { return a, size, 206; }
    let b, ok_b = parse_int(last);
    guard ok_b && b >= a else { return 0, size, 200; }
    return a, min(b + 1, size), 206;
}

fn digits_only(s: const u8[:]) -> bool {
    guard s.len <= 18 else { return false; }
    for c in s { if !is_digit(c) { return false; } }
    return true;
}

// The Content-Range field of a 206 for bytes start to end (exclusive) of
// size, or of a 416 when start == end == 0 (RFC 9110 §14.4).
fn content_range(out: Reply, start: i64, end: i64, size: i64) {
    out.buf.append("Content-Range: bytes ");
    if end > start {
        format(out.buf, start, "-", end - 1, "/", size);
    } else {
        format(out.buf, "*/", size);
    }
    out.buf.append("\r\n");
}

// Seconds since the epoch of an HTTP date in IMF-fixdate form, as
// format_date writes it ("Sat, 10 Oct 2026 12:00:00 GMT"), and whether it is
// one. The obsolete RFC 850 and asctime forms, which RFC 9110 §5.6.7 asks a
// recipient to accept, aren't: a condition with one is ignored.
fn parse_date(s: const u8[:]) -> i64, bool {
    guard s.len == 29 && s[3] == ',' && s[4] == ' ' && s[7] == ' ' && s[11] == ' ' &&
          s[16] == ' ' && s[19] == ':' && s[22] == ':' && s[25..] == " GMT" else { return 0, false; }
    var month = -1;
    for i in 12 {
        if "JanFebMarAprMayJunJulAugSepOctNovDec"[i * 3..i * 3 + 3] == s[8..11] { month = i + 1; }
    }
    let day, ok1 = parse_int(s[5..7]);
    let year, ok2 = parse_int(s[12..16]);
    let hh, ok3 = parse_int(s[17..19]);
    let mm, ok4 = parse_int(s[20..22]);
    let ss, ok5 = parse_int(s[23..25]);
    guard month > 0 && ok1 && ok2 && ok3 && ok4 && ok5 && day >= 1 && day <= 31 &&
          hh < 24 && mm < 60 && ss < 61 else { return 0, false; }
    // Days since the epoch, by Howard Hinnant's days_from_civil, as
    // format_date inverts it.
    let y = if month <= 2 { year - 1 } else { year };
    let era = (if y >= 0 { y } else { y - 399 }) / 400;
    let yoe = y - era * 400;
    let mp = if month > 2 { month - 3 } else { month + 9 };
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    return days * 86400 + hh * 3600 + mm * 60 + ss, true;
}
