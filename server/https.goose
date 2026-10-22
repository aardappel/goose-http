// The TLS listeners, with the PEM certificate chain TLS_CERT and its key
// TLS_KEY: TLS 1.3 on TLS_PORT, by default the port + 1, as HttpArena's 8081
// is beside 8080, and on H2_PORT, by default the port + 363, as HttpArena's
// 8443 is. Both share one context, which offers h2 and http/1.1, so ALPN
// chooses the protocol on each; HttpArena's TLS profiles on 8081 measure
// HTTP/1.1 since their load tool, wrk, offers no ALPN. Without both files no
// listener serves TLS, and a port of 0 turns its listener off. TLS_GROUPS
// sets the key exchange groups (tls::use_groups), goose-tls's default
// otherwise.
import std;
import os;
import http;
import http.tls;
import routes;

var tls_ctx = tls::Context { .. };

// Adds the TLS listeners to cfg, and says so in also.
fn tls_listener(cfg: http::Config&, also: u8[>..]&) {
    var cert: u8[>..] = [];
    var key: u8[>..] = [];
    guard env("TLS_CERT", cert) && env("TLS_KEY", key) else { return; }
    let p = port_of("TLS_PORT", cfg.port as i64 + 1);
    let q = port_of("H2_PORT", cfg.port as i64 + 363);
    if p > 0 || q > 0 { tls_ctx = context(cert, key); }
    if p > 0 {
        cfg.listeners.push(http::Listener { port: p as i32, tls: true });
        format(also, ", TLS on port ", p);
    }
    if q > 0 {
        cfg.listeners.push(http::Listener { port: q as i32, tls: true });
        format(also, ", TLS on port ", q);
    }
}

// The port the environment variable name gives, 0 for none, or otherwise.
fn port_of(name: const u8[:], otherwise: i64) -> i64 {
    var given: u8[>..] = [];
    guard env(name, given) else { return if otherwise < 65536 { otherwise } else { 0 }; }
    let n, ok = parse_int(given);
    guard ok && n >= 0 && n < 65536 else {
        write_stderr(str(name, " must be a port number, or 0 for none\n"));
        exit(2);
    }
    return n;
}

// A server context for the files cert and key, offering h2 and http/1.1, with
// TLS_GROUPS's groups.
fn context(cert: const u8[:], key: const u8[:]) -> tls::Context {
    let ctx, ok = tls::server_files(cert, key, ["h2", "http/1.1"]);
    guard ok else {
        write_stderr(str("TLS_CERT and TLS_KEY: ", tls::error_text(), "\n"));
        exit(2);
    }
    var groups: u8[>..] = [];
    if env("TLS_GROUPS", groups) && !tls::use_groups(ctx, groups) {
        write_stderr(str("TLS_GROUPS: goose-tls doesn't know a group in '", groups, "' ", tls::error_text(), "\n"));
        exit(2);
    }
    return ctx;
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
