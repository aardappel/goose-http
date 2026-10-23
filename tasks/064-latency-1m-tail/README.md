# 064: latency-1m's tail

Status: in-progress

On a laptop, HttpArena's latency-1m showed goose-http and Plod with p99 of seconds while
their workers had spare CPU. On the Mac, the same symptom appears only when zrk, the
load generator, runs out of CPU, and it appears for tokio as well. In every Mac run,
goose-http's io_uring loop held no request longer than about 20 ms. The open question
is whether zrk was saturated on the laptop too.

## Acceptance criteria

- [x] Reproduce the symptom on the Mac and find which side holds the requests
- [x] Rule each loop suspect in or out with counters (`counters.patch`)
- [ ] On the laptop, measure zrk's per-thread CPU during a tailed run, and rerun with
      `THREADS=8`
- [ ] If the tail stays with an idle client, find the cause in the loops; otherwise
      record the client's limit where the HttpArena results are recorded

## The laptop's evidence (2026-10-23)

Ryzen 7 PRO 6850U, WSL2, server on CPUs 0-3, zrk on CPUs 4-15 with `THREADS=4`.
latency-1m at 200,000 requests a second over 1,024 keep-alive connections for 20 s,
three rounds a run, HttpArena `3717e256`. Runs in this order:

| Run | rate_ratio | CPU/req | p50 | p99 | p99.9 |
|---|---|---|---|---|---|
| Plod (io_uring) | 0.994-0.995 | 13.34 µs | 2-3 ms | 35-89 ms | 105-274 ms |
| Aegon (C++, io_uring) | 0.995 | 15.25 µs | 3-4 ms | 52-101 ms | 104-358 ms |
| goose-http's entry | 0.974-0.981 | 13.51 µs | 19-67 ms | 1.8-2.8 s | 2.6-4.4 s |
| Plod without `mail_slots`/`max_waiting` | 0.985-0.987 | 13.94 µs | 16-20 ms | 0.93-1.23 s | 1.5-2.1 s |
| Plod again | 0.975-0.994 | 13.87 µs | 12-45 ms | 0.88-1.55 s | 1.4-2.9 s |
| Aegon again | 0.995 | 15.65 µs | 4-7 ms | 92-188 ms | 0.23-0.60 s |
| Plod on the epoll loop | 0.933-0.959 | 14.11 µs | 36-215 ms | 3.4-4.9 s | 4.9-7.4 s |

pidstat showed four even workers at 57-62% of a CPU each (peaks 66-75%), about 2.6 of
4 CPUs. zrk's CPU wasn't measured.

## Mac measurements (2026-10-23)

MacBook Pro M1 Pro, Docker Desktop 29.8.2, a 10-CPU VM on kernel 7.0.14-linuxkit. The
server ran on CPUs 0-2 (3 workers), zrk 2.3.0 on CPUs 3-9, with 1,024 connections and
20 s a round. goose-http was at `295bf036`, the uring loop, with the entry's settings
(`MAIL_SLOTS=256 MAX_WAITING=16384`). Harness runs used `bench/httparena.sh run` with
`PROFILES=latency-1m RUNS=3`. Manual runs started the entry's image and `zrk:local`
with HttpArena's arguments, one round each, and sampled the VM every 0.5 s with
`netstat -tn` and the containers' `cpu.stat`.

| Run | rate_ratio | zrk's peak lag | p50 | p99 | p99.9 |
|---|---|---|---|---|---|
| goose, harness, first run of the session | 0.955-0.998 | 1.6-3.0 s | 361-480 ms | 1.1-2.5 s | 1.4-2.7 s |
| tokio, harness, next | 0.998 | 22-41 ms | 84-91 µs | 1.5-2.5 ms | 10-27 ms |
| goose, harness, again | 0.998 | 15-30 ms | 71-73 µs | 0.5-0.6 ms | 5.4-8.0 ms |
| goose, manual, 200K, 8 rounds | 0.998 | 14-184 ms | < 1 ms | 1-52 ms | 6-100 ms |
| goose, manual, 300K, 10 rounds | 0.997-0.998 | 32-1,618 ms | < 1 ms | 0-1,326 ms (9 of 10 under 70 ms) | 9-1,445 ms |

