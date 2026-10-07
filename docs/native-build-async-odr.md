# Native-build release crash: mismatched async function pointer

A release build from SwiftPM's native build system
(`swift build -c release --build-system native`) aborted about a second
after launch, even when it ran unpackaged from `.build`:

```
freed pointer was not the last allocation
```

The abort came from `swift_task_dealloc`, called in a child task under
`Task.sleep(for:)`. It happened in `ProcessRunner.run`'s timeout race
(`DeviceHubPro-2026-09-25-020228.ips`) and also in the first-frame timeout of
`DeviceWatcher.runTrackDevices`. Every `Task.sleep(for:)` in the app was affected. The
Swift Build (default) debug and release builds did not crash.

**The cause is a toolchain bug, not a concurrency bug in our code.** The
task groups, continuations and cancellation handlers are correct. The
program was miscompiled: the caller allocated a 112-byte async context for
a function body that uses 128 bytes.

Toolchain: Apple Swift 6.4 (swiftlang-6.4.0.34.1), Xcode's ld, macOS 27.0 SDK.

## Root cause

1. `Task.sleep(for:)` and `Clock.sleep(for:)` are `@_alwaysEmitIntoClient`.
   So every module that calls them at `-O` emits its own copy of the
   specialization
   `$ss5ClockPsE5sleep3for9tolerancey8DurationQz_AGSgtYaKFs010ContinuousA0V_Tg5`
   (`Clock.sleep(for:tolerance:)` for `ContinuousClock`). Swift gives the copy
   weak, hidden linkage (*weak private external*), on the assumption that
   every copy is identical. It emits the copy's **async function pointer**
   (AFP, suffix `Tu`) as a second weak symbol. The AFP holds the size of the
   context that callers allocate for the function.
2. The copies are **not** identical. Their code depends on the deployment
   target. Our targets built at macOS 15.0 when this was found, and build
   at 26.0 now (see "Deployment target 26.0" below). grpc-swift-nio-transport
   (`GRPCNIOTransportCore/Subchannel.swift`) and swift-service-lifecycle
   (`ServiceLifecycle/ServiceGroup.swift`) build at their own macOS 12.0.
   The macOS 12 copy needs a **112-byte** context. The macOS 15 copy (13.0,
   14.0 and 26.0 give the same code) needs **128** bytes: the error is
   spilled at offset `0x70`.
3. The native build system links every module's per-file objects straight
   into the executable, so the weak copies from all four modules get merged.
   ld chooses **the body and the AFP separately**. For the body it took the
   first copy (`AppModel.swift.o`). For the AFP it took the more aligned copy
   (`Subchannel.swift.o`, whose AFP sits on a 16-byte boundary). The
   `-map` output shows the split:

   ```
   0x1000A6B60  0x9C  [  10] _$ss5ClockPsE5sleep3for...ContinuousA0V_Tg5     (AppModel.swift.o, needs 128)
   0x100DA0BB0  0x08  [1381] _$ss5ClockPsE5sleep3for...ContinuousA0V_Tg5Tu   (Subchannel.swift.o, says 112)
   ```

4. Every call therefore got a 112-byte context from the task allocator, and
   the 128-byte body stored the error register at `[ctx + 0x70]`, 8 bytes
   past the end. The task allocator is a LIFO stack. Each allocation is
   preceded by a header whose first word links to the previous allocation.
   The body's own temporaries are allocated right after its context, so the
   overrun overwrote their header's link. When the callee released those
   temporaries, the allocator's top pointer came back corrupted. The
   caller's `swift_task_dealloc(ctx)` then failed the LIFO check and the
   runtime aborted.

**Swift Build is unaffected.** Both build systems compile with the same
flags (`-O -whole-module-optimization -num-threads 12`, our targets at
macOS 15.0 then and 26.0 now, dependencies at 12.0). The difference is the
link. Swift Build first links each module into a single object (`ld -r`,
one per module), and that turns the hidden weak copies into local symbols
(`nm -m`: *non-external (was a private external)*). Each module keeps its
own consistent body and AFP pair, and nothing is merged across modules. The
Swift Build release binary has four separate copies. Xcode builds packages
with the same engine (Swift Build), so an Xcode release build should behave
the same way. That was not tested separately; `check-async-odr.sh` reads
only native-build objects.

### Evidence

- Crash reports: the faulting frame is the caller's resume function
  `closure #2 in closure #1 in ProcessRunner.run` (line 104) calling
  `swift_task_dealloc` on the callee context, right after the specialized
  `Task.sleep` returned. A fresh native release build crashes the same way
  under `DeviceWatcher.runTrackDevices` (line 199).
- Disassembly of the chosen body (`…Tg5TQ1_`): `str x20, [x23, #0x70]`,
  against an AFP whose context size is `112` (`0x70`).
- AFP sizes in the four defining objects: `AppModel.swift.o` 128,
  `AdbClient+WirelessPairing.swift.o` 128, `Subchannel.swift.o` 112,
  `ServiceGroup.swift.o` 112. Of the 931 weak async function pointers in the
  build, this is the only one whose copies disagree
  (`Scripts/check-async-odr.sh`).
