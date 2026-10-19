# 050: Restart a worker that aborts

Status: in-progress; `http::run` restarts workers on Linux and macOS, and its policy and
`mail_adopt` are ready for goose-rest's lanes (2026-10-19)

With `thread_spawn_contained` ([aardappel/goose#38](https://github.com/aardappel/goose/pull/38),
in the pinned `dcc2747`), an abort ends only its thread, and `thread_wait` returns false
for it. `http::run` uses that to keep serving when a handler aborts: Tina's "let it
crash", with the restart policy its supervisors have, a delay that grows and a limit
([decision](../docs/decisions.md#httprun-restarts-a-worker-that-aborts)).

How it works: a `thread_fn` can't be generic, so a watcher thread can't start the
program's worker again. Each worker has a small `thread_fn watch` that waits for it and
puts a `WorkerEnded` on Goose's queue; `run`'s loop takes them with `qget` and restarts
the worker, since `run` can name it. Each loop puts its listener and ring on the queue
of `Opened`, and `run` stops an aborted worker's: `ring_reap`, then
`net_close_listener`.

What an aborted worker opened through C stays open. Two parts take new connections
that no one answers, so `run` stops them:

- **The listener**, to which the kernel keeps queueing connections. On Linux with
  io_uring, closing it wasn't enough (2026-10-19, arm64 Docker, kernel
  7.0.14-linuxkit): the dead ring's multishot accept holds the socket, which stayed in
  its `SO_REUSEPORT` group with connections queued, after the thread had exited and
  both its fd and the ring's were closed; 2 of 8 new connections hung. Shutting the
  listener down first fixed it: 0 of 40 lost.
- **The ring's accept.** On Windows the completion loop posts the next `AcceptEx` from
  a wait callback on another thread, so it would go on taking connections from the
  shared listener; `ring_reap` cancels it. Built, not yet run.

The rest waits for the second step: its connections, whose clients get no answer until
they give up, its ring's memory, and its box and waker.

## Acceptance criteria

- [x] `http::run` starts workers contained and restarts an aborted one with the same
      `Config` and values, after 100 ms, doubling per abort in a row, ending the process
      with exit code 1 after `Config.restarts`; none after a stop
- [x] An aborted worker's ring stopped (`ring_reap`) and listener closed from `run`
      (`net_close_listener`: a TCP one shut down first on Linux, a shared one given back
      to its entry), in `shim/net.c`, `shim/kqueue.c`, `shim/net_win.c`, `shim/uring.c`,
      `shim/ring_epoll.c`, and `shim/iocp.c`
- [x] Tests: `test/server/run.goose` (a worker restarted with its index and values),
      and `scripts/test-http.sh`'s `/abort`, then 40 new connections all answered
- [x] `docs/decisions.md` replaces "a crash ends the process"; `docs/api.md`,
      `docs/patterns.md` ("Crashes"), and `docs/embedded.md` follow
- [x] `scripts/test.sh` passes on macOS, and on Linux in arm64 Docker with native
      io_uring, the emulated ring, and epoll (2026-10-19)
- [ ] `scripts/test.sh` passes on Windows (IOCP), the abort check showing that
      `ring_reap` stops the accept
- [ ] Second step: what an aborted worker opened through C closed by `run` in every
      backend, so its clients get a reset, or a reason recorded for each part left
- [ ] Lanes: opt-in, through a `thread_fn` the program writes that calls goose-rest's
      `rest::keep` (goose-rest's task 044), with no Goose change; task 052 cancelled
      ([decision](../docs/decisions.md#lanes-restart-through-a-wrapper-the-program-writes))
- [x] `run`'s policy shared as `http::restart_after` and `http::Restarts`, with
      `run`'s output unchanged; `test/server/restarts.goose` covers the limit's exit
- [x] `http::mail_adopt`: a box counts what its owner took and hasn't settled, so the
      owner that takes over after an abort in `mail_take`'s callback settles it, and
      `mail_stopped` comes true (`test/mail/mail_adopt.goose`)
- [ ] The cost of `mail_adopt`'s count, a non-atomic add per message taken, measured
      in the next overnight benchmark batch (unmeasured)
