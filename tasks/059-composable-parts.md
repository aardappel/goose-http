# 059: Composable parts

Status: in-progress (asked for 2026-10-22); items 5, 8, 13, and 14 open.

Every convenience is a composition of public parts
([decision](../docs/decisions.md#every-convenience-is-a-composition-of-public-parts)):
a check returns its verdict and a separate function writes the response, a protocol
function takes bytes rather than an `http::Event`, and a resource a worker keeps is one
a program can reach. Breaking changes cost least before v0.5.0 is tagged, so this task
audits the API against the rule, makes the changes that are small and clear, and
proposes the rest.

## Audit

Of `docs/api.md` and the `.goose` sources at `73c2d23b` (2026-10-22). Goose has no
namespace privacy, so any function in `http` can be called; a part is public here when
`docs/api.md` lists it, since that is what the package keeps. Each item names the
smallest change: usually the part exposed, with the convenience a short composition of
it. None may add instructions to a request ([task 027](027-idiomatic-api.md)).

1. [x] **`ws_upgrade(req, out, protocol)` decides and writes.** Its 426s, 400, and
   501 are the package's, so a framework can't answer in its own error shape.
   Change: `ws_check(req, minor)`, the verdict, with the key a 101 needs and the
   fields a refusal must carry, and `ws_switch(out, key, protocol)`, the 101 and the
   switch to frames. `ws_upgrade` composes them. Done ("WebSocket's parts" below).
2. [x] **`ws_read(ev, ws, out)` takes an `Event`** for its `kind` and `data`. A
   framework's handler holds the bytes in a context of its own. Change:
   `ws_take(bytes, ws, out)`, beside `ws_release` for `CLOSED`; `ws_read` calls one or
   the other. Done.
3. [x] **`body_within(taken, ev, out, limit)` writes its own 413**, and takes an
   `Event` for its kind, data, and the request's length. Change: the verdict
   `body_over(req, taken, limit) -> bool`, `taken > limit || !req.chunked &&
   req.body > limit`, which gives `body_within`'s answer at `REQUEST`, whole or not,
   and at `BODY`; `body_within` would add the event's bytes to `taken` and call it.
   Not done: tried on 2026-10-22, it changes the request path's generated code.
   Goose then inlines `body_within` into `answer` in `bench/rest/goose/rest.goose`
   and `examples/upload/`, where it stayed a call, so the upload routes' C changes,
   and only a count on Linux could say what that costs. A `body_over` beside an
   unchanged `body_within` would leave the generated code as it is, but would repeat
   the comparison rather than compose it. Decided (2026-10-22): neither. The verdict
   is one comparison of numbers a framework holds, as goose-rest's `arrived` already
   makes it, too small to be a part.
4. [x] **`gather(ev, g, out, limit)` and its pool.** It takes an `Event`, writes 413
   and 500 itself, and fills the worker's pool `gathered` through `gather_head`,
   `gather_piece`, and `release_gather`, which `docs/api.md` didn't list. goose-rest
   rebuilt gathering in a spill of its own, with a budget, so a goose-rest program's
   gathered bodies, and its WebSocket's runs once it has WebSocket, live in two arenas.
   Done (2026-10-22): the pool's parts are public, under a budget that counts bytes
   promised and refuses at admission ([The gather pool](#the-gather-pool)).
5. [ ] **`otherwise(r, out)` decides among 501, 400, 204, 405, and 404 and writes
   them.** goose-rest rebuilt the decision to answer in its own shape (its
   `runtime.goose`, `otherwise` and `no_route`). Change: `unrouted(r) -> i32`, the
   status, with `r.allow` for `Allow`, and `otherwise` its composition with `start`,
   `field`, and `finish`. `otherwise` is inlined into the benchmark server's handler,
   so its generated code must be compared first. Built (2026-10-22): `otherwise`
   matches on `unrouted`'s status, each arm starting a constant one, which the inline
   writers fold. The benchmark server and `examples/routes` keep the same functions,
   and their machine code changes by +48 and −76 bytes (Apple clang, `-O2`); the
   router test passes unchanged. Not landed until `bench/count.sh` on Linux shows
   the 404 path's instructions per request unchanged (tier A's `/nothing`).
   goose-rest's generated router has no `Router`, and built one for the verdict
   (2026-10-22), so the verdict takes its parts too: `unrouted(method, path,
   routable, allow)`, which `unrouted(r)` calls. The benchmark server's `.text` is
   unchanged and `examples/routes`'s 4 bytes smaller (Apple clang, `-O2`).
6. [x] **`require_type(req, out, want)` and `accept_or_406(req, out, offers)` write
   415 and 406.** Their verdicts, `has_type` and `negotiate`, exist, but
   `docs/api.md` doesn't list them, and goose-rest calls `has_type`. Change: list them.
   Done (`docs/api.md`, "Parts").
7. [x] **`upgrade(out, protocol)` writes 501 itself on an h2 stream.** The verdict is
   `out.minor == http::H2_MINOR`, and the switch after a 101 a program writes itself
   is `switched(out)`; `docs/api.md` lists neither. Change: list them. Done.
8. [x] **`serve_file(req, out, f, content_type, body)` chooses 304, 416, 206, or 200**
   from `not_modified` and `range_of`, which are public, but the entity tag it builds
   isn't, so a program that answers a 304 or 416 itself can't match it. Change:
   `file_tag(f)`, the `ETag` that `serve_file` sends. Low: no framework asks for it.
   Done (2026-10-22): `inline fn file_tag(f) -> u8[>..]`, which `serve_file` calls.
   Goose inlines it, so the C differs only in a block around the tag's appends; built
   with Apple clang, `-O2`, `.text` is 244 bytes smaller on the epoll server and 328
   on `examples/files`, whose handler takes in `serve_file`.
9. [x] **`client(req, out, trusted)` takes a `Reply`** for its socket alone.
   `forwarded_client(req, p, trusted)` takes the peer, but isn't listed. Change: list
   it. Done.
10. [x] **The loops' own refusals** go out in the package's shape, with an empty body:
    400, 408, 413 past `Config.max_body`, 414, 431, and 500 for a request no handler
    answered, before the handler is called or in its place, and the 413 that `whole`
    writes for a chunked body that didn't come whole. A framework can't give them its
    error body (goose-rest's is JSON with an error code by default, with RFC 9457
    problems as a preset). No small change exists: an event before each refusal adds a
    kind and grows `answer`, and Goose can't store a writer the program gives (spec
    §7.6). Decided (2026-10-22): they stay as they are, an engineering choice: RFC
    9110 §15.5 recommends an explanation in a 4xx's body. They come before any route.
    A legitimate request meets them past a deployment's ceiling, on a slow link, or
    after a handler bug; the common one, a body past a route's limit, a framework
    answers in its own shape below `Config.max_body`. Hyper and Actix also send
    parser-level refusals with no body. Should a framework need its shape, `refuse`
    could call an overload on the loop's state type, `fresh`'s before a request and
    the exchange's during one, declared in `http`, as goose-rest's `rest::error_body`
    is in `rest`; that needs `refuse` to take the state, and a comparison of the
    generated code, before calling it free.
11. [x] **Parts a framework already calls that `docs/api.md` doesn't list.** goose-rest
    calls `parse`, `refuse`, `status_line`, `write_body`, `known_method`,
    `is_routable`, `same_segment`, `has_type`, and `field_in`, and its test harness
    builds a `Stream` and reads its `Framing`; its compression calls `compress_whole`,
    `field_at`, and `same_name`. Change: list them as parts, or name what replaces
    each, so a change to one is an API change. Done, with compression's parts,
    `coding_for`, `coding_q`, `compressible`, and `coding_field`, which this audit
    first called public though `docs/api.md` listed none.
12. [x] **`TIMEOUT` meant two things**: `later`'s time passed, or no room to wait, so
    the exchange got it at once. A framework that answers 503 for the second and 504
    for the first told them apart by the clock (goose-rest's `rest::pause` and
    `on_event`). Change: the tag `NO_ROOM` on the second. Done, in `timed_out`, which
    runs per `TIMEOUT`, not per request.
13. [ ] **`begin_compressed` takes and resets a worker's pooled encoder** as it
    writes the response's head. A program that builds its own head can't take the
    encoder alone. Recorded; no framework asks for it yet.
14. [ ] **`open_precompressed(req, path)`** negotiates, probes the files, picks the
    fresher, and closes the ones it doesn't use. Its parts exist, `coding_q` now
    listed. Recorded, as item 13.

Checked and left as they are:

- Writers with no verdict in them: `respond`, `respond_json`, `challenge`,
  `set_cookie`, `begin`, `send`, `end`, `insert_field`, `ws_send`, and `ws_close`.
- Verdicts and readers already: `has_type`, `negotiate`, `not_modified`, `range_of`,
  `upgrade_of`, `field_of`, `find_part`, `start_multipart`, and `each_part`, which
  takes the body's piece, not the `Event`.
- `whole(ev, out)`, the adapter that gives `serve(cfg)`'s handler its request and
  body. A framework uses the handler with state; its 413 is item 10's.
- `respond_compressed`, a composition of `coding_for`, `compressible`,
  `coding_field`, and `compress_whole`, listed as parts (item 11). Its encoders are
  each worker's, reached through the `Compressed` a handler holds, as goose-rest's
  `compression.goose` does; `begin_compressed` is item 13.

## WebSocket's parts

Items 1 and 2, in `websocket.goose`:

```rust
fn ws_check(req: const Request&, minor: i32) -> i32, const u8[:], const u8[:]  // status, key, fields
fn ws_switch(out: Reply, key: const u8[:], protocol: const u8[:] = "")
fn ws_take<F>(bytes: const u8[:], ws: WebSocket&, out: Reply)                 // F(op, data, out)
```

`ws_check` takes `out.minor` rather than the `Reply`, since it writes nothing and needs
only to know an h2 stream. A 426 needs one of two fields, so the verdict returns them
as whole lines: a status alone couldn't tell `Upgrade: websocket` from
`Sec-WebSocket-Version: 13`. The subprotocol is the program's choice, not the
request's, so `ws_check` doesn't take it: `ws_upgrade` turns a 101 into 400 for one
`is_field` refuses, as before, and `ws_switch` leaves such a protocol out, as `field`
does. `ws_take` keeps `ws_read`'s order, the bytes where the event was.

Checked on macOS, at Goose v2026.3:

- The golden files of `ws_handshake` and `ws_frames` are unchanged, so `ws_upgrade`'s
  101 and refusals and `ws_read`'s frames are byte for byte what they were.
  `ws_parts` adds `ws_check`'s verdicts, a refusal in a program's own shape,
  `ws_switch`'s 101 against `ws_upgrade`'s, and `ws_take` from bytes alone against
  `ws_read` from events, with the same bytes back, pipelined, a byte per call, cut
  short, and over the limit. `scripts/test-http.sh`'s WebSocket echo passes on the
  epoll build.
- The C that Goose generates for `server/server.goose`, `server_epoll.goose`, and
  `server_tls.goose`, normalized for specialization and constant numbers, differs from
  `73c2d23b`'s only in `ws_upgrade`, `ws_read`, `ws_frames` (one more nested block for
  `ws_take`'s), and the new `ws_check`, `ws_switch`, and `ws_take`. For
  `bench/rest/goose/rest.goose` and `examples/upload/`, which don't import the module,
  it is identical.
- In the epoll server built with Apple clang, `ws_frames` is the same 419
  instructions, and `echo_frames`, which inlines `ws_read`, went from 587 to 581.
  `ws_upgrade` grew from 1,446 to 1,589, taking in `base64::encode` and SHA-1's
  rounds, once a connection. `http::upgrade`, with one caller left, the server's
  `/upgrade`, now has its `"echo"` folded in, which takes 3 instructions from each of
  that route's call sites in `answer` and `call`. The rest of the request path is the
  same instructions, with a few registers renamed in `call`.

## The gather pool

Item 4, built on the branch `gather-pool` (2026-10-22), as the
[decision](../docs/decisions.md#the-gather-budget-counts-bytes-promised-and-refuses-at-admission)
records.

### What each side had

`http::gather` kept a body that didn't come with its head in a run of `gathered`, a
`reusable[]` global and so each worker's own, which only a program that calls `gather`
or `http.websocket` has. A run started at 16 KB, or the first piece, and doubled as the
body grew; a body past `limit` got 413. Nothing bounded the pool as a whole: a worker
could hold `max_conns` bodies of `limit` bytes. WebSocket kept a frame not yet whole and
a fragmented message in two runs of the same pool, unbounded but by `WebSocket.limit`.

goose-rest keeps its own `reusable[]` spill, a local of each worker's `rest::serve`, for
three kinds of run (its `runtime.goose`):

- a body that `rest::body` gathers: a run of the rebuilt head and the body's exact size
  for a Content-Length, reserved at the head, which never grows or moves; for a chunked
  body, 16 KB, doubling;
- a reply that a lane sends in pieces, collected (`collect_reply`), whose length and
  capacity it keeps in the run's first 16 bytes, to save its connection slot the bytes;
- what an exchange's middleware kept for a later answer, about 100 bytes
  (`stash_kept`).

A `Budget` bounds the spill's length, its high-water mark, which the worker keeps for
its life: `rest::Config.gather_budget`, 64 MB by default. A run that would take the
spill past it is refused, and goose-rest answers the request 503 with `Retry-After: 1`,
at the head for a Content-Length, or a reply 502. To know whether a run fits, the
`Budget` mirrors every run in use, its middleware's included, and predicts where
`alloc_slice` and `realloc_slice` would put the next one, which spec §5.4 defines as the
first free span in index order (`track`, `untrack`, `spill_end`, `free_at`,
`grown_end`, `grow_run`): a scan of the runs in use for each run placed.

### What was built

The pool's runs are public parts under a budget that is always there, and `gather` and
`ws_upgrade` are compositions of them. A run is an `http::Gather`, which gained `most`,
the bytes promised it; its bytes are `http::gathered[g.at..g.at + g.len]`.

```rust
let GATHER_BUDGET: i64 = 64 << 20;
fn gather_budget(bytes: i64)                                // the worker's; main's is copied at spawn
fn gather_promise(g: Gather&, most: i64) -> bool            // false: nothing promised
fn gather_piece(g: Gather&, data: const u8[:]) -> bool      // false: past g.most, nothing appended
fn gather_clear(g: Gather&)                                 // frees the run, keeps the promise
fn release_gather(g: Gather&)                               // frees both
fn gather_head(g: Gather&, req: const Request&, limit: i64) -> bool
fn ws_admit(ws: WebSocket&) -> bool                         // ws.limit + WS_SLACK (131)
fn ws_upgrade(req: const Request&, ws: WebSocket&, out: Reply, protocol: const u8[:] = "") -> bool
```

- `gather_head` promises the rebuilt head and the body, a Content-Length's exact size
  in a run placed whole at the head, or a chunked body's `limit`. `gather` answers a
  refusal 503 with `Retry-After: 1` and closes; its 413 for a chunked body past
  `limit` is now `gather_piece`'s false, since the promise is the limit.
- A WebSocket holds one run, `WebSocket.held`: the message so far, its first `joined`
  bytes, then a frame not yet whole. That frame takes from the next bytes only what it
  lacks (`ws_length`), where the pending run took a whole read before, and a fragment's
  payload, unmasked already, takes the frame's place (`ws_join`). So the run never
  holds more than the limit and 131 bytes, the promise `ws_admit` makes at the
  upgrade. `ws_upgrade` refuses with 503 and `Retry-After: 1` where it can't, and keeps
  the connection. `WebSocket.limit`'s default is 64 KiB, from 1 MiB.
- The benchmark server keeps a spare `WebSocket` that `ws_upgrade` admits, which
  `open_socket` moves into `sockets`, with `WS_LIMIT` for its limit: 64 KiB by default,
  for HttpArena's 5-byte frames, and 16 MiB in `scripts/test-autobahn.sh`, the longest
  message Autobahn sends. `http_client.py`'s WebSocket check sends 60 KiB in fragments,
  where it sent 3 MiB, and a frame past the limit, which gets 1009.

goose-rest can then keep its three kinds of run in `gathered`: a body in an
`http::Gather` from `http::gather_head`, refused at `rest::body` where it returns
false; a kept run from `gather_promise` and `gather_piece`; and a collected reply in a
`Gather` promised its most when the route asks. It drops its spill, `Budget`, `Run`,
`track`, `untrack`, `spill_end`, `free_at`, `grown_end`, `grow_run`, `placed_end`,
`fits`, `run_size`, and its own `gather_head`, `gather_piece`, and `release`, and sets
`rest::Config.gather_budget` with `http::gather_budget`. A chunked body is then refused
at `rest::body`, not once it grows past the budget, and a reply needs a most bytes to
promise, which `rest::ask` doesn't take yet.

### The open questions, answered

1. **Bound the length, or the bytes promised?** The bytes promised: a promise of
   growth can't be checked against a length until the growth is placed, so a length
   budget refuses a chunked body or a WebSocket message partway, and needs the mirror.
   The length can pass the budget by what fragmentation leaves free; that is the
   trade-off the decision records.
2. **Goose placement or free spans.** Not needed: no mirror is left. Only a bound on
   the length would need it, which the decision names and no one asks for yet.
3. **Where the budget is set.** `gather_budget(bytes)`, per worker; main's value is
   each worker's at spawn, since a worker copies main's globals.
4. **Exact runs at the head.** Always, since a budget always is: the budget bounds what
   `max_conns` heads can make the worker zero-fill.
5. **WebSocket's runs.** Admitted at the upgrade, the promise held for the
   connection's life, one run of the limit and 131 bytes.
6. **The convenience's refusal.** 503 with `Retry-After: 1`, and for a body a close,
   since the rest would be drained under memory pressure; an upgrade has no body, so
   its connection stays.
7. **The loops' own spill** stays apart.

Checked on macOS, at Goose v2026.3:

- The golden files of `ws_frames` and `body_limits` are unchanged, so the frames a
  connection sends back, split across reads every way the test splits them, and
  `gather`'s answers are byte for byte what they were. `ws_frames` asserts the run
  never passes its promise after each read, and that `CLOSED` gives the promise back.
  `test/api/gather_pool.goose` adds the parts, `gather_head`'s runs, and `gather`'s
  503 at the head; `ws_handshake` the upgrade's 503 and the promise each 101 holds;
  `ws_parts` a framework's own 503 from `ws_admit`.
- The C that Goose generates for `examples/hello/` and `bench/rest/goose/rest.goose`,
  which don't gather, differs only in three numbers in main's globals and their
  initialization, which no worker copies.
- On the benchmark server, built with gcc for arm64 Linux in Docker and counted with
  valgrind over 100,000 plaintext requests, a request costs 1,543.9 instructions
  before and after. Written in `handle` rather than in `upgrade_ws`, the upgrade's new
  call cost 12 more.

Measured on Linux, on Enkidu (AMD Ryzen 7 PRO 6850U, WSL2 Ubuntu-26.04), Goose v2026.3
and gcc 15.2.0, `e73b9870` before and `b5f82a2d` after:

- Instructions per request are unchanged: `/plaintext` 1,894.7 on epoll, and 1,930.5
  and 1,930.6 on io_uring; tier A's `/api/items/1` 4,149.5 on epoll and 4,185.9 on
  io_uring.
- `.text` is 1,984 bytes smaller on the plaintext server and 256 on the REST tier
  server.
- Tier D's uploads per second, the median of 3 rounds of 5 s, before and after, all
  within the rounds' range:

  | Loop | Alone | Beside forms |
  |---|---:|---:|
  | io_uring | 643.7 → 651.4 | 99.5 → 103.6 |
  | epoll | 677.7 → 671.0 | 78.7 → 79.1 |

- Peak RSS is unchanged: 69-71 MB alone, 125-129 MB beside forms.
- perf profiles of uploads alone match, with no allocation function above 0.8%.

## Acceptance criteria

- [x] The decision recorded in `docs/decisions.md`
- [x] The audit, above
- [x] Items 1 and 2: the parts in `websocket.goose`, with tests under
      `test/websocket/` and `docs/api.md`; the 101, the refusals, and the frames
      unchanged byte for byte, and the request path's generated code unchanged
- [x] Item 3 done, or the reason it waits recorded here
- [x] Item 4's design, with its open questions
- [x] Item 4 built: the pool's parts under a budget of bytes promised, with tests under
      `test/api/` and `test/websocket/`, `docs/api.md`, `docs/architecture.md`, and the
      decision; the plaintext path's executed instructions unchanged
- [x] `scripts/test.sh` passes on macOS: with `AUTOBAHN=1`, on an M1 Pro, macOS 26.3,
      2026-10-22, each loop's Autobahn run 296 OK, 2 NON-STRICT, and 3 INFORMATIONAL,
      as task 054 recorded
- [ ] Items 5 to 11 done or decided by the maintainer
