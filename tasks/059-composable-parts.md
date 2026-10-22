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

1. [ ] **`ws_upgrade(req, out, protocol)` decides and writes.** Its 426s, 400, and
   501 are the package's, so a framework can't answer in its own error shape.
   Change: `ws_check(req, minor)`, the verdict, with the key a 101 needs and the
   fields a refusal must carry, and `ws_switch(out, key, protocol)`, the 101 and the
   switch to frames. `ws_upgrade` composes them.
2. [ ] **`ws_read(ev, ws, out)` takes an `Event`** for its `kind` and `data`. A
   framework's handler holds the bytes in a context of its own. Change:
   `ws_take(bytes, ws, out)`, beside `ws_release` for `CLOSED`; `ws_read` calls one or
   the other.
3. [ ] **`body_within(taken, ev, out, limit)` writes its own 413**, and takes an
   `Event` for its kind, data, and the request's length.
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

## Acceptance criteria

- [x] The decision recorded in `docs/decisions.md`
- [x] The audit, above
- [ ] Items 1 and 2: the parts in `websocket.goose`, with tests under
      `test/websocket/` and `docs/api.md`; the 101, the refusals, and the frames
      unchanged byte for byte, and the request path's generated code unchanged
- [ ] Item 3 done, or the reason it waits recorded here
- [ ] Item 4's design below, with its open questions
- [ ] `scripts/test.sh` passes on macOS
- [ ] Items 5 to 11 done or decided by the maintainer
