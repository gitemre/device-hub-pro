#!/usr/bin/env bash
#
# parity-check.sh — live pixel-parity harness for Device Hub Pro.
#
# What it does (all read-only: it builds nothing and modifies nothing in the
# project; it only observes the running app):
#   1. finds the main Device Hub Pro window (window owner "Device Hub Pro", window layer 0,
#      largest area) with the compiled windowlist helper;
#   2. captures that window by ID to a temp directory
#      (`screencapture -x -o -l <id>`);
#   3. runs every check in Scripts/parity-reference.json against the capture
#      and prints a `PASS/FAIL <name> expected=… actual=… (Δ…)` line per
#      check plus a summary.
#
# Exit status: 0 = all checks passed (SKIPs are not failures), 1 = at least
# one FAIL, 2 = harness/window/capture error.
#
# Usage:
#   bash Scripts/parity-check.sh
#
# Environment overrides:
#   PARITY_KEEP=1            keep the capture and print its path
#   PARITY_IMAGE=<png>       evaluate a saved capture instead of capturing live
#   PARITY_WINDOW_SIZE=WxH   window size in points for a saved capture; the
#                            scale is then the capture's width over it
#   PARITY_SCALE=<n>         pixels-per-point override (a saved capture with
#                            neither this nor PARITY_WINDOW_SIZE is read at
#                            1 px/pt, with a warning)
#   PARITY_WINDOW_ID=<id>    capture this window ID instead of auto-detecting;
#                            any owner (a renamed app copy too): the scale is
#                            the capture's width over the window's
#   PARITY_REFERENCE=<json>  use another reference file
#
# Notes:
#   * The harness measures the RUNNING app. Rebuild and relaunch before
#     trusting a failure (the stale-Xcode-build trap).
#   * The window must be on screen (not minimised) and, for the seeded checks,
#     at the stock 1920x985 size with the stock 300 pt sidebar / 300 pt
#     inspector, a selected device and the Apps inspector tab open.
#   * Checks tagged "appearance": "light" compare absolute colours; they are
#     reported as SKIP when the app renders dark. See Scripts/README.md.
#
# The two Swift helpers are compiled once into
# "$TMPDIR/devicehubpro-parity-helpers" (rebuilt when their sources change).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFERENCE="${PARITY_REFERENCE:-$SCRIPT_DIR/parity-reference.json}"
CACHE_DIR="${TMPDIR:-/tmp}/devicehubpro-parity-helpers"
mkdir -p "$CACHE_DIR"

compile_helper() {
    local source="$1" binary="$2"
    if [ ! -x "$binary" ] || [ "$source" -nt "$binary" ]; then
        echo "building $(basename "$source") …" >&2
        swiftc "$source" -o "$binary" || {
            echo "parity-check: failed to build $source" >&2
            exit 2
        }
    fi
}
compile_helper "$SCRIPT_DIR/windowlist.swift" "$CACHE_DIR/windowlist"
compile_helper "$SCRIPT_DIR/pixscan.swift" "$CACHE_DIR/pixscan"

