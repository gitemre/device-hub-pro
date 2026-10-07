#!/bin/bash
# Builds the Device Hub Pro iOS verifier for the simulator (no Xcode project, no
# signing: the linker's ad-hoc signature is enough for a simulator) and
# optionally installs and launches it on one simulator. With --device it
# builds a signed app for an iPhone instead (it never installs one).
#
#   ios/verifier/build.sh [--out <dir>]
#   ios/verifier/build.sh --install <UDID> [--set <device set dir>] [--launch] [--no-build]
#   ios/verifier/build.sh --device --profile <profile> --identity <SHA-1> [--out <dir>]
#
# --device compiles against the iPhoneOS SDK (arm64-apple-ios26.0), marks the
# bundle iPhoneOS, embeds the provisioning profile given by --profile, and
# signs with the keychain identity given by --identity (its 40-hex SHA-1) and
# entitlements derived from that profile: application-identifier
# <TEAM>.com.devicehubpro.verifier, get-task-allow and the team identifier. Both
# options are required, and --device cannot be combined with --install, --set,
# --launch or --no-build. Installing the result is a separate, explicit step.
#
# The simulator is named by its UDID, never `booted` or `all`, and must be
# listed by simctl in the given device set (the default set without --set),
# so nothing here can reach a physical device. No xcrun (its wrappers can
# run `xcodebuild -runFirstLaunch`): swiftc and the iPhoneSimulator SDK come
# from the developer directory ($DEVELOPER_DIR, else `xcode-select -p`), and
# simctl is the real binary (DHP_SIMCTL overrides it). The app lands in
# <out>/DeviceHubProVerifier.app (default: .build/ios-verifier in the
# repository). After an install it prints where readings.json is.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
bundle_id="com.devicehubpro.verifier"
out="$root/.build/ios-verifier"
udid=""
device_set=""
launch=0
build=1
device=0
profile=""
identity=""

usage() {
    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --out) out="${2:?--out needs a directory}"; shift 2 ;;
        --install) udid="${2:?--install needs a simulator UDID}"; shift 2 ;;
        --set) device_set="${2:?--set needs a device set directory}"; shift 2 ;;
        --launch) launch=1; shift ;;
        --no-build) build=0; shift ;;
        --device) device=1; shift ;;
        --profile) profile="${2:?--profile needs a provisioning profile}"; shift 2 ;;
        --identity) identity="${2:?--identity needs a signing identity SHA-1}"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "build.sh: unknown argument $1" >&2; usage 2 ;;
    esac
done

app="$out/DeviceHubProVerifier.app"

if [ "$device" -eq 1 ]; then
    if [ -z "$profile" ] || [ -z "$identity" ]; then
        echo "build.sh: --device needs both --profile <provisioning profile> and --identity <signing identity SHA-1>" >&2
        exit 2
    fi
    if [ -n "$udid" ] || [ -n "$device_set" ] || [ "$launch" -eq 1 ] || [ "$build" -eq 0 ]; then
        echo "build.sh: --device only builds and signs; it takes no --install, --set, --launch or --no-build" >&2
        exit 2
    fi
    if ! [[ "$identity" =~ ^[0-9A-Fa-f]{40}$ ]]; then
        echo "build.sh: --identity must be the 40-hex SHA-1 of a signing identity" >&2
        exit 2
    fi
    if [ ! -f "$profile" ]; then
        echo "build.sh: no provisioning profile at $profile" >&2
        exit 1
    fi
elif [ -n "$profile" ] || [ -n "$identity" ]; then
    echo "build.sh: --profile and --identity belong to --device" >&2
    exit 2
fi

