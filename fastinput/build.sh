#!/bin/bash
# Builds fastinput-helper into <output dir> (default: ./build next to this script).
#
#   fastinput/build.sh [<output-dir>]
#
# Same flags as the reviewed upstream Makefile's helper targets. Needs the selected
# Xcode (honours DEVELOPER_DIR). It never runs the helper.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/build}"
mkdir -p "$out"
dev="$(xcode-select -p)"
sdkpf="$dev/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/PrivateFrameworks"
src="$here/Sources"

clang -fno-objc-arc -fblocks -F/Library/Developer/PrivateFrameworks -F"$sdkpf" \
    -c "$src/fastinput_main.m" -o "$out/fastinput_main.o"
for s in mercury_abi universalhid_abi uhid_request_abi; do
    clang -c "$src/$s.S" -o "$out/$s.o"
done
for s in mercury_glue universalhid_glue; do
    swiftc -parse-as-library -c "$src/$s.swift" -o "$out/$s.o"
done
swiftc "$out"/fastinput_main.o "$out"/mercury_glue.o "$out"/mercury_abi.o \
    "$out"/universalhid_glue.o "$out"/universalhid_abi.o "$out"/uhid_request_abi.o \
    -o "$out/fastinput-helper" \
    -F/Library/Developer/PrivateFrameworks \
    -F/Library/Developer/PrivateFrameworks/CoreDevice.framework/Frameworks \
    -F/Library/Apple/System/Library/PrivateFrameworks \
    -F"$sdkpf" \
    -framework Foundation -framework CoreFoundation \
    -framework CoreDevice -framework CoreDeviceUtilities \
    -framework RemoteXPC -framework Mercury -framework UniversalHID
rm -f "${out:?}"/*.o
