// Files as response bodies. A body with a Content-Length goes to the loop,
// which sends it without copying (send_file): serve_epoll with sendfile, and
// serve's ring with splice, TransmitFile, or sendfile. Others are read in
// pieces with pread, as h2o reads them by default. A handler opens a file at REQUEST, answers with
// serve_file, and sends the body with send_file at each MORE, with the
// FileBody in its state:
//
//   if ev.kind == http::REQUEST {
//       let f, status = http::open_file(path);
//       if status != 200 { http::respond(out, status, "text/plain", ""); }
//       else { http::serve_file(ev.req, out, f, http::content_type_of(path), st.file); }
//   } else if ev.kind == http::MORE {
//       if !http::send_file(out, st.file) { http::end(out); }
//   } else if ev.kind == http::CLOSED {
//       http::close_body(st.file);
//   }
//
// open_precompressed in place of open_file serves a .br, .zst, or .gz copy
// made beforehand, by the request's Accept-Encoding; content_type_of still
// takes the original's name.
namespace http;

import std;
import message;
import media;
import sys;

// A file open_file opened: its handle, size in bytes, and modification time
// in seconds since the epoch. open_precompressed also sets the content coding
// it holds, "" for none, and vary, since its choice depends on the request's
// Accept-Encoding.
struct File { fd: i64 = -1, size: i64 = 0, modified: i64 = 0, coding: const u8[:] = "", vary: bool = false }

// The part of a file a response still has to send, kept in the handler's
// state between MORE events. fd is -1 once closed.
struct FileBody { fd: i64 = -1, off: i64 = 0, left: i64 = 0 }

// The most send_file reads at once.
let FILE_PIECE = 65536;
// The least of a file the loop sends itself (Stream.direct). Below it, one
// read and a send beat sendfile and io_uring's splices through a pipe: at
// 4 KB by 1.3 to 1.8 times, and they cross between 32 and 64 KB (task 020).
let DIRECT_MIN = FILE_PIECE;

// Writes info[0..2].
extern fn net_file_open(path: const u8[:], info: i64[:]) -> i64;
extern fn net_file_read(fd: i64, buf: u8[:], off: i64) -> i64;
extern fn net_file_close(fd: i64);
// Sends up to len bytes of file fd from off on socket s: the bytes sent, 0 at
// the file's end, or -code: EBADF for fd -1, and ENOSYS on Windows, where
// serve_epoll doesn't run.
extern fn net_sendfile(s: i32, fd: i64, off: i64, len: i64) -> i64;

// Opens the regular file at path for reading. Returns it and 200; or 404 for
// a path that names no file, or a directory; 403 where permission is denied;
// or 500.
fn open_file(path: const u8[:]) -> File, i32 {
    var info: i64[2] = [0; 2];
    let fd = net_file_open(path, info);
    guard fd >= 0 else {
        let e = -fd;
        return File { .. }, if e == ENOENT || e == ENOTDIR || e == EISDIR || e == ENAMETOOLONG { 404 }
                            else if e == EACCES { 403 } else { 500 };
    }
    return File { fd: fd, size: info[0], modified: info[1] }, 200;
}

// Opens path as open_file does, or in its place the precompressed copy beside
// it that req's Accept-Encoding weighs highest: path.br, path.zst, or path.gz,
// of equal weights in that order, as Caddy's precompressed prefers. A copy
// older than path is passed over, since it may hold what path held before.
fn open_precompressed(req: const Request&, path: const u8[:]) -> File, i32 {
    let f, status = open_file(path);
    guard status == 200 else { return f, status; }
    let codings = ["br", "zstd", "gzip"];
    let exts = [".br", ".zst", ".gz"];
    var qs: i64[3] = [0; 3];
    for c, i in codings { qs[i] = coding_q(req, c); }
    loop {
        var best = -1;
        for q, i in qs {
            if q > 0 && (best < 0 || q > qs[best]) { best = i; }
        }
        guard best >= 0 else { break; }
        qs[best] = 0;
        var name: u8[>..] = [];
        name.append(path);
        name.append(exts[best]);
        let v, s = open_file(name);
        guard s == 200 else { continue; }
        if v.modified >= f.modified {
            net_file_close(f.fd);
            return File { fd: v.fd, size: v.size, modified: v.modified, coding: codings[best], vary: true }, 200;
        }
        net_file_close(v.fd);
    }
    return File { fd: f.fd, size: f.size, modified: f.modified, vary: true }, 200;
}

