# 059: Composable parts

Status: in-progress (asked for 2026-10-22), on the branch `composable`.

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
3. [ ] **`body_within(taken, ev, out, limit)` writes its own 413**, and takes an
   `Event` for its kind, data, and the request's length. Change: the verdict
   `body_over(req, taken, limit) -> bool`, `taken > limit || !req.chunked &&
   req.body > limit`, which gives `body_within`'s answer at `REQUEST`, whole or not,
   and at `BODY`; `body_within` would add the event's bytes to `taken` and call it.
   Not done: tried on 2026-10-22, it changes the request path's generated code.
   Goose then inlines `body_within` into `answer` in `bench/rest/goose/rest.goose`
   and `examples/upload/`, where it stayed a call, so the upload routes' C changes,
   and only a count on Linux could say what that costs. A `body_over` beside an
   unchanged `body_within` would leave the generated code as it is, but would repeat
   the comparison rather than compose it. For the maintainer: either, after
   `bench/count.sh` on the upload tier, or neither, since the verdict is one
   comparison of numbers a framework holds, as goose-rest's `arrived` already makes
   it.
4. [ ] **`gather(ev, g, out, limit)` and its pool.** It takes an `Event`, writes 413
   and 500 itself, and fills the worker's pool `gathered` through `gather_head`,
   `gather_piece`, and `release_gather`, which `docs/api.md` doesn't list. goose-rest
   rebuilt gathering in a spill of its own, with a budget, so a goose-rest program's
   gathered bodies, and its WebSocket's runs once it has WebSocket, live in two arenas.
   Design below ([The gather pool](#the-gather-pool)); no code in this branch.
5. [ ] **`otherwise(r, out)` decides among 501, 400, 204, 405, and 404 and writes
   them.** goose-rest rebuilt the decision to answer in its own shape (its
   `runtime.goose`, `otherwise` and `no_route`). Change: `unrouted(r) -> i32`, the
   status, with `r.allow` for `Allow`, and `otherwise` its composition with `start`,
   `field`, and `finish`. `otherwise` is inlined into the benchmark server's handler,
   so its generated code must be compared first.
6. [ ] **`require_type(req, out, want)` and `accept_or_406(req, out, offers)` write
   415 and 406.** Their verdicts, `has_type` and `negotiate`, exist, but
   `docs/api.md` doesn't list them, and goose-rest calls `has_type`. Change: list them.
7. [ ] **`upgrade(out, protocol)` writes 501 itself on an h2 stream.** The verdict is
   `out.minor == http::H2_MINOR`, and the switch after a 101 a program writes itself
   is `switched(out)`; `docs/api.md` lists neither. Change: list them.
8. [ ] **`serve_file(req, out, f, content_type, body)` chooses 304, 416, 206, or 200**
   from `not_modified` and `range_of`, which are public, but the entity tag it builds
   isn't, so a program that answers a 304 or 416 itself can't match it. Change:
   `file_tag(f)`, the `ETag` that `serve_file` sends. Low: no framework asks for it.
9. [ ] **`client(req, out, trusted)` takes a `Reply`** for its socket alone.
   `forwarded_client(req, p, trusted)` takes the peer, but isn't listed. Change: list
   it.
10. [ ] **The loops' own refusals** go out in the package's shape, with an empty body:
    400, 408, 413 past `Config.max_body`, 414, 431, and 500 for a request no handler
    answered, before the handler is called or in its place, and the 413 that `whole`
    writes for a chunked body that didn't come whole. A framework can't give them its
    error body (goose-rest answers with RFC 9457 problems). No small change exists: an
    event before each refusal adds a kind and grows `answer`, and Goose can't store a
    writer the program gives (spec §7.6). Open: whether these refusals need a
    framework's shape at all, since RFC 9110 asks for no body.
11. [ ] **Parts a framework already calls that `docs/api.md` doesn't list.** goose-rest
    calls `parse`, `refuse`, `status_line`, `write_body`, `known_method`,
    `is_routable`, `same_segment`, `has_type`, and `field_in`, and its test harness
    builds a `Stream` and reads its `Framing`. Change: list them as parts, or name
    what replaces each, so a change to one is an API change.

Checked and left as they are:

- Writers with no verdict in them: `respond`, `respond_json`, `challenge`,
  `set_cookie`, `begin`, `send`, `end`, `insert_field`, `ws_send`, and `ws_close`.
- Verdicts and readers already: `has_type`, `negotiate`, `not_modified`, `range_of`,
  `upgrade_of`, `field_of`, `find_part`, `start_multipart`, and `each_part`, which
  takes the body's piece, not the `Event`.
- `whole(ev, out)`, the adapter that gives `serve(cfg)`'s handler its request and
  body. A framework uses the handler with state; its 413 is item 10's.
- `respond_compressed` and `begin_compressed`, compositions of `coding_for`,
  `compressible`, and `coding_field`, which are public. Their encoders are each
  worker's, reached through the `Compressed` a handler holds, as goose-rest's
  `compression.goose` does.

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

Item 4, a design for the maintainer; nothing here is built.

### What each side has now

`http::gather` keeps a body that didn't come with its head in a run of `gathered`, a
`reusable[]` global and so each worker's own, which only a program that calls `gather`
or `http.websocket` has. A run starts at 16 KB, or the first piece, and doubles as the
body grows; a body past `limit` gets 413. Nothing bounds the pool as a whole: a worker
can hold `max_conns` bodies of `limit` bytes. WebSocket keeps a frame not yet whole and
a fragmented message in runs of the same pool.

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

### Proposal

Make the pool's runs a public part, with an optional budget inside the pool, and keep
`gather` and `Gather` as the convenience over them. goose-rest's three kinds of run
then go in `gathered`, and it drops its spill and the functions above.

```rust
// Each worker's, before its loop: the most bytes the pool may reach; 0, the default, for none.
fn gather_budget(bytes: i64)
// A run of exactly n bytes; with checked, nothing and false where it would pass the budget.
fn gather_run(n: i64, checked: bool = false) -> i64, i64, bool          // at, cap, ok
// The run at, of cap bytes, made to hold n: as it is, doubled, or exactly n where doubling
// would pass the budget; with checked, unchanged and false where n would.
fn gather_grow(at: i64, cap: i64, n: i64, checked: bool = false) -> i64, i64, bool
fn gather_free(at: i64, cap: i64)
```

The bytes are `http::gathered[at..at + n]`, as `ws_take` reads them now. `Gather`'s
functions, `gather_head`, `gather_piece`, and `release_gather`, become compositions of
these, and `gather_head` reserves a Content-Length body's exact run at the head when a
budget is set. `gather` answers a refusal 503 with `Retry-After: 1` and closes, as
goose-rest does; a framework calls the parts and answers in its own shape.

- **The budget bounds the pool's length**, as goose-rest's does, since that is what the
  worker keeps. The pool mirrors its runs, as `Budget.runs` does, only while a budget
  is set: a program that gathers without one pays a branch per run placed or freed.
- **Checked or not is the caller's choice per run.** A run that may be refused, a body
  or a collected reply, is checked; one that mustn't fail, a middleware's kept fields
  or WebSocket's partial frame, isn't, but still counts toward the length the next
  checked run sees.
- **The parts take a run's place, `at` and `cap`, not a `Gather`**, so a framework
  stores a run in as few bytes as it likes, as goose-rest does for a reply.

Who gains:

- goose-rest: one arena per worker, one high-water mark, and one budget, its
  WebSocket's runs included once it has WebSocket. The functions above and its
  `gather_head`, `gather_piece`, and `run_size` are about 100 lines, with comments.
- Programs that call `http::gather`: a Content-Length body's run stops at its length,
  where today a 520 KB body doubles to a 1 MB run; under a budget it is reserved whole
  at the head and copied once. And an optional budget bounds what gathered bodies and
  WebSocket's runs may take of a worker, which today only `max_conns` times `limit`
  bounds.
- Programs that never call `gather` or `http.websocket`: nothing changes. Goose
  compiles a function only where it's called, and the globals only those functions
  use, `gathered`, the budget, and its mirror, aren't in the program.

### Open questions

1. **Bound the length, or the bytes in use?** The bytes in use need one counter, with
   no mirror and no scan, but fragmentation can take the length past the budget. The
   length is what memory follows, and goose-rest chose it. Recommended: the length.
2. **Could Goose tell where a slice pool would place a run**, or expose its free
   spans? Either removes the mirror and its scan. A feature request for
   `docs/goose-findings.md`, if the maintainer wants one.
3. **Where the budget is set.** `gather_budget(bytes)` in each worker before its
   loop, since a worker's globals are its own, rather than a `Config` field read by
   code the loop doesn't call (the rule against shared fields for one feature), or a
   budget passed to each call, as goose-rest's `Budget&` is now. Recommended: the
   function.
4. **Exact runs at the head without a budget.** A head alone would make the worker
   reserve, and Goose fill with zeros, a whole announced body: `max_conns` heads could
   reserve `max_conns` times `limit`. Recommended: exact runs at the head only under a
   budget; without one, growth that doubles but stops at the announced length.
5. **Are WebSocket's runs checked?** `WebSocket.limit` bounds them per connection.
   Checked, a refused frame would need a close code, 1011 or 1009. Recommended:
   unchecked but counted.
6. **The convenience's refusal.** 503 with `Retry-After: 1` and a close, as goose-rest
   answers, or a 503 that keeps the connection while the rest is under
   `Config.max_drain`.
7. **The loops' own spill stays apart.** The epoll and io_uring loops keep a
   connection's held bytes and queued output in a `reusable[]` local of the loop,
   which a handler can't reach without a field in `Reply`. Recommended: keep it apart;
   the pool is for what handlers hold.

## Acceptance criteria

- [x] The decision recorded in `docs/decisions.md`
- [x] The audit, above
- [x] Items 1 and 2: the parts in `websocket.goose`, with tests under
      `test/websocket/` and `docs/api.md`; the 101, the refusals, and the frames
      unchanged byte for byte, and the request path's generated code unchanged
- [x] Item 3 done, or the reason it waits recorded here
- [x] Item 4's design, with its open questions
- [x] `scripts/test.sh` passes on macOS: with `AUTOBAHN=1`, on an M1 Pro, macOS 26.3,
      2026-10-22, each loop's Autobahn run 296 OK, 2 NON-STRICT, and 3 INFORMATIONAL,
      as task 054 recorded
- [ ] Items 5 to 11 done or decided by the maintainer
