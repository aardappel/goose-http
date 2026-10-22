# Examples

Small servers, each showing part of the package. The concepts come first in the
[README](../README.md#concepts), [patterns](../docs/patterns.md) say which approach
fits large bodies, long responses, slow work, and limits, and the [API](../docs/api.md)
covers each function with the example that shows it. Each example shows one mechanism;
[Plod's tutorial](https://github.com/kaitk/plod/blob/main/docs/tutorial/README.md)
builds an application from them, step by step, with typed routes and middleware on top
of this package.

Each example imports the package from this checkout (`"../../"`), not from GitHub. A
program of your own imports it as the [Quick start](../README.md#quick-start) does.

| Example | What it shows |
|---|---|
| [`hello/`](hello/hello.goose) | One route, one worker per core: the Quick start |
| [`routes/`](routes/routes.goose) | The router: parameters, 404 and 405, a JSON response, a request body, and a stop on Ctrl+C |
| [`api/`](api/api.goose) | A JSON API: path parameters, JSON or CSV by `Accept`, a JSON or form body, an entity tag, Bearer and Basic credentials, a cookie, and the client's address behind a proxy |
| [`upload/`](upload/upload.goose) | Uploads read as they arrive: a raw body, and a multipart form part by part, with a body limit; and a body larger than the read buffer, gathered whole |
| [`later/`](later/later.goose) | An answer that waits for a lane over mail, with 504 when it takes too long, and jobs skipped once nobody waits for them |
| [`files/`](files/files.goose) | A directory's files, with ranges, conditional requests, and precompressed copies |
| [`compress/`](compress/compress.goose) | Responses compressed by `Accept-Encoding`, whole and streamed, with goose-compress |
| [`c/`](c/) | A handler written in C, with the server and its loops in Goose ([below](#a-handler-in-c)) |
| [`device/`](device/device.goose) | A board's HTTP API: temperature and an LED through sysfs, a GPIO line through C, the temperature as Server-Sent Events, and either loop by `LOOP` ([embedded Linux](../docs/embedded.md)) |

Build and run one from the repository's root:

```sh
goose build -o build/examples/routes examples/routes/routes.goose
./build/examples/routes
curl localhost:8080/users/42
```

Each one listens on port 8080. `scripts/test.sh` typechecks them, and
`scripts/test-examples.sh`, its last step, builds each and requests each of its
routes once.

## A handler in C

`examples/c/` is an experiment (2026-10-12): C programs using the package's server
without writing Goose. `app.goose` runs the server and calls `gh_handle` for each
request. `handler.c` defines `gh_handle`, and `goose_http.h` declares what it gets and
returns. The sidecar, `app.build`, has `goose build` compile `handler.c` and link it in.

```sh
goose build -o build/examples/c-app examples/c/app.goose
./build/examples/c-app
curl localhost:8080/count
```

The handler gets the request's method, target, header field lines, and body. It writes
a status, a content type, and a body of up to 1 MB (`MAX_RESPONSE` in `app.goose`). The
server writes the response's head and frames it, and keeps every connection, limit, and
timeout it has for Goose handlers.

The interface is limited to bytes in and bytes out by Goose, not by this package:

- The handler can't call the package's Goose functions, such as the router, the cookie
  and form parsers, or `send_file`. C calls Goose only on the thread that called
  `goose_init` (the pinned checkout's spec, §7.11), and the handler runs on the workers.
  `goose_http.h` has a field lookup, `gh_field`, written in C for that reason.
- Goose has no function pointers to hand a handler over at run time (§7.5). The handler
  is the one C function named `gh_handle`, linked in.
- The handler runs on every worker at once. State it shares must be atomic or locked, as
  `handler.c`'s request counter is.
- It gets a body only when the body fits in the read buffer with the head, 8 KB by
  default, and doesn't stream a response.

Rust or Zig could define `gh_handle` the same way, as an `extern "C"` or `export`
function in a static library the sidecar links. That isn't set up here.
`scripts/test-examples.sh` builds it and requests each route, on Linux with gcc and on
Windows with MSVC (2026-10-14).
