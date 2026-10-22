// The TLS listener: HTTP/1.1 over TLS 1.3 on TLS_PORT, by default the port
// + 1, as HttpArena's 8081 is beside 8080, with the PEM certificate chain
// TLS_CERT and its key TLS_KEY. Without both, or with TLS_PORT=0, no
// listener serves TLS. TLS_GROUPS sets the key exchange groups
// (tls::use_groups), OpenSSL's default otherwise.
import std;
import os;
import http;
import http.tls;
import routes;

var tls_ctx = tls::Context { .. };

// Adds the TLS listener to cfg, and says so in also.
fn tls_listener(cfg: http::Config&, also: u8[>..]&) {
    var cert: u8[>..] = [];
    var key: u8[>..] = [];
    guard env("TLS_CERT", cert) && env("TLS_KEY", key) else { return; }
    var p: i64 = cfg.port as i64 + 1;
    var given: u8[>..] = [];
    if env("TLS_PORT", given) {
        let n, ok = parse_int(given);
        guard ok && n >= 0 && n < 65536 else {
            write_stderr("TLS_PORT must be a port number, or 0 for none\n");
            exit(2);
        }
        p = n;
    }
    guard p > 0 && p < 65536 else { return; }
    let ctx, ok = tls::server_files(cert, key, ["http/1.1"]);
    guard ok else {
        write_stderr(str("TLS_CERT and TLS_KEY: ", tls::error_text(), "\n"));
        exit(2);
    }
    var groups: u8[>..] = [];
    if env("TLS_GROUPS", groups) && !tls::use_groups(ctx, groups) {
        write_stderr(str("TLS_GROUPS: OpenSSL doesn't know a group in '", groups, "' ", tls::error_text(), "\n"));
        exit(2);
    }
    tls_ctx = ctx;
    cfg.listeners.push(http::Listener { port: p as i32, tls: true });
    format(also, ", TLS on port ", p);
}

thread_fn worker_tls_epoll(cfg: http::Config, ctx: tls::Context) {
    var server = http::tls_server(ctx);
    let e = http::serve_epoll(cfg, Transfer { .. }, server, handle);
    http::release(server);
    http::exit_on_error(e);
}

thread_fn worker_tls(cfg: http::Config, ctx: tls::Context) {
    var server = http::tls_server(ctx);
    let e = http::serve(cfg, Transfer { .. }, server, handle);
    http::release(server);
    http::exit_on_error(e);
}

// The workers, each with the TLS context, if any.
fn tls_workers(cfg: http::Config, epoll: bool) {
    if epoll { http::run(cfg, tls_ctx, worker_tls_epoll); } else { http::run(cfg, tls_ctx, worker_tls); }
}
