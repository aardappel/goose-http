# 053: Outbound connections

Status: in-progress (asked for 2026-10-19). The blocking socket and the epoll, kqueue,
and io_uring loops' half are built, io_uring's on 2026-10-22, h2 streams that wait
included, and so are the fixes for items 7 and 8 found then. See "Handover" at the end
for what remains.

The loop opens TCP connections to other servers, not only accepts them. goose-postgres
needs them (its task 001), and so do the ACME package's requests to its directory over
goose-tls's client TLS (goose-rest's task 049) and any HTTP client. goose-rest's HttpArena plan (its task 047) puts them before Postgres:
api-4, api-16, gateway-64, gateway-h3, and production-stack all query Postgres.

HttpArena's `async-db` rules ask for an async driver with a pool sized from
`DATABASE_MAX_CONN` (256 at HttpArena `2d85137`, 2026-10-18), so a thread blocking on
each connection won't do. The protocol packages take bytes in and give bytes out, and
the loop owns the socket, as it does for accepted connections.

A second half came with goose-rest's task 052 (2026-10-19): database work with several
queries runs as one job on a lane, which runs no loop, and blocks on its socket.
goose-postgres's blocking facade (its task 002) takes that socket as its transport.

## Steps

1. The API: open a connection to an address and port, learn when it's connected or
   failed, then read and write as on an accepted connection, with its own timeouts.
   Decide which thread owns an outbound connection: the worker that asked, or a lane
   that holds a pool for every worker.
2. A non-blocking connect on each loop: epoll, io_uring (`IORING_OP_CONNECT`), kqueue,
   and IOCP (`ConnectEx`).
3. Name resolution. `getaddrinfo` blocks, so the first version takes `localhost` and
   IP addresses only, and a later one resolves names off the loop.
4. Tests: connect to a test server on each loop, a refused connection, a connect
   timeout, and a peer that closes.
5. A blocking socket, with time limits, for a thread that runs no loop.

## Acceptance criteria

- [x] The API and the owning thread recorded in `docs/decisions.md` and `docs/api.md`
- [ ] Connect, read, write, and close work on epoll, io_uring, kqueue, and IOCP, each
      with a test (epoll, kqueue, and io_uring done, io_uring with a test of its
      stale poll and of a socket hung up at `TIMEOUT`, and each over h2c with a stream
      reset while it waits; the emulated ring and IOCP fail with `ENOSYS`)
- [x] A refused connection and a connect timeout reach the program as errors
- [ ] A blocking socket for lanes, with a test, on Linux, macOS, and Windows (Linux and
      macOS pass; Windows's shim compiles, with Zig's MinGW target, but hasn't run)
- [ ] goose-postgres's task 001 can open its pool on it
- [x] The API's names agreed (2026-10-19)

## Handover

Written 2026-10-19, at the branch's first commit.

### Built

- `socket.goose` (`http::Socket`), imported by `http.goose`:
  - Blocking, for a lane: `connect(host, port, ms)`, `send_all(s, data, ms)`,
    `recv(s, buf, ms)`, `hangup(s)`.
  - On the loop: `connect_start(host, port)`, `connected(s)`, `wait_socket(out, s, events, ms)`
    with `READABLE` and `WRITABLE`, then `WAKE` with tag `SOCKET_READY` or `TIMEOUT`,
    and `recv(s, buf)` and `send(s, data)`, which never block.
  - A host is `localhost`, an IPv4 or IPv6 literal, or `unix:PATH`; other names fail
    with `resolve`'s `ENOSYS` (2026-10-19; the blocking `connect` resolves them since
    2026-10-22, item 4 below).
- The shim, per platform: `net_connect`, `net_connected`, `net_poll`, `net_port`,
  `net_loop_bind`, and `net_arm` in `shim/net.c`, `shim/kqueue.c`, and
  `shim/net_win.c` (where `net_arm` is `ENOSYS`). `sys.goose` declares them, with
  `ENOTCONN`, `ETIMEDOUT`, `ECONNREFUSED`, and `EINPROGRESS`.
- `epoll.goose`: the loop binds its poller for `net_arm` while it runs, and hands an
  event whose tag is a key (at least `SOCKET_KEYS`) to `delivered`, as mail.
- Tests: `test/outbound/outbound_blocking.goose` (round trip through `localhost`, an 8 MiB send,
  a server that closes, refused, a connect timeout against a full backlog, a name, port
  0) and `test/outbound/outbound_loop.goose` (the same through `serve_epoll`'s handler, a 4 MiB
  send, and `ENOSYS` on `serve`). The loops listen on Unix sockets in the test's own
  directory, so parallel runs share no port.
