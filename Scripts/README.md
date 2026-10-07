# Scripts — Device Hub Pro pixel-parity harness

Standalone, read-only tooling that measures the **running** Device Hub Pro window and
compares its pixels against the audited Device Hub references documented in
`Sources/DeviceHubProApp/ParityMetrics.swift`.

It builds nothing in the project and modifies nothing: it finds the window,
captures it, measures it, and reports.

> Performance measurements live in the sibling harness `Scripts/perf-check.sh`
> (same read-only pattern: it drives a fixed adb workload against a mirrored
> emulator and compares stream/app/guest metrics against
> `Scripts/perf-reference.json`). The reference is the 2026-09-24 MMAP
> baseline (emulator 37.2.3+ with `-gpu host`); each check is `min`
> (pass at ≥ expected − tolerance), `max` (pass at ≤ expected + tolerance) or
> `exact`. Baselines, the transport A/B and the performance code review are in
> `docs/performance.md`; modes are `workload | launch | idle | soak | all`.

## Quick start

```bash
# with the app running (and, for the seeded checks, a device selected and the
# Apps inspector tab open — see "Prerequisites" below)
bash Scripts/parity-check.sh
```

Exit status: `0` all checks passed (SKIPs are not failures), `1` at least one
FAIL, `2` harness/window/capture error.

Example output:

```
Device Hub Pro pixel-parity check
reference : Scripts/parity-reference.json
window    : id=14785 "Device Hub Pro" 1920x985pt
capture   : /var/.../devicehubpro-parity.XXXX/window.png (1920x985px, 1.0000 px/pt)

appearance: light   capture: 1920x985px @ 1 px/pt
------------------------------------------------------------------------------
PASS toolbar-trio-origin                expected=1307 actual=1307 (Δ0)  x=1307 #ffffff→#d0d0cf
PASS sidebar-search-height              expected=28 actual=30 (Δ2)  x=150: y 59–88
FAIL segmented-track-top                expected=60 actual=64 (Δ4)  y=64 #ededed→#e5e5e5
------------------------------------------------------------------------------
summary: 32 passed, 1 failed, 0 skipped
```

## How it works

1. **Find the window.** `windowlist.swift` (compiled on first run into
   `$TMPDIR/devicehubpro-parity-helpers`) lists every on-screen window with its
   `CGWindowNumber`, owner, layer and bounds. The harness keeps owner
   `DeviceHubPro` (a `.build/debug` run; a packaged app is `Device Hub Pro`) at window layer 0 and picks the largest — the compact mirror
   floats on layer 3, so it is never selected. Override with
   `PARITY_WINDOW_ID=<id>`, which is looked up among every window whatever
   its owner (a renamed copy of the app has its own owner name); a window
   that is not listed needs `PARITY_SCALE`.
2. **Capture it.** `screencapture -x -o -l <id> <tmp>/window.png` (no shadow),
   so the capture's top-left is the window frame's top-left, title bar
   included.
3. **Scale.** Coordinates in `parity-reference.json` are **window points**;
   the harness computes `px/pt = captureWidth / windowWidth` from the capture
   and the window bounds, so 1x and Retina displays both work. A saved
   capture (`PARITY_IMAGE`) has no window: pass `PARITY_WINDOW_SIZE=WxH` or
   `PARITY_SCALE`, or it is read at 1 px/pt with a warning.
4. **Measure.** `pixscan.swift` evaluates every check (see below) and prints
   the per-check `PASS/FAIL expected=… actual=… (Δ…)` lines and the summary.
5. **Appearance.** `pixscan` samples background pixels and classifies the
   capture as `light` or `dark`. Checks tagged `"appearance": "light"`
   compare absolute colours; when the app renders dark they are reported as
   `SKIP` (with a note), never as failures. All geometry checks are tagged
   `"any"` and were verified in both appearances (see "Appearance" below).

## Prerequisites

* macOS with `swiftc`, `screencapture` and `sips`-class system tooling — no
  extra installs. The two helpers are compiled into `$TMPDIR` on first run.
* The app must be **running and on screen** (not minimised; a locked screen
  can make `screencapture` fail). Screen Recording permission is required by
  `screencapture -l`.
