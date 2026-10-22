# 014: HTTP/2 and TLS

Status: in-progress (asked for 2026-10-11). Both halves of the split below are
recorded in `docs/decisions.md`: h2 on 2026-10-19, and TLS, goose-tls reached from
`http.tls`, on 2026-10-19 with phase 2's first part, HTTP/1.1 over TLS in the epoll
loop ([014.02](02-tls.md)).

HTTP/2 and HTTPS are out of scope in `README.md`. A server behind snowtime-native, or in
HttpArena's TLS and h2 profiles, needs both. This task decides where they live, then
builds them in phases, each measured against the competitors as tasks 004 and 005 were.

goose-rest's HttpArena plan (its task 047, 2026-10-19) takes TLS first: phase 2 adds
json-tls and 8gbit to the HTTP/1.1 board. Phase 4, h2c, needs no TLS and can run beside
it. goose-tls (`github.com/kaitk/goose-tls`) is OpenSSL 3 under a Goose API, with the
server side, kTLS, and client TLS. snowtime-native also needs SNI, certificates swapped
while running, and ACME in the process: goose-tls has the first two and ACME's hooks,
and ACME is a package of its own (goose-rest's task 049). Aegon, the C++ framework that
leads HttpArena's h2 profiles, does h2 through nghttp2, which this task's phase 4 should weigh (goose-rest's task 048).

## How the competitors split it

| Project | HTTP/1.1 and HTTP/2 | TLS |
|---|---|---|
| hyper (Rust) | One crate, with features; framing and HPACK in the separate `h2` crate | Outside, in `tokio-rustls` or `hyper-rustls` |
| xitca-web (Rust) | `xitca-http`: h1, h2, and h3 behind features | `xitca-tls`, over rustls or OpenSSL |
| Go `net/http` | Through Go 1.26, `x/net/http2` bundled into `net/http` as `h2_bundle.go`; from 1.27, the internal package `net/http/internal/http2` | `crypto/tls`, in the standard library |
| nginx, h2o (C) | One repository; h2 is a module | OpenSSL or BoringSSL, linked in |
| zzz (Zig) | HTTP/1.1 | `secsock`, its own package |
| odin-http | HTTP/1.1 only | OpenSSL, for its client only |
| may-minihttp, libreactor, the HttpArena epoll entries | HTTP/1.1 only | none |

The fast plaintext servers don't do TLS. The full servers keep h2 beside h1, as a module
or a feature, and put TLS in a layer of its own over a C library. Where the language
has packages, that layer is a package.

## Proposed split

- HTTP/2 goes in this repository, as modules of the `http` package (task 011). Framing,
  HPACK, flow control, and stream scheduling are HTTP, share the parser, the response
  builders, and the `Date`, and change the event loop itself. Goose has no runtime
  function pointers (spec §7.6), so a separate h2 package would be compiled into this
  loop through function values anyway. HPACK and the framing are bounded, table-driven
  byte work, 1,500 to 3,000 lines in other implementations, and are worth measuring in
  Goose.
- TLS goes in a separate package, `goose-tls`: a thin Goose API over a C library, with
  opaque handles and a byte-in, byte-out handshake, and the C built from its sidecar
  (`cmake_target` or `c_libs`). A program serving plaintext doesn't link the library,
  the library can change, and the exception to `AGENTS.md`'s "C is for what Goose can't
  reach" stays in one place. Writing TLS itself in Goose (constant-time crypto, X.509)
  is out of scope.
- `http` uses `goose-tls` only from a module of its own, `http.tls`, so only a program
  that imports `http.tls` declares `goose-tls` in its root file. At `efe3155` a library's
  `import` of another package is a requirement the root must declare
  (`docs/packages.md`). A module the program never imports doesn't count: at `efe3155`
  and `fe6c543`, a minimal program importing package `lib` builds without declaring
  `dep`, which only `lib`'s module `lib.tls` requires, and importing `lib.tls` fails
  with "lib needs the package dep: add `import dep from ...` to main.goose" until the
  root declares it (2026-10-11).
- snowtime-native, or any program, owns certificates and configuration and composes the
  two. A repository above this one can't hold h2 or TLS, because both change the loop.

Rejected: everything in this repository, because every program would link the TLS
library; h2 as its own package, because it couples to the loop through function values
and duplicates its types.

## The event loop

- A connection slot grows HPACK tables (4 KB by default; the encoder's can stay at 0
  through `SETTINGS_HEADER_TABLE_SIZE`), a stream table capped by
  `MAX_CONCURRENT_STREAMS`, flow-control windows, and partial-frame state. Keep them in
  a separate pool indexed from the slot, so an HTTP/1.1 connection stays at today's size.
- Responses on different streams interleave and wait on window updates, so the single
  spill buffer per connection becomes a queue per stream, with a round-robin scheduler
  (RFC 9113 deprecates priorities).
- Frames are up to 16 KB, and no peer may be asked for smaller (RFC 9113 §4.2), so the
  8 KB read buffer takes DATA in pieces and the spill pool gathers the other frames
  (task 014.01).
- With TLS, a read goes recv → decrypt → parser and a write the reverse. kTLS on Linux
  hands the record layer to the kernel after the handshake, so `send`, `recv`,
  `sendfile`, and io_uring carry plaintext again; KeyUpdate and alerts still need user
  space (`EKEYEXPIRED`, control messages through `recvmsg`).

## Phases

1. Record the decision in `docs/decisions.md`, with the TLS exception to the C
   rule, and update `README.md`'s scope.
2. `goose-tls` over OpenSSL 3 with memory BIOs, and HTTP/1.1 over TLS in the epoll loop on
   port 8443. Measure HttpArena's JSON-over-TLS profile against its Rust entries.
3. kTLS on Linux after the handshake, then TLS through io_uring; compare the two paths.
4. h2c with prior knowledge (the `PRI * HTTP/2.0` preface; HttpArena's port 8082): frames,
   HPACK, flow control, and the stream scheduler in Goose. Without TLS, its cost is h2's
   alone. Test with h2spec and HttpArena's h2c profiles. Task 014.01 has the work and
   the design for the loops.
5. ALPN `h2` over TLS: HttpArena's h2 baseline and static profiles. Task 061 has the
   work: it serves from both loops (2026-10-22), and HttpArena's profiles remain.

Out of scope: HTTP/3 and QUIC (UDP, loss recovery, and QUIC-TLS: a project of its own),
the `Upgrade: h2c` handshake, gRPC, and WebSocket over h2.

## Open questions

- Which TLS library. OpenSSL 3 is everywhere, and from 3.0 hands the record layer to the
  kernel on Linux when built with `enable-ktls` and the program sets
  `SSL_OP_ENABLE_KTLS`, for the ciphers the kernel supports (TLS 1.3 receive from 3.2;
  `include/openssl/ssl.h.in`, `CHANGES.md`). BoringSSL is what h2o and many fast servers
  use; rustls-ffi needs a Rust toolchain in the build. BearSSL's engine does no I/O of
  its own, the caller moving bytes through its four buffers (`inc/bearssl_ssl.h`), which
  fits Goose best, though its certificate, X.509, and cipher policies are vtables; it
  supports TLS 1.0 to 1.2 only (`BR_TLS12` is the highest version), and its last release
  is 0.6, from 2018. Checked against the sources 2026-10-11; BoringSSL's and rustls-ffi's
  claims aren't checked yet.
- Whether h2 lands in `http::serve`, `http::serve_epoll`, or both (task 011).
- What snowtime-native needs first: TLS alone covers browsers over HTTP/1.1.

## Acceptance criteria

- [x] The split above discussed for h2, and the decision recorded in
      `docs/decisions.md` with its reasons (2026-10-19)
- [x] The split above discussed for TLS, and the decision recorded in
      `docs/decisions.md` with its reasons, or this task rewritten to the one chosen
      (2026-10-19, with the API's names, [014.02](02-tls.md))
- [x] A test that a program importing `http` without `http.tls` builds without declaring
      `goose-tls`, at the pin of the day (`test/http/no_tls.goose`, with
      `test/tls/undeclared.goose` for the other way, 2026-10-19)
- [ ] HTTP/1.1 over TLS passes HttpArena's TLS validation and is measured in its
      JSON-over-TLS profile
- [ ] kTLS and user-space TLS compared on Linux
- [x] h2c passes h2spec and is measured in HttpArena's h2c profiles, on both loops
      ([014.01](01-h2c.md#httparenas-h2c-profiles), Linux in WSL2, 2026-10-19)
- [ ] h2 over TLS with ALPN measured in HttpArena's h2 profiles
- [x] An HTTP/1.1 connection's memory unchanged by the h2 state but for the 4 bytes of
      its slot's index (2026-10-19), shown by `bench/run.sh`'s peak RSS: for the epoll
      loop ([014.01](01-h2c.md#measurements), 2026-10-19), and for io_uring, whose
      process holds 68-88 KB more of code ([014.01](01-h2c.md#memory), 2026-10-19)
