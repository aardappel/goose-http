#!/bin/sh
# Measures static files: wrk downloads one file over and over, from each
# server in SERVERS, and the rate is the file's bytes, not the headers.
#
# Each cell (server, worker count, file size, run) gets a fresh server,
# pinned to SERVER_CPUS, with wrk pinned to CLIENT_CPUS: wrk for WARMUP
# seconds, discarded, then for DURATION seconds, with the server's CPU time
# over that run. The files are on tmpfs (/dev/shm), so no disk is measured.
#
# Settings, from the environment:
#   SERVERS       goose goose-uring goose-uring-epoll nginx caddy. A name
#                 starting with goose is a build of the Goose server in
#                 build/bench/, which serves FILES at /files/; one ending in
#                 -uring-epoll runs the -uring build with LOOP=uring-epoll.
#                 nginx is the system's, caddy bench/build.sh's.
#   WORKER_COUNTS 1 and the number of SERVER_CPUS ("1 4"). nginx runs that
#                 many worker processes, Caddy that many GOMAXPROCS.
#   SIZES         4096 65536 1048576, the files in bytes. bytes:N asks the
#                 Goose server's /bytes?n=N instead, N bytes from memory, to
#                 compare a response built in memory with a file; other
#                 servers skip it.
#   CONNS         64
#   SERVER_CPUS   0-3, CLIENT_CPUS 4-15, CLIENT_THREADS 8
#   RUNS 3, DURATION 10, WARMUP 3, PORT 29380, MACHINE as bench/run.sh's
#   OUT           bench/results/<date>-<machine>-files
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/scripts/goose.sh"
bin=$root/build/bench
servers=${SERVERS:-goose goose-uring goose-uring-epoll nginx caddy}
server_cpus=${SERVER_CPUS:-0-3}
client_cpus=${CLIENT_CPUS:-4-15}
threads=${CLIENT_THREADS:-8}
worker_counts=${WORKER_COUNTS:-1 $(taskset -c "$server_cpus" nproc)}
sizes=${SIZES:-4096 65536 1048576}
conns=${CONNS:-64}
runs=${RUNS:-3}
duration=${DURATION:-10}
warmup=${WARMUP:-3}
port=${PORT:-29380}
machine=${MACHINE:-$(hostname -s)}
out=${OUT:-$root/bench/results/$(date -u +%Y-%m-%dT%H%M)-$machine-files}
hz=$(getconf CLK_TCK)

ulimit -n 65536
mkdir -p "$out"
tmp=$(mktemp -d)
www=/dev/shm/goose-http-files.$$
mkdir -p "$www/files"
pid=
trap '[ -z "$pid" ] || kill "$pid" 2>/dev/null; rm -rf "$tmp" "$www"' EXIT
for size in $sizes; do
    case $size in bytes:*) ;; *) head -c "$size" /dev/urandom >"$www/files/f$size" ;; esac
done

{
    echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "machine: $machine"
    echo "kernel: $(uname -r)"
    echo "os: $(. /etc/os-release && echo "$PRETTY_NAME")"
    echo "cpu: $(lscpu | sed -n 's/^Model name: *//p'), $(nproc) logical CPUs"
    echo "memory: $(free -g | awk '/^Mem:/ {print $2}') GB"
    echo "server cpus: $server_cpus, client cpus: $client_cpus, client threads: $threads"
    echo "duration: $duration s, warm-up: $warmup s, runs: $runs, connections: $conns"
    echo "goose-http: $(git -C "$root" rev-parse --short HEAD)$(git -C "$root" diff --quiet || echo ' (modified)')"
    echo "goose: $(goose_version)"
    echo "nginx: $(nginx -v 2>&1)"
    [ ! -x "$bin/caddy" ] || echo "caddy: $("$bin/caddy" version)"
    echo "wrk: $(wrk -v 2>&1 | head -1)"
} >"$out/env.txt"
printf 'server\tworkers\tsize\tconns\trun\trps\tgbps\terrors\tnon2xx\tserver_cpu_s\twrk_cpu_s\n' \
    >"$out/runs.tsv"

# utime + stime, in clock ticks, of process $1 and its children: nginx's
# workers are children of its master.
cpu_ticks() {
    for p in $1 $(cat "/proc/$1/task/$1/children" 2>/dev/null); do
        awk '{print $14 + $15}' "/proc/$p/stat" 2>/dev/null || true
    done | awk '{n += $1} END {print n + 0}'
}

# Starts server $1 with $2 workers on CPUs $3, in the background.
start() {
    case $1 in
    goose*-uring-epoll)
        FILES=$www/files LOOP=uring-epoll WORKERS=$2 taskset -c "$3" "$bin/${1%-epoll}" http "$port" &
        ;;
    goose*) FILES=$www/files WORKERS=$2 taskset -c "$3" "$bin/$1" http "$port" & ;;
    nginx)
        # The settings TechEmpower's nginx entry and nginx's docs give for
        # static files: sendfile with tcp_nopush, the file descriptor cache,
        # no access log, and keep-alive without nginx's default cap of 1,000
        # requests a connection.
        mkdir -p "$tmp/nginx/logs"
        cat >"$tmp/nginx/nginx.conf" <<EOF