* The seeded geometry checks assume the **stock window**: currently
  `1920x985 pt` (full screen width), 300 pt sidebar and 300 pt inspector
  (`navigationSplitViewColumnWidth(ideal: 300)` and
  `inspectorColumnWidth(ideal: 300)`). The sidebar and inspector are
  user-resizable (272–320 / 260–360), and absolute x coordinates in the
  reference shift with them. A size mismatch prints a note; expect geometry
  failures.
* State-dependent checks (Apps card, tile, dividers, filter capsule) assume
  the **Apps inspector tab is open with at least one app row**, as in the
  audited captures. Colour checks (`"appearance": "light"`) additionally
  assume the documented light rendering.

## What the seeded checks verify

All values come from the audited docs; the description field in
`parity-reference.json` names the source (`SB-*`, `TB-*`, `PL-*`, `IN-*`).

| Check | Verifies |
|---|---|
| `toolbar-trio-origin` | Middle-trio first capsule left edge at x=1307 (TB-03) |
| `toolbar-leading-capsule-left/‑top/‑bottom` | +/menu capsule position and 36 pt band y≈8–44 (TB-01) |
| `toolbar-keyboard-capsule-top/‑bottom` | Middle-trio keyboard capsule 36 pt band |
| `sidebar-toggle-right` | 36 pt sidebar toggle right edge ≈8 pt before the sidebar edge (TB-02) |
| `sidebar-window-edge` | Sidebar column 300 pt (the visible tint step lands at 296 because the trailing ~4 pt split-divider zone is cleared to the window background) |
| `sidebar-search-height/‑left` | Search capsule 28 pt, side inset ≈10 pt (SB-01) |
| `sidebar-icon-left/top/right` | Row icon column at 16 pt, 32 pt circle at the audited rhythm (SB-02, 41 pt search→row) |
| `segmented-track-top/bottom/left` | Inspector segmented control: top 60 pt, bottom rim at 83.5 (24 pt tall), 9 pt side inset (IN-01); key window |
| `inspector-first-card-top` | First inspector card at y=94 (IN-02) |
| `apps-tile-left/right` | 26 pt app icon tile 14 pt in from the card edge (IN-03) |
| `apps-divider-left/right/width` | Row dividers: 52 pt text column, 10 pt trailing inset, 218 pt run (IN-03) |
| `apps-filter-height/‑bottom` | Bottom filter capsule 30 pt tall, 8.5 pt above the window bottom (IN-03) |
| `stage-pill-top/bottom` | Floating pill 36 pt tall with an 8 pt bottom inset (PL-02) |
| `sidebar-fill`, `canvas-fill`, `toolbar-band-fill` | Panel/background tones (`#ededed`, `#ffffff`) and the untinted toolbar band |
| `segmented-track-fill`, `segmented-pill-fill` | Inspector track `#e8e9ea`, selected pill `#d6d7d8` — DH's Liquid Glass control, key window (IN-01) |
| `app-card-fill`, `apps-filter-fill` | Card `#e5e5e5` / filter capsule `#e1e1e1` (IN-02/IN-03) |

## Controls inspector reference (CT checks)

`Scripts/parity-reference-controls.json` holds the **15 live checks for the
Controls inspector** (Device Hub's device-settings panel: card/row geometry,
group-header disclosure, glyph/label ink, switch metrics, fills) documented as
`CT-01…CT-09` in `ParityMetrics.swift`. The panel is organized into collapsible
domain groups (2026-09-20), so the prerequisite state is the **Network** card
at the top with every group expanded:

```bash
DHP_CONTROLS_EXPAND_ALL=1 .build/debug/DeviceHubPro &
PARITY_REFERENCE=Scripts/parity-reference-controls.json bash Scripts/parity-check.sh
```

