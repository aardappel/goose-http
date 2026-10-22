#!/bin/sh
# Runs h2spec, HTTP/2's conformance tests, against the h2c listener of
# build/server, run with LOOP (epoll by default), which serves h2c on PORT +
# 2 (29082), and, for the TLS build where openssl makes it a certificate,
# against its h2 over TLS on PORT + 363 (29443), with ALPN h2 (h2spec -t -k).
# Fetches h2spec's release binary into build/ first, checked
# against the SHA-256 sums below: h2spec v2.6.0 has binaries for Linux and
# macOS on x86-64 only, so on Apple Silicon it runs under Rosetta 2, and
# Linux on arm64 has none (run it there in an x86-64 container). Fails if any
# test fails; H2SPEC_ARGS passes more arguments, as -j for a JUnit report.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
port=${PORT:-29080}
h2c=$((port + 2))
version=v2.6.0
case $(uname -s) in
Darwin)
    asset=darwin_amd64
    sum=981cb9f90a6f5e36300063022bd4eb7438d3dcf66d63a146a8541359697d1601 ;;
Linux)
    asset=linux_amd64
    sum=157ee0de702e01ad40e752dbf074b366027e550c8e7504f9450da2809e279318 ;;
*)
    echo "test-h2spec.sh: no h2spec release for $(uname -s)" >&2
    exit 2 ;;
esac
dir=$root/build/h2spec-$version-$asset
h2spec=$dir/h2spec
if [ ! -x "$h2spec" ]; then
    tmp=$root/build/.h2spec-download
    rm -rf "$tmp" && mkdir -p "$tmp"
    file=h2spec_$asset.tar.gz
    echo "downloading h2spec $version ($asset) into $dir" >&2
    curl -fsSL -o "$tmp/$file" "https://github.com/summerwind/h2spec/releases/download/$version/$file"
    if command -v sha256sum >/dev/null; then got=$(sha256sum "$tmp/$file"); else got=$(shasum -a 256 "$tmp/$file"); fi
    if [ "${got%% *}" != "$sum" ]; then
        echo "$file: SHA-256 ${got%% *}, expected $sum" >&2
        exit 1
    fi
    tar -xzf "$tmp/$file" -C "$tmp"
    mkdir -p "$dir"
    mv "$tmp/h2spec" "$h2spec"
    rm -rf "$tmp"
fi

log=$(mktemp)
certs=$(mktemp -d)
pid=
trap 'if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi; rm -rf "$log" "$certs"' EXIT
# A self-signed pair, as scripts/test-http.sh makes, which only the TLS build
# reads.
if command -v openssl >/dev/null; then
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$certs/server.key" -out "$certs/server.crt" \
        -days 2 -subj /CN=localhost 2>/dev/null
    export TLS_CERT="$certs/server.crt" TLS_KEY="$certs/server.key"
fi
LOOP=${LOOP:-epoll} WORKERS=${WORKERS:-2} H2C_PORT=$h2c H2_PORT=$((port + 363)) "$root/build/server" http "$port" >"$log" 2>&1 &
pid=$!
tries=0
until grep -q "h2c on port $h2c" "$log"; do
    tries=$((tries + 1))
    if [ $tries -ge 50 ] || ! kill -0 "$pid" 2>/dev/null; then
        echo "the server didn't start:" >&2
        cat "$log" >&2
        exit 1
    fi
    sleep 0.1
done
sleep 0.2
# shellcheck disable=SC2086 # H2SPEC_ARGS is a list of arguments
# /plaintext, since h2spec's tests of flow control expect a response with a
# body.
"$h2spec" -h 127.0.0.1 -p "$h2c" -P /plaintext -o 2 ${H2SPEC_ARGS:-}
h2=$(sed -n 's/.*, h2 over TLS on port \([0-9]*\).*/\1/p' "$log" | head -n 1)
if [ -n "$h2" ]; then
    echo "h2 over TLS, on port $h2:"
    # h2spec v2.6.0 is built with Go 1.12, whose TLS 1.3 is opt-in, and the
    # server speaks only TLS 1.3.
    # shellcheck disable=SC2086
    GODEBUG=tls13=1 "$h2spec" -t -k -h 127.0.0.1 -p "$h2" -P /plaintext -o 2 ${H2SPEC_ARGS:-}
fi
kill -0 "$pid" || { echo "the server died:" >&2; cat "$log" >&2; exit 1; }
