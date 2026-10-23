// A program that imports http without http.tls builds without declaring
// goose-tls, and its serve_epoll and serve refuse a listener that asks for
// TLS before they open any. serve on IOCP serves no TLS and takes one listener,
// so it refuses either with ENOSYS, and a second listener before its TLS.
import std;
import http from "../../";

fn refused(e: http::Error) -> bool { e.code == http::EINVAL || e.code == http::ENOSYS }

fn main() {
    var cfg = http::Config { port: 1, .. };
    cfg.tls = true;
    var e = http::serve_epoll(cfg) { req, body, out => http::respond(out, 200, "text/plain", ""); };
    print("Config.tls: ", e.call, " ", e.code == http::EINVAL);
    e = http::serve(cfg) { req, body, out => http::respond(out, 200, "text/plain", ""); };
    print("serve, Config.tls: ", e.call, " ", refused(e));
    cfg.tls = false;
    cfg.listeners.push(http::Listener { port: 2, tls: true });
    e = http::serve_epoll(cfg) { req, body, out => http::respond(out, 200, "text/plain", ""); };
    print("Listener.tls: ", e.call, " ", e.code == http::EINVAL);
    e = http::serve(cfg) { req, body, out => http::respond(out, 200, "text/plain", ""); };
    print("serve, Listener.tls: ", e.call == "tls" || e.call == "listeners", " ", refused(e));
}
