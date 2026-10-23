#!/bin/sh
# Builds fuzz.goose's targets as libFuzzer binaries with AddressSanitizer and
# UndefinedBehaviorSanitizer, into build/fuzz/: fuzz_request, fuzz_hpack,
# fuzz_h2frame, and fuzz_multipart. The Goose program's C (goose -o,
# --standalone, --header) and targets.c are compiled together by CC, a clang
# with libFuzzer: Apple's has none, so on macOS use Homebrew's llvm
# (CC=$(brew --prefix llvm)/bin/clang). The parsers call no shim function.
#
# Run one with a corpus directory of its own, seeded from fuzz/seeds/, such as
#   mkdir -p build/fuzz/corpus-request
#   build/fuzz/fuzz_request -max_total_time=600 build/fuzz/corpus-request fuzz/seeds/request
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
. "$root/scripts/goose.sh"
out=$root/build/fuzz
mkdir -p "$out"

"$GOOSE" -o "$out/fuzz.c" --standalone --header "$out/fuzz.h" "$here/fuzz.goose" |
    grep -v '^parsed\|^typechecked\|^bce\|^wrote' || :

flags="-g -O1 -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=undefined -I$out"
for target in fuzz_request fuzz_hpack fuzz_h2frame fuzz_multipart; do
    ${CC:-clang} $flags -DTARGET=$target -o "$out/$target" "$out/fuzz.c" "$here/targets.c" -lm -pthread
done
echo "built: $out/fuzz_request $out/fuzz_hpack $out/fuzz_h2frame $out/fuzz_multipart"