- Docs: decisions ("Outbound connections: blocking on a lane, readiness on the worker's
  loop"), architecture, API ("Outbound connections"), patterns (slow work), README's
  status.

### What passes

On 2026-10-19, at Goose `dcc2747`, the pin:

- `scripts/test.sh` on macOS (M1 Pro, kqueue) and in an arm64 `ubuntu:26.04` container
  on it (Docker Desktop, `--security-opt seccomp=unconfined`, epoll and native
  io_uring): all passed, `test/outbound/` included, both before and after the branch
  was rebased onto `main` with h2c on io_uring merged (`37aa7030`). `wait_socket` on
  `serve` still fails with `ENOSYS` there: only `epoll_loop` binds a poller for it.
- `shim/net_win.c` compiles with `zig cc -target x86_64-windows-gnu`; nothing ran on
  Windows.
- goose-postgres's protocol over the blocking calls against `postgres:18` in Docker
  (host port 55510, SCRAM-SHA-256): it logged in, ran a query with parameters whose
  row held 100,000 bytes, and terminated, and a wrong password failed the login
  cleanly. The program was a scratch file outside both repositories, importing each
  from its checkout, as the facade's would; it isn't kept. goose-postgres's
  `scripts/live.sh` is the place for such a run once the facade exists.

### What remains, in order

1. goose-postgres's task 002 builds its facade on the blocking calls (below), and task
   005 its pool on `wait_socket`.
2. ~~io_uring~~: built 2026-10-22; see "io_uring" below.
3. The emulated ring and IOCP: the emulation can arm its own epoll instance or kqueue
   as `net_arm` does; IOCP needs `ConnectEx` and a zero-byte `WSARecv` for readability.
4. ~~Name resolution in the blocking `connect`~~: built 2026-10-22, with `getaddrinfo`
   in each shim (`net_resolve`), its addresses tried in order. `test/run_tests.py`
   passed on macOS, and the branch's runs on Windows and on Linux in WSL passed
   (2026-10-22). Names on the loop wait until a handler needs one.
5. Run `test/outbound/outbound_blocking.goose` on Windows. `test/run_tests.py` skips
   `test/outbound/` there for now: `outbound_loop.goose` needs `serve_epoll` and a Unix
   socket, and Windows may refuse a connect to a full backlog with `ECONNREFUSED` where
   the blocking test expects `ETIMEDOUT`.
6. ~~An h2 stream waiting on a socket~~: built 2026-10-22; see "io_uring" below.
7. ~~An HTTP/1.1 handler that answers in the call that waited, on io_uring~~: built
   2026-10-22; see "io_uring" below.
8. ~~h2's 413 without `CLOSED`~~: built 2026-10-22; see "io_uring" below.

### io_uring

Built 2026-10-22
([decision](../docs/decisions.md#io_uring-cancels-a-sockets-poll-when-its-wait-ends)):

- `uring.goose` calls `ring_bind` when waiting is configured, so `net_arm` queues a
  one-shot `IORING_OP_POLL_ADD` on the worker's ring (`ur_arm` in `shim/uring.c`,
  reached through `net_loop_ring`, so `shim/net.c` still links without `uring.c`).
  The connect is `connect_start`'s non-blocking one, polled for writable.
- The key stays in a record of the shim's; its completion carries the tag
  `RING_SOCKET` and the record's index, and `ring_socket` turns it into the key, or 0
  for a stale one. The loop reads it only on the path for completions that match no
  connection.
- `resume` calls `ring_disarm(r, key, ~0)` as a wait ends, by `WAKE` or `TIMEOUT`,
  and `close_conn` calls it for the connection's slot before `CLOSED`, when an
  exchange waits or the connection is h2c. The call sits in `resume` once: one in each
  of `delivered`'s and `timed_out`'s paths cost `/plaintext` 2 user instructions per
  request on io_uring, though none runs there.
- An h2 stream's wait can end without `resume`: the client resets the stream, the
  server resets it or answers it 413, or its handler answers in the call that
  waited. `h2_unwait` in `h2.goose` ends each and calls `net_disarm(key)`, which
  `ur_bind` points at the bound ring's `ur_disarm`; on epoll, kqueue, the emulated
  ring, and IOCP it does nothing, since closing a socket takes it off epoll's or
  kqueue's poller, and a stream's key, with its own generation, matches no later
  stream's wait. Only a stream that waits makes the call. Under cachegrind, one
  worker on arm64 Linux in Docker, user instructions per request, before and after:
  `/plaintext` 2672.9 and 2672.9 on epoll, 2729.1 and 2729.5 on io_uring; the REST
  server's `/api/me`, without `X-User-Id`, so a 4xx, 4590.0 and 4590.0 on epoll,
  4611.9 and 4611.5 on io_uring.
- The emulated ring and IOCP get no-op `ur_bind`, `ur_socket`, and `ur_disarm`, and
  `wait_socket` stays `ENOSYS` there.
- `test/outbound/outbound_loop.goose` runs every route on `serve` too, and on io_uring
  `/stale`, a socket that becomes readable after its wait's `TIMEOUT`, which must not
  wake the next wait, and `/hangup`, a socket hung up at `TIMEOUT`, which the backend
  must see closed before it takes the next connection. With `ur_disarm` made a no-op,
  both fail. On the emulated ring each route checks the `ENOSYS`.
- The test runs an h2c listener on `serve_epoll` and on `serve`: `/reset` sends part
  of its response, waits on a backend that never answers, and the client resets the
  stream; `/answered` waits and answers in the same call; a `/ping` after each must
  reach the backend, which serves one connection at a time. With `net_disarm` made a
  no-op, both `/ping`s on io_uring time out.
- HTTP/1.1's `unwait` in `http.goose`, for a handler that answers in the call that
  waited, calls `net_disarm(key)` as `h2_unwait` does. Before, its poll stayed armed
  past the connection's close, since `close_conn` disarms only while an exchange
  waits, and held a socket the handler hung up open until the socket's event. The
  test's `/answered` over HTTP/1.1, then a `/ping`, fails on io_uring without it.
- h2's `refuse_stream`, whose refusal closes the stream (413 for a body past
  `Config.max_body`), calls `h2_abandon` first, so a handler owed a call gets `CLOSED`
  and hangs up its socket, waiting or not. Before, `local_end` closed the stream
  without it. HTTP/1.1's refusals close the connection, whose `close_conn` gives
  `CLOSED`, and h2's resets and the client's call `h2_abandon` already. The test's
  h2c `/big` sends a body past its listener's 16 KiB `max_body` while the handler
  waits, then a `/ping`; without the call it fails on every loop where `wait_socket`
  works. The backend gives up on a socket after 10 s, so a socket left open fails the
  next route rather than hanging the run.
- `/answered`, over HTTP/1.1 and h2c, keeps its socket for the worker's next request
  to hang up, as a pool would. One hung up in the call that waited closes before the
  loop submits its poll, which then fails, so it tested nothing on io_uring.
- `unwait`'s call runs only for an exchange that waits. Under cachegrind, as above,
  before and after: `/plaintext` 2672.9 and 2672.9 on epoll, 2729.4 and 2729.3 on
  io_uring; `/api/me` 4590.0 and 4579.9 on epoll, 4611.7 and 4615.7 on io_uring, all of
  each difference in `http_answer`, where gcc lays the function out differently. The
  call in `retire` instead, which every wait's end passes, cost 1 more on each.

### What goose-postgres's facade calls

```rust
import http from "github.com/kaitk/goose-http@<tag with task 053>";

let s, e = http::connect(cfg.host, cfg.port, connect_ms);   // e.code: ECONNREFUSED, ETIMEDOUT, ...
http::send_all(s, out, ms);          // an http::Error; code 0 when all went
let n = http::recv(s, buf, ms);      // bytes into buf; 0: the server closed; -ETIMEDOUT; -code
http::hangup(s);
```

`pg::Config.host` passes straight in: `localhost`, an address, or `unix:` and a
directory's socket path for a Unix socket (`/var/run/postgresql/.s.PGSQL.5432`), which
the facade builds from a host that starts with `/`, as libpq does. A run against a live
Postgres 18 is recorded under "What passes".

### Traps

- `net_connected` reports a failed connect once: `SO_ERROR` is cleared by the read, and
  a second call gives `ENOTCONN`.
- A refused connect to loopback can fail inside `connect_start` on some platforms, or later in
  `connected`; a handler checks both.
- `wait_socket` arms the socket once (`EPOLLONESHOT`, `EV_ONESHOT`). An armed socket
  whose exchange stopped waiting, by `TIMEOUT` or mail, can still raise its event
  later, while the same exchange waits for something else: it gets a `WAKE` with
  `SOCKET_READY` that means nothing. Hang up the socket at `TIMEOUT`, or treat it as
  "try again". io_uring cancels the poll instead, since it would hold a hung-up socket
  open.
- The connect-timeout tests fill a listener's backlog of 1 with eight connects that are
  never accepted; Linux and macOS then drop the next SYN.

### Answers

- The names (2026-10-19): `dial` became `connect_start`; `http::Socket`, `connected`,
  `wait_socket`, `READABLE`, `WRITABLE`, `SOCKET_READY`, `recv` and `send` on a socket
  (overloads beside the reply's `send`), `connect`, `send_all`, and `hangup` stay.
- `wait_socket` on io_uring, the emulated ring, and IOCP keeps failing with `ENOSYS`
  when it's called (2026-10-19): `serve` can't know at startup whether a handler will
  call it, unlike an h2c or TLS listener. io_uring and IOCP support is to be done on
  the Windows desktop next.
