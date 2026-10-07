#!/usr/bin/env bash
#
# Live smoke check of the private simulator bridge (Sources/DeviceHubProSimBridge).
# Run it on every Xcode beta before trusting the canvas on it. A beta's
# CoreSimulator is not allowlisted, so run it there with
# DHP_SIMBRIDGE_ALLOW_UNTESTED=1, or the tool stops at its version gate.
#
# It builds the DeviceHubProSimBridgeSmoke debug tool, signs a copy with the
# hardened runtime (Apple Development when that identity signs within 60 s,
# otherwise ad hoc), checks that no private symbol is linked (`nm -u`), creates
# an iPhone in a private device set, boots it, runs the tool against it, and
# deletes the simulator, its set and the log folder CoreSimulator leaves in
# ~/Library/Logs/CoreSimulator. It never touches the default device set, never
# passes `booted` or `all`, and runs no devicectl, adb or idevice tools.
#
# Usage:
#   bash Scripts/ios-bridge-smoke.sh [--seconds N] [--out DIR] [--adhoc]
#
#   --seconds N  how long the tool drags while counting frames (default 10)
#   --out DIR    keep the tool's PNGs (Settings, after the tap, before and
#                after Home) and its log in DIR
#   --adhoc      skip the Apple Development identity and sign ad hoc
#
# Env overrides:
#   SMOKE_DEVICE_TYPE  default com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro
#   SMOKE_RUNTIME      default com.apple.CoreSimulator.SimRuntime.iOS-27-0
#   SMOKE_MAX_LOAD     1-minute load average to wait below before building
#                      and booting (default 40; waits up to 10 minutes)
#   DEVELOPER_DIR      the Xcode to use (default: xcode-select -p)
#   DHP_SIMBRIDGE_ALLOW_UNTESTED=1
#                      let the bridge load on a CoreSimulator it was not
#                      verified on (an Xcode beta); passed through to the tool
#
# Exit status: 0 every check passed, 1 a check failed, 2 setup error.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECONDS_TO_DRAG=10
OUT_DIR=""
ADHOC=0
DEVICE_TYPE="${SMOKE_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
RUNTIME="${SMOKE_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-27-0}"
MAX_LOAD="${SMOKE_MAX_LOAD:-40}"

note() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --seconds) [[ $# -ge 2 ]] || die "--seconds needs a value"; SECONDS_TO_DRAG="$2"; shift 2 ;;
        --out) [[ $# -ge 2 ]] || die "--out needs a directory"; OUT_DIR="$2"; shift 2 ;;
        --adhoc) ADHOC=1; shift ;;
        -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done

DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
export DEVELOPER_DIR

# The real simctl, not the xcrun wrapper (which may run xcodebuild
# -runFirstLaunch when CoreSimulator looks older than it expects).
SIMCTL=(/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl)
if [[ ! -x "${SIMCTL[0]}" ]]; then
    SIMCTL=(xcrun simctl)
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/devicehubpro-bridge-smoke.XXXXXX")"
SET_DIR="$WORK/simset"
mkdir -p "$SET_DIR"
UDID=""

cleanup() {
    local status=$?
    if [[ -n "$UDID" ]]; then
        note "Deleting simulator $UDID and its log folder"
        "${SIMCTL[@]}" --set "$SET_DIR" shutdown "$UDID" >/dev/null 2>&1 || true
        "${SIMCTL[@]}" --set "$SET_DIR" delete "$UDID" >/dev/null 2>&1 || true
        rm -rf "${HOME:?}/Library/Logs/CoreSimulator/$UDID"
    fi
    rm -rf "$WORK"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

load_average() {
    # vm.loadavg reads "{ 1m 5m 15m }".
    sysctl -n vm.loadavg | awk '{ print $2 }'
}

wait_for_load() {
    local waited=0 load
    load="$(load_average)"
    while awk -v load="$load" -v max="$MAX_LOAD" 'BEGIN { exit !(load > max) }'; do
        if [[ $waited -ge 600 ]]; then
            die "the 1-minute load average stayed above $MAX_LOAD for 10 minutes (now $load)"
        fi
        note "load average $load is above $MAX_LOAD; waiting"
        sleep 15
        waited=$((waited + 15))
        load="$(load_average)"
    done
    note "load average $load"
}

cd "$ROOT"

wait_for_load
note "Building DeviceHubProSimBridgeSmoke"
swift build --product DeviceHubProSimBridgeSmoke || die "swift build failed"
BIN_DIR="$(swift build --show-bin-path)" || die "swift build --show-bin-path failed"
SMOKE="$WORK/DeviceHubProSimBridgeSmoke"
cp "$BIN_DIR/DeviceHubProSimBridgeSmoke" "$SMOKE" || die "cannot copy the smoke tool"

# Sign a copy, never the build product. perl's alarm bounds codesign, which
# can block on a keychain prompt.
SIGNING="ad hoc"
if [[ $ADHOC -eq 0 ]] && perl -e 'alarm shift; exec @ARGV' 60 \
        codesign -f -s "Apple Development" -o runtime "$SMOKE" >/dev/null 2>&1; then
    SIGNING="Apple Development"
else
    [[ $ADHOC -eq 1 ]] || note "Apple Development signing failed or timed out; signing ad hoc (the Team-ID check stays open)"
    codesign -f -s - -o runtime "$SMOKE" >/dev/null 2>&1 || die "ad-hoc signing failed"
fi
SIGNATURE="$(codesign -dv "$SMOKE" 2>&1)"
TEAM_ID="$(printf '%s\n' "$SIGNATURE" | sed -n 's/^TeamIdentifier=//p')"
CODE_FLAGS="$(printf '%s\n' "$SIGNATURE" | sed -n 's/^CodeDirectory .*flags=\([^ ]*\).*/\1/p')"
note "Signed: $SIGNING, flags $CODE_FLAGS, Team ID ${TEAM_ID:-none}"
[[ "$CODE_FLAGS" == *runtime* ]] || die "the smoke binary lacks the hardened runtime ($CODE_FLAGS)"

# Nothing private may be linked: CoreSimulator is dlopen'ed and the *_4sim
# functions are found with dlsym.
LINKED_PRIVATE="$(nm -u "$SMOKE" | grep -E '_4sim|OBJC_CLASS_\$_Sim' || true)"
if [[ -n "$LINKED_PRIVATE" ]]; then
    printf 'FAIL nm -u lists private symbols:\n%s\n' "$LINKED_PRIVATE" >&2
    exit 1
fi
note "nm -u: no _4sim or OBJC_CLASS_\$_Sim symbols"

note "Creating $DEVICE_TYPE on $RUNTIME in $SET_DIR"
# Checked before it becomes UDID: cleanup deletes whatever UDID names.
CREATED="$("${SIMCTL[@]}" --set "$SET_DIR" create DeviceHubPro-BridgeSmoke "$DEVICE_TYPE" "$RUNTIME")" \
    || die "simctl create failed"
[[ "$CREATED" =~ ^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$ ]] || die "simctl create returned '$CREATED'"
UDID="$CREATED"

wait_for_load
note "Booting $UDID"
# simctl's exit status is CoreSimulator's error code modulo 256, which can
# read 0; confirm the state as well.
"${SIMCTL[@]}" --set "$SET_DIR" bootstatus "$UDID" -b >/dev/null || die "simctl bootstatus -b failed"
"${SIMCTL[@]}" --set "$SET_DIR" list devices | grep -F "($UDID) (Booted)" >/dev/null \
    || die "$UDID is not Booted after bootstatus -b"
# "Booted" comes well before SpringBoard takes input.
sleep 10

SMOKE_OUT="$WORK/out"
mkdir -p "$SMOKE_OUT"
note "Running the smoke tool"
set +e
"$SMOKE" --udid "$UDID" --set "$SET_DIR" --seconds "$SECONDS_TO_DRAG" --out "$SMOKE_OUT" | tee "$SMOKE_OUT/smoke.log"
STATUS=${PIPESTATUS[0]}
set -e

if [[ -n "$OUT_DIR" ]]; then
    mkdir -p "$OUT_DIR"
    cp "$SMOKE_OUT"/* "$OUT_DIR"/
    note "Kept the PNGs and log in $OUT_DIR"
fi

note "Signing: $SIGNING (Team ID ${TEAM_ID:-none}, flags $CODE_FLAGS); nm -u clean"
if [[ $STATUS -eq 0 ]]; then
    note "PASS: every bridge check passed"
else
    note "FAIL: the smoke tool exited $STATUS"
fi
exit "$STATUS"
