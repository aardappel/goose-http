# 060: Who keeps an exchange's state

Status: todo (asked for 2026-10-22)

goose-rest keeps what an exchange needs past the handler's first call in
`Exchange.mode`, ten bits of a `u16`, beside goose-http's `Stream` and the loop's
`Exchange`. This task compares them bit by bit. A bit that records transport progress,
which goose-http tracks, belongs to goose-http and reaches the handler as a signal, as
`TIMEOUT`'s tag `NO_ROOM` now does (task 059, item 12). A bit that records what a route
asked goose-rest for stays in goose-rest. Breaking changes cost least before v0.5.0.

Result: one field and one bit mirror transport progress. `Exchange.due` stands in for
`NO_ROOM`, which is on `main`; `PENDING` copies `Event.whole`, which goose-http already
gives at each `REQUEST`. No further goose-http signal is needed. The other bits are
goose-rest's, and the review of 2026-10-22 agreed that not every bit is duplication.

## The audit

goose-rest at `d7c3525` (`runtime.goose`, `pieces.goose`, `middleware.goose`,
`compression.goose`, `testing.goose`), against goose-http at `e73b9870`.

| goose-rest's state | What it says | goose-http's nearest | Verdict |
|---|---|---|---|
| `GATHERING` | `rest::body` gathers the body into goose-rest's spill | `Exchange.body`: a body is coming, not who keeps it | Keep. Its run may move to goose-http's pool (task 059, item 4); the bit stays. |
| `RECEIVING` | The route takes the body's pieces (`rest::body_in_pieces`), and `len` counts them against its limit | The loop calls every handler with `BODY` and `END`; its `Exchange.taken` counts the same bytes, unexposed | Keep. The limit is the comparison task 059's item 3 leaves to a framework, and `len` also holds a gathered run's length, so exposing `taken` saves no byte. |
| `SENDING` | The route owns an open response (`rest::begin`, `rest::file`) and gets `MORE` | `Stream.open` | Keep. `Stream.open` also holds while goose-rest relays a reply's pieces itself (`relay_piece`), whose `MORE` isn't the route's, and `SENDING` without `open` tells goose-rest the response ended other than by `rest::end`, so it owes the route `CLOSED`. Its clock check at `TIMEOUT` goes (below). |
| `UPGRADED` | The route took the connection (`rest::upgrade`) | `Stream.framing == Framing.Raw`, which `switched` sets | Keep. It's a bit of `LATER`, the one test `serve` makes per request; reading `framing` as well adds a load and a branch per request. |
| `LATER` | Any of the four above: `serve` calls `on_later` | | Keep. |
| `KEPT` | Middleware's fields kept in a run for a later answer | | Keep. |
| `OFFERED` | The handler runs inside `rest::compressed` | | Keep. |
| `CODED` | The response holds a goose-compress encoder | The handler holds the slot of the worker's encoder | Keep. |
| `COLLECTING` | A `reply_value`'s pieces are collected in a run | `WAKE`'s tag carries goose-rest's own `REPLY_*` bits | Keep. |
| `PAUSED` | The wait is `rest::pause`'s before a response, not `rest::ask`'s | `Stream.waiting`: the exchange waits, not why | Keep. `later` is one wait for any purpose, and telling purposes apart would put a field in `Stream` for one feature. Its clock check goes (below). |
| `PENDING` | The request's body didn't come whole | `Event.whole`, at `REQUEST` | Transport: goose-rest keeps per connection what goose-http gives per call. |
| `Exchange.due`, not a bit | The clock halfway to a pause's `ms` | `TIMEOUT`'s tag `NO_ROOM` | Transport: replaced by `NO_ROOM`. |

Found on the way, a goose-rest fix with no signal: `rest::upgrade` sets `UPGRADED` after
`http::upgrade` has answered 501 on an h2 stream, so the route then gets `CLOSED`. It
should set the bit only when `cx.out.stream.open`, as `rest::file` does for `SENDING`.

## `NO_ROOM`, for `due`

On `main` since `b56d724c`, tested in `f1c4e657`: both loops' and h2's
`timed_out(key, waited)` tag a `TIMEOUT` that found no timer with `NO_ROOM`. It costs
the request path nothing, since the tag is chosen per `TIMEOUT`. It ships in v0.5.0,
and goose-rest uses it once its pin moves there.

It replaces two goose-rest decisions: the 2026-10-16 entry on long responses, whose
first point stores the deadline in `Exchange.due`, halfway to `ms`, and compares it
with `clock_ns()` at `TIMEOUT`; and the clock comparison in the 2026-10-21 entry on
`PAUSED`. The clock can misclassify: an immediate `TIMEOUT` that reaches the handler
after half a pause's time, as when the loop is busy, passes for the pause's own. (The
plan of 2026-10-22 dated the first decision 2026-10-19; goose-rest records it under
2026-10-16.)

The goose-rest code it lets go:

- `pieces.goose`, both `pause` functions: `x.due = clock_ns() + max(ms, 0) * 500000`,
  and the comment on the loop's clock lagging.
- `runtime.goose`, `on_event`'s `TIMEOUT` branch: `clock_ns() >= st.ex.due` becomes
  `(ev.tag & http::NO_ROOM) == 0`.
