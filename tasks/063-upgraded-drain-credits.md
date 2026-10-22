# 063: Upgraded output drain credits

Status: in-progress

`after_drain` and `DRAINED` let a publisher keep one bounded batch in flight per
upgraded connection. The application bounds its queues; this is not a cap on
arbitrary sends or an acknowledgement from the peer.

## Acceptance criteria

- [x] Both loops deliver one credit after socket acceptance, preserving mailbox waits.
- [x] Flag, repeated-call, and close tests pass at `-O0` and `-O2` with Goose v2026.3.
- [x] Linux stalled-reader test preserves 32 MiB in order and reuses disconnected slots.
- [x] Direct publishers yield to other sockets and remain active beyond the idle timeout.
- [x] `scripts/test.sh` runs the Unix integration tests; API, patterns, and changelog agree.
- [x] Record `bench/count.sh` before/after instructions on the final patch.
- [ ] Run drain integration on native io_uring, macOS, and Windows before release.

## Review checks (2026-10-22)

The original PR's direct epoll publisher can starve another socket. The regression
times out on that version and passes with at most one credit per connection turn,
using the loop's existing ready queue. No connection fields are added.

The original ring code already refreshes the deadline: `answer` increments `done`
for the `DRAINED` callback, and `pump` restores `progress` before `resume` calls
`touch`. The regression passes on the original PR and on the revised patch; no
additional assignment is needed.

Linux validation uses Goose v2026.3 on x86-64, Clang 18.1.3, Docker on WSL2 kernel
5.15.167.4. All 60 unit tests pass at both optimization levels. The drain tests
exercise both explicit epoll and the ring's epoll emulation. Native ring setup
reports `EINVAL` on this kernel even with the container syscall filter removed.
The test runner includes the macOS check, but no macOS or Windows run is recorded.

## Plain HTTP cost

Compared upstream `a7ce7d1` to this patch with the same Goose v2026.3 release and
GCC 13.3.0 (`--standalone`, release build). Machine: AMD Ryzen 9 9950X3D, WSL2
5.15.167.4, Docker with hardware perf counters. Each of three alternating runs uses
`LOOP=uring|epoll RUNS=3 N=10000000 sh bench/count.sh goose-before goose-after`:
one worker on CPU 0, h2load on CPUs 4-15, eight client threads, 256 connections,
16 requests in flight per connection, `/plaintext`. Every response is checked as 2xx.
The uring row uses the reported epoll emulation, not native io_uring.

| Loop | Before user instructions/request, median (range) | After | Median delta |
|---|---:|---:|---:|
| Emulated ring | 1,944.8 (1,944.8-1,944.8) | 1,944.9 (1,944.8-1,944.9) | +0.1 |
| Epoll | 1,904.3 (1,904.3-1,904.3) | 1,904.6 (1,904.5-1,904.6) | +0.3 |

Both deltas are below 0.02% in this pipelined HTTP workload. Native io_uring's
instruction cost remains unmeasured. The framing check comes first, so ordinary
HTTP skips the upgraded-stream conditions.
