#!/usr/bin/env bash
#
# Device Hub Pro performance harness — measures the *running* app, its emulator and
# the live mirror stream, then compares the numbers against
# Scripts/perf-reference.json. It builds nothing and changes no project files.
#
# Usage:
#   bash Scripts/perf-check.sh [workload|launch|idle|soak|all]
#
#   workload  fixed adb workload on a mirrored emulator (default)
#   launch    cold-launch timing (restarts the app; PERF_LAUNCH_RUNS runs)
#   idle      30 s idle CPU/memory with the mirror attached
#   soak      long-session memory growth (PERF_SOAK_SECONDS)
#   all       launch -> workload -> idle -> soak
#
# Env overrides:
#   PERF_REFERENCE   reference JSON      (default Scripts/perf-reference.json)
#   PERF_PERF_LOG    app mirror-stats    (default $TMPDIR/devicehubpro-perf.jsonl,
#                                         set DHP_PERF_LOG to the same path
#                                         when launching the app)
#   PERF_SERIAL      device serial       (default: the only online emulator)
#   PERF_WINDOW_ID   pin the app window  (default: largest layer-0 window)
#   PERF_APP_BINARY  launch/soak binary  (default .build/debug/DeviceHubPro)
#   PERF_LAUNCH_RUNS launch repetitions  (default 5)
#   PERF_SOAK_SECONDS soak duration      (default 600)
#   PERF_KEEP=1      keep the capture/log temp dir
#
# Exit status: 0 all checks passed (SKIPs are not failures), 1 at least one
# FAIL, 2 harness/precondition error.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REFERENCE="${PERF_REFERENCE:-$ROOT/Scripts/perf-reference.json}"
HELPERS="${TMPDIR:-/tmp}/devicehubpro-perf-helpers"
PERF_LOG="${PERF_PERF_LOG:-${TMPDIR:-/tmp}/devicehubpro-perf.jsonl}"
APP_BINARY="${PERF_APP_BINARY:-$ROOT/.build/debug/DeviceHubPro}"
LAUNCH_RUNS="${PERF_LAUNCH_RUNS:-5}"
SOAK_SECONDS="${PERF_SOAK_SECONDS:-600}"
MODE="${1:-workload}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/devicehubpro-perf.XXXXXX")"

say() { printf '%s\n' "$*"; }
note() { printf 'note: %s\n' "$*" >&2; }
die() { printf 'perf-check: %s\n' "$*" >&2; exit 2; }

cleanup() {
    [ "${PERF_KEEP:-0}" = "1" ] || rm -rf "$TMP"
}
trap cleanup EXIT

[ -f "$REFERENCE" ] || die "missing reference $REFERENCE"
case "$MODE" in workload|launch|idle|soak|all) ;; *) die "unknown mode $MODE";; esac

# --- helpers ---------------------------------------------------------------

find_adb() {
    if command -v adb >/dev/null 2>&1; then command -v adb; return; fi
    local c
    for c in "${ANDROID_HOME:-}/platform-tools/adb" \
             "${ANDROID_SDK_ROOT:-}/platform-tools/adb" \
             "$HOME/Library/Android/sdk/platform-tools/adb"; do
        [ -n "$c" ] && [ -x "$c" ] && { printf '%s\n' "$c"; return; }
    done
}
ADB="$(find_adb)"
[ -n "$ADB" ] || die "adb not found (set ANDROID_HOME or PATH)"

build_helper() {
    mkdir -p "$HELPERS"
    if [ ! -x "$HELPERS/windowlist" ] || [ "$ROOT/Scripts/windowlist.swift" -nt "$HELPERS/windowlist" ]; then
        swiftc "$ROOT/Scripts/windowlist.swift" -o "$HELPERS/windowlist" \
            || die "swiftc failed for windowlist.swift"
    fi
}

# Finds the app window (id + pid). Sets WINDOW_ID and APP_PID.
find_window() {
    if [ -n "${PERF_WINDOW_ID:-}" ]; then
        WINDOW_ID="$PERF_WINDOW_ID"
        APP_PID="$("$HELPERS/windowlist" DeviceHubPro | awk -F'\t' -v id="$WINDOW_ID" '$1 == id { print $10; exit }')"
        [ -n "$APP_PID" ] || die "window $WINDOW_ID is not a Device Hub Pro window"
        return
    fi
    local line
    line="$("$HELPERS/windowlist" DeviceHubPro | awk -F'\t' '$4 == 0 && $5 == 1' | sort -t$'\t' -k8,8nr | head -1)"
    [ -n "$line" ] || die "no on-screen Device Hub Pro window (launch the app first)"
    WINDOW_ID="$(printf '%s' "$line" | cut -f1)"
    APP_PID="$(printf '%s' "$line" | cut -f10)"
}

