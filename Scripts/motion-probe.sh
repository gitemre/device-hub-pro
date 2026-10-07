#!/usr/bin/env bash
#
# motion-probe.sh — record and measure window animations.
#
# Companion to the pixel-parity harness: where parity-check.sh measures still
# pixels, this records a window while an interaction runs and extracts the
# animation's duration, settle and velocity profile from the frames.
#
# Usage:
#   bash Scripts/motion-probe.sh record <owner> <out.mov> <seconds> [pid]
#   bash Scripts/motion-probe.sh analyze <movie> [--threshold T] [--strip out.png]
#                                                 [--frames dir] [--max-frames N]
#   bash Scripts/motion-probe.sh list [owner]
#
# record:
#   Finds the frontmost window owned by <owner> (optionally for a given pid),
#   records it by window ID with `screencapture -v -V<seconds> -l <id>`. The
#   window is never raised and no synthetic input is sent.
#
# analyze:
#   Runs the compiled motion-frames helper (built into
#   $TMPDIR/devicehubpro-parity-helpers on first use) and prints the per-frame
#   change metric, the motion window and a normalized velocity profile.
#
# Exit status: 0 ok, 1 no motion, 2 harness/window/capture error.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${TMPDIR:-/tmp}/devicehubpro-parity-helpers"
mkdir -p "$CACHE_DIR"

compile_helper() {
    local source="$1" binary="$2"
    if [ ! -x "$binary" ] || [ "$source" -nt "$binary" ]; then
        echo "building $(basename "$source") …" >&2
        swiftc "$source" -o "$binary" || {
            echo "motion-probe: failed to build $source" >&2
            exit 2
        }
    fi
}

find_window() {
    local owner="$1" wanted_pid="${2:-}"
    compile_helper "$SCRIPT_DIR/windowlist.swift" "$CACHE_DIR/windowlist"
    "$CACHE_DIR/windowlist" "$owner" | awk -v pid="$wanted_pid" '
        $4 == 0 && (pid == "" || $10 == pid) { print $1; exit }
    '
}

command="${1:-}"
shift || true

case "$command" in
    list)
        owner="${1:-}"
        compile_helper "$SCRIPT_DIR/windowlist.swift" "$CACHE_DIR/windowlist"
        if [ -n "$owner" ]; then
            "$CACHE_DIR/windowlist" "$owner"
        else
            "$CACHE_DIR/windowlist"
        fi
        ;;
    record)
        owner="${1:-}"; shift || true
        output="${1:-}"; shift || true
        seconds="${1:-2}"; shift || true
        pid="${1:-}"
        if [ -z "$owner" ] || [ -z "$output" ]; then
            echo "usage: motion-probe.sh record <owner> <out.mov> <seconds> [pid]" >&2
            exit 2
        fi
        window_id="$(find_window "$owner" "$pid")"
        if [ -z "$window_id" ]; then
            echo "motion-probe: no on-screen layer-0 window for owner '$owner'" >&2
            exit 2
        fi
        echo "recording window id=$window_id for ${seconds}s → $output" >&2
        screencapture -x -v -V"$seconds" -l "$window_id" "$output" || {
            echo "motion-probe: screencapture failed" >&2
            exit 2
        }
        ;;
    analyze)
        movie="${1:-}"; shift || true
        if [ -z "$movie" ]; then
            echo "usage: motion-probe.sh analyze <movie> [options]" >&2
            exit 2
        fi
        compile_helper "$SCRIPT_DIR/motion-frames.swift" "$CACHE_DIR/motion-frames"
        "$CACHE_DIR/motion-frames" "$movie" "$@"
        ;;
    *)
        echo "usage: motion-probe.sh record|analyze|list …" >&2
        exit 2
        ;;
esac
