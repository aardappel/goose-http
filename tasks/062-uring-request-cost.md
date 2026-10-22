# 062: io_uring's request cost since TLS

Status: todo (asked for 2026-10-22)

Since `4324c388`, which serves TLS on the io_uring loop, a plaintext request on io_uring
costs more user instructions on some routes: tier A's `/api/me` +22.9 and `/nothing`
+5.8 on goose-http's REST tier server, with `/api/items/1` and epoll unchanged
(Enkidu, a Ryzen 7 PRO 6850U, WSL2, gcc 15.2, Goose v2026.3, `bench/count.sh` at
N=1,000,000). The loop moved from `http_serve` into `http_ring_loop`, and `flush` now
takes the TLS state and the clock, which changes gcc's register use in `answer`.

`7590b1ff` stopped `take` copying the exchange by value, about 8 instructions under
valgrind on x86-64. Enkidu's v0.4.3 to v0.5.0 count still shows `/api/me` at +22.0,
but its v0.4.3 side was built with Goose v2026.2 (task 059, "v0.4.3 to v0.5.0 on
Linux"). Two alternatives counted worse under valgrind: `flush` given a ROOM of
`{ false }` as on epoll, and a ROOM for plaintext only (+24 to +28).

goose-rest on io_uring shows the same kind of change: +6 to +14 on its rows, and
about +20 on its bare tier F server, where gcc stopped inlining `answer` into `pump`.

## Acceptance criteria

- [ ] `7590b1ff`'s saving counted on Linux with one compiler on both sides
- [ ] The +22 on `/api/me` explained from the generated code and machine code, and
      removed, or recorded here with the reason it stays
