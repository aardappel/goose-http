#!/bin/bash
# Compares the code each revision generates, without running it: builds the
# benchmark server (build.sh's uring build) and bench/rest's server at each
# REV, keeps their generated C, and prints .text, each function family's size
# summed over its specializations, and the loops' hot functions' instruction
# counts, each against the first REV. Goose numbers specializations anew per
# build, so families group them by name, without the number. "work" is the
# working tree. Run in WSL; it builds under OUT, in Linux's file system.
#
#   bench/codegen.sh REV...   (OUT /root/goose-http-codegen, TOP 25)
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
out=${OUT:-$HOME/goose-http-codegen}
top=${TOP:-25}
. "$root/scripts/goose.sh"
goose=$GOOSE
mkdir -p "$out"

for rev in "$@"; do
    d=$out/$rev
    rm -rf "$d"
    mkdir -p "$d/src"
    if [ "$rev" = work ]; then
        (cd "$root" && git ls-files -co --exclude-standard | grep -v '^\.claude/' | tar -cf - -T -) |
            tar -xf - -C "$d/src"
    else
        git -C "$root" archive "$rev" | tar -xf - -C "$d/src"
    fi
    (cd "$d/src" && LOOP=uring scripts/build.sh >/dev/null)
    cp "$d/src/build/server" "$d/server"
    cp "$(ls -t ~/.goose/build/prog/*/server.c | head -1)" "$d/server.c"
    "$goose" build --cc gcc --standalone -o "$d/rest" "$d/src/bench/rest/goose/rest.goose" >/dev/null
    cp "$(ls -t ~/.goose/build/prog/*/rest.c | head -1)" "$d/rest.c"
done

# Function families: name without Goose's specialization number or gcc's clone
# suffix, total bytes, and copies.
families() {
    nm -S -C "$1" | awk '$3 ~ /[tT]/ {
        n = $4; sub(/\..*/, "", n); sub(/_g[0-9]*(_[0-9]+)?$/, "", n)
        s[n] += strtonum("0x" $2); c[n]++
    } END { for (k in s) printf "%s %d %d\n", k, s[k], c[k] }' | sort
}

for bin in server rest; do
    echo "== $bin: .text bytes"
    for rev in "$@"; do
        printf '%-10s %s\n' "$rev" "$(size -A "$out/$rev/$bin" | awk '$1 == ".text" { print $2 }')"
    done
    echo "-- families that changed most, bytes (copies)"
    first=$1
    families "$out/$first/$bin" >"$out/f.$first"
    for rev in "${@:2}"; do
        families "$out/$rev/$bin" >"$out/f.$rev"
        echo "   $first -> $rev"
        join -a1 -a2 -e0 -o 0,1.2,1.3,2.2,2.3 "$out/f.$first" "$out/f.$rev" |
            awk '{ d = $4 - $2; a = d < 0 ? -d : d; if (a > 0) print a, $0 }' | sort -k1,1nr | head -"$top" |
            awk '{ printf "   %-36s %8d (%2d) -> %8d (%2d)\n", $2, $3, $4, $5, $6 }'
    done
done

echo "== server: the loops' hot functions, instructions"
for rev in "$@"; do
    echo "   $rev"
    nm -C "$out/$rev/server" | awk '$2 ~ /[tT]/ && $3 ~ /^http_(answer|pump|advance|serve_epoll)_g/ { print $3 }' |
        sort | while read -r f; do
            k=$(objdump -d --no-show-raw-insn "$out/$rev/server" --disassemble="$f" | grep -cE '^\s+[0-9a-f]+:')
            printf '   %-44s %6d\n' "$f" "$k"
        done
done
