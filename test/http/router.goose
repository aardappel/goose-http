// The router: parameters, a wildcard, 405 with Allow, OPTIONS, 404, escapes,
// dot-segments, and methods the server doesn't know.
import std;
import http from "../../";
import check from "../";

// A small app's routes on text's request: which route took it and its
// parameters, or the response the router gave.
fn app(text: const u8[:], out: u8[>..]&) {
    let req, s = http::parse(text);
    assert(s == 200);
    var keep = true;
    var stream = http::Stream { .. };
    let reply = http::Reply { buf: out, common: check::COMMON, keep_alive: keep, minor: 1, head: req.method == "HEAD",
                              stream: stream };
    var r = http::router(req);
    if http::on(r, "GET", "/") { out.append("root"); }
    else if http::on(r, "GET", "/users/:id") { format(out, "user ", http::param(r, "id")); }
    else if http::on(r, "PUT", "/users/:id") { format(out, "put ", http::param(r, "id")); }
    else if http::on(r, "GET", "/users/:id/posts/:post") {
        format(out, "post ", http::param(r, "id"), " ", http::param(r, "post"));
    }
    else if http::on(r, "GET", "/files/*path") { format(out, "file ", http::param(r, "path")); }
    else if http::on(r, "POST", "/upload") { out.append("upload"); }
    else { http::otherwise(r, reply); }
}

var routed = 0;

fn routes_to(text: const u8[:], want: const u8[:]) {
    var out: u8[>..] = [];
    app(text, out);
    check::same(out, want);
    routed++;
}

fn main() {
    routes_to("GET / HTTP/1.1\r\nHost: x\r\n\r\n", "root");
    routes_to("GET /users/42 HTTP/1.1\r\nHost: x\r\n\r\n", "user 42");
    routes_to("GET /users/42?x=1 HTTP/1.1\r\nHost: x\r\n\r\n", "user 42");
    routes_to("HEAD /users/42 HTTP/1.1\r\nHost: x\r\n\r\n", "user 42");
    routes_to("PUT /users/7 HTTP/1.1\r\nHost: x\r\n\r\n", "put 7");
    routes_to("GET /users/7/posts/9 HTTP/1.1\r\nHost: x\r\n\r\n", "post 7 9");
    routes_to("GET http://x/users/5 HTTP/1.1\r\nHost: x\r\n\r\n", "user 5");
    routes_to("GET /files/a/b%20c HTTP/1.1\r\nHost: x\r\n\r\n", "file a/b%20c");
    routes_to("GET /files/ HTTP/1.1\r\nHost: x\r\n\r\n", "file ");
    print("routes: ", routed);
    // A method that the path's routes don't take, OPTIONS, and no route.
    routes_to("DELETE /users/42 HTTP/1.1\r\nHost: x\r\n\r\n",
              "HTTP/1.1 405 Method Not Allowed\r\nServer: goose\r\nDate: Sat, 10 Oct 2026 12:00:00 GMT\r\nAllow: GET, HEAD, PUT\r\nContent-Length: 0\r\n\r\n");
    routes_to("OPTIONS /users/42 HTTP/1.1\r\nHost: x\r\n\r\n",
              "HTTP/1.1 204 No Content\r\nServer: goose\r\nDate: Sat, 10 Oct 2026 12:00:00 GMT\r\nAllow: GET, HEAD, PUT\r\n\r\n");
    routes_to("GET /upload HTTP/1.1\r\nHost: x\r\n\r\n",
              "HTTP/1.1 405 Method Not Allowed\r\nServer: goose\r\nDate: Sat, 10 Oct 2026 12:00:00 GMT\r\nAllow: POST\r\nContent-Length: 0\r\n\r\n");
    let missing = "HTTP/1.1 404 Not Found\r\nServer: goose\r\nDate: Sat, 10 Oct 2026 12:00:00 GMT\r\nContent-Length: 0\r\n\r\n";
    routes_to("GET /nope HTTP/1.1\r\nHost: x\r\n\r\n", missing);
    routes_to("GET /users/ HTTP/1.1\r\nHost: x\r\n\r\n", missing);
    routes_to("GET /users/1/posts HTTP/1.1\r\nHost: x\r\n\r\n", missing);
    routes_to("GET /files HTTP/1.1\r\nHost: x\r\n\r\n", missing);
    routes_to("GET //users/1 HTTP/1.1\r\nHost: x\r\n\r\n", missing);
    print("405, OPTIONS, and 404: ", routed);
    // An escaped unreserved byte matches a literal; an escaped '/' doesn't
    // split a segment, and parameters stay as sent.
    routes_to("GET /%75sers/4%32 HTTP/1.1\r\nHost: x\r\n\r\n", "user 4%32");
    routes_to("GET /users%2F42 HTTP/1.1\r\nHost: x\r\n\r\n", missing);
    // Dot-segments, escaped or not, and escaped control bytes: 400.
    let bad = "HTTP/1.1 400 Bad Request\r\nServer: goose\r\nDate: Sat, 10 Oct 2026 12:00:00 GMT\r\nContent-Length: 0\r\n\r\n";
    routes_to("GET /files/../secret HTTP/1.1\r\nHost: x\r\n\r\n", bad);
    routes_to("GET /files/%2e%2E/secret HTTP/1.1\r\nHost: x\r\n\r\n", bad);
    routes_to("GET /files/./a HTTP/1.1\r\nHost: x\r\n\r\n", bad);
    routes_to("GET /files/a/.. HTTP/1.1\r\nHost: x\r\n\r\n", bad);
    routes_to("GET /files/a%00b HTTP/1.1\r\nHost: x\r\n\r\n", bad);
    routes_to("GET /files/a%7fb HTTP/1.1\r\nHost: x\r\n\r\n", bad);
    routes_to("GET /files/...x HTTP/1.1\r\nHost: x\r\n\r\n", "file ...x");
    print("escapes and dot-segments: ", routed);
    // A method the server doesn't know: 501 (RFC 9110 §9.1), methods being
    // case-sensitive. OPTIONS *: 204, for the server as a whole (§9.3.7).
    let unknown = "HTTP/1.1 501 Not Implemented\r\nServer: goose\r\nDate: Sat, 10 Oct 2026 12:00:00 GMT\r\nContent-Length: 0\r\n\r\n";
    routes_to("FOO /users/42 HTTP/1.1\r\nHost: x\r\n\r\n", unknown);
    routes_to("get / HTTP/1.1\r\nHost: x\r\n\r\n", unknown);
    routes_to("OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n",
              "HTTP/1.1 204 No Content\r\nServer: goose\r\nDate: Sat, 10 Oct 2026 12:00:00 GMT\r\n\r\n");
    print("501, and OPTIONS *: ", routed);
    // The verdict without a Router, from its parts.
    print("unrouted: ", http::unrouted("FOO", "/", true, ""), " ", http::unrouted("GET", "/a/../b", false, ""), " ",
          http::unrouted("OPTIONS", "*", true, ""), " ", http::unrouted("OPTIONS", "/users/1", true, "GET"), " ",
          http::unrouted("POST", "/users/1", true, "GET, PUT"), " ", http::unrouted("GET", "/nothing", true, ""));
}
