# Decisions

The record for contributors and agents: each design decision, dated, with its reason,
what was rejected, and the task that measured it. How the package works now is in
[architecture](architecture.md); this page keeps why it came to work that way. Entries
run oldest first, and a later entry that replaces an earlier one says so.

## Goose unmodified

Decided 2026-10-10.

The package uses the pinned Goose checkout without modifying it. Compiler and stdlib
gaps that meet the reporting bar go to [Goose findings](goose-findings.md).

## Workers own their connections

Decided 2026-10-10, task 003.

The program spawns workers and passes each a flat `Config`. A `thread_fn` is compiled
as its own program and copies the non-static globals it uses (§11.2). Spawning stays
in the program because `thread_spawn` cannot take a `thread_fn` passed through a
package function. Each worker runs one loop and owns its connections for their
lifetime. Where workers are spawned was replaced on 2026-10-18 by
[the package spawns the workers](#the-package-spawns-the-workers).

## Connection slots and a spill pool

Decided 2026-10-10, task 009.

Connections live in a worker's `reusable` pool. A slot as the event tag avoids an
fd-indexed table growing to the highest fd across all workers. Read and write buffers
belong to the worker; incomplete requests and output that could not be sent go to a
spill pool. Full buffers in every slot were rejected for their memory cost.

## HTTP in Goose, syscalls in a C shim

Decided 2026-10-11, tasks 010 and 011.

HTTP parsing, routing, response building, loop state machines, messages between threads,
timers, and JSON are Goose. C in `shim/` wraps syscalls and kernel structures that
Goose cannot reach. The package sidecar, `http.build`, selects and compiles each
platform's C files; Goose code needs no conditional compilation.

## io_uring is the default loop on Linux

Decided 2026-10-11, task 005.

`http::serve` is the default on Linux. `http::serve_epoll` remains buildable and tested
as a lower-memory alternative. Linux is the benchmark platform; the
[current comparisons](benchmarks.md) record both wins and losses.

## The ring falls back to an emulation

Decided 2026-10-11, task 011.

Where `io_uring_setup` fails, the ring falls back to `shim/ring_epoll.c`: Docker's
default seccomp profile, disabled io_uring, or an older kernel. The same emulation
runs over kqueue on macOS. `Config.emulate_ring` selects it for tests;
`http::ring_probe()` reports why native io_uring is unavailable. The package does not
log the fallback; the benchmark server does.

## macOS over kqueue

Decided 2026-10-11, task 012.

On macOS, kqueue filters become poll flags. Events for one fd are merged within a
batch so a second event cannot drive a slot freed by the first. Workers share a
listener because separate `SO_REUSEPORT` listeners did not distribute connections.
An accept counter limits an already-ahead worker; a level-triggered listener keeps
declined connections available to others. Near the fd limit, a locked free-fd check
avoids macOS dropping a connection on `EMFILE`. Writability is watched only while
output waits for room.

## Linux error codes on every platform

Decided 2026-10-11, task 006.

Goose sees Linux errno values on every platform. Linux passes them through, macOS and
Windows translate, and `net_strerror` supplies platform text. An unmapped code becomes
1000 plus the platform code. The C shims own this mapping.

## A handler with state is called again

Decided 2026-10-12, task 013.

A handler with state is called again for each part of an exchange, with a flat value
of the program's type kept in the connection slot. Goose cannot suspend or store a
handler (§7.6), so this is how bodies, streamed responses, upgrades, and waiting
answers resume. The [event table](api.md#streaming) defines each call and its lifetime.

## The epoll loop bounds reads per turn

Decided 2026-10-12, task 021.

The epoll loop reads at most `Config.max_read` bytes from one connection per turn,
16 KB by default. A connection left readable goes on a deferred list because an
edge-triggered socket may raise no new event while its sender waits. This prevents
a sustained upload taking a worker for the entire body. Completion-loop latency
beside uploads remains open in task 026.

## Large io_uring sends go inline

Decided 2026-10-12, task 021.

The ring owns memory the kernel touches after a call returns. The shim copies sends
into its own buffers, and the loop copies receives out of provided buffers, because
an `extern fn` cannot retain a Goose argument (§7.10). A send of at least 64 KB with
nothing queued on its socket first tries synchronous `send(2)`; only unsent bytes
need a retained copy. Smaller sends stay asynchronous because a syscall per response
cost small REST responses throughput.

## Files of 64 KB or more go to the loop

Decided 2026-10-12, task 020.

`http::send_file` hands a file to the loop when the remaining `Content-Length`
response is at least 64 KB: `sendfile` on epoll and the emulated ring, splice through
a pipe on io_uring, and `TransmitFile` on IOCP. Smaller files and chunked responses
use `pread` in pieces. The threshold avoids direct-send overhead for small files; its
[measurement](results.md#static-files) and the remaining 64 KB gap to nginx are
recorded in task 024.

## Waiting through bounded boxes in C

Decided 2026-10-12, task 015.

Waiting uses bounded boxes, a fixed-capacity timer table, and generation-checked
handles, each independent of HTTP. Boxes are C because Goose has neither atomics
nor a wait another thread can end. Goose's typed queues have no bound, allow any
thread to receive, and cannot wake an event loop.

Since Goose's queues took a limit and a timed wait (2026-10-19, task 051), jobs that
any thread of a pool may take go through a queue chosen by type instead, as the
benchmark server's backend's do. Boxes stay for the rest, which a queue chosen by type
can't do: a reply to the one worker that waits, whose event loop only an fd wakes; a
lane's own jobs, where `rest::ask_by` keeps one key's in order on one thread and a send
picks the least busy box; keys a box tracks as live; and a stop that a full box can't
refuse.

## The log measures the write buffer

Decided 2026-10-12, task 015.

With `Config.log`, `DONE` reports status, bytes, and elapsed loop time. It measures
completion in the write buffer, not delivery to the client, which the loop does not
track per response.

## The API isn't frozen

Decided 2026-10-13, task 027.

The API may change when an idiom improves clarity without costing speed or memory
beyond the benchmark runs' spread.

## Sends to an exchange that no longer waits are stale

Decided 2026-10-14, tasks 027 and 028.

Send checks the key atomically before claiming a queue slot and returns `STALE` for
an exchange that no longer waits. `mail_live` gives any thread the same snapshot
without sending. A send that read a live key before it was cleared can still be
queued; the loop checks each delivered key and drops messages that no longer match
a waiting exchange. Repeating `later` on the same exchange marks its key live again.
Send returns `SENT`, `FULL`, `TOO_LONG`, or `STALE` without blocking; senders can query
the slot size, or -1 for a stale address.

As first decided, both Goose loops cleared the key before `WAKE`, `TIMEOUT`, or
`CLOSED`, when a timer could not be armed, or when a handler answered instead of
waiting. The next entry replaces that for `WAKE`.

## A waiting key stays live through WAKE

Decided 2026-10-14. Replaces clearing the key before `WAKE`, in the entry above.

`later` marks the key before returning, so a reply from another thread can arrive
before the handler returns. The key stays live through a `WAKE` and is cleared after
the handler returns without waiting again, so a reply sent in pieces never finds it
stale between one piece and the handler's next `later`. It is cleared before
`TIMEOUT` and `CLOSED`, when a timer cannot be armed, and when a handler answers or
stops waiting instead of waiting. `Stream.live` records whether the key is marked, so
only an exchange that waited pays for an atomic write. This covers io_uring, epoll,
kqueue, and IOCP through their shared Goose paths.

## A store for read-only blobs

Decided 2026-10-14, task 025.

The store (`store.goose` over `shim/store.c`) holds byte blobs populated by one thread
and frozen before others read. Queues, `thread_spawn`, or `thread_wait` order writes
before reads. Reads copy ranges into Goose arrays because an `extern fn` cannot return
a view of C memory (§7.10). The data's meaning and response construction remain Goose.
The store imports nothing of HTTP and is reached through `import http.store`.

This avoids a copy per worker for JSON built at startup. Loading it from disk per
request was rejected: it would move memory out of RSS into the page cache and add a
syscall per response. Other REST records still cost a copy per worker.

## An upgraded connection is read while it waits

Decided 2026-10-15, task 038.

A waiting exchange holds back the bytes after it, since the next request must wait
its turn, except an upgraded one: its connection is a stream both ways, so the loops
go on reading it and `answer` hands what arrives to the handler as `BODY` while the
wait stands (`holds_input`). The wait still ends only with `WAKE`, `TIMEOUT`, `end`,
or `CLOSED`, so this adds no state, and the handler sees bytes and the reply in the
order they reached the worker.

## Tests follow Goose's convention

Decided 2026-10-15, task 041, for goose-http, goose-rest, and goose-compress alike.
Tests follow Goose's own convention, as the Goose repository's `test/` and
`docs/testing.md` lay it out:

- A top-level `test/` holds the tests, in a folder per area.
- Each test is a small program: a `main` with `assert`s, which prints what it checks.
  Its expected output is a golden file, `test/expected/<name>.out`, with
  `<name>.stderr` for lines its standard error must hold, and `<name>.aborts` for a
  test that must abort.
- A test that must not compile carries `// error: <substring>` comments.
- The repository's own runner, `test/run_tests.py` in Python as Goose's is, finds the
  tests, compiles them in batches with `goose --multi-test`, runs each as a process of
  its own and in parallel, and reports every failure without stopping at the first.
  No runner is shared between repositories, as none is with Goose's. In goose-http the
  batch is the typecheck, and `goose build` builds each test, since most tests link C
  that a sidecar names, the package's shim or the box's, which `goose build`
  compiles.
- Helpers the tests share are one imported module, not a copy in each test.

This replaces the test programs `scripts/test.sh` runs by name, where the first failed
`assert` ends a program and hides the rest. A test framework inside Goose was rejected:
Goose has no reflection to find tests, and checking by printing against a golden file
needs none. So were tests beside the code: Goose's compiler already leaves out of a
build what its root doesn't import, so a separate `test/` costs nothing, and it matches
the convention any reader of Goose's own repository knows.

## One name for each place data lives

Decided 2026-10-16, with goose-rest. A thread's queue of messages is a *box*
(`http::Box`), and a message reaches it *by mail*; the shared blobs are the *store*
(`http.store`); a global with a literal value, compiled into the program, is a
*constant*; and the thread that does one kind of slow work, which workers send jobs to
by mail, is a *lane*. These replace "mailbox", "shared store", "a global with a literal
initializer", and, in the slow-work pattern, "service thread" and "backend thread".
The request's state in `http::serve` keeps its name, and no API name changed.

Decided 2026-10-16, with goose-rest: work of minutes that the handler answers with
`202 Accepted`, and that the client then polls, is a *background task*, not a job. A
*job* is the work a handler mails a lane and waits for, as in goose-rest, where a
background task is made of jobs: one that starts it, and one for each poll.

## http::run restarts a worker that aborts

Decided 2026-10-19, task 050; it replaces "a crash ends the process" (2026-10-16).

`http::run` starts each worker with `thread_spawn_contained`
([aardappel/goose#38](https://github.com/aardappel/goose/pull/38)), so an abort, such
as an index out of bounds or a failed `assert`, ends only that worker. `run` closes its
listener and starts it again with the same `Config` and values, while the other workers
serve on: Tina's "let it crash", which restarts one Isolate and keeps the rest of its
shard running. A worker that keeps aborting is restarted after 100 ms, then twice as
long each time, and after `Config.restarts` aborts in a row, 5 by default, `run` ends
the process with exit code 1, for the service manager to restart
([crashes](patterns.md#crashes)). A program that spawns its own workers still ends the
process on an abort, and so does a lane unless it opts in
([lanes restart through a wrapper](#lanes-restart-through-a-wrapper-the-program-writes)).

A `thread_fn` can't be generic, so a watcher thread can't start the program's worker
again. Each worker has a small `thread_fn watch` that waits for it and puts how it
ended on Goose's queue of `WorkerEnded`; `run`, which can name the worker, takes them
with `qget` and does the restart. Each loop puts its listener and its ring on the queue
of `Opened` when it opens them, so that `run` can stop an aborted worker's. A
generic `thread_fn` would have saved the queue, but it is a language change, and the
queue does the job with what Goose has (2026-10-19).

The runtime frees only the aborted worker's Goose memory. What it opened through C
stays open. Two parts would take new connections that no one answers, so `run` stops
them: the listener, which the kernel keeps queueing connections to, and the ring's
accept. On Linux, an io_uring multishot accept holds its listener open after the
thread exits and its fd is closed, so `net_close_listener` shuts a TCP listener down
first, which takes it out of its `SO_REUSEPORT` group; on Windows, the completion
port's accept posts itself again from a wait callback, so `ring_reap` cancels it. The
rest stays open, bounded by `Config.restarts`: its connections, whose clients get no
answer until they give up, its ring's memory, and its box; closing them is task 050's
next step. Each worker also has its watch thread, mostly blocked, which costs a
thread's stacks.

## Lanes restart through a wrapper the program writes

Decided 2026-10-19, task 050; it replaces waiting for a Goose change (task 052).

A lane thread that should survive an abort is restarted by a `thread_fn` the program
writes, which calls goose-rest's generic `rest::keep` with the spawn of the lane's own
`thread_fn`. Since Goose `fb5698125`, a generic plain `fn` called from a `thread_fn` can
spawn the `thread_fn` it is handed, so the wrapper needs no Goose change. The cost is
three lines per lane that opts in. A `thread_fn` that takes a function value would have
saved them, but it covered only one form of `lane_open`, and the maintainer would ask
for type generics as well.

goose-http gives the restart two pieces, so that a lane restarts as a worker does:

- `http::restart_after` with an `http::Restarts` per thread is `run`'s policy: 100 ms,
  doubling, and the process ended after `Config.restarts` aborts in a row, 5 by
  default.
- `http::mail_adopt` settles what an aborted owner took. `mail_take` settles a round's
  messages after its callback returns, so an abort inside it leaves them counted, and
  the next owner's `mail_stopped` never came true: `lane_stop` hung. The box now
  counts what its owner took and hasn't settled, in a plain field only the owner
  writes, which the new owner reads once `thread_wait` has joined the old one. It
  costs a non-atomic add per message taken; `mail_take` still settles each round
  with one atomic.

## A stop is a flag in the box, not a message

Decided 2026-10-17, task 044; `mail_stopped`'s wait, 2026-10-18.

`http::mail_stop(box)` sets a flag in the box and wakes its owner, and
`http::mail_stopped(box)` is true once the box is stopped and empty. A `STOP` message
needs a free slot: to a full box at shutdown, its send returns `FULL`, the stop is
lost, and the lane waits forever, which goose-rest's lanes did. Tina reserves part of
its message pool for shutdown, timers, and restarts for that reason; a flag needs no
reserve, since traffic can't crowd it out. A send to a stopped box returns `STALE`, so
a lane that finds its box stopped and empty can close it without dropping a job sent
after. `mail_stopped` waits, yielding in the shim, for the sends in
flight across the stop, since returning `false` to a lane whose box workers were
polling made it spin at 100% CPU. The cost is one more load of the flag on every send,
a locked instruction under MSVC (task 047).

## Placement is opt-in, and a file per machine places the code's roles

Decided 2026-10-17, task 046; the exclusive and `incoming` rules, 2026-10-18.

The code names roles, the workers (`Config.role`) and each lane, and a placement file,
one per kind of machine, maps them to cores, a priority, and `SO_INCOMING_CPU`
([tuning](tuning.md)). Without a file, every thread floats, as before. A machine that
changes needs a new file, not a new build. Tina fixes each shard's core in a boot spec
compiled into the program; here the file is read at startup and holds only cores, and
the operator writes down which share an L3 cache or a NUMA node, since the package
reads no topology. The file is a line format that `place.goose` parses, as Goose has no
TOML or YAML parser.

Nothing about the hardware stops the start: cores the process can't use, more threads
than a set's cores, an overlap with an exclusive set, and a platform with no affinity
each print a warning, and the program runs with what it could apply. A file that
doesn't parse ends it with exit code 2, as any malformed configuration does. The cost
is that a wrong file runs, placed otherwise than written, with only stderr to say so.

Placement took the place of `http::pin_thread` and `Config.pin`, built first for task
045's spike and never released; neither had an entry here. Whether any placement beats
floating on real cores is unmeasured: task 045's pinned layouts wait for bare-metal
Linux, and only those that beat floating by more than the runs' spread are to stay.

## The shim holds the placement, and Config a handle

Decided 2026-10-18, task 046.

`place_load` hands the parsed `Place` to `shim/place.c`, which keeps a copy, and
`Config.place` is its handle, an `http::PlaceRef` of one `i32`. A worker reads the
`Place` into a local as its loop starts and keeps only its seat. With the `Place`
itself in `Config`, every worker held about three copies of it, since `thread_spawn`
and the loops take `Config` by value: `sizeof(Config)` in the generated C went from
4,757 bytes to 390, and `examples/hello`'s peak RSS from 3.56-3.82 MB back to
3.26-3.34 MB, within `main`'s 3.29-3.41 MB before placement (machine and method in
task 046). The cost is a C call and a copy as each worker starts, and a limit of 8
placements a process.

## A worker's seat goes by the order workers start

Decided 2026-10-17, task 046.

A worker takes the next index of its role from a counter per placement and role in
`shim/place.c`, as its loop starts, so the program's spawn loop passes no index and
doesn't change. Which worker gets which core is then arbitrary, which costs nothing,
since every worker is the same. Two servers that share a placement and a role share
the counter, so each needs a role of its own. Replaced on 2026-10-18 by
[the package spawns the workers](#the-package-spawns-the-workers).

## An exclusive set takes its cores from other roles

Decided 2026-10-18, task 046.

A role whose cores an exclusive set it doesn't name holds loses them, with a warning,
and floats on the cores no exclusive set holds when none are left. Where the exclusive
sets hold every core the process may use, such a role, and one the file doesn't name,
floats on any core, the exclusive ones included, with one warning. Refusing the file
would break the rule that hardware doesn't stop the start, and the same file runs on a
smaller machine. The cost is that a role can run on fewer cores than its line says.

## No .env loader

Decided 2026-10-18, task 046.

`http::env_load`, which put a development `.env` file into the environment through the
placement file's line reader, was built and dropped. No program called it, and in
production systemd's `EnvironmentFile` and Compose's `env_file` already load one into
the environment that `env` reads.

## The package spawns the workers

Decided 2026-10-18, task 048. Replaces the spawning in
[workers own their connections](#workers-own-their-connections) and
[a worker's seat goes by the order workers start](#a-workers-seat-goes-by-the-order-workers-start).

`http::run(cfg, worker)` spawns the workers, with up to two values of the program's
between `cfg` and the worker, and returns once every one has returned. It sets each
worker's index in `Config.worker`, and the loop takes the seat of that index. Goose
`fb5698125` lets a generic function spawn the `thread_fn` its caller binds, which made
this possible; before it, every program wrote the same spawn loop, and the shim
counted workers as they started, since none knew its index. The counter was global C
state, and with it gone, `shim/place.c` keeps only the placements. Goose has no
variadic parameters, so `run` has an overload for each count of values; two cover
every program in goose-http and goose-rest. The worker comes last, as Goose passes a
function value after a call's other arguments.

A program that picks the loop for its workers at run time, such as `server/app.goose`,
calls `run` once per choice (2026-10-18). Only a program that must interleave spawning
with other work, such as the REST benchmark servers with their startup handshake, keeps
its own spawn loop and sets `Config.worker`. A placed worker spawned without `Config.worker` floats and prints a warning,
rather than falling back to a counter, so that no C state stays for code that `run`
replaces. Two servers that share a placement and a role now take the same seats, so
each still needs a role of its own.

## Not yet decided

### Compression in an optional module

Implemented, with no recorded approval; task 022.

Precompressed files need no codec. Dynamic compression is implemented in the optional
`http.compression` module using goose-compress's pure-Goose gzip, deflate, and zstd
encoders. Negotiation and response framing stay in `http`; codecs import nothing of
HTTP. Programs without the module need no codec dependency. Compression remains part
of measuring Goose; TLS crypto is outside this project's scope. Task 022 retains the
split's unrecorded approval and remaining validation.