`DHP_CONTROLS_EXPAND_ALL=1` starts every group expanded under a
harness-only persistence key (the user's saved layout is untouched), the
Controls inspector is open (toolbar sliders button) on a device whose first
card is Network (e.g. the Pixel 9 Pro Fold emulator), the panel is at the top
of its scroll and no sheet is up.

The value-popup and slider rows live in the collapsed-by-default
**Display & sound** group: collapse every group above it, expand Display & sound at
the top of the panel, take a 2x capture of the window and check it with

```bash
PARITY_IMAGE=<capture.png> PARITY_SCALE=2 \
  PARITY_REFERENCE=Scripts/parity-reference-controls-display.json bash Scripts/parity-check.sh
```

Expected values (Device Hub 27.0, 2x, window inactive — colours are key-state
equivalents) are in `Sources/DeviceHubProApp/ParityMetrics.swift`. Live colour checks read a few units
lighter while the window is not key; re-run with the app front before treating
a colour failure as a regression (geometry checks are key-independent).

## Reference JSON

`parity-reference.json` is one object: an informational `window` size plus a
`checks` array. Every check has `name`, `description`, `kind`, `appearance`
(`any` | `light` | `dark`), `expected` and `tolerance`, plus kind-specific
fields (coordinates in **window points**, measured from the capture's
top-left, title bar included):

| `kind` | Fields | Measures |
|---|---|---|
| `pixel-color-at-point` | `x`, `y`, `color` (`"#rrggbb"`) | The pixel's channel-max distance from `color`; `tolerance` is in 0–255 units |
| `color-run-width` | `axis` (`row`/`col`), `fixed`, `from`, `to`, `color`, `matchTolerance` (default 6) | Width of the longest contiguous run matching `color` |
| `edge-x` | `row`, `from`, `to`, `delta` (default 8), optional `relativeTo: "right"` | First x where the channel-max distance from the pixel at `from` reaches `delta` |
| `edge-y` | `col`, `from`, `to`, `delta`, optional `relativeTo: "bottom"` | First y with the same step rule (`from > to` scans upwards) |
| `band-height` | `col`, `from`, `to`, `delta` | Contiguous run of pixels differing from the pixel at `from` |

Edge/band checks are relative to the pixel they start from, which is why they
work in both appearances; prefer them over absolute colours. `relativeTo`
expresses the documented inset (`expected` counts from the window's bottom /
right edge).

### Adding a check

1. Measure candidates with the primitives:

   ```bash
   H="$TMPDIR/devicehubpro-parity-helpers"   # or compile: swiftc Scripts/pixscan.swift -o /tmp/pixscan
   "$H/pixscan" edge Scripts/../window.png row 28 1250 1350 10   # needs a capture; keep one with PARITY_KEEP=1
   "$H/pixscan" point <png> 700 5
   "$H/pixscan" band <png> col 150 40 110 4
   ```

2. Add the check to `parity-reference.json` with the documented expected value
   and a sensible tolerance, tag `"appearance"` honestly, then run
   `bash Scripts/parity-check.sh`. To inspect a saved capture instead of the
   live window, use `PARITY_IMAGE=<png> [PARITY_SCALE=2]`.

## Appearance (light/dark)

* Most geometry checks are relative edge/band scans and are tagged `"any"`.
  They were validated in dark mode by launching a second instance with
  `DHP_APPEARANCE=dark`, capturing its window and running the reference
  against that capture (`PARITY_IMAGE=... bash Scripts/parity-check.sh`).
* Colour checks are tagged `"light"` and are skipped with an explicit note
  when the app renders dark. If you add dark values, tag them `"dark"` (the
  harness runs whichever matches the capture).

## Known limits

* **The stale-build trap.** The harness measures the **running** app, not the
  source tree and not Xcode's latest build. Rebuild and relaunch before
  trusting a failure (or a pass).
* **One window.** With several same-size Device Hub Pro windows the harness takes
  the first/largest returned by `CGWindowList` (usually the frontmost). Use
  `PARITY_WINDOW_ID=<id>` to pin one; `windowlist.swift` prints IDs.
* **State matters.** The Apps checks need the Apps inspector tab with a
  visible row; the light colour checks need the documented light rendering.
  Switching sections moves the inspector content and invalidates them.
* **Stock geometry.** Absolute x coordinates assume the stock 300/300 pt
  sidebar/inspector split at the stock window size. Resize the panes and the
  x-values shift.
* **White-on-white edges.** Some light surfaces (the floating pill's rim)
  differ from the canvas by only a few levels; their `delta` values are
  intentionally small. If you raise them, these checks will report "no edge".
* **The 4 pt divider zone.** The sidebar's tint ends ~4 pt before the
  logical 300 pt column because the split divider is cleared to the window
  background; `sidebar-window-edge` documents this with a ±4 tolerance.
* **Locked screen / minimised window.** `screencapture` fails or captures the
  lock screen; the harness exits 2 with a message.
* **The `swiftc` build** happens on first run (cached in
  `$TMPDIR/devicehubpro-parity-helpers`, rebuilt when a helper source changes);
  add a few seconds for the first invocation.

## Files

| File | Purpose |
|---|---|
| `parity-check.sh` | Entry point: find → capture → evaluate → report |
| `parity-reference.json` | Audited values + tolerances, one entry per check |
| `windowlist.swift` | Lists on-screen windows (id/owner/name/layer/bounds/pid) |
| `pixscan.swift` | Pixel primitives (`size`, `point`, `run`, `edge`, `band`) and the check evaluator |
| `perf-check.sh` | Performance harness: fixed adb workload + stream/app/guest metrics vs `perf-reference.json` |
| `perf-reference.json` | Performance baseline (2026-09-24, MMAP) + regression tolerances, one entry per check |

## Motion probe (animation measurements)

`motion-probe.sh` is the animation counterpart of the pixel harness: it
records a window while an interaction runs and extracts the animation's
duration, motion window and velocity profile from the frames. The audited
Device Hub values live in
`Sources/DeviceHubProApp/MotionMetrics.swift` (pinned by `MotionMetricsTests`).

```bash
# record a window (by id, no focus theft; never raises the window)
bash Scripts/motion-probe.sh record "Device Hub" /tmp/dh-rotate.mov 5
bash Scripts/motion-probe.sh record Device Hub Pro /tmp/app-rotate.mov 5 <pid>

# analyze: per-frame change metric, motion window, velocity profile
bash Scripts/motion-probe.sh analyze /tmp/dh-rotate.mov --threshold 0.003
bash Scripts/motion-probe.sh analyze /tmp/app-rotate.mov --range 1.80,2.15 \
    --max-frames 8 --strip /tmp/strip.png

# list windows (front-to-back) with ids/pids
bash Scripts/motion-probe.sh list [owner]
```

| Helper | Purpose |
|---|---|
| `motion-frames.swift` | AVAssetReader frame analysis (change metric, motion window, velocity profile, strip/frame export); `--range start,end` isolates one animation when the guest re-renders later |
| `click-window.swift` | Posts a click **only when the target window is frontmost** (the parity skill's synthetic-input rule); supports `--right`, `--double`, `--hold ms` |
| `activate-app.swift` | Brings a running app's existing windows forward without `open -a`'s reopen-new-window behavior |
| `axdump.swift` | Dumps an app's accessibility tree (with the `AXEnhancedUserInterface` nudge) and performs `--press`/`--select` by substring; used for non-activating Device Hub interaction |

Synthetic-input rules still apply: verify the frontmost window first
(`click-window` does it for you), prefer AX actions, and capture with
`screencapture -l` (never raise the window).

## Native-build async ODR check

`check-async-odr.sh` guards against the toolchain bug behind the native-build
release crash ("freed pointer was not the last allocation";
`docs/native-build-async-odr.md`). It reads every object of a native-build
build and reports each weak async function pointer whose copies record
different context sizes. ld can pair such a pointer with a body that needs
more room, and that corrupts the task allocator. Swift Build is not exposed,
because it keeps each module's copies private.

```bash
bash Scripts/check-async-odr.sh --build   # native release build, then check
bash Scripts/check-async-odr.sh [objects-dir]
```

Exit status: `0` no mismatch, `1` at least one mismatch (listed with the
objects on each side), `2` usage/build error.

`async-odr-repro/repro.sh` is the minimal standalone reproducer. It uses two
Swift files at macOS 12.0 and 26.0 and one plain `swiftc` link, with no
packages. It shows the crash, then shows that the `Task.sleep(for:)` shim
(`-D WORKAROUND`) fixes it. Exit `0` means the crash reproduced and the
workaround ran.
