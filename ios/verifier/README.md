# Device Hub Pro iOS verifier

A one-page iOS app that shows one live row per Device Hub Pro Controls row it can observe,
read through the APIs any app uses (SwiftUI's environment, `UIAccessibility`,
`CLLocationManager`, `LAContext`, `UIPasteboard`, the frameworks' authorization
statuses, …). Change a setting on the simulator (from Device Hub Pro, simctl or devicectl) and
the matching row flips, flashes and stamps its change time. It is the iOS twin of
[`android/verifier`](../../android/verifier/README.md).

It reads and displays; it never changes a setting on the device. Its only actions are
its own prompts: Authenticate (a Face ID / Touch ID match this app asks for) and Allow
(its own location permission, while undecided).

Every change is also written to `Documents/readings.json` in the app's data container,
so a test on the Mac can read the round trip back:

```sh
simctl get_app_container <UDID> com.devicehubpro.verifier data   # + /Documents/readings.json
```

```json
{
  "bundle" : "com.devicehubpro.verifier",
  "launchedAt" : "2026-09-26T14:31:17.861Z",
  "rows" : {
    "display.appearance" : {
      "changedAt" : "2026-09-26T14:32:01.410Z",
      "changes" : 1,
      "observes" : "effect",
      "raw" : "dark",
      "title" : "Appearance",
      "value" : "Dark"
    }
  },
  "schema" : 1,
  "system" : "iOS 27.0 · iPhone18,1 simulator",
  "writtenAt" : "2026-09-26T14:32:01.412Z"
}
```

`value` is the row's text; `raw` is a stable token in the writer's own words (simctl's
appearance and content size names, `lat,lon` with five decimals, a language tag, a zone
identifier, `12`/`24`, a count); `changedAt` is absent until the row changes after launch.

## Build and install

Apple silicon, Xcode 27 (the iOS 26 SDK or later). No Xcode project and no signing: the
linker's ad-hoc signature is enough for a simulator.

```sh
ios/verifier/build.sh                                 # → .build/ios-verifier/DeviceHubProVerifier.app
ios/verifier/build.sh --install <UDID> --launch       # a default-set simulator
ios/verifier/build.sh --install <UDID> --set <dir> --launch --no-build   # a private set
```

`build.sh` compiles `App/` and `Shared/` with the developer directory's own `swiftc`
(`$DEVELOPER_DIR`, else `xcode-select -p`; `Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
-sdk <Platforms/iPhoneSimulator.platform/…/iPhoneSimulator.sdk> -parse-as-library -target
arm64-apple-ios26.0-simulator`, Swift 6 mode; no xcrun, whose wrappers can run
`xcodebuild -runFirstLaunch`), copies `Info.plist` and checks the linker signature. With `--install` it
takes only a simulator UDID that `simctl list` shows in that set (never `booted` or
`all`, never a physical device), runs the real simctl binary (`DHP_SIMCTL`
overrides it; never the xcrun wrapper), installs, grants the location permission
(`simctl privacy <UDID> grant location com.devicehubpro.verifier`) and, with `--launch`,
relaunches the app. `build.sh` never installs onto a physical iPhone.

### Starting Authenticate without touching the screen

`simctl launch --terminate-running-process <UDID> com.devicehubpro.verifier --authenticate-after <seconds>`
makes the app start its Authenticate action once that delay is over (used by
`BiometricWaitLiveTests`, which presses "Matching" before the prompt exists).

### A signed build for the test iPhone

```sh
ios/verifier/build.sh --device --profile <profile> --identity <SHA-1> [--out <dir>]
```

`--device` builds `DeviceHubProVerifier.app` for iPhoneOS (`swiftc -sdk <iPhoneOS.sdk> -target
arm64-apple-ios26.0`, `CFBundleSupportedPlatforms` iPhoneOS, `DTPlatformName` iphoneos),
embeds the provisioning profile given by `--profile` as `embedded.mobileprovision` and signs
the bundle with the keychain identity given by `--identity` (the 40-hex SHA-1 of an Apple
Development certificate). The entitlements are derived from that profile and written outside
the bundle: `application-identifier` (`<TEAM>.com.devicehubpro.verifier`),
`com.apple.developer.team-identifier` and `get-task-allow`. It refuses to run without both
options, with `--install`, `--set`, `--launch` or `--no-build`, and when the profile is unreadable,
expired, not a development profile or does not cover the bundle identifier. It prints neither the
team nor the identity. Installing the app is a separate step; `DevicectlPhysicalClient.installApp`
does it for the dedicated test iPhone, and `ApplePhysicalLiveTests` runs the round trip when
`DHP_IOS_DEVICE_VERIFIER_APP` names the built app (install, launch, copy
`Documents/readings.json` out of the container, terminate, screenshot).

## Rows

