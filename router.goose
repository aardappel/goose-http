// A router for a handler's REQUEST: method and path patterns with
// parameters, tried in order in an if chain, and 405 with Allow, or 404,
// from the routes that didn't match. Nothing allocates: the parameters are
// slices of the target and the patterns.
//
//   var r = http::router(req);
//   if http::on(r, "GET", "/users/:id") { show(http::param(r, "id"), out); }
//   else if http::on(r, "PUT", "/users/:id") { ... }
//   else if http::on(r, "GET", "/files/*path") { ... }
//   else { http::otherwise(r, out); }
namespace http;

import std;
import message;

// The most parameters a pattern captures.
let MAX_PARAMS = 8;

struct Param { name: const u8[:], value: const u8[:] }

struct Router {
    method: const u8[:],
    path: const u8[:],           // the target's path, still encoded
    params: Param[..MAX_PARAMS],  // the last matched route's
    allow: u8[..96],             // methods of routes whose path matched, ", " between
    bad: bool,                   // a path no route takes: otherwise answers 400
}

// A router for req, whose slices it keeps: it lasts until the handler returns.
// A path with a "." or ".." segment, escaped or not, or an escaped control
// byte matches no route, so that a handler that checks access by a path's
// prefix can't be walked around it, and a parameter holds neither.
fn router(req: const Request&) -> Router {
    let path = path_of(req.target);
    return Router { method: req.method, path: path, params: [], allow: [], bad: !is_routable(path) };
}

// Whether path, still encoded, has no dot-segment and no escaped control
// byte (RFC 3986 §3.3, §2.1).
fn is_routable(path: const u8[:]) -> bool {
    var start = 0;
    var dots = 0;       // the segment's bytes so far, if all are dots
    var plain = true;   // whether all of them are
    var i = 0;
    while i <= path.len {
        if i == path.len || path[i] == '/' {
            guard !(plain && (dots == 1 || dots == 2)) else { return false; }
            dots = 0;
            plain = true;
            i++;
            continue;
        }
        let c, n = unescaped(path, i);
        guard c >= 0x20 && c != 0x7f || n == 1 else { return false; }
        if c == '.' { dots++; } else { plain = false; }
        i += n;
    }
    return true;
}

// The byte at path[i], with an escape decoded: the byte, and how many bytes
// of path it took, 3 for an escape and 1 otherwise, a '%' without two hex
// digits included.
fn unescaped(path: const u8[:], i: i64) -> u8, i64 {
    if path[i] == '%' && i + 2 < path.len && is_hex(path[i + 1]) && is_hex(path[i + 2]) {
        return (hex(path[i + 1]) * 16 + hex(path[i + 2])) as! u8, 3;
    }
    return path[i], 1;
}

// Whether c may stand for itself in a path (RFC 3986 §2.3), so that its
// escape means the same as it.
fn is_unreserved(c: u8) -> bool {
    return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
        c == '-' || c == '.' || c == '_' || c == '~';
}

// Whether a pattern's literal segment matches a path's, still encoded: an
// escape of an unreserved byte matches the byte (RFC 3986 §6.2.2.2), and any
// other byte only itself.
fn same_segment(lit: const u8[:], seg: const u8[:]) -> bool {
    var i = 0;
    var j = 0;
    while j < seg.len {
        guard i < lit.len else { return false; }
        let c, n = unescaped(seg, j);
        let b = if n == 3 && is_unreserved(c) { c } else { seg[j] };
        let step = if n == 3 && is_unreserved(c) { 3 } else { 1 };
        guard lit[i] == b else { return false; }
        i++;
        j += step;
    }
    return i == lit.len;
}

// Whether req is method on a path pattern matches, with HEAD taken by GET's
// routes. A pattern is segments after '/': a literal, ":name" for one
// segment, or "*name", last, for the rest of the path, empty or not. A
// pattern that matches with another method adds the method to r's Allow.
// The parameters are the path's bytes, still encoded: http::decode decodes
// one.
fn on(r: Router&, method: const u8[:], pattern: const u8[:]) -> bool {
    guard !r.bad && matches(r, pattern) else { return false; }
    if method == r.method || (method == "GET" && r.method == "HEAD") { return true; }
    allow(r, method);
    if method == "GET" { allow(r, "HEAD"); }
    return false;
}