daemon off;
worker_processes $2;
pid $tmp/nginx/nginx.pid;
error_log stderr warn;
events { worker_connections 65536; multi_accept off; }
http {
    access_log off;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_requests 10000000;
    keepalive_timeout 65;
    open_file_cache max=1000 inactive=60s;
    open_file_cache_valid 60s;
    default_type application/octet-stream;
    server {
        listen 127.0.0.1:$port reuseport backlog=4096;
        root $www;
    }
}
EOF
        taskset -c "$3" nginx -p "$tmp/nginx" -c "$tmp/nginx/nginx.conf" -e stderr &
        ;;
    caddy)
        cat >"$tmp/Caddyfile" <<EOF
{
    admin off
    auto_https off
    persist_config off
}
http://127.0.0.1:$port {
    root * $www
    file_server
}
EOF
        GOMAXPROCS=$2 taskset -c "$3" "$bin/caddy" run --config "$tmp/Caddyfile" --adapter caddyfile &
        ;;
    *) echo "bench/files.sh: unknown server $1"; exit 1 ;;
    esac
    pid=$!
}

for run in $(seq "$runs"); do
for workers in $worker_counts; do
    if [ "$workers" = 1 ]; then cpus=${server_cpus%%[-,]*}; else cpus=$server_cpus; fi
    for server in $servers; do
    for size in $sizes; do
        case $size in
        bytes:*)
            case $server in goose*) ;; *) continue ;; esac
            n=${size#bytes:}
            path="/bytes?n=$n"
            name=$server-w$workers-b$n-r$run
            ;;
        *)
            n=$size
            path=/files/f$size
            name=$server-w$workers-s$size-r$run
            ;;
        esac
        echo "$name"
        if nc -z 127.0.0.1 "$port" 2>/dev/null; then
            echo "bench/files.sh: port $port is taken; set PORT"
            exit 1
        fi
        start "$server" "$workers" "$cpus" >"$out/$name.log" 2>&1
        tries=0
        until nc -z 127.0.0.1 "$port" 2>/dev/null; do
            tries=$((tries + 1))
            [ $tries -lt 100 ] || { echo "bench/files.sh: $server isn't listening"; exit 1; }
            sleep 0.1
        done
        url=http://127.0.0.1:$port$path
        [ "$(curl -s -o /dev/null -w '%{size_download}' "$url")" = "$n" ] ||
            { echo "bench/files.sh: $server doesn't serve $url whole"; exit 1; }

        wrk="taskset -c $client_cpus wrk -t $threads -c $conns --timeout 8"
        LD_PRELOAD=$bin/wrk-monotonic.so $wrk -d "$warmup" "$url" >/dev/null
        c0=$(cpu_ticks $pid)
        (
            LD_PRELOAD=$bin/wrk-monotonic.so $wrk -d "$duration" "$url" >"$out/$name.wrk"
            times >"$out/$name.times"
        )
        c1=$(cpu_ticks $pid)
        kill $pid
        wait $pid 2>/dev/null || true
        pid=
        # nginx's workers outlive a killed master for a moment.
        tries=0
        while nc -z 127.0.0.1 "$port" 2>/dev/null && [ $tries -lt 50 ]; do
            tries=$((tries + 1))
            sleep 0.1
        done

        w=$out/$name.wrk
        rps=$(awk '/^Requests\/sec/ {print $2}' "$w")
        errors=$(awk '/Socket errors/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+,?$/) n += $i; print n }' "$w")
        non2xx=$(awk '/Non-2xx/ {print $NF}' "$w")
        wrk_cpu=$(awk 'NR == 2 {
            split($1, u, /[ms]/); split($2, s, /[ms]/); printf "%.2f", u[1] * 60 + u[2] + s[1] * 60 + s[2]
        }' "$out/$name.times")
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$server" "$workers" "$size" "$conns" "$run" "$rps" \
            "$(echo "$rps $n" | awk '{printf "%.3f", $1 * $2 / 1e9}')" "${errors:-0}" \
            "${non2xx:-0}" "$(echo "$c0 $c1 $hz" | awk '{printf "%.2f", ($2 - $1) / $3}')" \
            "$wrk_cpu" >>"$out/runs.tsv"
    done
    done
done
done
echo "results: $out"
python3 - "$out/runs.tsv" "$duration" <<'EOF' | tee "$out/summary.md"
import csv, statistics, sys
from collections import defaultdict
dur = float(sys.argv[2])
cells = defaultdict(list)
order = []
for r in csv.DictReader(open(sys.argv[1]), delimiter="\t"):
    k = (r["size"], int(r["workers"]), r["server"])
    if k not in cells:
        order.append(k)
    cells[k].append(r)
print("| Size | Workers | Server | GB/s, median (spread) | req/s | server CPU µs/req | wrk CPU s | errors |")
print("|---:|---:|---|---|---:|---:|---:|---:|")
for k in sorted(order, key=lambda k: (int(k[0].split(":")[-1]), k[0], k[1], order.index(k))):
    rs = cells[k]
    g = sorted(float(r["gbps"]) for r in rs)
    rps = statistics.median(float(r["rps"]) for r in rs)
    cpu = statistics.median(float(r["server_cpu_s"]) * 1e6 / max(float(r["rps"]) * dur, 1)
                            for r in rs)
    wrk = statistics.median(float(r["wrk_cpu_s"]) for r in rs)
    err = sum(int(r["errors"] or 0) + int(r["non2xx"] or 0) for r in rs)
    print(f"| {k[0]} | {k[1]} | {k[2]} | {statistics.median(g):.2f} ({g[0]:.2f}-{g[-1]:.2f}) "
          f"| {rps:,.0f} | {cpu:.2f} | {wrk:.1f} | {err} |")
EOF
