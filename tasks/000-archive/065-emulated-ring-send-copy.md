# 065: Avoid copying immediately accepted large sends

Status: cancelled

The readiness-based ring can submit a large buffer during the extern call and own
only its unsent tail. Small sends remain queued, and all completions remain deferred.

Cancelled at the consumer's request on 2026-10-23 after the upstream review finds
a 13-28% server-bound throughput regression. The consumer removes its patch and
uses unpatched upstream. The code and measurements remain in this closed PR's
history; a future send proposal must establish a server-bound benefit first.

## Acceptance criteria

- [x] No Goose argument survives the extern call; queued sends and files retain order.
- [x] Full/partial sends, EAGAIN, EINTR/errors, allocation failure, close and completion
  overflow pass deterministic tests, including the 16 KiB boundary and empty sends.
- [x] Sanitizers, the 60 package tests at both optimization levels, and both Linux
  loops' stalled-reader, disconnect-reuse and publisher-fairness tests pass.
- [x] Record individual application and plaintext samples, including adverse results.
- [x] Record the review's A/A controls and characterization of the plaintext difference.
- [ ] Demonstrate a server-bound benefit against two base builds before proposing a send change.
- [ ] Validate the shared emulation on macOS; native io_uring and Windows are unchanged.

The all-size attempt reduces application CPU cost but loses 25.5% median throughput
in pipelined plaintext. A 16 KiB floor restores user-cycle cost close to baseline,
but its six-sample plaintext median remains 8.5% lower. This is a review candidate,
not a demonstrated win across workloads. The review then measures a 13-28% loss
on server-bound 21 KiB responses; copying the base response twice has no measurable
cost. Native io_uring requires Linux 6.1 or later and a container policy that permits
its syscalls. See the
[measurement record](../bench/results/2026-10-22-campfire-send-copy/summary.md) for
the machine, commands, compiler pins, individual samples and limitations.
