# 061: h2 over TLS, chosen by ALPN

Status: in-progress (asked for 2026-10-22). h2 over TLS serves from both loops, on
`main`, over goose-tls `v0.0.4`'s TLS 1.3 server in Goose; HttpArena's validation and
its baseline-h2 runs remain, and static-h2 is deferred ([below](#static-h2)).

Task 014's phase 5: one TLS listener serves h2 or HTTP/1.1 on the same port, as the
client's ALPN offer and the context's protocol list decide, on the epoll loop (and so
kqueue) and the io_uring loop (and its emulated ring on macOS). HttpArena's baseline-h2
and static-h2 profiles need it on port 8443, and browsers reach h2 no other way.

## Decisions

Taken 2026-10-22, on the design below:

1. ALPN alone decides: the program lists `["h2", "http/1.1"]` in its TLS context, and
   goose-http adds no `Listener.h2` flag and no other name
   ([decisions](../docs/decisions.md#alpn-chooses-h2-over-tls)).
2. The benchmark server offers h2 over TLS on 8443 only. 8081 stays at ALPN
   `http/1.1` alone, as HttpArena's json-tls and static-tls pages ask.
3. static-h2 is in scope only if it needs no more than the 8443 listener and the
   existing static-file route over h2.
4. Instruction counts now; HttpArena's numbers wait for goose-tls's rewritten server,
   which changes both the memory and the rate. That server came first, as goose-tls
   `v0.0.4` (pinned 2026-10-22, before this task's change), and h2 over TLS is built on
   it.

## Design

### ALPN is goose-tls's already

goose-tls has server-side ALPN selection, and goose-http needs nothing new from it.
The context holds the server's protocols in its order of preference
(`tls::server_files(chain, key, ["h2", "http/1.1"])`, `tls::server`), the server
selects the first of them the client offered, and
`tls::alpn(c)` gives the choice after the handshake, or "" for none. This holds at
goose-tls `v0.0.3` and at `v0.0.4`, whose TLS 1.3 server in Goose (goose-tls's task
007) selects ALPN the same way.

One behavior changed with `v0.0.4`: at `v0.0.3` a client that offers ALPN with no
protocol in common got no ALPN and HTTP/1.1; `v0.0.4` fails that handshake with
`no_application_protocol`, as RFC 7301 §3.2 asks. A client that offers no ALPN still
connects and gets HTTP/1.1. `test/tls/alpn.goose`'s golden output shows both, and
`scripts/http_client.py`'s `tls-h2` accepts either.

### Where TLS sits, and what h2c assumes

On both loops the record layer sits between the socket and the worker's buffers, and
the protocol drivers see only plaintext. h2c's driver, `h2_answer`, reads frames from
`rbuf[..rlen]` and writes frames to `wbuf`, and never touches the socket. It expects
the connection preface first, and an h2 client over TLS sends the same preface after
the handshake (RFC 9113 §3.4). Its streams already read files in pieces. So h2 frames
run over TLS unchanged; what was missing is only the choice of driver, which h2c makes
at accept, from the listener.

### The change

1. `tls.goose`: `tls_h2(t, k)`, `tls::alpn(conn) == "h2"`, and a `NoTls` stub that
   returns false.
2. epoll loop (`advance`): right after `tls_recv` returns the first plaintext, before
   the HTTP/1.1 parser can see it, a connection whose `h2` is -1 asks `tls_h2`. For h2
   it sets `c.ready` and returns; `drive` keeps the preface in `c.held`, and `go`, which
   lists the connection for another turn in the same pass, allocates its `H2Conn` as
   accept does for h2c, so that turn, and any event before it, goes through the h2
   branch. Otherwise `h2` becomes -2, HTTP/1.1 by ALPN, and later receives only compare.
3. io_uring loop (`received`): after `tls_take` and before `take`, the same question,
   which sets `h2` to the new `H2Conn` or -2, so `feed` picks `pump_h2` for the first
   plaintext.
4. Both loops keep refusing `tls` with `h2c` on one listener: h2c means prior
   knowledge over TCP, and h2 over TLS is negotiated.
5. The ends of a connection. At a stop both loops already sent GOAWAY, and then
   close_notify once the streams are done, since `tls_seal` seals it once the h2 driver
   leaves the connection CLOSING. At `idle_ms` the sweep closed an h2 connection without
   a GOAWAY, h2c too, and over TLS the epoll loop then sent close_notify alone. Now an
   idle h2 connection with no stream open and nothing to send is sent GOAWAY, with
   close_notify after it over TLS, and lingers as a refusal does (RFC 9113 §9.1): on
   epoll through the 408's path, made a function (`bye`), on io_uring through `notify`.

Nothing changes in `h2.goose`, `h2frame.goose`, or `hpack.goose`.

### Cost

- Plaintext programs: none. `tls` is the loops' untyped parameter, so a program
  without `http.tls` instantiates the loops with `NoTls` and never links goose-tls; the
  new checks sit inside the `c.tls >= 0` branches, which plaintext connections never
  enter. Counted below.
- HTTP/1.1 over TLS: one `tls::alpn` call, which allocates the name, and a comparison
  per connection, at its first plaintext, and a compare of `h2` per TLS receive. An
  HTTP/1.1 connection's memory stays as it is: `H2Conn` is allocated only when ALPN
  chose h2. Two placements cost more and were dropped: the alpn call in `tls_plain`,
  where the handshake ends, made gcc's `tls_recv` 14 instructions a request dearer;
  and the choice kept in the TLS slot, asked for on each receive, 31, since
  `tls_h2` then didn't inline.

### API

Additive, with no new goose-http name. A program offers h2 by listing it in the
context's protocols; the listener stays `tls: true` (`docs/api.md`, "HTTPS").
`Config.h2_max_streams`, `h2_stream_window`, and `h2_conn_window` apply to h2 over TLS
as to h2c. goose-rest's `rest.tls` passes a `TlsServer` through and needs no change.

### The benchmark server

A loop has one `TlsServer`, so one context and one ALPN list for all its TLS
listeners, and decision 2 wants two lists. The server keeps 8081's context at
`["http/1.1"]` and serves `H2_PORT` (its port + 363, 8443 beside 8080; 0 for none)
from a second context, `["h2", "http/1.1"]`, and a second set of workers, as many as
the first, which `tls_workers` spawns beside them (`server/https.goose`). No
`MAX_LISTENERS` change was needed. The cost is a second set of idle workers in every
TLS profile: their threads, stacks, rings, and buffers. With `WORKERS=4`, the TLS
build's resident memory after 2 s idle went from 19.5 to 30.2 MB on io_uring and from
17.3 to 28.0 MB on epoll, about 2.7 MB per idle worker (Docker Desktop on an Apple
M-series Mac, arm64 Ubuntu 26.04, `VmRSS`, 2026-10-22): about 170 MB more on a server
with 64 workers, in json-tls as in baseline-h2. This is for the maintainer to settle
before the h2 profiles run. A context per listener would
avoid it, at the cost of a new name in goose-http's API; one context for both ports
would avoid it too, and HttpArena's validation allows `h2` advertised on 8081, but its
pages ask for `http/1.1` alone there.

The Dockerfile exposes 8443. `meta.json` lists neither h2 profile yet: baseline-h2
once HttpArena's validation passes with it, after goose-tls's rewrite.

### static-h2

Deferred (2026-10-22). Over h2 and TLS, the server's existing route serves HttpArena's
20 files with their pre-compressed `.br` and `.gz` siblings, by `Accept-Encoding`
(checked with HttpArena's `data/static` at `0720ee57`). But the profile needs more
than that: the route is `/files/` where HttpArena requests `/static/`, the container
would have to set `FILES=/data/static`, and HttpArena's validation expects
`Content-Type: application/javascript` for `app.js` where `http::content_type_of`
gives `text/javascript`, which RFC 9239 made the type for JavaScript. Each is small,
but the last is a choice about the package's content types, for a benchmark.

## Tests

- `scripts/test-http.sh`, on both loops: `curl -k --http2` gets HTTP/2 and
  `curl -k --http1.1` HTTP/1.1 on the h2 port, and `--http2` HTTP/1.1 on the TLS port,
  which offers `http/1.1` alone; `openssl s_client -alpn h2` and `-alpn http/1.1`
  each get their protocol; a 3 MB body echoed and a 3 MB file sent over h2 through the
  record layer; h2load over TLS (`-c 64 -m 100`, 100,000 requests), every request 2xx
  with ALPN h2.
- `scripts/http_client.py`'s `tls-h2`, with `IDLE_MS=2000`: the driver each ALPN offer
  gets (h2; `http/1.1`; none; and `spdy/3`, refused with RFC 7301's alert, or HTTP/1.1
  from goose-tls `v0.0.3`), a GET over each, and an idle h2 connection's GOAWAY of NO_ERROR, then
  close_notify, after idle_ms. Its `stop` check adds an idle h2 connection over TLS,
  which must get GOAWAY, then close_notify.
- `scripts/test-h2spec.sh` over TLS (`h2spec -t -k`, with `GODEBUG=tls13=1` for
  h2spec's Go 1.12), beside the h2c run: 146 of 146 on both loops.
- `test/tls/alpn.goose`: a `TlsServer` slot's handshake against goose-tls's client
  in memory, with a self-signed certificate made in the test, prints the driver each
  offer selects from a context that lists h2 and one that doesn't, at -O0 and -O2.

Results (2026-10-22): `scripts/test.sh` passes on macOS (kqueue, and the emulated
ring) with h2spec under Rosetta 2, and in Linux Docker (arm64, seccomp unconfined, so
real io_uring) on uring, epoll, and uring-epoll, with h2spec run from an x86-64
container against the uring and epoll loops, h2c and over TLS, 146 of 146 each. All on
goose-tls `v0.0.4`.

## Measurements

User instructions per request under valgrind's cachegrind, one worker, the difference
between runs of 22,000 and 2,000 requests from h2load (`-t 1`): base is the goose-tls
`v0.0.4` pin's commit, mine this task's change. Plaintext rows use 16 connections
with 16 requests in flight on each, `/plaintext` on the benchmark server
(`server/server.goose`) and `/api/me` on the REST tier A server; the TLS rows use the
TLS build with 4 connections and 1 request in flight (`-c 4 -m 1`), the two runs one
after the other, since pipelined TLS batches records differently from run to run, and
`H2_PORT=0`. Docker Desktop on an Apple M1 Pro, arm64 Ubuntu 26.04, kernel
7.0.14-linuxkit, real io_uring (seccomp unconfined), gcc 15.2, Goose v2026.3,
valgrind 3.26.0, h2load 1.68.0, 2026-10-22.

| Row | Loop | Base | Mine | Change |
|---|---|---:|---:|---:|
| `/plaintext` | epoll | 2,673.1 | 2,672.5 | -0.6 |
| `/plaintext` | io_uring | 2,729.8 | 2,724.9 | -4.9 |
| `/api/me` | epoll | 4,579.9 | 4,579.6 | -0.3 |
| `/api/me` | io_uring | 4,615.6 | 4,615.6 | 0 |
| HTTP/1.1 over TLS, `/json` | epoll | 16,153.0 | 16,173.5 | +20.5 |
| HTTP/1.1 over TLS, `/json` | io_uring | 16,960.0 | 16,998.9 | +38.9 |
| h2 over TLS, `/json`, `-m 1` | epoll | | 16,090.1 | |
| h2 over TLS, `/json`, `-m 1` | io_uring | | 15,417.1 | |
| h2 over TLS, `/json`, `-m 16` | epoll | | 3,578.8 | |
| h2 over TLS, `/json`, `-m 16` | io_uring | | 3,625.2 | |

The TLS rows are the mean of two runs each, which agreed to within 6. Plaintext is
unchanged: the io_uring row's -4.9 repeated in each of three builds of the change. Of
HTTP/1.1 over TLS's +20.5 and +38.9, cachegrind's per-function difference puts +8 to
+13 in goose-tls's own `tls_s_read`, which this change doesn't touch, and the rest in
the loop functions (`worker_tls_epoll`, +10; `http_ring_loop`, +26), where the code
added is a compare per receive: gcc's register allocation in the loop, not the check
itself. That is 0.13% and 0.23% of a request over TLS. On the `v0.0.3` pin, with
libssl's server, HTTP/1.1 over TLS cost 28,823 on epoll and 27,850 on io_uring by the
same method; goose-tls's own server takes 44% and 39% fewer.

## Acceptance criteria

- [x] A TLS listener whose context lists `h2` serves h2 to a client that selects it by
      ALPN, and HTTP/1.1 to one that selects `http/1.1` or offers no ALPN, on one port,
      on the epoll loop (Linux, and kqueue on macOS) and the io_uring loop (Linux, and
      the emulated ring on macOS)
- [x] h2spec passes over TLS on each loop where it runs, and the curl, s_client, and
      h2load checks pass on macOS and Linux
- [x] At a stop, and at idle_ms, an h2 connection over TLS gets GOAWAY and then
      close_notify
- [x] The in-memory ALPN test passes at -O0 and -O2
- [x] Plaintext user instructions per request unchanged, and HTTP/1.1 over TLS's
      within 0.25% (valgrind, numbers above); on bare-metal Linux with
      `bench/count.sh`, still to run
- [ ] HttpArena's validation passes with baseline-h2, and baseline-h2 is measured
- [x] `docs/decisions.md`, `docs/api.md`, `docs/architecture.md`, `README.md`, and
      `CHANGELOG.md` describe h2 over TLS
