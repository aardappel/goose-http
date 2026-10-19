# API

The package's API by topic, each with the example that shows it. The concepts come first
in the [README](../README.md#concepts), which pattern fits large bodies, long responses,
and slow work is in [patterns](patterns.md), and the examples are listed in
[examples/](../examples/README.md).

## Requests and responses

### Handler

Shown in `hello/` and `routes/`.

- **`req`**: the parsed head, `http::Request`. Slices into the read buffer, valid until
  the handler returns.
  - `http::field_of(req, name)`: a field's value, and whether it's there. Name is
    case-insensitive.
  - `http::each_field(req) { name, value => }`: all fields, repeats included.
  - `http::authority(req)`: the host and port, from an absolute-form target before
    `Host` (RFC 9112 §3.2.2).
  - `http::path_of(req.target)`, `http::query_of(req.target, key)`,
    `http::each_query(req.target) { key, value => }`: still percent-encoded.
  - `http::query_int(req.target, key)`: a query value as an integer, and whether it's
    there as one.
  - `http::decode(s, out)`: decodes one. With `plus` set, `+` is a space.
  - A target with a bad `%` escape gets 400.
- **`body`**: the whole body, if it fits in the read buffer with the head. Chunked is
  decoded. A longer body is dropped and `body` is empty, and a longer chunked body gets
  413, since the handler couldn't tell it from an empty one. To read one, gather it whole
  with `http::gather` ([Helpers for APIs](#helpers-for-apis)) or take it in pieces
  ([Streaming](#streaming)).
- **`out`**: an `http::Reply`. One whole response, any size.
  - `http::respond(out, status, content_type, body)`, with no `Content-Type` for an
    empty `content_type`, as for a 204, or
  - `http::start(out, status)`, `http::field(out, name, value)`,
    `http::finish(out, fields, body)`. `fields` ends in `"Content-Length: "`, which
    `finish` follows with the body's length: `http::TEXT` and `http::JSON` add their
    `Content-Type`, `http::NO_TYPE` none, and a response with fields of its own writes
    them in one string, as `"Allow: GET\r\nContent-Length: "`.
  - `http::field` drops a field with CR, LF, or an invalid name, so request data can't
    split the response, and returns false; `http::is_field(name, value)` checks one
    before the response starts. `finish`'s `fields` are written as they are, for
    constant text.
  - Clear `out.keep_alive` before `start` to close after the response.
  - `out.common` is the fields `start` writes after each status line: `Server` and
    `Date`, which the loop renders once a second. To add fields to every response, as
    for CORS, set it to the loop's fields followed by yours, whole lines each ending
    in `\r\n`:

    ```rust
    var common: u8[>..] = [];
    common.append(out.common);
    common.append("X-Frame-Options: DENY\r\n");
    out.common = common;
    ```

    `out` is the handler's copy, so the change holds for each `start` after it, in the
    functions given `out` included, until the handler returns. The next call starts
    from the loop's fields again, and the responses the loop writes itself, such as a
    400 for a request it couldn't parse, don't get yours. `start` copies the bytes, so
    they need last only until then. Check a value from the request with
    `http::is_field` first.
  - `http::insert_field(out, mark, name, value)` adds a field to a response already
    written, for a value known only then, such as `Server-Timing`'s: `mark` is
    `out.buf.len` from before the response began. The field goes at the end of the
    head, and the body moves up. It's dropped as `http::field` drops one, and returns
    whether it was added.

A handler passed by name, `http::serve(cfg, route)`, should be an `inline fn`, as in
`server/routes.goose`. As a call, it keeps `http::start` from folding a constant status:
about 190 instructions per request in the benchmark server.

Don't `return` from a handler written as a block. A block's `return` returns from the
function the block is written in, the worker's `thread_fn`, which ends its loop with
the request unanswered and the client waiting. Neither the loop nor the compiler can
catch it
([findings](goose-findings.md#a-function-cant-keep-its-block-from-returning-past-it)).
A handler that returns early is a function: passed by name, as `upload/` does, or
called from the block, as `api/` and `later/` do.

### Routes

Shown in `routes/`.

```rust
var r = http::router(req);
if http::on(r, "GET", "/users/:id") { show(http::param(r, "id"), out); }
else if http::on(r, "PUT", "/users/:id") { update(http::param(r, "id"), body, out); }
else if http::on(r, "GET", "/files/*path") { file(http::param(r, "path"), out); }
else { http::otherwise(r, out); }
```

- `:name` matches one segment, `*name` the rest of the path, last only.
- A `GET` route takes `HEAD` too.
- A literal segment matches an escape of an unreserved character (`/%75sers` is
  `/users`); an escaped `/` doesn't split a segment.
- A path with a `.` or `..` segment, escaped or not, or an escaped control byte, matches
  no route: a handler that checks access by a path's prefix can't be walked around.
- `http::otherwise`: 501 for a method the server doesn't know, 400 for a path the
  router refused, 204 for `OPTIONS *`, 405 with `Allow` from the routes whose path
  matched, 204 with it for `OPTIONS`, else 404.
- Parameters are slices of the target, still encoded, valid until the handler returns.
  Nothing allocates.

### Helpers for APIs

`respond_json` is shown in `routes/` and `api/`; media types, cookies, Bearer and Basic
credentials, forms, and the client's address in `api/`; multipart, `body_within`, and
`gather` in `upload/`.

The helpers that read a request take it as `const http::Request&`, so a call doesn't
copy it. Pass them a variable, such as the handler's `req`: Goose doesn't yet bind a
call's result to a reference parameter.

- Media types: `http::require_type(req, out, "application/json")` answers 415 for
  another `Content-Type`; `http::accept_or_406(req, out, ["application/json",
  "text/csv"])` picks an offer by `Accept`, or answers 406. `http::media_type` and
  `http::param_of` parse a type and its parameters.
- Cookies: `http::cookie_of(req, name)`, `http::each_cookie(req) { name, value => }`,
  and `http::set_cookie(out, http::Cookie { name: "sid", value: id, max_age: 3600,
  http_only: true, same_site: "Lax", .. })`, which returns false and writes nothing
  for a cookie `http::is_cookie` refuses.
- `http::authorization(req)`: the scheme and credentials. `http::basic_auth(req,
  decoded)`: the user and password. `http::bearer(req)`: a Bearer token.
  `http::challenge(out, "Basic realm=\"api\"")`: 401.
- Forms: `http::form_value(body, key, out)` and `http::each_form(body) { key, value =>
  }`. Multipart: `http::start_multipart(req, st.parts)` at `REQUEST`, then
  `http::each_part(st.parts, ev.data) { part => }` for each piece of the body, where
  `part` is an `http::Part`: `Head { fields }`, `Data { bytes }`, or `End`. Use
  `http::disposition(fields)` for a part's name and filename. A check of your own,
  such as of a part's head, fails the body with `http::fail_multipart(st.parts)`.
  At `END`, the body is whole if `http::multipart_done(st.parts)`. An
  `http::Multipart` holds up to 2 KB of a part's head between pieces, and fails the
  body on a longer one. It's in the request's state, so every connection's slot holds
  those 2 KB, whichever route the connection is on. For a body already
  whole, `http::find_part(req, body, name)` returns the first part with that
  Content-Disposition name as slices of `body`: its content, its head fields (for
  `disposition` and `field_in`), and a status, `http::PART_FOUND`, `PART_ABSENT`,
  `PART_TYPE` (not `multipart/form-data`, or no usable boundary), or `PART_BAD` (a body
  `each_part` fails, a part without a form-data Content-Disposition, or one never
  closed). It stops at the part it finds.
- `http::respond_json(out, status) { b => json::format_key(b, "id"); ... }`.
  `http::json_string(b, s)` writes `s` as a JSON string, quotes included, into any
  builder with `push` and `append`. Its output is `json::format_string`'s: `\n`, `\t`,
  `\r`, `\b`, and `\f` in their short forms, and other control bytes as `\u00XX`. It
  looks for a byte to escape 16 bytes at a time, where `json::format_string` tests each
  byte.
- `Config.max_requests` caps a connection's requests. `http::body_within(st.taken, ev,
  out, limit)` at `REQUEST` and each `BODY` answers 413 past a route's own limit.
- `http::gather(ev, st.body, out, limit) { req, body, o => }`, called with every event
  of a handler with state, calls its block once with the whole body, however large, up
  to `limit` bytes. `st.body` is an `http::Gather` in the request's state. A body that
  came with its head goes to the block at `REQUEST`. A longer one is copied, with the
  head, into a buffer of the worker's as it arrives, and goes to the block at `END`.
  `CLOSED` frees what it held. Past `limit`, at most `Config.max_body`, it answers 413
  and closes, as `body_within` does. The worker holds each gathered body whole, so keep
  `limit` to what the program can hold at once.
- `http::peer(out)`: the connection's address and port. `http::client(req, out,
  trusted)`: the client a trusted proxy forwarded for, from `Forwarded` or
  `X-Forwarded-For`, with `trusted` from `http::network("10.0.0.0/8")`.
  `http::format_address(text, a)` writes one.

### Conditional requests and ranges

`http::serve_file` uses these ([Files](#files)), as `files/` shows. `api/` answers
`If-None-Match` for a note with `not_modified` alone.

- `http::not_modified(req, etag, modified)`: whether a `GET` gets 304. `If-None-Match`
  first, else `If-Modified-Since`.
- `http::range_of(req, size, etag)`: the one byte range asked for, with 206, 416, or
  200 for the whole (for example when `If-Range` names another entity tag).
- `http::content_range(out, start, end, size)`: writes `Content-Range`.

## Bodies and responses of any size

### Streaming

A handler with state is called once for each event of an exchange, below, so it can
read a body and write a response in pieces. When a route needs one:
[request bodies](patterns.md#request-bodies) and
[long responses](patterns.md#long-responses). Shown in `upload/`, and in `server/`:
`/upload`, `/echo`, `/bytes`, `/stream`, and `/upgrade`.

`st` is state of the program's own type, reset to `fresh` per request, kept in the
connection's slot. A handler that keeps none, but needs `WAKE` or `TIMEOUT`, passes
`false`, as `later/` does.

```rust
struct Upload { bytes: i64 = 0 }

thread_fn worker(cfg: http::Config) {
    let e = http::serve(cfg, Upload { .. }) { ev, st, out =>
        if ev.kind == http::REQUEST && !ev.whole {
            // The body comes in BODY pieces; answer at END.
        } else if ev.kind == http::REQUEST || ev.kind == http::END {
            st.bytes += ev.data.len;
            var text: u8[..24] = [];
            format(text, st.bytes);
            http::respond(out, 200, "text/plain", text);
        } else if ev.kind == http::BODY {
            st.bytes += ev.data.len;
        }
    };
    http::report(e);
}
```

| Event | When |
|---|---|
| `REQUEST` | Head parsed, in `ev.req`. With `ev.whole`, the body is in `ev.data`, as it always is when it fits in the read buffer with the head. |
| `BODY` | A piece of a longer body, decoded if chunked, up to `Config.max_body`. |
| `END` | The body is complete. Request trailers are in `ev.trailers`, here or at a whole body's `REQUEST`; `http::field_in` finds one. |
| `MORE` | A response is open, the body has ended, and the connection has room to send. |
| `CLOSED` | The connection closed while the handler was owed a call. Release what `st` holds. |
| `WAKE` | A message came to the address `later` returned: its bytes in `ev.data`, its tag in `ev.tag`. ([Answers that wait](#answers-that-wait)) |
| `TIMEOUT` | `later`'s time limit passed first, or there was no room to wait. |
| `DONE` | With `Config.log`, the response is whole: `ev.status`, `ev.sent` bytes, and `ev.ms` from the head's first byte, for an access log. `ev.req` is the request only when it was answered at `REQUEST`. |

- `http::begin(out, status, length)` opens a response: `Content-Length`, or chunked
  for -1. HTTP/1.0 then closes at the end.
- `http::send(out, bytes)` writes a piece. `http::end(out)` ends it;
  `http::end(out, trailers)` adds trailer fields to a chunked one.
- The loop calls `MORE` only while the client takes what it's sent, so a slow client
  can't make the worker hold a whole response. A `MORE` that neither sends, ends, nor
  waits closes the connection. The client has fallen behind once the output queued for
  it passes the write buffer, on `serve_epoll`, or `Config.max_queued`, on `serve`.
- A response before the body has arrived drops the rest, up to `Config.max_drain`,
  then closes.
- `Expect: 100-continue` gets `100 Continue` unless the handler answers at `REQUEST`.
- `http::upgrade_of(req)`: the protocol asked for, such as `websocket`.
  `http::upgrade(out, protocol)` answers 101. After that, bytes come as `BODY`,
  `http::send` writes them raw, and `http::end` closes. `BODY` keeps coming while the
  exchange waits with `later` ([answers that wait](#answers-that-wait)).

### Files

Shown in `files/`, and in `server/`: `/files/NAME` serves the directory in `FILES`.

- `http::open_file(path)`: opens a regular file, or 404 or 403.
- `http::open_precompressed(req, path)`: the same, or in its place `path.br`,
  `path.zst`, or `path.gz`, whichever the request's `Accept-Encoding` weighs highest,
  and not older than `path`. `serve_file` then adds `Content-Encoding`, `Vary`, and an
  `ETag` of the copy's own. Dynamic gzip, deflate, and zstd use the optional
  `http.compression` module, as [`compress/`](../examples/compress/compress.goose) shows;
  `serve_file` does not compress a file on the fly.
- `http::serve_file(req, out, f, http::content_type_of(path), st.file)`: answers `GET`
  or `HEAD` with 200, 206, 304, or 416, with `ETag`, `Last-Modified`, and
  `Accept-Ranges`.
- `http::send_file(out, st.file)` at each `MORE` until false, then `http::end(out)`.
  With a `Content-Length` of 64 KB or more, it hands the file to the loop, which sends
  it without copying it through the program: `sendfile` on the epoll loop and the
  emulated ring, splice through a pipe on io_uring, and `TransmitFile` on IOCP. Client
  editions of Windows run two `TransmitFile` calls at a time across the system, so many
  downloads at once may queue there. A smaller file, which one read and a send serve
  faster, and a chunked response read up to 64 KB with `pread` per call.
- `http::close_body(st.file)` at `CLOSED`.
- `http::file_path(dir, name, path)`: appends to `path` the file in `dir` that `name`
  names, such as a route's `*name` parameter, decoded. False for a bad escape or a
  path that would leave `dir`, which `http::is_safe_path` checks: it rejects `.` and
  `..` segments, NUL, backslashes, and colons, escaped or not.

## Answers that wait

A handler with state can hand a request to another thread, or wait for a timer, and
answer later without blocking its worker. How to shape that work, with a diagram of
`later/`: [slow work](patterns.md#slow-work). Shown in `later/`, and in `server/`:
`/later` and `/events` wait for a worker thread with a box and a timer table of its own
(`server/backend.goose`), with `MAIL_SLOTS` set, as does `/upgrade?delay=D` once
upgraded, and `/delay/MS` waits for a timer.

`Config.mail_slots` and `Config.max_waiting` turn waiting on; both are 0 by default, and
then a loop opens no box and arms no timer.

```rust
// At REQUEST: the reply's address, with a time limit the handler must give.
let job = Job { reply: http::later(out, 5000), .. };
guard http::mail_send_value(worker, JOB, job) == http::SENT
else { http::respond(out, 503, "text/plain", "busy"); return; }

// At WAKE: ev.data and ev.tag are what the worker sent to reply.
// At TIMEOUT: the limit passed first; answer 504.
```

- `http::later(out, ms)` makes the exchange wait for a message to the address it
  returns, then calls the handler with `WAKE` or `TIMEOUT`. After `begin`, or at
  `MORE`, it pauses an open response, for Server-Sent Events and long polling. A call
  that writes a whole response doesn't wait. A worker holds at most
  `Config.max_waiting` exchanges waiting at once; past it, `later` gives `TIMEOUT` at
  once.
- Requests pipelined behind a waiting exchange wait in the read buffer, and reading
  stops once it's full.
- An upgraded connection is read while it waits: the client's bytes still come as
  `BODY`, and the handler can answer them with `http::send`, then `WAKE` or `TIMEOUT`
  comes when the reply or the limit does. A `later` at `BODY` starts the limit again,
  and `http::end` stops the wait and closes. A client that closes meanwhile gets the
  handler `CLOSED`, and the reply then finds the address `STALE`.
- A send to an exchange that no longer waits returns `STALE`. A message already
  queued or in flight when the wait ends can still be dropped by the loop. At stop,
  a waiting exchange gets `Config.grace_ms`, then `CLOSED`.
- `http::mail_live(address)` tells any thread whether the box accepts that key now,
  so a lane can skip work for a client that is no longer waiting. It is a snapshot:
  a later send can still return `STALE`. The key stays live through `WAKE` while the
  handler calls `later` again, so a reply can go in pieces back to back; it is
  cleared once the handler returns without waiting, and before `TIMEOUT` or
  `CLOSED`.
- A worker thread owns a box: `http::mail_open(slots, size)`, which returns the box
  and an `http::Error`, `http::mail_wait(box, ms)`, `http::mail_take(box) { key, tag, bytes => }`. `http::mail_send(address, tag,
  bytes)` returns `SENT`, `FULL` (no slot free), `TOO_LONG` (longer than a slot), or
  `STALE` at once, from any thread, and never blocks. `http::mail_slot_size(address)`
  gives a sender the box's slot size, or -1 for a `STALE` address, a stopped box
  included; `mail_live` is false for a stopped box too.
- `http::mail_stop(box)` stops a box, from any thread. The stop is a flag in the box,
  not a message, so a full box can't refuse it, and it wakes the owner's `mail_wait`.
  From then on, sends return `STALE`, and what the box already holds is still taken.
  Once the box is stopped, `mail_wait` returns at once on every call, `false` when
  nothing is pending, so a lane ends its loop on `http::mail_stopped(box)`. In the
  owner, `mail_stopped` is true once the box is stopped and holds nothing, or is
  closed. It first waits out a send in flight across the stop, so a job sent before
  the stop is never left behind. A second stop does nothing. As `later/` does:

  ```rust
  while !http::mail_stopped(box) {
      http::mail_wait(box, -1);
      http::mail_take(box) { key, tag, bytes => /* ... */ };
  }
  http::mail_close(box);
  ```

- `http::mail_adopt(box)` is for a thread that takes a box over after its owner
  aborted inside `mail_take`'s callback, which settled nothing: called once
  `thread_wait` has returned for that owner, it settles what the owner took, so that
  `mail_stopped` can come true. goose-rest's `rest::keep` calls it.
- `http::mail_queued(address)` gives any thread how many messages the box holds, to
  pick the least busy of several lane threads' boxes, or -1 for a `STALE` address or
  a stopped box. It's a snapshot, and counts the messages the owner's `mail_take` has
  taken until it settles them, after each run it finds, so the job in progress may be
  counted.
- A box's slot count is a power of two of at least 2. `mail_open` refuses any other
  count with `EINVAL`, including 1: the ring tells a full slot from a free one by its
  sequence number, which takes at least two slots.
- `http::mail_send_value(address, tag, v)` sends a flat value, such as a struct
  holding the reply's address, as its `to_bytes` image, and `http::mail_value(bytes,
  v)` reads it back into `v`, verified by `from_bytes`, or returns false. A limited
  array's image takes its whole capacity: size the box for that.
- `http::timer_table(n)`, `http::arm`, `http::cancel`, and `http::expire` are the
  loops' timers, for a worker's own.
- Generic boxes can opt into key tracking with
  `http::mail_open(slots, size, waker, live_keys, key_shift)`. Only their owner calls
  `http::mail_mark(box, key, live)`: a nonzero key selects entry `key >> key_shift`,
  and sends require the whole key to match. Clearing an old key preserves a newer
  key in the same entry. With `live_keys = 0`, the default, any key is accepted.
- A worker's own box, which replies come to, has `Config.mail_slots` slots of
  `Config.mail_size` bytes, 256 by default. A `Config.mail_slots` that `mail_open`
  refuses stops the loop with that error.

## The store

Used by the benchmarks' REST server, `bench/rest/goose/rest.goose`.

`import http.store` gives byte blobs that `main` writes before it starts the workers,
and every worker then reads: one copy for the process
([architecture](architecture.md#the-store)).

- `http::store_put(bytes)` copies bytes into a new blob and returns an `http::Blob`
  and 0, or a blob with id -1 and `-EPERM` after the freeze or `-ENOMEM`.
- `http::store_freeze()` ends the puts. Call it before any other thread reads, and
  hand the blobs on through a queue, `thread_spawn`, or `thread_wait`.
- `http::store_len(b)`: the blob's length, or -1 for a blob the store doesn't have.
- `http::store_append(b, from, to, out)` appends bytes `from..to` to `out`, such as
  `out.buf` for a response, or returns false with nothing appended for a range
  outside the blob or a blob the store doesn't have.
- `http::store_i64(b, at)`, `http::store_u32(b, at)`, `http::store_u8(b, at)`, and
  `http::store_f64(b, at)` return the value at byte `at`, little-endian as
  `bytes_of` writes it, and true, from one C call with no buffer. A value that
  doesn't fit inside the blob, or a blob the store doesn't have, gives 0 and false.
  A column is one blob, read at `i * 8` for an `i64`:

  ```rust
  let prices, err = http::store_put(bytes_of(price_column));   // an i64[>..]
  let price, ok = http::store_i64(prices, i * 8);
  ```

- `http::store_record<T>(b, i, read)` returns record `i` of a blob of flat
  fixed-size `T`s end to end, such as `bytes_of` an array of them gives, by value,
  and true; or `default<T>()` and false for an `i` outside the blob or a blob the
  store doesn't have. `read` is the program's own C function for `T`, since an
  `extern fn` can't be generic (spec §7.10). It copies the record with
  `store_record_at`, which the package's C provides:

  ```rust
  struct Item { id: i64, price: i64, stock: i32 }
  extern "app_item_read" fn item_read(id: i64, i: i64, out: Item&) -> i32;
  let item, ok = http::store_record<Item>(items, i, item_read);
  ```

  ```c
  /* app.c, named by the program's sidecar: c_sources = ["app.c"]; */
  #include <stdint.h>
  #include <string.h>

  #pragma pack(push, 1)  /* Goose structs have no padding */
  typedef struct { int64_t id, price; int32_t stock; } item;
  #pragma pack(pop)
  _Static_assert(sizeof(item) == 20, "Item's size in Goose");

  const uint8_t *store_record_at(int64_t id, int64_t i, int64_t size);

  int32_t app_item_read(int64_t id, int64_t i, item *out) {
      const uint8_t *p = store_record_at(id, i, sizeof *out);
      if (!p) return -1;
      memcpy(out, p, sizeof *out);
      return 0;
  }
  ```

  The C needs only the record's size, but declaring its fields lets
  `_Static_assert` catch a struct that changed on one side. Nothing verifies the
  bytes, as `from_bytes` would, so the blob must hold `T`s as `bytes_of` wrote them,
  and `T` no references, whose links would come back unproven.

A scalar read costs half of a `store_append` of the same 8 bytes into a buffer, and a
record read half of a `store_append` of the record. Rebuilding the record in Goose
from its `store_append` image with `from_bytes` costs four times the C read
(task 040, `bench/store.sh`).

## Running a server

### Config and shutdown

The stop on Ctrl+C is shown in `routes/`.

`http::Config`: address, port, workers, limits, timeouts, buffer sizes. All have
defaults. `Config.workers`, 0 by default, gives one worker per hardware thread, or on
macOS per performance core ([tuning](tuning.md#worker-count)), and
`http::worker_count(cfg)` returns the count. `Config.place` and `Config.role` place the
workers ([placement](#placement)).

`http::run(cfg, worker)` spawns `http::worker_count(cfg)` workers, each a `thread_fn`
that calls a loop with its own copy of `cfg`, and returns once every one has returned.
Up to two of the program's values go between `cfg` and the worker, which takes them
after its `Config`: `http::run(cfg, app, worker)` spawns
`thread_fn worker(cfg: http::Config, app: App)`. The worker comes last because Goose
passes a function value after a call's other arguments (spec §7.6). `run` sets each
copy's `Config.worker` to the worker's index, from 0, which its seat goes by. A program
that picks a loop at run time calls `run` once per choice, as `server/app.goose` does.
Only a program that must interleave spawning with other work spawns its workers itself
and sets `Config.worker`; a placed worker without one floats, with a warning.

A worker that `run` started and that aborts, as on a failed `assert`, ends alone. `run`
prints the abort to stderr, closes the worker's listener, and starts it again with the
same `Config` and values, 100 ms later and twice as long after each abort in a row.
After `Config.restarts` aborts in a row, 5 by default, it ends the process with exit
code 1; 0 ends it at the first. A worker that ran for a minute starts a new count, and
after a stop no worker is restarted. The aborted worker's connections stay open,
unanswered ([crashes](patterns.md#crashes)). One `run` at a time in a process: it
takes its workers' ends from Goose's queue of `http::WorkerEnded`. The policy is
`http::restart_after(r, name, why, stopping)`, with an `http::Restarts` per thread, for
a library that restarts threads of its own the same way, as goose-rest's lanes do.

`Config.address` is where to listen: empty for every IPv4 address (127.0.0.1 on
Windows), an IPv4 or IPv6 address, `"::"` for every address, IPv4 too unless
`Config.ipv6_only`, or `"unix:/run/app.sock"` for a Unix socket on Linux and macOS,
whose path fits in 104 bytes on macOS and 108 on Linux. The server removes a socket file
left at the path before it binds, and its own when it stops.

A loop returns:

- when a call fails, with an `http::Error`. `http::report` prints it to stderr.
- after `http::stop()`, with error code 0. The listener and idle connections close.
  Each other connection gets `Connection: close` on its next response. The loop returns
  when they close, or after `Config.grace_ms`.

`http::stop_on_signals()` makes `SIGTERM` and `SIGINT` stop the loops, and returns an
`http::Error` whose code is 0 when it can. `http::exit_on_error(e)` prints an error to
stderr and ends the process with status 1, and does nothing for code 0:

```rust
fn main() {
    http::exit_on_error(http::stop_on_signals());
    http::run(http::Config { port: 8080, .. }, worker);
}
```

### Placement

Placement is experimental: it's opt-in and free when unused, but not yet measured to
help on real cores (only macOS has been measured, with no gain), so its grammar and
calls may be trimmed or removed once measured.

Shown in `bench/pinning/pinning.goose`. When placement helps, the placement file's
grammar, and what each platform does: [tuning](tuning.md).

- `http::place_load(path = "")` reads the placement file at `path`, checks it against
  this machine, hands it to the shim, and returns it as an `http::Place`. An empty
  `path` is the file the command line names with `--place FILE` or `--place=FILE`, or
  else `GOOSE_PLACE`. With no file named, the placement is empty, and every thread
  floats. It prints a warning for each thing the machine can't do and goes on. A file
  that can't be read or doesn't parse ends the program with exit code 2. Call it in
  `main`, before the threads it places start.
- `Config.place = http::place_ref(place)` places the workers: an `http::PlaceRef`, a
  handle to the copy the shim holds, so a worker's `Config` stays small. The default
  places nothing. `Config.role` is the workers' role in the file, `"workers"` unless
  written. Each loop takes the seat of its role's thread `Config.worker` as it starts,
  and sets `SO_INCOMING_CPU` on its listener where the seat asks for it.
  `http::worker_count(cfg)` returns the file's count for the role where it gives one.
  Workers of two servers that share a placement and a role take the same seats, so give
  each server's `Config` a role of its own.
- `http::place_seat(place, role, i)` returns thread `i`'s `http::Seat`, for a thread
  the program spawns, such as a lane's: core `i` of its set for `each`, wrapping
  around; any core of its set for `within` or `core`; otherwise the cores no exclusive
  set holds. A negative `i` is 0. On a platform that can't pin, the seat only lowers
  the priority, where the file says `low`.
- `http::take_seat(seat)` pins the calling thread and lowers its priority, as `seat`
  says. Call it first in the thread, before it touches memory of its own. A failure
  prints a warning, and the thread runs on where it is.
- `http::place_threads(place, role, threads, max = 0)` returns a role's thread count:
  the file's, or `threads` where the file gives none, cut to `max` with a warning when
  `max` is above 0.
- `http::place_listener(seat, fd)` sets `SO_INCOMING_CPU` on a listener of the
  program's own, where `seat` asks for it. The loops call it for theirs.
- `http::place_register(place)` hands a `Place` to the shim and gives it the handle
  `place_ref` returns; `place_load` calls it. A `Place` from `place_parse` that no
  `place_check` has recorded the machine in is checked first, so it pins. The shim
  holds 8 at most: past them, it
  prints a warning, and the placement places nothing.

### Event loops

The program calls one. Goose compiles a generic function only where it's called, so the
other isn't in the binary.

| Loop | Linux | macOS | Windows |
|---|---|---|---|
| `http::serve` | io_uring, kernel 6.1+ | ring emulated on kqueue | IOCP |
| `http::serve_epoll` | epoll | kqueue | `ENOSYS` |

- `http::serve` is the default. On Linux 12-22% faster than epoll, at 2-5 times the
  peak RSS, 10-16 MB with 4 workers. Where `io_uring_setup` fails, as under Docker's
  default seccomp profile, it emulates the ring on epoll; `http::ring_probe()` says why.
- `http::serve_epoll` is faster on macOS, and on Linux uses a quarter of the memory.

The benchmark server links both. `LOOP` picks: `uring` (`iocp` on Windows), `epoll`,
or `uring-epoll`. See
[architecture](architecture.md#completion-loop).