Sections follow Device Hub Pro's groups. Tags: **Effect** rows read what an app sees;
**Note** rows say that nothing an app can read changes and show what apps see instead.
There are no Key value rows yet (an iOS app cannot read another domain's preferences).
Round trips were measured on an iPhone 17 Pro, iOS 27.0, Xcode 27.0 (27A266a), from the
command's start to the reading (`IOSVerifierLiveTests`, 2026-09-26).

| Row (id) | Observes | How to change it | Round trip |
|---|---|---|---|
| Appearance (`display.appearance`) | `colorScheme` | `simctl ui <UDID> appearance dark` · devicectl `settings appearance --mode dark` | 0.35 s · 0.17 s |
| Text Size (`display.textSize`) | `dynamicTypeSize` | `simctl ui <UDID> content_size extra-extra-large` · devicectl `--text-size extra-large` | 0.33 s · 0.18 s |
| Reduce Motion (`display.reduceMotion`) | `accessibilityReduceMotion` | devicectl `--reduce-motion on` | 0.18 s |
| Liquid Glass (`display.liquidGlass`) | Note: no API tells an app the opacity; the row always reads `unreadable` | devicectl `--liquid-glass-opacity 0.8` (read back with `info appearance`) | — |
| Reduce Transparency (`display.reduceTransparency`) | `accessibilityReduceTransparency` | devicectl `--reduce-transparency on` | 0.17 s |
| Show Borders (`display.showBorders`) | `accessibilityShowButtonShapes` (iOS Button Shapes) | devicectl `--show-borders on` | 0.17 s |
| Sound (`display.sound`) | `AVAudioSession.outputVolume` | devicectl `settings audio --volume 70` | 0.98 s |
| VoiceOver (`accessibility.voiceOver`) | `accessibilityVoiceOverEnabled` | devicectl `settings voiceover --enable` | 1.46 s |
| Color Filter (`accessibility.colorFilter`) | `UIAccessibility.isGrayscaleEnabled` (only grayscale is readable) | devicectl `--color-filter on --color-filter-type grayscale` | 0.19 s (protanopia: no change) |
| Increase Contrast (`accessibility.increaseContrast`) | `colorSchemeContrast` | `simctl ui <UDID> increase_contrast enabled` · devicectl `--increase-contrast on` | 0.35 s · 0.17 s |
| Location (`location.lastFix`) | `CLLocationManager` | `simctl location <UDID> set 37.33,-122.03` | 0.41 s |
| Orientation (`sensors.orientation`) | `UIDevice.orientation` (devicectl's pose names: `faceUp`, `landscapeLeft`, …) | devicectl `orientation set landscapeLeft` | 0.17–0.42 s |
| Biometrics (`advanced.biometrics`) | `LAContext` type and enrolment; Authenticate shows the last match | devicectl `settings biometrics --enable`; `simulate biometrics --success` while Authenticate waits | 0.81 s (enrolment) |
| Language (`languageTime.language`) | `Locale.preferredLanguages`, layout direction | `simctl spawn <UDID> defaults write -g AppleLanguages -array ar-EG`, then relaunch the app | 1.64 s |
| Time zone (`languageTime.timeZone`) | `TimeZone.autoupdatingCurrent` | `SIMCTL_CHILD_TZ=Asia/Tokyo simctl boot <UDID>` (a reboot) | 15.2 s |
| 24-hour time (`languageTime.timeFormat24`) | the locale's `j` hour pattern | `simctl spawn <UDID> defaults write -g AppleICUForce24HourTime -bool true` (or `…12HourTime`), then `simctl spawn <UDID> notifyutil -p AppleTimePreferencesChangedNotification` | 0.99 s, live |
| Clean status bar (`statusBar.batteryLevel`, `statusBar.batteryState`) | Note: `UIDevice` battery stays -1 / unknown | `simctl status_bar <UDID> override --time 9:41 --batteryLevel 100 --batteryState charged` (the Clean status bar switch) changes only the drawing | — |
| Memory warning (`appConditions.memoryWarning`) | `didReceiveMemoryWarningNotification` count | bump the modification time of `<device>/data/var/run/memory_warning_simulation` (`SimulatorDebugActions.simulateMemoryWarning`); devicectl `process sendMemoryWarning --pid <pid>` answers success, yet no warning arrives | under 1 s |
| Slow Animations (`display.slowAnimations`) | completion time of a 0.1 s `UIView` animation, timed every 2 s (over 0.3 s is slow) | `simctl spawn <UDID> notifyutil -s com.apple.UIKit.SimulatorSlowMotionAnimationState 1 -p com.apple.UIKit.SimulatorSlowMotionAnimationState` (`0` turns it off) | up to 2 s |
| Push notification (`appConditions.push`) | `UNUserNotificationCenterDelegate.willPresent` | `simctl push <UDID> com.devicehubpro.verifier payload.json` | 0.42 s |
| Permissions (`appConditions.permissions`) | nine frameworks' authorization status | `simctl privacy <UDID> grant photos com.devicehubpro.verifier` (ends the app; relaunch it) | 1.23 s with the relaunch |
| Last link (`links.lastLink`) | `onOpenURL` | `simctl openurl <UDID> 'devicehubpro-verifier://link/check?q=a%20b'`, then tap Open | by hand |
| Clipboard (`clipboard.pasteboard`) | `UIPasteboard.changeCount` and types, never the contents | `simctl pbcopy <UDID>` | 0.28 s |

Where a row has two times, the first is simctl's and the second devicectl's. The devicectl
rows were measured on a default-set simulator (CoreDevice does not see private sets),
CoreDevice 642.16, CoreSimulator 1171.7.

## Kept in step with the Controls rows

`controls-rows.json` at the repository root lists every `ControlsRow`, and under `menuRows` what
only the menus and the stage carry (Orientation is the stage's Rotate, Clipboard, Slow Animations,
Add Sample Data): they keep their `ios` keys, so these rows stay mapped. The simulator panel has
Face ID, Push notification, Permissions, Language, Time zone, 24-hour time, the status bar, Open URL,
the Target app and the Memory warning as rows, listed under `rows`. An entry's `ios`
key says that the row is offered on iOS, which verifier rows here observe it
(`verifier`, `sameTitle`: the title is the iOS label verbatim), what it `targets`
(`simulator`, `device`), what the verifier `observes` (`effect`, `key`, `note`) and
whether the write relies on undocumented behaviour (`privateApi`).
`IOSVerifierRegistryTests` (`swift test --filter IOSVerifierRegistryTests`, UIKit-free:
`Shared/` and `RegistryTests/` build for the Mac) checks it against `Shared/Registry.swift`:
every mapped row exists, every row here is mapped or listed in
`Registry.awaitingControlsRow` with the Controls row it waits for, mirrored titles are
verbatim and each row observes what its entry says.

Rows listed in `awaitingControlsRow` observe settings that Device Hub Pro's iOS Controls do not
offer: only Memory warning, which no mechanism reaches (devicectl answers success, nothing
arrives). When a Controls row maps one, remove it from that list; the test fails while it
is in both.

The iOS Controls panel's own mechanisms (`AppleControlsBackend`) are round-tripped against
these rows by `AppleControlsLiveTests` (below): 17 Controls rows, every one within 3 s of
the command's start on 2026-09-26.

## Adding a row

1. Add a `VerifierRow` to its section in `Shared/Registry.swift`; its title is the iOS
   Controls label, verbatim.
2. Add its text and token to `Shared/Readings.swift` (Foundation only) with a test in
   `RegistryTests/ReadingsTests.swift`.
3. Feed it in `App/VerifierModel.swift` (a notification, the environment snapshot in
   `App/VerifierView.swift`, or the one-second poll).
4. Map it under the row's `ios` key in `controls-rows.json`, or list it in
   `Registry.awaitingControlsRow`.
5. Add a round trip to `IOSVerifierLiveTests` where a public tool can change it, and to
   `AppleControlsLiveTests` when a Controls row changes it.

## Tests

```sh
swift test --filter IOSVerifierRegistryTests          # registry, readings, manifest
DHP_IOS_LIVE=1 swift test --filter IOSVerifierLiveTests/testSimctlRoundTripsOnAPrivateSetSimulator
DHP_IOS_LIVE=1 DHP_SIM_UDID=<default-set UDID> \
    swift test --filter IOSVerifierLiveTests/testDevicectlRoundTripsOnAPinnedSimulator
DHP_IOS_LIVE=1 DHP_SIM_UDID=<default-set UDID> \
    swift test --filter AppleControlsLiveTests   # the Controls panel's mechanisms
```

The simctl test builds the verifier (or takes `DHP_IOS_VERIFIER_APP`), creates an
iPhone in a private device set, drives the rows above and deletes the device with its set
and log folders. The devicectl test needs a booted default-set simulator named in
`DHP_SIM_UDID`; it installs the verifier there, puts every appearance setting it
changed back and uninstalls the verifier if it installed it. With
`DHP_IOS_VERIFIER_READINGS_DIR` a failing test leaves its last readings.json and a
screenshot there. There is no CI job for it; run it locally.

## Caveats

- `simctl openurl` with the verifier's scheme makes iOS ask "Open in “AQA Verifier”?";
  the link reaches the app only after Open.
- `simctl push` exits 211 (`UNErrorDomain` 2003, "Source is not authorized") because the
  verifier never asks to post notifications, yet the app in front receives the push.
- `simctl privacy` ends the app for some services (photos did); the new status shows when
  the app opens again.
- A language reaches an app when it relaunches; a time zone only at boot.
- The status bar override is drawn by SpringBoard only; apps keep reading the
  simulator's own battery (-1, unknown).
- Only the grayscale colour filter is readable by apps; confirm the others on the screen.