app_running() {
    "$HELPERS/windowlist" DeviceHubPro | awk -F'\t' '$4 == 0 && $5 == 1 { found = 1 } END { exit !found }'
}

# Online emulator serial, preferring PERF_SERIAL.
find_serial() {
    if [ -n "${PERF_SERIAL:-}" ]; then
        printf '%s\n' "$PERF_SERIAL"
        return
    fi
    "$ADB" devices | awk '{ sub(/\r$/, "") } $1 ~ /^emulator-/ && $2 == "device" { print $1; exit }'
}

# Prints the qemu command line for the AVD behind SERIAL (empty when unknown).
emulator_command() {
    local avd
    avd="$("$ADB" -s "$SERIAL" emu avd name 2>/dev/null | head -1 | tr -d '\r')"
    [ -n "$avd" ] || return
    ps axww -o command | grep -F "qemu-system" | grep -F -- "-avd $avd" | grep -v grep | head -1
}

# The app's phys_footprint in MB.
app_footprint_mb() {
    footprint -p "$APP_PID" 2>/dev/null \
        | sed -n 's/.*Footprint: \([0-9]*\) MB.*/\1/p' | head -1
}

# Mean CPU% of the app over `seconds`, first (unreliable) sample dropped.
app_cpu_mean() {
    local seconds="$1"
    local out="$TMP/top-$seconds.txt"
    top -l "$((seconds + 1))" -s 1 -pid "$APP_PID" -stats pid,cpu >"$out" 2>/dev/null
    awk 'NR > 1 && $1 ~ /^[0-9]+$/ { sum += $2; n += 1 } END { if (n > 0) printf "%.1f", sum / n; else print "" }' "$out"
}