The tail came and went as on the laptop: one bad harness run, one bad 300K round. In
that round, `netstat` showed both sides behind at once for 4.5 s: about 500 server
sockets held an unread request while 300-500 client sockets held an unread response.

zrk costs more CPU than the server. At 200K with 4 threads it used 50-56 CPU-seconds
in 20 s, 2.5-2.8 CPUs or 12.5-14 µs a request, against the server's 32-36. To check
the symptom of a saturated client, zrk ran 2 threads:

| zrk | Server | rate_ratio | Peak lag | p50 | p99 | p99.9 |
|---|---|---|---|---|---|---|
| 2 threads, 230K, 1.75 CPUs | tokio | 0.998 | 69-71 ms | < 1 ms | 2-3 ms | 23-31 ms |
| 2 threads, 230K, 1.75 CPUs | goose | 0.998 | 83-108 ms | < 1 ms | 1-3 ms | 20-31 ms |
| 2 threads, 270K, 1.95 CPUs | tokio | 0.992-0.998 | 0.69-1.30 s | 0-19 ms | 135-390 ms | 322-656 ms |
| 2 threads, 270K, 1.95 CPUs | goose | 0.995-0.996 | 0.90-1.14 s | 2-17 ms | 383-395 ms | 579-670 ms |

At 270K, both servers show the laptop's symptom: zrk falls behind its schedule, the
rate ratio drops, and p99 reaches hundreds of milliseconds while the server uses 1.6-1.8
of its 3 CPUs. In the same goose runs, the longest pass of the loop was 5.1 ms and its
longest wait under load 17 ms, so the server held no request for longer than that. The
latency built up in the client.

Other comparisons at 200K (tokio, then goose): server voluntary context switches 656K
and 667K, zrk's 2.46M and 2.27M. With one server CPU at 90-150K, goose's tail matched
or beat tokio's. A CPU hog on the server's CPUs for 2 s raised tokio's p99 to 207 ms
and left goose's under 1 ms. None of these shows goose-http costing more than tokio,
for itself or for the client.

## Loop suspects

`counters.patch` adds per-worker counters to `ur_wait` in `shim/uring.c`, printed to
stderr each second. They are for scratch builds only. Over 18 instrumented runs, in
steady load:

- Lost wakeups recovered by a timeout: the wait's timeout (`wait_for`, at most 1 s)
  never expired under load. Ruled out.
- Completion-queue overflow: 0. Ruled out.
- The cap of 256 completions a pass: reached only during the connection burst at the
  start. The rest stay in the completion queue, in order, for the next pass. Ruled out.
- Provided-buffer exhaustion (`ENOBUFS`): none with 3 workers at about 341 connections
  each. With one worker holding all 1,024 connections and 256 buffers, about 1,000 in
  20 s; the loop arms the receive again, and the connection waits one more pass. Not a
  cause of the tail. The laptop's 4 workers have about 256 connections each, which is
  `ring_buffers`' default.
- Long passes: at most 5.1 ms. Goose code takes 5-6% of a worker's wall time; the rest
  is in `io_uring_enter`, which also runs the TCP work under `DEFER_TASKRUN`.
- Persistent state across runs: four rounds against one server container stayed clean
  (p99 1-6 ms).

What differs between goose-http and Aegon (`UdayKhare09/Aegon` `e649022`): both
use `DEFER_TASKRUN` and `submit_and_wait(1)` with multishot receives. Aegon pins each
worker to one CPU of its cpuset, and its HttpArena entry gives each ring 16,384 provided
buffers and 8,192 entries, where goose-http has 256 and 4,096. Both are candidates for
the laptop only if zrk turns out to have CPU to spare there.

## Remaining

The Mac reproduces the tail only by starving the client, so the laptop has to show
whether its tail is the same. At the Mac's ratio of zrk's cost to the server's (about
1.6 to 1), the laptop's 13.5 µs a request on the server would need about 4.3 CPUs of
zrk at 200K, more than its 4 threads. Its rate ratio of 0.995 even for Aegon, against
the Mac's 0.998, also points to a client at its limit. The check: zrk's per-thread CPU
during a tailed run, and the same runs with `THREADS=8`.