// The value of the matched route's parameter name, or "".
fn param(r: const Router&, name: const u8[:]) -> const u8[:] {
    for p in r.params {
        if p.name == name { return p.value; }
    }
    return "";
}

// The status for a request that no route took: 501 for a method the server
// doesn't know (RFC 9110 §9.1); 400 for a path router refused; 204 for
// OPTIONS *, for the server as a whole (§9.3.7), and for OPTIONS of a path
// some route matched; 405 for another method there; and 404 for a path no
// route matched. A 204 and a 405 carry r.allow in Allow when it isn't empty.
// Calling the form below instead would load the fields before the method's
// compare, and keep them across it: 4 instructions more on each 404.
fn unrouted(r: const Router&) -> i32 {
    if !known_method(r.method) { return 501; }
    if r.bad { return 400; }
    if r.method == "OPTIONS" && r.path == "*" { return 204; }
    if r.allow.len == 0 { return 404; }
    return if r.method == "OPTIONS" { 204 } else { 405 };
}

// The same status for a request routed without a Router: its method, its
// path, whether is_routable(path) holds, and allow, the methods of the
// routes whose path matched, ", " between.
fn unrouted(method: const u8[:], path: const u8[:], routable: bool, allow: const u8[:]) -> i32 {
    if !known_method(method) { return 501; }
    if !routable { return 400; }
    if method == "OPTIONS" && path == "*" { return 204; }
    if allow.len == 0 { return 404; }
    return if method == "OPTIONS" { 204 } else { 405 };
}

// Answers a request that no route took, with unrouted's status. Each arm
// starts a constant status, which the inline writers fold.
fn otherwise(r: const Router&, out: Reply) {
    match unrouted(r) {
        204 => {
            start(out, 204);
            if r.allow.len > 0 { field(out, "Allow", r.allow); }
            finish(out, "", "");
        },
        405 => {
            start(out, 405);
            field(out, "Allow", r.allow);
            finish(out, NO_TYPE, "");
        },
        501 => {
            start(out, 501);
            finish(out, NO_TYPE, "");
        },
        400 => {
            start(out, 400);
            finish(out, NO_TYPE, "");
        },
        _ => {
            start(out, 404);
            finish(out, NO_TYPE, "");
        },
    }
}

fn allow(r: Router&, method: const u8[:]) {
    var at = 0;
    while at < r.allow.len {
        var end = at;
        while end < r.allow.len && r.allow[end] != ',' { end++; }
        if r.allow[at..end] == method { return; }
        at = end + 2;
    }
    guard r.allow.len + method.len + 2 <= r.allow.cap else { return; }
    if r.allow.len > 0 { r.allow.append(", "); }
    r.allow.append(method);
}

// Whether r's path matches pattern, with the parameters in r.params.
fn matches(r: Router&, pattern: const u8[:]) -> bool {
    r.params.clear();
    let path = r.path;
    var p = 0;   // in pattern
    var q = 0;   // in path
    loop {
        if p == pattern.len { return q == path.len; }
        guard q < path.len && pattern[p] == '/' && path[q] == '/' else { return false; }
        p++;
        q++;
        var pe = p;
        while pe < pattern.len && pattern[pe] != '/' { pe++; }
        var qe = q;
        while qe < path.len && path[qe] != '/' { qe++; }
        let seg = pattern[p..pe];
        if seg.len > 0 && seg[0] == '*' {
            guard r.params.len < MAX_PARAMS else { return false; }
            r.params.push(Param { name: seg[1..], value: path[q..] });
            return pe == pattern.len;
        }
        if seg.len > 0 && seg[0] == ':' {
            guard qe > q && r.params.len < MAX_PARAMS else { return false; }
            r.params.push(Param { name: seg[1..], value: path[q..qe] });
        } else {
            guard same_segment(seg, path[q..qe]) else { return false; }
        }
        p = pe;
        q = qe;
    }
}