if [ "$device" -eq 1 ]; then
    rm -rf "$app"
    mkdir -p "$app"
    started=$(date +%s)
    developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
    swiftc="$developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    sdk="$developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"
    if [ ! -x "$swiftc" ] || [ ! -d "$sdk" ]; then
        echo "build.sh: no swiftc or iPhoneOS SDK under $developer (install Xcode, or set DEVELOPER_DIR)" >&2
        exit 1
    fi

    # The profile is a CMS-signed plist; read the team and check it fits the
    # app before compiling. Nothing from it is printed.
    scratch="$(mktemp -d)"
    trap 'rm -rf "$scratch"' EXIT
    security cms -D -i "$profile" > "$scratch/profile.plist" 2>/dev/null || {
        echo "build.sh: $profile is not a readable provisioning profile" >&2
        exit 1
    }
    team="$(plutil -extract TeamIdentifier.0 raw -o - "$scratch/profile.plist" 2>/dev/null || true)"
    if ! [[ "$team" =~ ^[0-9A-Z]{10}$ ]]; then
        echo "build.sh: the profile names no team identifier" >&2
        exit 1
    fi
    profile_app_id="$(plutil -extract Entitlements.application-identifier raw -o - "$scratch/profile.plist" 2>/dev/null || true)"
    if [ "$profile_app_id" != "$team.$bundle_id" ] && [ "$profile_app_id" != "$team.*" ]; then
        echo "build.sh: the profile does not cover $bundle_id (its application identifier is another app's)" >&2
        exit 1
    fi
    if [ "$(plutil -extract Entitlements.get-task-allow raw -o - "$scratch/profile.plist" 2>/dev/null || true)" != "true" ]; then
        echo "build.sh: the profile is not a development profile (get-task-allow is off)" >&2
        exit 1
    fi
    expires="$(plutil -extract ExpirationDate raw -o - "$scratch/profile.plist" 2>/dev/null || true)"
    if [ -n "$expires" ] && [[ "$expires" < "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]]; then
        echo "build.sh: the provisioning profile has expired" >&2
        exit 1
    fi

    # -parse-as-library: the app's entry point is @main, not main.swift.
    "$swiftc" \
        -sdk "$sdk" \
        -parse-as-library \
        -target arm64-apple-ios26.0 \
        -swift-version 6 \
        -O \
        -module-name DeviceHubProVerifier \
        "$here"/App/*.swift "$here"/Shared/*.swift \
        -o "$app/DeviceHubProVerifier"
    cp "$here/Info.plist" "$app/Info.plist"
    plutil -replace CFBundleSupportedPlatforms -json '["iPhoneOS"]' "$app/Info.plist"
    plutil -replace DTPlatformName -string iphoneos "$app/Info.plist"
    plutil -lint -s "$app/Info.plist"
    cp "$profile" "$app/embedded.mobileprovision"

    # The entitlements come from the profile, and live outside the bundle.
    cat > "$scratch/entitlements.plist" <<ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>$team.$bundle_id</string>
	<key>com.apple.developer.team-identifier</key>
	<string>$team</string>
	<key>get-task-allow</key>
	<true/>
</dict>
</plist>
ENTITLEMENTS
    plutil -lint -s "$scratch/entitlements.plist"
    codesign --force --sign "$identity" --entitlements "$scratch/entitlements.plist" "$app" >/dev/null
    codesign --verify --deep --strict "$app"
    echo "Built and signed $app for iPhoneOS in $(( $(date +%s) - started )) s (not installed)"
    exit 0
fi

if [ "$build" -eq 1 ]; then
    rm -rf "$app"
    mkdir -p "$app"
    started=$(date +%s)
    developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
    swiftc="$developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    sdk="$developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"
    if [ ! -x "$swiftc" ] || [ ! -d "$sdk" ]; then
        echo "build.sh: no swiftc or iPhoneSimulator SDK under $developer (install Xcode, or set DEVELOPER_DIR)" >&2
        exit 1
    fi
    # -parse-as-library: the app's entry point is @main, not main.swift.
    "$swiftc" \
        -sdk "$sdk" \
        -parse-as-library \
        -target arm64-apple-ios26.0-simulator \
        -swift-version 6 \
        -O \
        -module-name DeviceHubProVerifier \
        "$here"/App/*.swift "$here"/Shared/*.swift \
        -o "$app/DeviceHubProVerifier"
    cp "$here/Info.plist" "$app/Info.plist"
    plutil -lint -s "$app/Info.plist"
    # The arm64 linker signs ad hoc; simctl install accepts that as is.
    signature="$(codesign -dv "$app/DeviceHubProVerifier" 2>&1 || true)"
    if ! grep -q "linker-signed" <<<"$signature"; then
        echo "build.sh: the binary carries no linker signature; simctl install may refuse it" >&2
    fi
    echo "Built $app in $(( $(date +%s) - started )) s"
elif [ ! -x "$app/DeviceHubProVerifier" ]; then
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
# The Location row needs the permission; granting it here keeps the
# verifier from asking.
"$simctl" ${set_args[@]+"${set_args[@]}"} privacy "$udid" grant location "$bundle_id"
echo "Installed $bundle_id on $udid"

if [ "$launch" -eq 1 ]; then
    "$simctl" ${set_args[@]+"${set_args[@]}"} launch --terminate-running-process "$udid" "$bundle_id"
fi

container="$("$simctl" ${set_args[@]+"${set_args[@]}"} get_app_container "$udid" "$bundle_id" data)"
echo "Readings: $container/Documents/readings.json"