// Closes b's file, if open, and leaves nothing to send.
fn close_body(b: FileBody&) {
    if b.fd >= 0 { net_file_close(b.fd); }
    b.fd = -1;
    b.left = 0;
}

// Answers a GET or HEAD for f, which open_file opened, as content_type: with
// 304 when not_modified, 416 for a range past its end, 206 for one range of
// it, or 200 with all of it, each with an ETag of its size and modification
// time, Last-Modified, and Accept-Ranges; and with f's Content-Encoding and
// Vary from open_precompressed, the range taken of the coded bytes, as RFC
// 9110 §14 has it. body becomes the bytes still to
// send, which the handler sends with send_file at each MORE until it returns
// false, and then ends the response with end. With none to send, as for
// HEAD, the response has ended and f is closed.
fn serve_file(req: const Request&, out: Reply, f: File, content_type: const u8[:], body: FileBody&) {
    let tag = file_tag(f);
    body.fd = f.fd;
    body.off = 0;
    body.left = 0;
    if not_modified(req, tag, f.modified) {
        start(out, 304);
        file_fields(out, f, tag);
        finish(out, "", "");
        close_body(body);
        return;
    }
    let a, e, status = range_of(req, f.size, tag);
    if status == 416 {
        start(out, 416);
        content_range(out, 0, 0, f.size);
        finish(out, NO_TYPE, "");
        close_body(body);
        return;
    }
    begin(out, status, e - a);
    if status == 206 { content_range(out, a, e, f.size); }
    field(out, "Content-Type", content_type);
    if f.coding.len > 0 { field(out, "Content-Encoding", f.coding); }
    file_fields(out, f, tag);
    body.off = a;
    body.left = e - a;
    if out.head || body.left == 0 {
        end(out);
        close_body(body);
    }
}

// The entity tag serve_file sends for f, quoted: its size and modification
// time in hex, then the coding of a precompressed copy. A program that
// answers f's 304 or 416 itself passes it to not_modified and range_of.
inline fn file_tag(f: File) -> u8[>..] {
    var tag: u8[>..] = [];
    tag.push('"');
    hex_size(tag, f.size);
    tag.push('-');
    hex_size(tag, max(f.modified, 0));
    if f.coding.len > 0 {
        tag.push('-');
        tag.append(f.coding);
    }
    tag.push('"');
    return tag;
}

inline fn file_fields(out: Reply, f: File, tag: const u8[:]) {
    out.buf.append("ETag: ");
    out.buf.append(tag);
    out.buf.append("\r\nLast-Modified: ");
    format_date(out.buf, max(f.modified, 0));
    out.buf.append("\r\nAccept-Ranges: bytes\r\n");
    if f.vary { out.buf.append("Vary: Accept-Encoding\r\n"); }
}

// Sends the next piece of b, at most FILE_PIECE bytes, into the response
// begin started. Returns whether more is left; after the last piece, it
// closes the file. Where the loop sends files itself (Stream.direct) and
// the response has a Content-Length, it gives the loop the file and the rest
// of b at once, and returns false. A read that fails, or ends early as for a file cut short
// meanwhile, stops the response there and closes the connection after it,
// since what the head promised can't be sent; end is then a no-op.
fn send_file(out: Reply, b: FileBody&) -> bool {
    let s .= out.stream;
    send(out, "");
    guard s.open && b.left > 0 && !s.bodyless && !out.head else {
        close_body(b);
        return false;
    }
    // What a Content-Length body has left to send, or -1 for another framing.
    let left = match s.framing { Length l => l.left, _ => -1 };
    if s.direct && left >= 0 && min(b.left, left) >= DIRECT_MIN {
        let k = min(b.left, left);
        s.file = b.fd;
        s.file_off = b.off;
        s.file_left = k;
        s.framing = Framing.Length { left: left - k };
        s.moved = true;
        b.fd = -1;
        b.left = 0;
        return false;
    }
    let n = if left >= 0 { min(min(b.left, FILE_PIECE), left) } else { min(b.left, FILE_PIECE) };
    // Read apart from the write buffer, which can't shrink back past a failed
    // read: out holds slices of bytes, as common, that for all the checker
    // knows point into it (spec §5.1).
    var piece: u8[>..] = [];
    push_n(piece, 0, n);
    guard n > 0 && net_file_read(b.fd, piece, b.off) == n else {
        s.open = false;
        out.keep_alive = false;
        close_body(b);
        return false;
    }
    send(out, piece);
    b.off += n;
    b.left -= n;
    guard b.left > 0 else {
        close_body(b);
        return false;
    }
    return true;
}

