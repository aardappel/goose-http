# 061: h2 over TLS, chosen by ALPN

Status: in-progress (asked for 2026-10-22). h2 over TLS serves from both loops, on
`main`, over goose-tls `v0.0.4`'s TLS 1.3 server in Goose, and the benchmark server
serves static-h2's `/static/`. HttpArena's validation passes; its baseline-h2 and
static-h2 runs remain.

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
   `http/1.1` alone, as HttpArena's json-tls and static-tls pages ask. Replaced the
   same day: both ports share one context that offers h2
   ([decisions](../docs/decisions.md#the-benchmark-server-offers-h2-on-both-tls-ports),
   [below](#the-benchmark-server)).
3. static-h2 is in scope only if it needs no more than the 8443 listener and the
   existing static-file route over h2. Widened the same day: the server serves
   `/static/` too ([below](#static-h2)).
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
listeners. The server first kept 8081's context at `["http/1.1"]`, as decision 2 had
it, and served `H2_PORT` (its port + 363, 8443 beside 8080; 0 for none) from a second
context, `["h2", "http/1.1"]`, and a second set of workers, as many as the first. That
cost a second set of idle workers in every TLS profile: their threads, stacks, rings,
and buffers. With `WORKERS=4`, the TLS build's resident memory after 2 s idle went
from 19.5 to 30.2 MB on io_uring and from 17.3 to 28.0 MB on epoll, about 2.7 MB per
idle worker (Docker Desktop on an Apple M-series Mac, arm64 Ubuntu 26.04, `VmRSS`,
2026-10-22): about 170 MB more on a server with 64 workers, in json-tls as in
baseline-h2.

So both TLS listeners now share one context, `["h2", "http/1.1"]`, and one set of
workers (2026-10-22,
[decisions](../docs/decisions.md#the-benchmark-server-offers-h2-on-both-tls-ports)):
`TLS_PORT` and `H2_PORT` are two listeners of the same workers, which takes the loop
to four listeners with h2c's, the most `MAX_LISTENERS` and the emulated ring allow.
HttpArena's validation (at the pinned `3717e256`) allows `h2` on 8081: its json-tls,
static-tls, and 8gbit checks ask with `curl --http1.1` and with `openssl s_client
-alpn http/1.1`, and accept either protocol where curl offers both. Those profiles
load 8081 with wrk, which offers no ALPN (`wg/wrk`'s `ssl.c` at `a211dd5a` sets none),
so they still measure HTTP/1.1. With `WORKERS=4` on macOS (Apple M1 Pro, `ps` RSS
after 2 s idle, the median of three, 2026-10-22), the TLS build went from 7.6 to
6.3 MB on kqueue and from 7.9 to 6.4 MB on the emulated ring; macOS touches few of an
idle worker's pages, so Linux's `VmRSS`, as measured above, is still to take.

The Dockerfile exposes 8443. `meta.json` lists static-h2; baseline-h2 once
HttpArena's validation passes with it.

### static-h2

The server serves `/static/NAME` as it serves `/files/NAME`, from the directory
`FILES` names, which the Dockerfile sets to `/data/static`, where HttpArena mounts its
20 files with their pre-compressed `.br` and `.gz` siblings; the route picks a
sibling by `Accept-Encoding`. `/files/` stays, for `bench/files.sh`, `bench/oha.sh`,
and the tests, whose rival servers serve a directory named `files`.

`app.js` goes out as `text/javascript`, `http::content_type_of`'s type, which RFC 9239
made the type for JavaScript, where HttpArena's static checks name
`application/javascript`. The benchmark server was to map `.js` to
`application/javascript` itself, but HttpArena's `check_header` treats the two as
equal (RFC 9239), at the pinned `3717e256` and at `0720ee57`, which this task first
read, so the server keeps the package's type.

## Tests

- `scripts/test-http.sh`, on both loops: `curl -k --http2` gets HTTP/2 and
  `curl -k --http1.1` HTTP/1.1 on the h2 port, and `--http2` HTTP/2 on the TLS port,
  which shares its context; `openssl s_client -alpn h2` and `-alpn http/1.1`
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

### On Linux (2026-10-22)

Tiamat (Ryzen 7 5800X3D, WSL2 Ubuntu 26.04.1, kernel 6.18.54.1, gcc 15.2, Goose
v2026.3, perf 6.18, h2load 1.68.0), `main` at `2127390f` (goose-tls `v0.0.4`) against
v0.5.0 (`e128cb39`, goose-tls `v0.0.3`, libssl's server). `scripts/test.sh` passed on
every loop, with h2spec 146/146 over h2c and TLS on each. `bench/count.sh` at
N=1,000,000; the TLS rows by its perf and h2load command (`-c 256 -m 16 -t 8`), so
they weigh the swap of server along with this task's change:

| Row | Loop | v0.5.0 | `2127390f` | Change |
|---|---|---:|---:|---:|
| `/plaintext` | io_uring | 1,930.8 | 1,923.7 | -7.1 |
| `/api/me` | io_uring | 3,667.9 | 3,667.9 | 0 |
| HTTP/1.1 over TLS, `/json` | epoll | 6,078.6 | 5,146.2 | -15.3% |
| HTTP/1.1 over TLS, `/json` | io_uring | 6,862.0 | 6,041.1 | -12.0% |
| h2 over TLS, `/json` | epoll | | 11,111.0 | |

The benchmark server's idle `VmRSS` with TLS and 4 workers, median of three, fell from
10,696 to 10,224 kB on epoll and from 12,744 to 12,040 kB on io_uring. HttpArena's
validation at `3717e256` passed json-tls, baseline-h2, and static-h2 (for static-h2:
the certificate, TLS 1.3, ALPN h2, content types, size, and 404). The report of that
run lost the epoll plaintext rows and h2 on io_uring.

v0.5.2 (`136d49cd`, goose-tls `v0.0.5`) against v0.5.1 (`297de935`, goose-tls
`v0.0.4`), the same way on the same machine: `scripts/test.sh` passed on every loop,
and HttpArena's validation passed baseline-h2 and static-h2, 82 checks in all.
Plaintext and `/api/me` didn't change on either loop. Idle `VmRSS` moved by 40 kB or
less, within the runs' spread.

| Row | Loop | v0.5.1 | v0.5.2 | Change |
|---|---|---:|---:|---:|
| `/plaintext` | epoll | 1,893.3 | 1,893.3 | 0 |
| `/plaintext` | io_uring | 1,923.7 | 1,923.7 | 0 |
| HTTP/1.1 over TLS, `/json` | epoll | 5,146.3 | 4,879.5 | -5.2% |
| HTTP/1.1 over TLS, `/json` | io_uring | 6,042.2 | 5,825.8 | -3.6% |
| h2 over TLS, `/json` | epoll | 11,089.9 | 10,842.2 | -2.2% |
| h2 over TLS, `/json` | io_uring | 11,171.2 | 10,974.2 | -1.8% |

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
- [ ] HttpArena's validation passes with baseline-h2 and static-h2 (passed on Tiamat,
      2026-10-22), and both are measured
- [x] `docs/decisions.md`, `docs/api.md`, `docs/architecture.md`, `README.md`, and
      `CHANGELOG.md` describe h2 over TLS