# Stream stats from the app's perf log between two epochs (start, end),
# for one device's rows only (the "device" field the app now writes per
# sample — a serial or a UDID). Filtering matters once two devices can log
# to the same file at once: each writes its own monotonic frames/dropped
# counters, and mixing them would corrupt the frames delta below. Omit
# device to read every row (pre-field logs, or a single-device run).
# Prints "peakFps droppedPct latencyMs frames" or nothing.
stream_stats() {
    local start="$1" end="$2" device="${3:-}"
    [ -f "$PERF_LOG" ] || return
    python3 - "$PERF_LOG" "$start" "$end" "$device" <<'PY'
import json, sys
path, start, end, device = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
rows = []
try:
    with open(path) as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if device and entry.get("device") != device:
                continue
            if start - 1.0 <= entry.get("t", 0) <= end + 1.0:
                rows.append(entry)
except OSError:
    sys.exit(0)
if not rows:
    sys.exit(0)
fps = max(r.get("fps", 0.0) for r in rows)
frames = rows[-1].get("frames", 0) - rows[0].get("frames", 0)
dropped = rows[-1].get("dropped", 0) - rows[0].get("dropped", 0)
latencies = sorted(r.get("latencyMs", 0.0) for r in rows)
median = latencies[len(latencies) // 2]
dropped_pct = (dropped / frames * 100.0) if frames > 0 else 0.0
print(f"{fps:.1f} {dropped_pct:.2f} {median:.1f} {frames}")
PY
}

# Guest frame percentiles for a package: "p50 jankyPct frames" or nothing.
guest_gfxinfo() {
    local pkg="$1" out
    out="$("$ADB" -s "$SERIAL" shell dumpsys gfxinfo "$pkg" 2>/dev/null | tr -d '\r')"
    printf '%s\n' "$out" | python3 -c '
import re, sys
text = sys.stdin.read()
total = re.search(r"Total frames rendered:\s*(\d+)", text)
janky = re.search(r"Janky frames:\s*\d+\s*\(([\d.]+)%\)", text)
p50 = re.search(r"50th percentile:\s*(\d+)ms", text)
if not (total and janky and p50) or int(total.group(1)) == 0:
    sys.exit(0)
print(f"{int(p50.group(1))} {float(janky.group(1)):.1f} {int(total.group(1))}")
'
}

# Fixed, deterministic workload; resolution-aware swipes.
run_workload() {
    local size w h cx
    size="$("$ADB" -s "$SERIAL" shell wm size 2>/dev/null | tr -d '\r' | sed -n 's/.*: \([0-9]*\)x\([0-9]*\).*/\1 \2/p')"
    w="${size% *}"; h="${size#* }"
    [ -n "$w" ] && [ -n "$h" ] || { w=1280; h=2856; }
    cx=$((w / 2))

    "$ADB" -s "$SERIAL" shell input keyevent KEYCODE_HOME >/dev/null 2>&1
    sleep 1
    "$ADB" -s "$SERIAL" shell input swipe "$cx" $((h * 84 / 100)) "$cx" $((h * 30 / 100)) 120 >/dev/null 2>&1
    sleep 1
    local i
    for i in 1 2 3 4 5 6; do
        "$ADB" -s "$SERIAL" shell input swipe "$cx" $((h * 62 / 100)) "$cx" $((h * 18 / 100)) 60 >/dev/null 2>&1
    done
    sleep 1
    "$ADB" -s "$SERIAL" shell am start -a android.settings.SETTINGS >/dev/null 2>&1
    sleep 2
    for i in 1 2 3; do
        "$ADB" -s "$SERIAL" shell input swipe "$cx" $((h * 62 / 100)) "$cx" $((h * 22 / 100)) 60 >/dev/null 2>&1
    done
    "$ADB" -s "$SERIAL" shell am force-stop com.android.settings >/dev/null 2>&1
    "$ADB" -s "$SERIAL" shell input keyevent KEYCODE_HOME >/dev/null 2>&1
    sleep 1
    "$ADB" -s "$SERIAL" shell settings put system accelerometer_rotation 0 >/dev/null 2>&1
    "$ADB" -s "$SERIAL" shell settings put system user_rotation 1 >/dev/null 2>&1
    sleep 2
    "$ADB" -s "$SERIAL" shell settings put system user_rotation 0 >/dev/null 2>&1
    sleep 1
}

# --- metrics collection ----------------------------------------------------

METRICS="$TMP/metrics.json"
echo '{}' >"$METRICS"

record() {
    local name="$1" value="$2"
    [ -n "$value" ] || return
    python3 - "$METRICS" "$name" "$value" <<'PY'
import json, sys
path, name, value = sys.argv[1], sys.argv[2], float(sys.argv[3])
with open(path) as handle:
    data = json.load(handle)
data[name] = value
with open(path, "w") as handle:
    json.dump(data, handle)
PY
}

preconditions() {
    find_window
    SERIAL="$(find_serial)"
    [ -n "$SERIAL" ] || die "no online emulator (start one from Device Hub Pro)"
    local command
    command="$(emulator_command)"
    [ -n "$command" ] || die "cannot find the qemu process for $SERIAL"
    if printf '%s' "$command" | grep -q -- "-gpu host"; then
        record emulator-gpu-host 1
    else
        record emulator-gpu-host 0
    fi
    say "window    : id=$WINDOW_ID pid=$APP_PID"
    say "device    : $SERIAL ($(printf '%s' "$command" | sed -n 's/.*-avd \([^ ]*\).*/\1/p'))"
    say "perf log  : $PERF_LOG$([ -f "$PERF_LOG" ] && printf ' (fresh)' || printf ' (missing)')"
}

collect_workload() {
    local before_footprint after_footprint pkg start end
    before_footprint="$(app_footprint_mb)"
    pkg="com.google.android.apps.nexuslauncher"
    "$ADB" -s "$SERIAL" shell dumpsys gfxinfo "$pkg" reset >/dev/null 2>&1
    start="$(python3 -c 'import time; print(time.time())')"
    top -l 60 -s 1 -pid "$APP_PID" -stats pid,cpu >"$TMP/top-workload.txt" 2>/dev/null &
    local top_pid=$!
    run_workload
    end="$(python3 -c 'import time; print(time.time())')"
    kill "$top_pid" 2>/dev/null
    wait "$top_pid" 2>/dev/null
    after_footprint="$(app_footprint_mb)"

    local cpu
    cpu="$(awk 'NR > 1 && $1 ~ /^[0-9]+$/ { sum += $2; n += 1 } END { if (n > 0) printf "%.1f", sum / n }' "$TMP/top-workload.txt")"
    record app-cpu-mean-pct "$cpu"
    record app-footprint-mb "$after_footprint"

    local guest
    guest="$(guest_gfxinfo "$pkg")"
    if [ -n "$guest" ]; then
        record guest-frame-p50-ms "$(printf '%s' "$guest" | cut -d' ' -f1)"
        record guest-janky-pct "$(printf '%s' "$guest" | cut -d' ' -f2)"
    else
        note "guest gfxinfo for $pkg gave no frames; guest checks SKIP"
    fi

    local stream
    stream="$(stream_stats "$start" "$end" "$SERIAL")"
    if [ -n "$stream" ]; then
        record stream-fps-peak "$(printf '%s' "$stream" | cut -d' ' -f1)"
        record stream-dropped-pct "$(printf '%s' "$stream" | cut -d' ' -f2)"
        record stream-latency-ms "$(printf '%s' "$stream" | cut -d' ' -f3)"
    else
        note "no mirror-stats lines in $PERF_LOG for the workload window; stream checks SKIP (launch the app with DHP_PERF_LOG=$PERF_LOG)"
    fi
}

collect_launch() {
    local runs="$LAUNCH_RUNS" i times=()
    [ -x "$APP_BINARY" ] || die "app binary not found at $APP_BINARY (build first or set PERF_APP_BINARY)"
    for i in $(seq 1 "$runs"); do
        pkill -f "$APP_BINARY" >/dev/null 2>&1
        sleep 1
        local start end
        start="$(python3 -c 'import time; print(time.time())')"
        nohup "$APP_BINARY" >/dev/null 2>&1 &
        local pid=$!
        local waited=0
        while [ "$waited" -lt 150 ]; do
            if "$HELPERS/windowlist" DeviceHubPro | awk -F'\t' -v pid="$pid" '$4 == 0 && $5 == 1 && $10 == pid { found = 1 } END { exit !found }'; then
                break
            fi
            sleep 0.1
            waited=$((waited + 1))
        done
        end="$(python3 -c 'import time; print(time.time())')"
        local elapsed
        elapsed="$(python3 -c "print(f'{$end - $start:.2f}')")"
        times+=("$elapsed")
        say "launch $i: ${elapsed} s"
        pkill -f "$APP_BINARY" >/dev/null 2>&1
        sleep 1
    done
    local median
    median="$(printf '%s\n' "${times[@]}" | sort -n | awk '{ v[NR] = $1 } END { print v[int((NR + 1) / 2)] }')"
    record launch-median-s "$median"
}

collect_idle() {
    local before after cpu
    before="$(app_footprint_mb)"
    cpu="$(app_cpu_mean 30)"
    after="$(app_footprint_mb)"
    record idle-cpu-mean-pct "$cpu"
    record idle-footprint-mb "$after"
    say "idle      : cpu ${cpu}%  footprint ${before} -> ${after} MB"
}

collect_soak() {
    local interval=30 samples=$((SOAK_SECONDS / 30)) i
    local values=()
    for i in $(seq 1 "$samples"); do
        sleep "$interval"
        local value
        value="$(app_footprint_mb)"
        [ -n "$value" ] || die "cannot read the app footprint during the soak (is the app running?)"
        values+=("$value")
        say "soak $((i * interval))s: ${value} MB"
    done
    # The allocator churns tens of MB while the stream is idle, so a simple
    # first-vs-last comparison is noise; compare the floors (minimums) of the
    # two halves instead — a leak raises the floor.
    local growth
    growth="$(python3 - "${values[@]}" <<'PY'
import sys
vals = [float(v) for v in sys.argv[1:]]
half = max(1, len(vals) // 2)
floor_first, floor_second = min(vals[:half]), min(vals[half:])
print(f"{(floor_second - floor_first) / floor_first * 100:.2f}")
PY
)"
    record soak-footprint-growth-pct "$growth"
}

# --- evaluation ------------------------------------------------------------

evaluate() {
    say ""
    say "-------------------------------------------------------------------------------"
    python3 - "$REFERENCE" "$METRICS" <<'PY'
import json, sys

with open(sys.argv[1]) as handle:
    reference = json.load(handle)
with open(sys.argv[2]) as handle:
    metrics = json.load(handle)

passed = failed = skipped = 0
for check in reference.get("checks", []):
    name = check["name"]
    if name not in metrics:
        print(f"SKIP {name:<28} {check.get('description', '')}")
        skipped += 1
        continue
    actual = metrics[name]
    expected = float(check["expected"])
    tolerance = float(check.get("tolerance", 0))
    kind = check.get("kind", "max")
    if kind == "min":
        ok = actual >= expected - tolerance
        bound = expected - tolerance
    elif kind == "max":
        ok = actual <= expected + tolerance
        bound = expected + tolerance
    else:
        ok = actual == expected
        bound = expected
    unit = check.get("unit", "")
    status = "PASS" if ok else "FAIL"
    if ok:
        passed += 1
    else:
        failed += 1
    print(f"{status} {name:<28} expected {expected:g}{unit} bound {bound:g}{unit} actual {actual:g}{unit}")
print("-------------------------------------------------------------------------------")
print(f"summary: {passed} passed, {failed} failed, {skipped} skipped")
sys.exit(1 if failed else 0)
PY
    EXIT_CODE=$?
}

# --- main ------------------------------------------------------------------

say "Device Hub Pro performance check"
say "reference : $REFERENCE"
say "mode      : $MODE"
say ""

build_helper

EXIT_CODE=0
case "$MODE" in
    workload)
        preconditions
        collect_workload
        evaluate
        ;;
    launch)
        collect_launch
        evaluate
        ;;
    idle)
        preconditions
        collect_idle
        evaluate
        ;;
    soak)
        preconditions
        collect_soak
        evaluate
        ;;
    all)
        collect_launch
        preconditions
        collect_workload
        collect_idle
        collect_soak
        evaluate
        ;;
esac
exit "$EXIT_CODE"
