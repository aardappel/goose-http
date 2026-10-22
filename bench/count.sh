#!/bin/sh
# Counts the user instructions each server in build/bench/ spends on exactly
# N plaintext requests, with perf stat on the server's process alone: one
# worker on CPU 0, h2load on CPUs 4-15 with 8 threads, 256 connections, 16
# requests in flight on each. Unlike bench/instructions.sh, which divides a
# CPU's count by wrk's rate, the count repeats to within 0.1 instruction per
# request, so it tells apart builds 2 or 3 instructions apart in one run.
# h2load keeps 16 requests in flight rather than sending them 16 at a time, as
# wrk's pipeline.lua does, so reads bring fewer requests: what a read costs
# weighs more here than in bench/instructions.sh and bench/run.sh, and the
# totals are about 300 higher. Compare builds with it, not servers. Run as
# root, for perf.
#
#   bench/count.sh SERVER...   (RUNS 1, N 10000000, PORT 29281, TARGET /plaintext,
#                               STATUS 2)
#
# TARGET is the request's path, and STATUS the class every response must have,
# 4 for a 404 or 405: h2load counts a 4xx as failed, so the run checks its
# status-code line instead. Prints one line per run: user instructions and
# user cycles per request, and h2load's rate.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
bin=$root/build/bench
runs=${RUNS:-1}
n=${N:-10000000}
port=${PORT:-29281}
target=${TARGET:-/plaintext}
class=${STATUS:-2}
accept='Accept: text/plain,text/html;q=0.9,application/xhtml+xml;q=0.9,application/xml;q=0.8,*/*;q=0.7'
tmp=$(mktemp -d)
pid=
trap '[ -z "$pid" ] || kill "$pid" 2>/dev/null; rm -rf "$tmp"' EXIT

printf 'server\trun\tuser instructions/req\tuser cycles/req\treq/s\n'
for run in $(seq "$runs"); do
for server in "$@"; do
    case $server in
    goose*) WORKERS=1 taskset -c 0 "$bin/$server" http "$port" >/dev/null 2>&1 & ;;
    *) WORKERS=1 taskset -c 0 "$bin/$server" "$port" >/dev/null 2>&1 & ;;
    esac
    pid=$!
    until nc -z 127.0.0.1 "$port" 2>/dev/null; do sleep 0.1; done
    perf stat -x, -e instructions:u,cycles:u -p "$pid" -o "$tmp/perf" -- \
        taskset -c 4-15 h2load --h1 -n "$n" -c 256 -m 16 -t 8 -H "Connection: keep-alive" \
        -H "$accept" "http://127.0.0.1:$port$target" >"$tmp/h2load" 2>&1
    kill "$pid"
    wait "$pid" 2>/dev/null || true
    pid=
    ok=$(awk -v c="$class" '/^status codes:/ {print $(2 * c - 1)}' "$tmp/h2load")
    if [ "$ok" != "$n" ]; then
        echo "$server: $ok of $n responses were ${class}xx" >&2
        exit 1
    fi
    rps=$(awk '/^finished in/ {print $4}' "$tmp/h2load")
    awk -F, -v s="$server" -v r="$run" -v n="$n" -v rps="$rps" '
        $3 ~ /^instructions/ { i = $1 } $3 ~ /^cycles/ { c = $1 }
        END { printf "%s\t%s\t%.1f\t%.1f\t%.0f\n", s, r, i / n, c / n, rps }
    ' "$tmp/perf"
done
done
