# 052: Goose PR: a thread_fn that takes a function value

Status: cancelled — not opened (2026-10-19, after a review of the change and its PR
description)

The change covered only `lane_open`'s two-argument form, the maintainer would likely ask
for type generics on a `thread_fn` too, and lane restarts need no Goose change: a
`thread_fn` the program writes calls goose-rest's generic `rest::keep`
([decision](../../docs/decisions.md#lanes-restart-through-a-wrapper-the-program-writes)).
The branch `thread-fn-values` (`5b3e92d`) stays on `kaitk/goose` with two known
findings: a spawn from an `export fn` skips `CheckThreadGlobals`, and its docs used this
repository's term "lane".

What follows is the task as it stood.

A `thread_fn` can't be generic in Goose, so a library that is handed a `thread_fn`
can't write a watcher thread that starts it again after an abort: the watcher would
have to name it. `http::run` works round it with a queue to its own blocked loop (task
050), but `rest::lane_open` returns at once, and no thread is left that can name the
lane's `thread_fn` (goose-rest's task 044, which records the two workarounds rejected).

The change: a `thread_fn` may take function values, bound at `thread_spawn` and
`thread_spawn_contained` by trailing function names, as a call binds them (spec §7.6).
Each binding is its own thread program. A type generic on a `thread_fn` stays an error.
No new syntax, and only code that is an error today becomes valid:

```goose
thread_fn watch<W>(box: http::Box, at: http::Seat) {
    while !thread_wait(thread_spawn_contained(W, box, at)) { ... }
}
// in lane_open<W>:
thread_spawn(watch, b, at, W);
```

It completes #37 (a generic spawns the worker it was handed) and #38 (an abort ends
only that worker). With it in the pin, nothing more in Goose blocks restarting lanes;
what an aborted thread opened through C stays ours (task 050).

## Acceptance criteria

- [ ] The change on `thread-fn-values`, Goose's full suite passing, with a test and an
      error fixture for a type generic, and the spec and reference updated
- [ ] A lane restart in goose-rest built and run against it, as a check before the PR
- [ ] The PR description reviewed, then the PR opened upstream
- [ ] Merged, or its outcome recorded here, with any changes the maintainer asks for
- [ ] The pin moved to a Goose commit or release with it; then goose-rest's task 044's
      lanes, and `http::run`'s supervisor simplified to the same `watch<W>` where that
      drops its queue of `WorkerEnded`