- Linking the same objects in another order (the macOS 12 objects first, or
  ours last) keeps the body and the AFP from one object, and the mismatch
  goes away. The crash is therefore not in any source line. It is decided by
  link order and by where each AFP happens to be aligned.

## Minimal reproducer

`Scripts/async-odr-repro/repro.sh` needs no packages and no SwiftPM. It uses
two files and one plain link:

- `LibA.swift`, built `-O -wmo -target arm64-apple-macosx12.0`: calls
  `Task.sleep(for:)`. It also carries a SIMD constant, which makes its
  `__TEXT,__const` 16-byte aligned and puts the AFP on a 16-byte boundary.
- `main.swift`, built `-O -wmo -target arm64-apple-macosx26.0` (the app's
  deployment target; it was 15.0 when this was found): calls
  `Task.sleep(for:)`.
- `swiftc main.o LibA.o` gives body `[1] main.o` and AFP `[2] LibA.o`, and
  the program aborts with *freed pointer was not the last allocation*
  (exit 134). The same file built with `-D WORKAROUND` runs.

```bash
bash Scripts/async-odr-repro/repro.sh    # exit 0 = reproduced + workaround runs
```

## Workaround in our code

`Sources/DeviceHubProKit/Internal/TaskSleep.swift` adds a non-generic
`package static func Task.sleep(for: Duration)`. Overload resolution prefers
a non-generic function over the standard library's generic
`sleep(for:tolerance:clock:)`, so every existing and future
`Task.sleep(for:)` in DeviceHubProKit, DeviceHubProApp and their tests now goes to
it, with no call-site changes. It calls
`ContinuousClock().sleep(until: .now + duration, tolerance: nil)`. That
function lives in the runtime and is not emitted into client modules. This
is what the standard library's version does after inlining, so timing and
cancellation behave the same (`TaskSleepTests`).

With it, our modules emit no copy of the specialization. The copies that
remain come from the two macOS 12 dependencies and agree (112 bytes), so any
body and AFP pair ld picks is consistent. This is a workaround, not a fix:
other `@_alwaysEmitIntoClient` async functions (`withTaskCancellationHandler`,
`withThrowingTaskGroup`, …) have copies in several modules too. Their sizes
agree today and ld splits some of them harmlessly.

**Keep the shim until the toolchain is fixed.** A sleep that bypasses it
brings the crash back. That includes `Task.sleep(for:tolerance:)`,
`Task.sleep(for:clock:)` and `someClock.sleep(for:)` on a `ContinuousClock`.
A generic helper specialized for `ContinuousClock` does too. To check a
native release build:

```bash
bash Scripts/check-async-odr.sh --build   # exit 1 lists any disagreeing AFP
```

## Verification (2026-09-25)

- Native release, before: aborts within ~1 s (`DHP_ADB=/usr/bin/false`),
  and the checker reports one mismatch (`Clock.sleep(for:)`, 112 vs 128).
- Native release, after: the checker finds no mismatch among 915 weak AFPs,
  and no object from DeviceHubProKit or DeviceHubProApp defines or references the
  specialization. The linked AFP (112) points at a macOS 12 body. The app
  stays up for 30 s.
- Native debug, after: no mismatch among 428 weak AFPs, and the app stays up
  for 30 s.
- Swift Build debug and release still stay up for 30 s. `swift test`
  passes with the live-device suites skipped: Kit 934 tests (3 skipped),
  App 402.

## Deployment target 26.0 (2026-09-25)

The app's minimum rose from macOS 15.0 to 26.0. The mismatch does not depend
on 15.0 in particular: 13.0, 14.0, 15.0 and 26.0 all compile the
specialization with a 128-byte context, and the two dependencies still build
at their own 12.0. Checked with Apple Swift 6.4 and the macOS 27.0 SDK:

- `Scripts/async-odr-repro/repro.sh`, with `main.swift` at 26.0: the checker
  reports the same mismatch (112 vs 128), the linked program aborts with
  *freed pointer was not the last allocation* (exit 134), and the
  `-D WORKAROUND` build runs.
- `Scripts/check-async-odr.sh --build` (native release build of the app at
  26.0): no mismatch among 1016 weak AFPs in 2938 objects. `AppModel.swift.o`
  (minos 26.0) defines no copy of the specialization; `Subchannel.swift.o`
  (minos 12.0) and `ServiceGroup.swift.o` still do.

So the shim stays until the toolchain is fixed.

## Upstream report

A Swift bug report is warranted, against the compiler (IRGen/linkage), with
`Scripts/async-odr-repro` attached. Summary for the report:

> A specialization of an `@_alwaysEmitIntoClient` async function is emitted
> as `linkonce_odr hidden` in every module that uses it, together with a
> separately coalescible async function pointer that carries the context
> size. Modules built at different deployment targets (macOS 12 vs 13+,
> here `Clock.sleep(for:)` for `ContinuousClock`) produce copies that need
> different context sizes. When the objects are linked together without a
> per-module `ld -r` (SwiftPM `--build-system native`), ld can take the body
> from one object and the AFP from another. The context is then too small,
> and the task allocator is corrupted: "freed pointer was not the last
> allocation". The ODR assumption does not hold across deployment targets.
> The AFP should be tied to its body (or the context size should not depend
> on per-module codegen), or such specializations should not be shared
> across modules.
