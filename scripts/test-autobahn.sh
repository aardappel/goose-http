#!/bin/sh
# Runs the Autobahn test suite's fuzzing client, WebSocket's conformance
# tests, in Docker against build/server's /ws echo (scripts/build.sh) on PORT
# (29080). Every case runs but those of sections 12 and 13, which test
# permessage-deflate, an extension the package doesn't negotiate. Fails when a
# case's behavior is other than OK, NON-STRICT, or INFORMATIONAL, or its close
# other than OK or INFORMATIONAL, or a case doesn't run; the report is in
# build/autobahn/reports/. The server takes messages of up to 16 MiB
# (WS_LIMIT), the longest section 9 sends.
#
# The image is pinned by digest. It is built for x86-64 only, so on an arm64
# host it runs under emulation (Rosetta 2 in Docker Desktop on Apple
# Silicon). On Linux the container shares the host's network; under Docker
# Desktop it reaches the server at host.docker.internal. CASES picks other
# cases, as a JSON list ("[\"1.*\", \"5.*\"]").
#
# The fuzzing client stops at the first connection it can't open. Under Docker
# Desktop on macOS, about one full run in four loses a connection to
# host.docker.internal in section 9 while the server answers the host at once
# (docs/known-issues.md), so the cases a run didn't reach run again, up to
# three runs in all.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
port=${PORT:-29080}
image=crossbario/autobahn-testsuite@sha256:519915fb568b04c9383f70a1c405ae3ff44ab9e35835b085239c258b6fac3074
cases=${CASES:-'["*"]'}
dir=$root/build/autobahn
case $(uname -s) in
Linux) host=127.0.0.1 network="--network host" ;;
*) host=host.docker.internal network= ;;
esac
mkdir -p "$dir/reports"
rm -f "$dir/results.json" "$dir/expected.json"

log=$(mktemp)
pid=
trap 'if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi; rm -f "$log"' EXIT
WORKERS=${WORKERS:-2} H2C_PORT=0 WS_LIMIT=16777216 "$root/build/server" http "$port" >"$log" 2>&1 &
pid=$!
tries=0
until grep -q "on port $port" "$log"; do
    tries=$((tries + 1))
    if [ $tries -ge 50 ] || ! kill -0 "$pid" 2>/dev/null; then
        echo "the server didn't start:" >&2
        cat "$log" >&2
        exit 1
    fi
    sleep 0.1
done

# Merges a run's results into results.json, and prints the cases still to
# run, as a JSON list, or nothing once every case has run. The first run's log
# lists the cases expected.
merge() {
    python3 -I - "$dir" <<'EOF'
import ast, json, os, sys

d = sys.argv[1]
results = json.load(open(f"{d}/results.json")) if os.path.exists(f"{d}/results.json") else {}
run = json.load(open(f"{d}/index.json")).get("goose-http", {}) if os.path.getsize(f"{d}/index.json") else {}
results.update(run)
json.dump(results, open(f"{d}/results.json", "w"))
if not os.path.exists(f"{d}/expected.json"):
    for line in open(f"{d}/wstest.log"):
        if line.startswith("Cases = "):
            json.dump(ast.literal_eval(line[len("Cases = "):]), open(f"{d}/expected.json", "w"))
missing = [c for c in json.load(open(f"{d}/expected.json")) if c not in results]
if missing:
    print(json.dumps(missing))
EOF
}

attempt=1
while :; do
    # The configuration goes in on stdin, and the results come back on stdout:
    # Docker Desktop's file sharing can show the host a stale copy of a file
    # the container just wrote, and the container a stale copy of the host's.
    # The mounted reports are for reading.
    config="{
      \"outdir\": \"/autobahn/reports\",
      \"servers\": [{ \"agent\": \"goose-http\", \"url\": \"ws://$host:$port/ws\" }],
      \"cases\": $cases,
      \"exclude-cases\": [\"12.*\", \"13.*\"],
      \"exclude-agent-cases\": {}
    }"
    # shellcheck disable=SC2086 # network is empty or two words
    echo "$config" | docker run --rm -i $network -v "$dir/reports:/autobahn/reports" "$image" sh -c '
        cat >/tmp/fuzzingclient.json &&
        wstest -m fuzzingclient -s /tmp/fuzzingclient.json >&2 &&
        cat /autobahn/reports/index.json' >"$dir/index.json" 2>"$dir/wstest.log" ||
        { cat "$dir/wstest.log" >&2; exit 1; }
    kill -0 "$pid" || { echo "the server died:" >&2; cat "$log" >&2; exit 1; }
    missing=$(merge)
    [ -n "$missing" ] || break
    grep "failed" "$dir/wstest.log" | sed "s/^/autobahn, run $attempt: /" >&2 || true
    if [ $attempt -ge 3 ]; then
        echo "autobahn: these cases didn't run: $missing" >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    cases=$missing
done

python3 -I - "$dir/results.json" <<'EOF'
import collections, json, sys

results = json.load(open(sys.argv[1]))
counts = collections.Counter()
failed = []
for case, r in sorted(results.items(), key=lambda kv: [int(p) for p in kv[0].split(".")]):
    counts[r["behavior"]] += 1
    if r["behavior"] not in ("OK", "NON-STRICT", "INFORMATIONAL") or \
       r["behaviorClose"] not in ("OK", "INFORMATIONAL"):
        failed.append(f"{case}: {r['behavior']}, close {r['behaviorClose']}")
print(f"autobahn: {len(results)} cases, " + ", ".join(f"{n} {b}" for b, n in sorted(counts.items())))
for f in failed:
    print("  " + f)
sys.exit(1 if failed else 0)
EOF