[ -f "$REFERENCE" ] || { echo "parity-check: reference file '$REFERENCE' not found" >&2; exit 2; }

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/devicehubpro-parity.XXXXXX")"
CAPTURE_PATH=""
cleanup() {
    if [ "${PARITY_KEEP:-0}" = "1" ] && [ -n "$CAPTURE_PATH" ]; then
        echo "capture kept at $CAPTURE_PATH" >&2
    else
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

IMAGE="$TMP_DIR/window.png"
WINDOW_DESCRIPTION=""
WINDOW_WIDTH=""
# Set only for a live capture; read by the key-window note at the end.
WINDOW_ID=""

if [ -n "${PARITY_IMAGE:-}" ]; then
    IMAGE="$PARITY_IMAGE"
    [ -f "$IMAGE" ] || { echo "parity-check: PARITY_IMAGE '$IMAGE' not found" >&2; exit 2; }
    WINDOW_DESCRIPTION="saved capture"
    if [ -n "${PARITY_WINDOW_SIZE:-}" ]; then
        WINDOW_WIDTH="${PARITY_WINDOW_SIZE%%x*}"
    fi
    SCALE="${PARITY_SCALE:-}"
else
    WINDOW_ID="${PARITY_WINDOW_ID:-}"
    if [ -z "$WINDOW_ID" ]; then
        LIST="$("$CACHE_DIR/windowlist" DeviceHubPro)"
        LINE="$(printf '%s\n' "$LIST" | awk -F'\t' '$2 == "DeviceHubPro" && $4 == 0 { area = $8 * $9; if (area > best) { best = area; line = $0 } } END { if (best > 0) print line }')"
        [ -n "$LINE" ] || {
            echo "parity-check: no on-screen Device Hub Pro window found (main window must be open and not minimised)" >&2
            exit 2
        }
        WINDOW_ID="$(printf '%s' "$LINE" | cut -f1)"
        WINDOW_WIDTH="$(printf '%s' "$LINE" | cut -f8)"
        WINDOW_HEIGHT="$(printf '%s' "$LINE" | cut -f9)"
        WINDOW_DESCRIPTION="id=$WINDOW_ID \"$(printf '%s' "$LINE" | cut -f3)\" ${WINDOW_WIDTH}x${WINDOW_HEIGHT}pt"
    else
        # Looked up among every window, not only those owned by "Device Hub Pro":
        # a renamed copy of the app has its own owner name.
        LINE="$("$CACHE_DIR/windowlist" | awk -F'\t' -v id="$WINDOW_ID" '$1 == id { print; exit }')"
        if [ -n "$LINE" ]; then
            WINDOW_WIDTH="$(printf '%s' "$LINE" | cut -f8)"
            WINDOW_HEIGHT="$(printf '%s' "$LINE" | cut -f9)"
            WINDOW_DESCRIPTION="id=$WINDOW_ID (PARITY_WINDOW_ID) \"$(printf '%s' "$LINE" | cut -f2)\" ${WINDOW_WIDTH}x${WINDOW_HEIGHT}pt"
        elif [ -z "${PARITY_SCALE:-}" ]; then
            echo "parity-check: window $WINDOW_ID is not on screen, so its size (and the capture's px/pt) is unknown; set PARITY_SCALE" >&2
            exit 2
        else
            WINDOW_DESCRIPTION="id=$WINDOW_ID (PARITY_WINDOW_ID, not listed)"
        fi
    fi

    screencapture -x -o -l "$WINDOW_ID" "$IMAGE" || {
        echo "parity-check: screencapture failed for window $WINDOW_ID" >&2
        exit 2
    }
    [ -s "$IMAGE" ] || {
        echo "parity-check: capture is empty — the window may be minimised or the screen locked" >&2
        exit 2
    }
    CAPTURE_PATH="$IMAGE"
    SCALE="${PARITY_SCALE:-}"
fi

SIZE="$("$CACHE_DIR/pixscan" size "$IMAGE")" || exit 2
IMAGE_WIDTH="${SIZE%% *}"
IMAGE_HEIGHT="${SIZE##* }"

if [ -z "$SCALE" ]; then
    if [ -n "$WINDOW_WIDTH" ] && [ "$WINDOW_WIDTH" -gt 0 ] 2>/dev/null; then
        SCALE="$(awk -v iw="$IMAGE_WIDTH" -v ww="$WINDOW_WIDTH" 'BEGIN { printf "%.4f", iw / ww }')"
    else
        echo "parity-check: warning: no window size or PARITY_SCALE for this capture; reading it at 1 px/pt" >&2
        SCALE="1"
    fi
fi

echo "Device Hub Pro pixel-parity check"
echo "reference : $REFERENCE"
echo "window    : $WINDOW_DESCRIPTION"
echo "capture   : $IMAGE (${IMAGE_WIDTH}x${IMAGE_HEIGHT}px, ${SCALE} px/pt)"
echo

"$CACHE_DIR/pixscan" check "$IMAGE" "$REFERENCE" "$SCALE"
STATUS=$?

# Material-dependent color checks read a few units lighter whenever the app is
# not the key window (the app stays key only while it is frontmost). Hint at
# that instead of ever widening the tolerances.
if [ "$STATUS" -ne 0 ]; then
    FRONT="$("$CACHE_DIR/windowlist" 2>/dev/null | grep -vE "Window Server|Dock|Menubar|Cursor" | head -1 | cut -f1)"
    if [ -n "$WINDOW_ID" ] && [ -n "$FRONT" ] && [ "$FRONT" != "$WINDOW_ID" ]; then
        echo
        echo "note: window $WINDOW_ID is not the key window (front is $FRONT)."
        echo "      material-dependent color checks read lighter while inactive;"
        echo "      geometry checks are key-independent. Re-run with the app front"
        echo "      before treating color failures as regressions."
    fi
fi
exit $STATUS
