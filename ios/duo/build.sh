#!/bin/bash
# Builds Daybreak, the iPhone Duo showcase app, for the simulator (no Xcode
# project, no signing: the linker's ad-hoc signature is enough for a
# simulator) and optionally installs and launches it on one simulator.
#
#   ios/duo/build.sh [--out <dir>]
#   ios/duo/build.sh --install <UDID> [--set <device set dir>] [--launch] [--no-build] [-- <app arguments>]
#
# The app uses the iOS 27.1 foldable APIs (onHingeChange, the reserved
# division region, the vertical bar), so it needs the iPhoneSimulator 27.1
# SDK or later and runs on iOS 27.1 or later. The developer directory is
# $DEVELOPER_DIR, else `xcode-select -p`; an older SDK is refused (set
# DEVELOPER_DIR to an Xcode 27.1's Contents/Developer). The sources are App/
# (SwiftUI) and Shared/ (Foundation only, also tested on the Mac as
# DaybreakTests). actool compiles Assets.xcassets for the icon; when it is
# missing or fails, the app is built without one.
#
# The simulator is named by its UDID, never `booted` or `all`, and must be
# listed by simctl in the given device set (the default set without --set),
# so nothing here can reach a physical device. No xcrun (its wrappers can
# run `xcodebuild -runFirstLaunch`): swiftc, actool and the iPhoneSimulator
# SDK come from the developer directory, and simctl is the real binary
# (DHP_SIMCTL overrides it). Arguments after `--` are passed to the app on
# --launch (for example `-- --log-readings`). The app lands in
# <out>/Daybreak.app (default: .build/ios-duo in the repository). After an
# install it prints where readings.jsonl is.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
bundle_id="com.devicehubpro.duo"
minimum_sdk="27.1"
out="$root/.build/ios-duo"
udid=""
device_set=""
launch=0
build=1
app_args=()

# The SDK the app is built with, which the linker must record in
# LC_BUILD_VERSION: left to itself it records the deployment target, and
# iOS then treats the app as built with that SDK (on iPhone Duo, iOS 27.1
# showed such an app in a 375 × 667 compatibility window).
sdk_version() {
    plutil -extract Version raw "$1/SDKSettings.plist"
}

simulator_sdk() {
    echo "$1/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"
}

# at_least <version> <minimum>: dotted versions, compared field by field.
at_least() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        split(a, x, "."); split(b, y, ".")
        for (i = 1; i <= 3; i++) {
            if (x[i] + 0 > y[i] + 0) exit 0
            if (x[i] + 0 < y[i] + 0) exit 1
        }
        exit 0
    }'
}

usage() {
    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# compile_assets <developer dir> <app>: compiles Assets.xcassets into the
# app (Assets.car, plus the loose PNGs CFBundleIconFiles names) and merges
# the CFBundleIcons keys actool writes into its Info.plist. Everything goes
# to a scratch folder first, so a failure leaves the app as it was; keys
# the app's own Info.plist already has win over actool's.
compile_assets() {
    local actool="$1/usr/bin/actool" app="$2" scratch status=0
    if [ ! -x "$actool" ]; then
        echo "build.sh: warning: no actool at $actool; building without the icon" >&2
        return 1
    fi
    scratch="$(mktemp -d)"
    mkdir "$scratch/compiled"
    cp "$app/Info.plist" "$scratch/Info.plist"
    if DEVELOPER_DIR="$1" "$actool" \
            --output-format human-readable-text --errors --warnings \
            --platform iphonesimulator \
            --minimum-deployment-target "$minimum_sdk" \
            --target-device iphone \
            --app-icon AppIcon \
            --output-partial-info-plist "$scratch/partial.plist" \
            --compile "$scratch/compiled" \
            "$here/Assets.xcassets" >"$scratch/actool.log" 2>&1 \
        && [ -f "$scratch/compiled/Assets.car" ] \
        && [ "$(plutil -extract CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName raw -o - "$scratch/partial.plist" 2>/dev/null)" = "AppIcon" ] \
        && /usr/libexec/PlistBuddy -c "Merge \"$scratch/partial.plist\"" "$scratch/Info.plist" >/dev/null; then
        cp -R "$scratch/compiled/." "$app/"
        cp "$scratch/Info.plist" "$app/Info.plist"
        # actool exits 0 on warnings (an icon with alpha, a wrong size).
        grep -E ': (warning|error):' "$scratch/actool.log" >&2 || true
    else
        echo "build.sh: warning: actool could not compile Assets.xcassets; building without the icon" >&2
        sed 's/^/    /' "$scratch/actool.log" >&2
        status=1
    fi
    rm -rf "$scratch"
    return "$status"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --out) out="${2:?--out needs a directory}"; shift 2 ;;
        --install) udid="${2:?--install needs a simulator UDID}"; shift 2 ;;
        --set) device_set="${2:?--set needs a device set directory}"; shift 2 ;;
        --launch) launch=1; shift ;;
        --no-build) build=0; shift ;;
        --) shift; app_args=("$@"); break ;;
        -h|--help) usage 0 ;;
        *) echo "build.sh: unknown argument $1" >&2; usage 2 ;;
    esac
