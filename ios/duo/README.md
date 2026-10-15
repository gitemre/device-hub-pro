# Daybreak

An iPhone Duo showcase for the simulator: open the phone and the sun rises. The hinge angle
is the time of day, from night on the closed cover through blue hour (Tent), sunrise
(Laptop) and golden hour (the half-open book) to noon flat open. It is one picture, a sky
over mountains and a still lake drawn in SwiftUI, that re-flows around the fold: the horizon
sits on the crease in a laptop, and the sun rises in the spine's valley in a book. The
postures' angles are the ones apps read at Device Hub Pro's presets (Closed 0°, Tent 71.1°,
Laptop 104.2°, Partially Open 127.8°, Open 180°), so it doubles as a visual check of the
fold pill and the stage.

The light comes from the angle only (`onHingeChange`), never from the hinge's status. The
layout comes from the window's division region (`GeometryProxy.reservedRegions(kind:
.division, options: .includeInactive)`), read in the layout pass and never stored. On the
cover a white clock shows the time; inside, a Liquid Glass deck shows the phase and the angle
and plays the **Time-Lapse** (night to noon and back over 16 s; moving the hinge more than 2°
or a second tap stops it). **Readings** shows the live hinge, window and region readings. On
an iPhone without a hinge a glass slider scrubs the day.

## Build and install

Apple silicon and the iPhoneSimulator 27.1 SDK or later (Xcode 27.1); the app runs on
iOS 27.1 or later. No Xcode project and no signing: the linker's ad-hoc signature is enough
for a simulator.

```sh
ios/duo/build.sh                                       # → .build/ios-duo/Daybreak.app
ios/duo/build.sh --install <UDID> --launch             # a default-set simulator
ios/duo/build.sh --install <UDID> --set <dir> --launch --no-build   # a private set
DEVELOPER_DIR=/Applications/<Xcode 27.1>.app/Contents/Developer ios/duo/build.sh
```

`build.sh` compiles `App/` and `Shared/` with the developer directory's own `swiftc`
(`$DEVELOPER_DIR`, else `xcode-select -p`; an SDK older than 27.1 is refused; Swift 6 mode,
`-target arm64-apple-ios27.1-simulator`; no xcrun, whose wrappers can run
`xcodebuild -runFirstLaunch`) and `Assets.xcassets` with its `actool` (without one, the app is
built without an icon). The linker is told the SDK's own version (`-Xlinker -platform_version
ios-simulator 27.1 <SDK version>`): left to itself it records the deployment target as the SDK,
and iOS 27.1 then showed such an app on iPhone Duo in a 375 × 667 compatibility window. With
`--install` it takes only a simulator UDID that `simctl list` shows in that set (never
`booted`, `all` or a physical device) and runs the real simctl binary (`DHP_SIMCTL` overrides
it). `ios/duo/build.sh --help` has the rest.

## Launch arguments

Arguments after `--` go to the app on `--launch`:

```sh
ios/duo/build.sh --install <UDID> --launch -- --log-readings --time-lapse-after 3,9
simctl get_app_container <UDID> com.devicehubpro.duo data   # + /Documents/readings.jsonl
```

- `--log-readings` appends one JSON object per line to `Documents/readings.jsonl` and to the
  unified log (subsystem `com.devicehubpro.duo`, category `readings`): `app.launch`, every
  `hinge` callback, each `layout` change (size, size classes, safe area, regions, layout,
  bar edge), `phase` changes, `hinge.none`, `timeLapse.start` / `timeLapse.stop`, and once a
  second `frames` (frames the main thread delivered, `hitches` and `dropped` frames, the
  `longestMs` frame, the angle the sky showed or was easing to, `busyMs` the main thread spent
  outside its run loop's wait, and `busyHitches`, the hitches during which it was busy for more
  than a frame; in the others it waited for a frame the system did not deliver), with a `stall`
  line (and its `busyMs`) for any frame 100 ms or more late. During a Time-Lapse the deck, the
  phase and the Readings follow its angle ten times a second; the sky works it out every
  frame. Every line carries `t` (ISO 8601, UTC), `up` (milliseconds since launch) and `kind`;
  each launch starts with `app.launch`, and earlier launches' lines stay.
- `--time-lapse-after <seconds>[,<seconds>…]` toggles the Time-Lapse at those times after
  launch, as its button does (logged with `"reason": "launchArgument"`), so a check can play
  and stop it without touching the screen.

```json
{"dtMs":null,"kind":"hinge","n":1,"new":{"deg":127.8,"status":"partiallyOpen"},"old":null,"t":"2026-10-15T14:42:21.029Z","up":516}
{"angle":127.8,"from":null,"kind":"phase","source":"hinge","t":"2026-10-15T14:42:21.029Z","to":"goldenHour","up":516}
```

## Measured on iOS 27.1 (Xcode 27.1 RC)

On the iPhone Duo simulator, Xcode 27.1 RC (27A9275), driven by Device Hub Pro's fold pill,
2026-10-15.

| Posture | Angle apps read | Window | Sky |
|---|---|---|---|
| Closed | 0° | cover, 678 × 466 or 466 × 678 | night |
| Tent | 71.1° | cover, 678 × 466, landscape left | blue hour |
| Laptop | 104.2° | inner, 669 × 951, portrait | sunrise |
| Partially Open (book) | 127.8° | inner, 951 × 669, landscape left | golden hour |
| Open | 180° | inner, 951 × 669, or 669 × 951 turned | noon |

- **Status is not the posture.** Tent reads `closed` at 71.1°, and slow steps on the cover
  read `closed` up to 124° with the app still on the cover. The app takes the time of day
  from the angle only.
- **The hinge.** `onHingeChange` first fires with `old.hinge == nil`, 0.35–2.6 s after
  launch over nine launches. It repeats values at rest and gives 26–30 updates a second
  during a preset's sweep. Apps read a sent angle as 5 + angle × 170 / 180; only 0° and 180°
  snap.
- **Windows.** The cover is compact width; the inner windows are regular. A move between the
  panels is not animated: SpringBoard covers it with a snapshot and a fade of about a second,
  so the scene is simply right when it shows.
- **The division band.** It is 40 pt wide, 20 pt either side of the hinge line at 475.5:
  455.5,0,40,669 in the book, 0,455.5,669,40 in the laptop. Flat open it is inactive and
  only returned with `.includeInactive`; `isActive` lags the posture by 0.02–2 s, so nothing
  is drawn from it. After a move to the cover, a pass or two report stale regions, some of
  them active (182.5,0,40,669 or 455.5,−203,40,669 in the 678 × 466 window). The app uses a
  region only in a regular-width window, inside its bounds and across it.
- **In the laptop** the top half of the 669 × 951 window is the standing lid and the bottom
  half the base: the horizon sits on the crease, and the deck and Readings sit on the base.
- **The vertical bar.** Toolbar items with `.axisBehavior(.verticalPreferred)` join a
  vertical bar beside the status bar, 84 pt of safe area on its edge: trailing on the
  portrait cover, in Tent and in the wide inner window, leading on the cover turned the
  other way. The tall inner window has top and bottom bars instead (`toolbarVerticalEdge`
  nil, 82 pt of safe area at the top and the bottom).
- **Arrangements.** `ArrangementView`'s `.overlay` showed only the primary pane, and `.split`
  crossed the fold in the laptop; the app lays out from the division region instead.
- **The cover stays lit.** Device Hub Pro counts a panel as lit from its brightness, so the
  cover keeps its white clock at night.

## Tests

`Shared/` (the day cycle, the palette, the fold layout, the ridges, the hinge rules, the
Time-Lapse's day and the control areas) is Foundation only and runs on the Mac against the
regions and safe areas the Duo simulator reported:

```sh
swift test --filter DaybreakTests
```

## Icon

`Icon/make-icon.swift` draws `Assets.xcassets/AppIcon.appiconset/AppIcon.png`
(`swift ios/duo/Icon/make-icon.swift <out.png>`).
