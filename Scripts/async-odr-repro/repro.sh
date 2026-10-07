#!/usr/bin/env bash
#
# Minimal reproducer for the native-build release crash ("freed pointer was
# not the last allocation" in swift_task_dealloc). No SwiftPM and no packages:
# two Swift files, two deployment targets, one plain link.
# Write-up: docs/native-build-async-odr.md.
#
#   LibA.swift  -O -wmo, -target arm64-apple-macosx12.0  (a dependency)
#   main.swift  -O -wmo, -target arm64-apple-macosx26.0  (the app)
#
# Both objects define the weak specialization `Clock.sleep(for:tolerance:)`
# for ContinuousClock and its weak async function pointer (AFP). The copies
# differ: the macOS 12 body needs a 112-byte async context, the macOS 26 body
# 128. Linked main.o first, ld keeps main.o's body (first copy) but LibA.o's
# AFP (more aligned copy). Each call then gets a 112-byte context for a
# 128-byte body, and the runtime aborts.
#
# Usage: bash Scripts/async-odr-repro/repro.sh   (REPRO_KEEP=1 keeps the work dir)
# Exit status: 0 crash reproduced and the workaround build runs,
#              1 the crash did not reproduce (or the workaround failed),
#              2 build error.

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d -t async-odr-repro)"
[[ "${REPRO_KEEP:-0}" == 1 ]] || trap 'rm -rf "$out"' EXIT
sym='$ss5ClockPsE5sleep3for9tolerancey8DurationQz_AGSgtYaKFs010ContinuousA0V_Tg5'
arch="arm64"
[[ "$(uname -m)" == "x86_64" ]] && arch="x86_64"

echo "toolchain: $(xcrun swiftc --version 2>&1 | head -1)"
echo "work dir : $out"

xcrun swiftc -O -wmo -parse-as-library -target "$arch-apple-macosx12.0" \
    -module-name LibA -emit-module -emit-module-path "$out/LibA.swiftmodule" \
    -c "$here/LibA.swift" -o "$out/LibA.o" || exit 2
xcrun swiftc -O -wmo -parse-as-library -target "$arch-apple-macosx26.0" \
    -module-name Main -I "$out" -c "$here/main.swift" -o "$out/main.o" || exit 2

echo
echo "== weak copies and their async context sizes"
bash "$here/../check-async-odr.sh" "$out"

echo
echo "== link main.o first; which object each symbol came from"
xcrun swiftc -target "$arch-apple-macosx26.0" "$out/main.o" "$out/LibA.o" \
    -o "$out/repro" -Xlinker -map -Xlinker "$out/repro.map" || exit 2
grep -E "^\[ *[12]\] " "$out/repro.map"
grep -F "$sym" "$out/repro.map" | grep -v -e '<<dead>>' -e 'FDE for'

echo
echo "== run (expect: freed pointer was not the last allocation, SIGABRT)"
"$out/repro"
status=$?
echo "exit status $status"
reproduced=0
[[ $status -eq 134 ]] && reproduced=1

echo
echo "== workaround: main.swift with -D WORKAROUND (non-generic Task.sleep(for:) shim)"
xcrun swiftc -O -wmo -parse-as-library -target "$arch-apple-macosx26.0" -D WORKAROUND \
    -module-name Main -I "$out" -c "$here/main.swift" -o "$out/main-workaround.o" || exit 2
if nm "$out/main-workaround.o" | grep -qF "$sym"; then
    echo "workaround object still defines the specialization"
    exit 1
fi
echo "main-workaround.o defines no copy of the specialization"
xcrun swiftc -target "$arch-apple-macosx26.0" "$out/main-workaround.o" "$out/LibA.o" \
    -o "$out/repro-workaround" || exit 2
"$out/repro-workaround"
workaround=$?
echo "exit status $workaround"

if [[ $reproduced -eq 1 && $workaround -eq 0 ]]; then
    echo "RESULT: crash reproduced; the workaround build runs"
    exit 0
fi
echo "RESULT: crash reproduced=$reproduced, workaround exit=$workaround"
exit 1