done

if [ "$launch" -eq 1 ] && [ -z "$udid" ]; then
    echo "build.sh: --launch needs --install <UDID>" >&2
    exit 2
fi
if [ "${#app_args[@]}" -gt 0 ] && [ "$launch" -eq 0 ]; then
    echo "build.sh: app arguments after -- are passed on --launch only" >&2
    exit 2
fi

app="$out/Daybreak.app"

if [ "$build" -eq 1 ]; then
    developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
    swiftc="$developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    sdk="$(simulator_sdk "$developer")"
    if [ ! -x "$swiftc" ] || [ ! -f "$sdk/SDKSettings.plist" ]; then
        echo "build.sh: no swiftc or iPhoneSimulator SDK under $developer (install Xcode 27.1, or set DEVELOPER_DIR=/Applications/<Xcode 27.1>.app/Contents/Developer)" >&2
        exit 1
    fi
    version="$(sdk_version "$sdk")"
    if ! at_least "$version" "$minimum_sdk"; then
        echo "build.sh: the iPhoneSimulator SDK under $developer is $version; Daybreak needs $minimum_sdk or later (set DEVELOPER_DIR=/Applications/<Xcode 27.1>.app/Contents/Developer)" >&2
        exit 1
    fi

    rm -rf "$app"
    mkdir -p "$app"
    started=$(date +%s)
    # -parse-as-library: the app's entry point is @main, not main.swift.
    "$swiftc" \
        -sdk "$sdk" \
        -parse-as-library \
        -target "arm64-apple-ios$minimum_sdk-simulator" \
        -Xlinker -platform_version -Xlinker ios-simulator -Xlinker "$minimum_sdk" -Xlinker "$version" \
        -swift-version 6 \
        -O \
        -module-name Daybreak \
        "$here"/App/*.swift "$here"/Shared/*.swift \
        -o "$app/Daybreak"
    cp "$here/Info.plist" "$app/Info.plist"
    icon="the icon"
    compile_assets "$developer" "$app" || icon="no icon"
    plutil -lint -s "$app/Info.plist"
    # The arm64 linker signs ad hoc; simctl install accepts that as is.
    signature="$(codesign -dv "$app/Daybreak" 2>&1 || true)"
    if ! grep -q "linker-signed" <<<"$signature"; then
        echo "build.sh: the binary carries no linker signature; simctl install may refuse it" >&2
    fi
    echo "Built $app ($icon) with the iPhoneSimulator $version SDK in $(( $(date +%s) - started )) s"
elif [ ! -x "$app/Daybreak" ]; then
    echo "build.sh: --no-build, but $app is missing" >&2
    exit 1
fi

[ -n "$udid" ] || exit 0

if ! [[ "$udid" =~ ^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$ ]]; then
    echo "build.sh: '$udid' is not a simulator UDID (booted, all and names are refused)" >&2
    exit 2
fi

simctl="${DHP_SIMCTL:-/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl}"
if [ ! -x "$simctl" ]; then
    echo "build.sh: no simctl at $simctl (install Xcode and open it once, or set DHP_SIMCTL)" >&2
    exit 1
fi
# macOS's bash 3.2 treats an empty array as unset under -u, hence the
# ${set_args[@]+…} form below.
set_args=()
if [ -n "$device_set" ]; then
    set_args=(--set "$device_set")
fi

# Read whole first: grep -q stopping early would fail the pipe under pipefail.
listing="$("$simctl" ${set_args[@]+"${set_args[@]}"} list devices -j)"
if ! grep -q "\"udid\" : \"$udid\"" <<<"$listing"; then
    echo "build.sh: simctl lists no simulator $udid${device_set:+ in $device_set}" >&2
    exit 1
fi

"$simctl" ${set_args[@]+"${set_args[@]}"} install "$udid" "$app"
echo "Installed $bundle_id on $udid"

if [ "$launch" -eq 1 ]; then
    "$simctl" ${set_args[@]+"${set_args[@]}"} launch --terminate-running-process "$udid" "$bundle_id" \
        ${app_args[@]+"${app_args[@]}"}
fi

container="$("$simctl" ${set_args[@]+"${set_args[@]}"} get_app_container "$udid" "$bundle_id" data)"
echo "Readings: $container/Documents/readings.jsonl"
