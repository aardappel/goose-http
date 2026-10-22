#!/bin/sh
# Measures Goose server builds with oha, on Windows in Git Bash or on Linux,
# for comparing the IOCP loop with io_uring on one machine (task 017). oha
# runs on both, where wrk and h2load don't run on Windows. Not pipelined:
# oha can't pipeline.
#
# Each cell (server, worker count, path, run) gets a fresh server. oha sends
# REQUESTS requests over CONNS connections; the rate is oha's, and the
# server's user and kernel CPU time over the oha run, divided by REQUESTS,
# is the CPU per request. Nothing is pinned to CPUs unless PIN is set.
#
# Settings, from the environment:
#   SERVERS       name=path pairs: "iocp=build/server.exe". A name may say
#                 LOOP after a colon: "ring-epoll:uring-epoll=build/server"
#   WORKER_COUNTS 1 4
#   PATHS         /plaintext. A path under /files/ names a file of SIZES
#                 bytes this script writes: /files/f65536
#   SIZES         65536 1048576, the files written for /files/
#   REQUESTS      2000000, CONNS 256, RUNS 3, PORT 29380
#   PAUSE         15 s between cells on Windows, 0 elsewhere: Windows keeps
#                 closed connections in TIME_WAIT, and oha opens new ones
#   PIN           server and oha CPUs as "0-3 8-15", Linux only (taskset)
#   OHA           oha's path (oha)
#   MACHINE, OUT  as bench/run.sh's, OUT defaulting to
#                 bench/results/<date>-<machine>-oha
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/scripts/goose.sh"
case $(uname -s) in MINGW* | MSYS* | CYGWIN*) windows=1 ;; *) windows= ;; esac
servers=${SERVERS:?name=path pairs}
worker_counts=${WORKER_COUNTS:-1 4}
paths=${PATHS:-/plaintext}
sizes=${SIZES:-65536 1048576}
requests=${REQUESTS:-2000000}
conns=${CONNS:-256}
runs=${RUNS:-3}
port=${PORT:-29380}
if [ -n "$windows" ]; then pause=${PAUSE:-15}; else pause=${PAUSE:-0}; fi
oha=${OHA:-oha}
machine=${MACHINE:-$(hostname)}
out=${OUT:-$root/bench/results/$(date -u +%Y-%m-%dT%H%M)-$machine-oha}

mkdir -p "$out"
files=$(mktemp -d)
for size in $sizes; do
    head -c "$size" /dev/urandom >"$files/f$size"
done
if [ -n "$windows" ]; then FILES=$(cygpath -m "$files"); else FILES=$files; fi
export FILES
pid=
stop() {
    [ -n "$pid" ] || return 0
    if [ -n "$windows" ]; then
        taskkill //F //PID "$(cat "/proc/$pid/winpid")" >/dev/null 2>&1 || true
    else
        kill "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
    pid=
}
trap 'stop; rm -rf "$files"' EXIT

# The server's user and kernel CPU seconds.
cpu() {
    if [ -n "$windows" ]; then
        # The invariant culture, for a decimal point whatever the locale.
        powershell.exe -NoProfile -Command "\$p = Get-Process -Id $(cat "/proc/$pid/winpid"); \
            [string]::Format([cultureinfo]::InvariantCulture, '{0} {1}', \
            \$p.UserProcessorTime.TotalSeconds, \$p.PrivilegedProcessorTime.TotalSeconds)" |
            tr -d '\r'
    else
        awk -v hz="$(getconf CLK_TCK)" '{print $14 / hz, $15 / hz}' "/proc/$pid/stat"
    fi
}

{
    echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "machine: $machine"
    echo "os: $(uname -srv)"
    echo "requests: $requests, connections: $conns, runs: $runs, pin: ${PIN:-none}"
    echo "goose-http: $(git -C "$root" rev-parse --short HEAD)$(git -C "$root" diff --quiet || echo ' (modified)')"
    echo "goose: $(goose_version)"
    echo "oha: $("$oha" --version)"
    echo "servers: $servers"
} >"$out/env.txt"
printf 'server\tworkers\tpath\trun\trps\tok\tother\tuser_s\tkernel_s\tuser_us\tkernel_us\n' \
    >"$out/runs.tsv"

for run in $(seq "$runs"); do
for workers in $worker_counts; do
    for s in $servers; do
    for path in $paths; do
        name=${s%%=*}
        exe=${s#*=}
        loop=
        case $name in *:*) loop=${name#*:} name=${name%%:*} ;; esac
        cell=$name-w$workers-$(echo "$path" | tr -c 'a-zA-Z0-9\n' '_')-r$run
        echo "$cell"
        if [ -n "${PIN:-}" ]; then
            set -- taskset -c "${PIN%% *}" "$exe"
            client="taskset -c ${PIN#* } $oha"
        else
            set -- "$exe"
            client=$oha
        fi
        if [ -n "$loop" ]; then
            LOOP=$loop WORKERS=$workers "$@" http "$port" >"$out/$cell.log" 2>&1 &
        else
            WORKERS=$workers "$@" http "$port" >"$out/$cell.log" 2>&1 &
        fi
        pid=$!
        tries=0
        until curl -s -o /dev/null "http://127.0.0.1:$port/plaintext"; do
            tries=$((tries + 1))
            [ $tries -lt 100 ] || { echo "bench/oha.sh: $name isn't listening"; exit 1; }
            sleep 0.1
        done
        set -- $(cpu)
        u0=$1 k0=$2
        $client -n "$requests" -c "$conns" --no-tui --output-format json \
            "http://127.0.0.1:$port$path" >"$out/$cell.json"
        set -- $(cpu)
        u1=$1 k1=$2
        stop
        json=$out/$cell.json
        # Windows' python3 reads Windows paths, not Git Bash's.
        [ -z "$windows" ] || json=$(cygpath -m "$json")
        # MSYS would rewrite the path argument, /plaintext, as a Windows path.
        MSYS2_ARG_CONV_EXCL='*' python3 - "$json" "$name" "$workers" "$path" "$run" "$u0" "$u1" "$k0" "$k1" \
            "$requests" >>"$out/runs.tsv" <<'EOF'
import json, sys
f, name, workers, path, run, u0, u1, k0, k1, n = sys.argv[1:]
j = json.load(open(f, encoding="utf-8"))
codes = j.get("statusCodeDistribution", {})
ok = codes.get("200", 0) + codes.get("206", 0)
other = sum(codes.values()) - ok + sum(j.get("errorDistribution", {}).values())
u, k, n = float(u1) - float(u0), float(k1) - float(k0), int(n)
print(f"{name}\t{workers}\t{path}\t{run}\t{j['summary']['requestsPerSec']:.0f}\t{ok}\t{other}"
      f"\t{u:.2f}\t{k:.2f}\t{u * 1e6 / n:.2f}\t{k * 1e6 / n:.2f}")
EOF
        tail -1 "$out/runs.tsv"
        [ "$pause" = 0 ] || sleep "$pause"
    done
    done
done
done
echo "results: $out"