- `runtime.goose`, `arrived`'s `TIMEOUT` on a response begun: `clock_ns() >= x.due`
  becomes the same tag test.
- `runtime.goose`, `on_event`: `let run = st.ex.due` and `drop_run(st.ex, run, ...)`
  become `drop_reply`, since no pause moves `due` any more, and `drop_run` folds into
  `drop_reply`. `due` then holds only a collected reply's start, and is renamed for
  it; `Exchange`'s comment loses "an exchange has one wait, a pause's or a reply's,
  and a pause sets due afresh".
- `testing.goose`, `serve_one`: `st.ex.due = if w.early { 1 << 62 } else { 0 }`
  becomes the `TIMEOUT` event's `tag: if w.early { http::NO_ROOM } else { 0 }`, which
  also stops `serve_one` writing the field a collected reply's run is found by.
- goose-rest's docs: a decision replacing the two above, the two `rest::pause` rows of
  `docs/reference.md`, which say "by the clock, halfway to `ms`", and
  `docs/architecture.md` where it says the same.

goose-http's own `examples/device/device.goose` tells them apart by the clock too:
`guard now_ms() >= st.due - st.ms / 2` becomes `guard ev.tag != http::NO_ROOM`, and
`Watch.due`, which only that check reads, goes.

## `Event.whole`, for `PENDING`

goose-http needs no new signal: it gives `Event.whole` at each `REQUEST`, and every
reader of `PENDING` runs in a call that has that event at hand, or on `on_later`'s
replay of a gathered body, where the body is whole.

- `after` (`runtime.goose`) has the event: `(x.mode & PENDING) == 0 && k ==
  http::REQUEST` becomes `ev.whole && k == http::REQUEST`, and `(x.mode & PENDING) ==
  0 && k == http::BODY`, a `BODY` made from a whole `REQUEST`, becomes `ev.kind ==
  http::REQUEST && k == http::BODY`. Reading the event also closes a case the bit
  leaves open, found by reading the code and not yet tested: `on_event` clears
  `PENDING` at `WAKE`, so a route that calls `rest::body_in_pieces` after a wait gets
  an `END` made up after its body's first real piece, answers there, and the rest of
  the body is dropped.
- `rest::body`, `rest::body_in_pieces`, and `answers_later` (`middleware.goose`) see
  only `cx`. Three ways to carry `whole` to them:
  1. A field of `Cx`, `pending`, which `on_event` sets to `!wake && !ev.whole` and
     `on_later` leaves false. A `Cx` is a local of each call, so it costs no byte per
     connection, and a store that an inlined handler never reads is dead. It costs a
     store for each `Cx` built, in `on_event` and in each copy that routing makes,
     unless the compiler drops it, against today's load, mask, and store of the
     slot's `mode` per request. It removes `PENDING`, `on_event`'s update of `mode`,
     and `on_later`'s clear.
  2. Keep the bit, as goose-rest's `b080f25` chose, and change `after` alone.
  3. A flag in goose-http's `Stream`, "the body has more to come". Rejected:
     goose-http would mirror its own `Exchange.body` at each place that changes it,
     in both loops, h2, a skipped body, and `abandon`, to report a value it already
     reports.

## Decisions for the maintainer

1. **`NO_ROOM` at `rest::ask`'s wait.** Today it gets 504 `timeout`, as a lane that
   didn't answer in time does. Recommended: 503 `unavailable` with `Retry-After: 1`, as
   `rest::pause` before a response answers it, since no room to wait is a refusal at
   admission, not a slow lane.
2. **Where `PENDING` goes.** Recommended: option 1, the `Cx` field, if an
   instruction count on Linux shows goose-rest's request path no longer than now; otherwise
   option 2. Option 1 is against the letter of goose-rest's rule of no fields in `Cx`
   for one feature, though it serves three readers and replaces a field of every
   connection.
3. **`rest::body` or `rest::body_in_pieces` after `REQUEST`.** Today `rest::body` at
   `WAKE` returns an empty body for one still coming, and `rest::body_in_pieces` cuts it
   at its first piece (above). Recommended: both fail with 500 after `REQUEST`, as the
   head the gathering needs is gone by then.
4. **`NO_ROOM` on an upgraded connection.** Its route gets `TIMEOUT` as if the time had
   passed, as now, since a 101 has gone and `Cx` carries no tag. Recommended: leave it
   until a route needs to tell them apart.

## Acceptance criteria

- [x] The audit and the signals, above (2026-10-22)
- [ ] goose-http: `examples/device/` tells an early `TIMEOUT` by `NO_ROOM`, with
      `Watch.due` gone and its output unchanged
- [ ] Decisions 1 to 4 made and recorded in goose-rest's `docs/decisions.md`
- [ ] goose-rest, once its pin is v0.5.0: `due`'s clock checks replaced by `NO_ROOM`
      in `pause`, `on_event`, `arrived`, and `serve_one`, with the docs listed above;
      its pause tests pass with an early `TIMEOUT` given as `NO_ROOM`
- [ ] goose-rest: `after` reads `ev.kind` and `ev.whole`, `PENDING` goes or stays as
      decision 2 says, with a test of `rest::body_in_pieces` after a wait as decision 3
      says
- [ ] goose-rest: `rest::upgrade` sets `UPGRADED` only on an open stream
