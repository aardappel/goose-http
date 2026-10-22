// The TLS listeners, with the PEM certificate chain TLS_CERT and its key
// TLS_KEY: HTTP/1.1 over TLS 1.3 on TLS_PORT, by default the port + 1, as
// HttpArena's 8081 is beside 8080, and h2 or HTTP/1.1 over TLS 1.3, as ALPN
// chooses, on H2_PORT, by default the port + 363, as HttpArena's 8443 is.
// Without both files no listener serves TLS, and a port of 0 turns its
// listener off. TLS_GROUPS sets the key exchange groups (tls::use_groups),
// goose-tls's default otherwise.
//
// A loop's listeners share one context, and with it one ALPN list, and
// HttpArena wants only http/1.1 advertised on 8081. So H2_PORT has a context
// of its own, ["h2", "http/1.1"], and workers of their own, as many again.
import std;
import os;
import http;
import http.tls;
import routes;

var tls_ctx = tls::Context { .. };
var h2_ctx = tls::Context { .. };
var h2_port: i64 = 0;

// Adds the TLS listener to cfg, sets up H2_PORT's, and says so in also.
fn tls_listener(cfg: http::Config&, also: u8[>..]&) {
    var cert: u8[>..] = [];
    var key: u8[>..] = [];
    guard env("TLS_CERT", cert) && env("TLS_KEY", key) else { return; }
    let p = port_of("TLS_PORT", cfg.port as i64 + 1);
    let q = port_of("H2_PORT", cfg.port as i64 + 363);
    if p > 0 {
        tls_ctx = context(cert, key, ["http/1.1"]);
        cfg.listeners.push(http::Listener { port: p as i32, tls: true });
        format(also, ", TLS on port ", p);
    }
    if q > 0 {
        h2_ctx = context(cert, key, ["h2", "http/1.1"]);
        h2_port = q;
        format(also, ", h2 over TLS on port ", q);
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

// A server context for the files cert and key, with the ALPN protocols, and
// TLS_GROUPS's groups.
fn context(cert: const u8[:], key: const u8[:], protocols: const u8[:][:]) -> tls::Context {
    let ctx, ok = tls::server_files(cert, key, protocols);
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

fn tls_run(cfg: http::Config, ctx: tls::Context, epoll: bool) {
    if epoll { http::run(cfg, ctx, worker_tls_epoll); } else { http::run(cfg, ctx, worker_tls); }
}

thread_fn h2_workers(cfg: http::Config, ctx: tls::Context, epoll: bool) { tls_run(cfg, ctx, epoll); }

// The workers, each with the TLS context, if any, and H2_PORT's beside them.
fn tls_workers(cfg: http::Config, epoll: bool) {
    var id: i64 = -1;
    if h2_port > 0 {
        var h2 = cfg;
        h2.port = h2_port as i32;
        h2.tls = true;
        h2.h2c = false;
        h2.listeners = [];
        id = thread_spawn(h2_workers, h2, h2_ctx, epoll);
    }
    tls_run(cfg, tls_ctx, epoll);
    if id >= 0 { thread_wait(id); }
}
