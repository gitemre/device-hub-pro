# Performance harness

`Scripts/perf-check.sh` measures the **running** Device Hub Pro app, its emulator and
the live mirror stream, then compares the numbers against
`Scripts/perf-reference.json`. Like the pixel-parity harness it builds nothing
and changes no project files; it drives a fixed adb workload and reports
PASS/FAIL/SKIP with the same exit codes (0 pass, 1 fail, 2 harness error).

```sh
# app running, a mirrored host-GPU emulator selected, launched with
# DHP_PERF_LOG=<path> so the stream checks have data:
DHP_PERF_LOG=/tmp/devicehubpro-perf.jsonl .build/debug/DeviceHubPro

bash Scripts/perf-check.sh workload   # fixed workload + stream/app/guest metrics
bash Scripts/perf-check.sh launch     # cold-launch timing (restarts the app)
bash Scripts/perf-check.sh idle       # 30 s idle CPU/memory
bash Scripts/perf-check.sh soak       # 10 min memory soak (PERF_SOAK_SECONDS)
bash Scripts/perf-check.sh all        # launch -> workload -> idle -> soak
```

Useful overrides: `PERF_SERIAL`, `PERF_WINDOW_ID` (pin one of several app
instances), `PERF_PERF_LOG` (must match the app's `DHP_PERF_LOG`),
`PERF_REFERENCE`, `PERF_APP_BINARY`, `PERF_LAUNCH_RUNS`, `PERF_SOAK_SECONDS`,
`PERF_KEEP=1`.

The app side is a single opt-in hook: with `DHP_PERF_LOG` set,
`MirrorController.startStatsPolling` appends one JSON line per stats poll
(`{t, device, fps, frames, dropped, latencyMs}`) through the Kit's
`PerfLogWriter` (`Sources/DeviceHubProKit/Diagnostics/PerfLog.swift`). `device` is
the workspace's mirrored `DeviceRef.id` (an adb serial or a simulator UDID),
so multiple windows mirroring different devices (`DHP_MULTIWINDOW=1`)
can log to the same file and still be read apart — `stream_stats` in
`Scripts/perf-check.sh` filters rows by `device` before computing the frames
delta, since two devices' monotonic counters interleaved would corrupt it.
Unset, logging costs nothing. The same stats line is available live via
the debug HUD launched with `DHP_SHOW_MIRROR_STATS=1` (our own; it had a View menu item until the menu bar followed Device Hub's; the values come from the
Kit's `StreamStatsCounter`).

Two simultaneous devices' perf bounds (workload CPU/memory/fps/latency per
device, side by side) have not been measured live yet — pending a run with
two attached devices; see "Open" below.

## Reference (2026-09-24, MMAP default)

Measured with the harness on macOS 27 arm64: Pixel 9 Pro Fold AVD on the
canary emulator **37.2.8** started with `-gpu host -qt-hide-window`, debug
build, no transport variables set (so the default MMAP path). This is what
`Scripts/perf-reference.json` now expects; the bounds are tight enough that a
fall back to raw frames, a software-rendering emulator or the audio regression
below fails at least one check.

| Check | Measured | Bound | Notes |
|---|---|---|---|
| emulator-gpu-host | 1 | =1 | precondition: the qemu command line carries `-gpu host` |
| stream-fps-peak | 60.1 fps | ≥54 | raw frames on 37.2.8 peak at 53 |
| stream-dropped-pct | 0 % | ≤3 % | raw frames drop 12–18 % |
| stream-latency-ms | 7.1 ms | ≤12.1 ms | frame timestamp → render; raw 27–28 ms |
| app-cpu-mean-pct | 21.9 % | ≤30 % | one core = 100 %; raw 41 % |
| app-footprint-mb | 390 MB | ≤520 MB | post-workload; raw 37.2.8 measured 829 MB |
| guest-frame-p50-ms | 17 ms | ≤23 ms | guest launcher `dumpsys gfxinfo` |
| guest-janky-pct | 8.4 % | ≤16.4 % | guest-side rendering is healthy |
| idle-cpu-mean-pct | 5.6 % | ≤8 % | 30 s idle, mirror attached, in-app audio on (see below) |
| launch-median-s | 0.5 s | ≤0.75 s | from the 2026-09-20 run; not re-measured |
| soak-footprint-growth-pct | 1 % | ≤9 % | from the 2026-09-20 run (raw transport); not re-measured |

The workload passed **8/8**. All bounds are one-sided, so a faster run
passes. On an emulator older than 37.2.3 (no MMAP) the stream and CPU checks
fail by design; to compare raw-frame runs, point `PERF_REFERENCE` at the
previous reference (`git show 4f528a2:Scripts/perf-reference.json`), which
holds the 2026-09-20 raw baseline below.

### Idle CPU and in-app audio

The first idle run on this build measured **15.9 %** app CPU against the old
3 % expectation. Time Profiler put most of it in the in-app audio path
(Settings ▸ Emulator ▸ Audio ▸ In-app), which runs for every 10 ms chunk the
emulator streams, silence included. `239411c` keeps the engine's running state
instead of asking the output device over IPC per chunk, converts samples with
vDSP and drops all-zero chunks before they reach the main actor. Idle then
measured **5.6 %**; what remains is decoding the gRPC audio stream. With the
default audio mode (the emulator plays its own sound) the app does not stream
audio at all.

### Software GPU is an environment artifact

An emulator started with `-no-window` and no `-gpu` flag renders in software.
In that configuration the same workload measured a guest frame p50 of
**93 ms** and a stream peak of **26.6 fps** — the emulator's own frame rate,
not the app's. The harness's `emulator-gpu-host` check fails such a run (it looks
for `-gpu host` on the qemu command line), and the reference's stream-fps and
guest-frame bounds fail it too. The app itself always launches emulators with
`-gpu host` (`EmulatorManager.swift`).

## Transport default (decided 2026-09-24, `db5626f`)

MMAP is the default emulator transport. `MirrorSession.start()` negotiates it
whenever the emulator is 37.2.3 or newer (`EmulatorVersion.supportsMMAP`;
older engines crash on it) and falls back to raw frames by itself for the
rest of the session when the frame file cannot be created, the frame does not
fit the 64 MB buffer, the emulator never writes the buffer, or three streams in
a row end before a written mapped frame arrives (`MirrorVideo.RetryState`). The
protocol's tearing warning is handled in the Kit: the first frame and every
geometry change come from a consistent screenshot, and on a static screen a
watchdog compares the last frame with one and repairs a torn frame. The frame
files live in a `0700` `devicehubpro-mirror` folder of the per-user temporary
directory, are `0600`, are removed when a stream ends and are swept after a
crash; the world-readable `/tmp/devicehubpro-mirror-*.raw` files of older builds
are removed on the first MMAP stream.

Environment switches (neither bypasses the version gate):

| Variable | Effect |
|---|---|
| `DHP_DISABLE_MMAP=1` | Escape hatch: raw frames only. Also how to measure the raw path on a 37.2.3+ emulator. |
| `DHP_FORCE_MMAP=1` | Allows MMAP even for a caller that asked for raw frames (`start(allowMMAP: false)`). |

## Rendering pipeline (2026-09-24)

The app-side mirror path was reworked in the same round; each change moves
work off the main thread or removes it:

- **Zero-copy physical frames.** The scrcpy decoder's `CVPixelBuffer` travels
  through `FrameStore` and is wrapped with `CVMetalTextureCache` as a
  `.bgra8Unorm` texture (measured 0.001 ms). The old path swizzled each frame
  into a new RGBA `Data` (0.13–0.17 ms and a 15 MB buffer per 1280×2856 frame)
  and then copied it with `texture.replace` on the main thread. RGBA bytes are
  now made once, lazily, only for replay and capture.
- **Emulator uploads off the main thread.** Frames are copied on a private
  `userInteractive` queue into a ring of at most **3 textures** with per-texture
  in-flight counts released by the command buffer's completion handler;
  textures are reallocated only when the size changes. This moves about
  0.8 ms per frame per view (0.69 ms hot, 0.78 ms cold on an M4 Pro at
  1280×2856) off the main thread and removes the race with a texture the GPU
  is still sampling.
- **Draw on demand.** The `MTKView` is paused; a new frame, a layout, backing
  or presentation change triggers one draw. A static screen causes no draws
  (the old display link woke the main thread 60 times a second per view).
- **One shader pipeline per process.** `MirrorRenderPipeline` compiles the
  shaders once, off the main thread (a cold compile measured 170 ms for the
  library plus 23 ms for the pipeline), and a failure is shown in the mirror
  instead of a silently blank view.
- **Pooled feed buffers.** The replay ring and the host-side recorder share
  one RGBA→BGRA conversion per frame into a `CVPixelBufferPool`
  (`BGRAPixelBufferPool`), instead of allocating an IOSurface-backed buffer per
  frame; the feed runs only while one of them consumes frames.

- **Replay ring on a simulator (2026-10-05).** A simulator on the live canvas
  now feeds the same ring as an Android mirror: its BGRA frames are scaled once
  (`vImageScale_ARGB8888`, straight from the session's buffer when nothing
  records) to fit 1080 × 1920, then hardware-H.264 encoded at 15 fps with a
  keyframe at least every 1-2 s; the encoded ring is bounded in time (the
  Settings window) and in bytes (`ReplayBuffer.memoryBoundBytes`, about
  0.1 bit/pixel/frame x window x 1.25). The feed pauses while the stage is
  hidden or occluded (unless a recording runs) and only encodes frames that
  are new, so a static screen costs nothing. The view-only canvas (one frame a
  second) and physical iPhones keep no ring. Measured live: 58 frames over
  4.5 s at 884 × 1920 retained 1.2 MB on a mostly static home screen; CPU was
  not profiled separately (expect the Android ring's ~0.2 %, plus the scale).

Scrolling, gallery previews and logcat filtering were also moved off the main
thread or made incremental in this round (see `CHANGELOG.md`).

## Earlier baseline (2026-09-20, raw transport)

Stock configuration then: emulator **36.6.11** (SDK stable) with `-gpu host`,
the **raw gRPC transport**, Pixel 10 Pro (1280×2856). 36.6.11 predates the
emulator's MMAP fix, so the version gate keeps the app on raw frames there.

| Check | Baseline | Bound then | Notes |
|---|---|---|---|
| stream-fps-peak | 32 fps | ≥22 | peak 1 s stream fps during the workload |
| stream-dropped-pct | 18 % | ≤26 % | seq gaps; the raw transport is the limiter |
| stream-latency-ms | 28 ms | ≤38 ms | frame timestamp → render |
| app-cpu-mean-pct | 41 % | ≤53 % | one core = 100 % |
| app-footprint-mb | 500 MB | ≤650 MB | post-workload; idle floor ~200-360 MB (allocator churn) |
| guest-frame-p50-ms | 17 ms | ≤23 ms | guest launcher `dumpsys gfxinfo` |
| guest-janky-pct | 10 % | ≤18 % | |
| launch-median-s | 0.5 s | ≤0.75 s | process start → first on-screen window, 5 runs |
| idle-cpu-mean-pct | 3 % | ≤6 % | 30 s idle, mirror attached |
| soak-footprint-growth-pct | 1 % | ≤9 % | floors of the soak halves — **no leak** |

## Transport A/B (same AVD, same workload, 2026-09-20)

An early spike measured the transports on their own; this round
re-measured them through the full app with the harness, on the canary emulator
(37.2.8.0) that supports the shared-memory
transport, with `DHP_FORCE_MMAP=1` for the MMAP run (raw frames were
still the default then):

| Metric | raw (36.6.11) | raw (37.2.8) | **MMAP (37.2.8)** |
|---|---|---|---|
| stream fps peak | 32 | 53 | **60** |
| dropped | 18 % | 12 % | **0 %** |
| stream latency | 28 ms | 27 ms | **7.5 ms** |
| app CPU mean | 41 % | 41 % | **13.5 %** |
| app footprint | 500 MB | 829 MB | **204 MB** |

Visual tearing was checked with window captures taken during continuous fast
scrolling (8 captures, heavy motion): no streaked rows. This matches the S1
spike's acceptance ("pixel-perfect", tester accepted) and the emulator's own
fix release (MMAP is only attempted on emulator ≥ 37.2.3; on 36.6.11 it crashes
the engine, which is why `EmulatorVersion.supportsMMAP` gates it). The
2026-09-24 reference above differs from this MMAP column in device (Pixel 9
Pro Fold instead of Pixel 10 Pro), build and in-app audio, so its CPU and
footprint are higher; both runs are MMAP.

## Profile (CPU Profiler, 30 s workload, raw transport, 2026-09-20)

`xcrun xctrace record --instrument 'CPU Profiler' --attach <pid>` while the
harness workload runs. The profile is flat (no hot function above 3 %), so the
cost is scattered:

| Bucket | Share | What it is |
|---|---|---|
| gRPC/protobuf decode | 20.1 % | per-frame `Image` message (17.9 MB RGBA payload) through `ByteBuffer` |
| Swift runtime/alloc | 10.6 % | per-frame `Data` allocation, metadata caches, actor hops |
| GPU driver / texture | 3.6 % | `texture.replace` upload of the full frame (now on the upload queue, not the main thread) |
| MetalKit draw path | 0.5 % | |
| vImage/encoder/replay | 0.2 % | the replay feed is **not** a cost (hardware H.264 encode) |
| AppKit/SwiftUI | 0.1 % | the UI is not the cost |

So the raw transport's 17.9 MB/frame dominates, which is why raw frames are
transport-bound (32 fps, 18 % drops) while MMAP reaches the display rate. Two
further raw-transport ideas, both measured in the spike and not implemented:

- **RGB888 raw** (`--rgb888` in the spike): 13.4 MB/frame instead of 17.9,
  measured 47 fps vs 23 fps reception on the same emulator. Needs a 3→4 byte
  conversion before the Metal upload and the replay encoder; not a free win.
- **Adaptive stream size** (`ImageFormat.width/height`): the mirror renders at
  ~200 pt, native 1280×2856 is far more than shown; needs input coordinates
  scaled back to native (touches the input path).

## Performance code review (2026-09-20, updated 2026-09-24)

| Severity | Finding | Where |
|---|---|---|
| ~~High (product call)~~ Resolved | MMAP was never selected by default even on capable emulators; it is now the default behind the version gate with automatic raw fallback (`db5626f`, see "Transport default") | `Sources/DeviceHubProKit/Mirror/MirrorSession.swift` |
| ~~Medium (deferred)~~ Resolved | A fresh IOSurface-backed `CVPixelBuffer` per accepted replay frame; now one `CVPixelBufferPool` per frame size, shared with the recorder | `Sources/DeviceHubProApp/AppModel+FrameFeed.swift` |
| ~~Low~~ Resolved | `MirrorMetalView.draw`'s muddled early-return condition; the view now draws on demand from textures prepared off the main thread | `Sources/DeviceHubProApp/MirrorRenderer.swift` |
| ~~Low~~ Resolved | The replay feed polled while replay was disabled; the feed now runs only while the replay ring or a recording consumes frames (66 ms, 33 ms while recording) | `Sources/DeviceHubProApp/AppModel.swift` |
| ~~Not covered~~ Resolved | `PhysicalMirrorSession` (scrcpy) copied and permuted every frame, and its stream reader retained every streamed byte (about 1 MB/s); frames are now zero-copy and the leak is fixed (`ac5936d`) | `Sources/DeviceHubProKit/Scrcpy/` |
| Open | The 7 h soak (2026-09-19) ran on the gRPC path; a physical-device soak with a memory graph has not been recorded | — |
| Open | Two-device perf bounds: the perf log now carries a `device` field and `stream_stats` filters by it, but a live two-device workload run (per-device CPU ≤30 %, ≤520 MB, ≥54 fps, ≤12.1 ms) has not been measured — pending real hardware | — |
| Info | Guest-side rendering is healthy (p50 17 ms, 8–10 % janky); on raw frames the fps ceiling is the transport, not the emulator | — |

## Idle and hidden resource use

Expected effects, not yet measured live (no micro-measurement was run; the
tests pin the behaviour):

- **Logcat** (`LogcatController.setLogShown`): with no log view on screen in a
  visible window, the `adb logcat` child, the 400 ms poll and the 5 s package
  refresh stop; showing it again restarts the child with `-T <newest held
  timestamp>`, so history is continuous. The poll republishes the tail only when
  `LogcatStream.revision` changed, and the stream trims in chunks (at 1.25x
  capacity) instead of `removeFirst` per batch.
- **Clipboard**: the app-level Mac pasteboard poll reads `NSPasteboard` only
  while the app is active and some workspace has auto-sync on; the device to Mac
  gRPC poll pauses while the stage is hidden.
- **Hidden stage**: `FrameStore.isPaused` makes the emulator stream drop frames
  (MMAP: no per-frame copy of the mapped buffer) while the stage is hidden and
  nothing records; showing it again clears the flag and calls `resync()`. The
  stats poll slows 5x (it is also the health monitor, so it is not stopped) and
  the display-rotation poll pauses.
- **Controls poll**: language/time, colour filters, appearance and data saver are
  read when the device is new and then every 10 s; the fast rows stay at 2 s.
- **Caches**: simulator app icons and physical icon images are pruned to the
  listed apps; the physical apps list cache keeps the 4 most recent devices.
- **Physical screenshot**: the PNG is read and decoded off the main actor once,
  when it lands.

Not changed (audited, risky or not effective): zero-copy MMAP upload (the
emulator rewrites the mapped buffer during upload, which is the tearing the copy
exists to prevent); `malloc_zone_pressure_relief` (the header documents it as
releasing zone memory by `munmap`, says nothing about the large-allocation cache,
and a live trial showed no shrink); the 15 Hz media feed loop (the frame
observer would still need a timer for the retry of a dropped static frame and the
15/30 fps pacing).

## Known limits

- The harness measures the **running** app; rebuild and relaunch before
  trusting a failure (the stale-build trap from the parity harness applies).
- The stream checks need the app launched with `DHP_PERF_LOG` pointing at
  `PERF_PERF_LOG`; without it they SKIP.
- With several app instances on screen, pin `PERF_WINDOW_ID` (and `PERF_SERIAL`).
- Guest `gfxinfo` percentiles vary with emulator load; the workload is fixed
  but the guest bounds are intentionally loose.
- Idle CPU depends on the audio mode: the reference was measured with in-app
  audio on, the heaviest setting.
- The soak's footprint floor is robust to allocator churn but not to a
  concurrent profile; run `soak` alone.
- `launch` mode restarts the app (`PERF_APP_BINARY`) — pass the absolute path
  you launched it with so the kill matches.