// Whether path, a decoded request path, names a file below the directory it
// is joined to without leaving it: no "." or ".." segment, and no NUL,
// backslash, or colon, which Windows takes as separators and drive letters.
fn is_safe_path(path: const u8[:]) -> bool {
    var seg = 0;
    for i in path.len + 1 {
        if i == path.len || path[i] == '/' {
            let s = path[seg..i];
            guard s != "." && s != ".." else { return false; }
            seg = i + 1;
        } else {
            let c = path[i];
            guard c != 0 && c != '\\' && c != ':' else { return false; }
        }
    }
    return true;
}

// Appends to out the path of the file in dir that encoded names, a request
// path still percent-encoded, such as a router's *name parameter: dir, a '/'
// unless dir is empty or ends in one, and encoded decoded. False, with out
// as it was, for a bad escape or a decoded path is_safe_path refuses. An
// empty dir is the working directory.
fn file_path(dir: const u8[:], encoded: const u8[:], out: u8[>..]&) -> bool {
    let start = out.len;
    out.append(dir);
    if dir.len > 0 && dir[dir.len - 1] != '/' { out.push('/'); }
    let at = out.len;
    guard decode(encoded, out) && is_safe_path(out[at..]) else {
        out.resize(start);
        return false;
    }
    return true;
}

// The media type of a file, by its name's extension, ignoring case, for the
// common types of a web site; application/octet-stream for any other.
fn content_type_of(name: const u8[:]) -> const u8[:] {
    var dot = name.len;
    while dot > 0 && name[dot - 1] != '.' && name[dot - 1] != '/' { dot--; }
    guard dot > 0 && name[dot - 1] == '.' else { return "application/octet-stream"; }
    let x = name[dot..];
    if eq_fold(x, "html") || eq_fold(x, "htm") { return "text/html; charset=utf-8"; }
    if eq_fold(x, "css") { return "text/css; charset=utf-8"; }
    if eq_fold(x, "js") || eq_fold(x, "mjs") { return "text/javascript; charset=utf-8"; }
    if eq_fold(x, "json") { return "application/json"; }
    if eq_fold(x, "txt") { return "text/plain; charset=utf-8"; }
    if eq_fold(x, "csv") { return "text/csv; charset=utf-8"; }
    if eq_fold(x, "xml") { return "application/xml"; }
    if eq_fold(x, "svg") { return "image/svg+xml"; }
    if eq_fold(x, "png") { return "image/png"; }
    if eq_fold(x, "jpg") || eq_fold(x, "jpeg") { return "image/jpeg"; }
    if eq_fold(x, "gif") { return "image/gif"; }
    if eq_fold(x, "webp") { return "image/webp"; }
    if eq_fold(x, "avif") { return "image/avif"; }
    if eq_fold(x, "ico") { return "image/vnd.microsoft.icon"; }
    if eq_fold(x, "wasm") { return "application/wasm"; }
    if eq_fold(x, "pdf") { return "application/pdf"; }
    if eq_fold(x, "woff") { return "font/woff"; }
    if eq_fold(x, "woff2") { return "font/woff2"; }
    if eq_fold(x, "ttf") { return "font/ttf"; }
    if eq_fold(x, "mp4") { return "video/mp4"; }
    if eq_fold(x, "webm") { return "video/webm"; }
    if eq_fold(x, "mp3") { return "audio/mpeg"; }
    if eq_fold(x, "zip") { return "application/zip"; }
    if eq_fold(x, "gz") { return "application/gzip"; }
    return "application/octet-stream";
}
