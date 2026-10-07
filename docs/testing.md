# Testing Device Hub Pro

Notes for contributors. The README has the build and run commands; this page covers what
the live tests do to devices and the `DHP_*` switches.

`swift test` runs the live integration tests against an online emulator
automatically (they skip without one). They tap, type, fold, paste and send
telephony events on that emulator, and a run is **not** state-neutral. Brightness,
the developer toggles, the keyboard (IME) and the paused VM are put back. Location
(41.01, 28.97), the clipboard, the acceleration sensor (1.5/2.5/3.5), the hinge
(180° on a foldable), the battery (set to 100 %, charging) and the SIM number
(+15551234567, where the image accepts it) are left changed, an SMS lands in the
inbox, the call log gets missed calls from 5551234, the browser is left on a new
pinch-zoomed tab of example.com (fetched over the network), and Settings and
Messages are force-stopped. Use an emulator whose state you do not need.

The rest of the suite (`--skip IntegrationTests`) never reaches an emulator it did
not start. Its models and emulator managers see only the VMs the test process
launches itself (stub processes), so they never match, attach to, stop or kill a VM
running on the Mac, and never probe the default gRPC ports (8554–8563). Other VMs
are only read from `ps`, so that deleting, renaming, resetting, starting or powering
on an AVD that one of them runs is refused. The ports the Kit and app suites dial
are either port 0 (nothing can listen on it) or a loopback listener the test owns.

Which device a live test uses depends on the test:

- The scrcpy / physical-path tests (`ScrcpyServerIntegrationTests`,
  `PhysicalMirrorSessionIntegrationTests`) use only the device that
  `DHP_SCRCPY_SERIAL` names, and without it only emulators. Of the default
  tests, they are the only ones that drive a phone, and only when it is named.
- The other emulator tests (`IntegrationTests`, `DeviceTogglesIntegrationTests`) take
  the first online emulator, or the one whose gRPC answers on port 8554, **whatever
  the pin**. With several emulators running they may use a different one.
- `LanguageTimeIntegrationTests`, `ConditionsIntegrationTests`,
  `StatusBarIntegrationTests`, `ColorFilterIntegrationTests` and
  `LinksIntegrationTests` use the emulator that `DHP_SCRCPY_SERIAL` names, else
  the first online emulator, and skip when the pin names a phone. They put back what
  they change, except that the conditions tests may trim and kill a cached
  background app and end on the full signal profile.
  - The status bar tests turn demo mode on for a few seconds each and skip when it
    is already on (someone else's). A teardown that runs even when an assertion
    fails puts `sysui_demo_allowed` and `sysui_tuner_demo_on` back. A run that is
    killed can leave demo mode on: end it with Developer options ▸ System UI demo
    mode, or with `adb -s <serial> shell am broadcast -a com.android.systemui.demo
    -e command exit` while `sysui_demo_allowed` is 1, then set both keys back to 0
    (unless `sysui_demo_allowed` was on before).
  - The colour filter tests restore the four secure rows exactly (the value and
    `is_preserved_in_restore`; only the rows' `_id` changes) and the Quick Settings
    tile lists by value. Their writes tint the emulator's window for a moment.
  - The Links tests change no settings and never clear logcat. One test opens a link
    in the Device Hub Pro verifier; it skips when the verifier is not installed, or when an
    app other than the launcher or the verifier is on top. It then removes the task
    it created, force-stops the verifier if the test started it, and presses Home
    if the launcher was on top.
- `IntegrationTests.testLogcatStreamReceivesEntries` still reads logcat (read-only)
  from the first online device of **any** kind, which can be a phone. Unplug phones,
  accept that read, or add `--skip testLogcatStreamReceivesEntries`.

Switches:

| Variable | Effect |
|---|---|
| `DHP_SDK_INSTALL_LIVE=1` | Opt-in `AndroidToolsInstallerLiveTests`: downloads Google's command-line tools and platform-tools (about 170 MB, network) into a temporary folder through the guided-setup installer (never `~/Library/Android/sdk`), accepts the license there, runs `adb version` from the result and deletes the folder. `DHP_SDK_INSTALL_EMULATOR=1` adds the 400 MB emulator package; `DHP_SDK_INSTALL_JAVA=1` also runs `testTheRealTemurinRuntimeIsDownloadedAndRunsSdkmanager` (downloads Temurin 21, about 48 MB, into a temporary folder and runs sdkmanager on it). |
| `DHP_SHAPING_SERIAL=<emulator serial>` | Opt-in `ShapingLiveTests`: on an emulator made for the run (google_apis, not Play) it roots adbd, applies UMTS and then 600 ms of latency, checks the device reports them and that a 128 KiB download from a loopback server of the host (10.0.2.2) takes longer by the host clock, then clears the rules and unroots. Boots nothing, never touches another device. |
| `DHP_SCRCPY_SERIAL=<serial>` | Pins the device for the scrcpy / physical-path tests only (see above). A phone is used by those tests only when it is named here. |
| `DHP_RUN_INTEGRATION=1` | Also runs the `adb track-devices` watcher test against the real adb. |
| `DHP_LIVE_ICON=1` | Opt-in live APK icon extraction check (`aapt2` + a device). `DHP_LIVE_ICON_SERIAL` picks the device, and it can name a phone; otherwise the first online emulator. |
| `DHP_REAL_SDKMANAGER=1` | Opt-in checks against the installed cmdline-tools: sdkmanager `--list` and avdmanager `list device` (read-only). Without it neither tool is run. |
| `DHP_SKIN_ART_SWEEP=1` | Opt-in sweep in `SkinButtonsTests`: lifts the side buttons out of every accepted installed SDK skin's artwork and checks that the pieces put it back byte for byte (a few seconds of decoding). It reads the skins in place and changes nothing; without an SDK it skips. |
| `DHP_NAV_LIVE_SERIAL=emulator-NNNN` + `DHP_NAV_LIVE_GRPC_PORT=<port>` | Opt-in `NavigationKeyLiveTests`: opens Settings on that emulator, presses Home, Back and Recents the way the stage's navigation bar does (gRPC) and checks the resumed activity and the launcher's overview panel. Refuses a serial that is not an emulator. It leaves the emulator on its home screen. |
| `DHP_CAPTURE_STATUS_BAR_FIXTURES=<dir>` / `DHP_CAPTURE_COLOR_FILTER_FIXTURES=<dir>` / `DHP_CAPTURE_LINKS_FIXTURES=<dir>` | Opt-in capture test of the matching live class: it writes its commands and the device's outputs to `<dir>`, the source of the `status-bar`, `color-filters` and `links` fixtures. The status bar and colour filter captures change the emulator as their tests do and put it back; the links capture launches nothing. |
| `DHP_DISABLE_MMAP=1` / `DHP_FORCE_MMAP=1` | Mirror transport switches for the app and the MMAP test (see performance.md). |
| `DHP_IOS_LIVE=1` | Opt-in live iOS Simulator tests (`AppleLiveTests`, `SimBridgeSmokeTests`, `SimulatorMirrorSessionLiveTests`, `SimulatorMediaLiveTests`, `IOSVerifierLiveTests`: the iOS verifier's round trips, `AppleControlsLiveTests`: the simulator Controls panel's mechanisms against the verifier, and the app suite's `SimulatorAppsLiveTests`: the Apps inspector and the stage's drops, with a tiny app it builds, a photo, a link and two root certificates it makes, and `SimulatorAppDataLiveTests`: the app data inspector and Add Sample Data, checked in the Address Book database, `Media/DCIM` and Settings' data container). They create an iPhone 17 Pro on iOS 27.0 in a private device set under `$TMPDIR/devicehubpro-live-sims`, boot it, drive it, and delete it afterwards with its `~/Library/Logs/CoreSimulator` folder. They never use the default set, `booted` or `all`. |
| `DHP_IOS_DEVICE_LIVE=1` + `DHP_IPHONE_UDID=<hardware UDID>` | Opt-in `ApplePhysicalLiveTests` (both switches are required): with only that UDID opted in, the lister must return exactly that device as physical, paired and connected, and the test then runs the read-only `devicectl device info` calls (`details`, `apps`, `processes`, `displays`, `lockState`, `appearance`, `voiceover`, `ddiServices`) against it. That test changes nothing on the phone and never prints the UDID. Name only a dedicated test iPhone. |
| `DHP_IOS_DEVICE_LIVE=1` + `DHP_IPHONE_UDID=<hardware UDID>` + `DHP_IOS_DEVICE_VERIFIER_APP=<signed DeviceHubProVerifier.app>` | Opt-in `ApplePhysicalControlsLiveTests` (all three): the phone's Controls rows (appearance, text size, Reduce Motion, Reduce Transparency, Show Borders, Increase Contrast, colour filter, Liquid Glass, VoiceOver, simulated location, clipboard text) are each changed, read back through the verifier and put back, VoiceOver first, whatever happens; the orientation canary puts the all-orientation host app (`com.devicehubpro.agent.host`, when installed) in front and pins by screenshot aspect that `orientation set` rotates it, then restores portrait; the memory-warning canary pins the row that does not work on an iPhone 12 / iOS 27.0. The verifier must be installed (it is left installed). Name only a dedicated test iPhone. |
| `DHP_IOS_DEVICE_LIVE=1` + `DHP_IPHONE_UDID=<hardware UDID>` + `DHP_IOS_TEAM_ID=<team>` + `DHP_IOS_AGENT_DIR=<checkout>/ios/agent` | Opt-in `PhysicalControlLiveTests` (all four; `DHP_CONTROL_LOG=<file>` logs each phone step with `<test iPhone>` for the UDID): builds or finds the signed input runner, starts it over the tunnel, checks that it refuses a missing or wrong token and answers on no other address of the phone, then taps, types, deletes, swipes and rotates through the host app `com.devicehubpro.agent.host`, and puts the phone back (portrait, Home, runner stopped). The phone must be unlocked. Name only a dedicated test iPhone. With `DHP_CONTROL_LATENCY=1` (and optionally `DHP_CONTROL_LATENCY_N=<taps per variant>`, default 20) `testTapLatency` also runs there: it taps only the host app's empty page and prints min/median/p90/max of the tap's Mac round trip, runner resolve and action time and touch delivery for the old two-request path, the session's one-request path and a full candidate scan. |
| `DHP_IOS_DEVICE_LIVE=1` + `DHP_IPHONE_UDID=<hardware UDID>` + `DHP_NATIVE_MIRROR_LIVE=1` | Opt-in `NativeMirrorLiveTests`: holds the tunnel, starts the native live view (private CoreDevice media stream, `Sources/DeviceHubProNativeMirror`), counts frames for 10 s (at least 60, and 1170x2532 for an iPhone13,2 in portrait) and prints fps and frame-interval p50/p95. View only; the phone must be unlocked. `DHP_DISABLE_NATIVE_MIRROR` (any value) turns the native live view off everywhere. |
| `DHP_NATIVE_MIRROR_TUNING=target.key=value;...` | Diagnostic switch (not a user setting) for the native live view: sets stream properties by key-value coding to measure their effect on latency with `NativeMirrorLiveTests/testTouchToFrameLatency`. Targets: `config` (stream configuration), `options` (stream init options), `negotiator`, `avcstream`, `stream`, `receiver`, `defaults`; values parse as bool, int, float or string; unknown keys are skipped with a stderr line naming the key. Unset changes nothing. |
| `DHP_IOS_DEVICE_LIVE=1` + `DHP_IPHONE_UDID=<hardware UDID>` + `DHP_FAST_INPUT_LIVE=1` (+ optional `DHP_FAST_INPUT_DIR=<checkout>/fastinput`) | Opt-in `FastInputLiveTests`: builds the fast input helper (private CoreDevice input path, see `fastinput/PROVENANCE.md`), holds the tunnel, taps the host app `com.devicehubpro.agent.host` twice and checks its colour flipped and flipped back, measures 20 taps 100 ms apart (min/median/p90/max of the helper's round trip per command) and presses Home. The phone must be unlocked. Name only a dedicated test iPhone. `DHP_DISABLE_FAST_INPUT` (any value) turns fast input off everywhere. |
| `DHP_IOS_AGENT_DIR=<dir>` (the app) | Where the app finds the input runner's sources (`ios/agent`) instead of the bundled copy or the checkout it was built in. |
| `DHP_IPHONE_UDID=<hardware UDID>` (the app) | Restricts the app's physical Apple devices to that one: with "Show physical Apple devices" on, it is the only device listed and it counts as enabled without the "Use This Device…" dialog. It does not turn the setting on: with the setting off the app makes no `list devices` call. Agent-driven runs of the app set it (never a personal phone). |
| `DHP_IOS_DEVICE_VERIFIER_APP=<path>` (with the two switches above) | Also runs the verifier round trip on the test iPhone: installs that signed `DeviceHubProVerifier.app` (built with `ios/verifier/build.sh --device --profile … --identity …`), launches it, copies `Documents/readings.json` out of its container and decodes it, terminates it by pid and takes a screenshot. The phone is left as found: a verifier that was installed before stays installed, otherwise it is uninstalled. It never opens a URL or records the screen. |
| `DHP_IOS_CAPTURE_DIR=<dir>` | `SimulatorMirrorSessionLiveTests` also writes its orientation rows there as `orientation-uiOrientation.txt` (the source of the bridge fixture of that name). |
| `DHP_IOS_VERIFIER_APP=<path>` / `DHP_IOS_VERIFIER_READINGS_DIR=<dir>` | `IOSVerifierLiveTests` and `AppleControlsLiveTests` install that built `DeviceHubProVerifier.app` instead of running `ios/verifier/build.sh` (into a temporary folder they remove), and a failing round trip leaves its last `readings.json` and a screenshot in the readings folder. |
| `DHP_SIM_UDID=<udid>` / `DHP_SIM_SET=<path>` | Point `SimBridgeSmokeTests` at an already booted simulator instead, plus its device set when it is not in the default one; `DHP_SIM_UDID` alone also names the default-set simulator for the devicectl checks in `AppleLiveTests`, `IOSVerifierLiveTests` and `AppleControlsLiveTests` (which install the verifier there, read the settings they change first and put them back whether they pass or fail — the appearance flags, the colour filter's type, intensity and state, the text size, VoiceOver, the enrolment and the volume; `AppleControlsLiveTests` also the orientation, the pasteboard's text, the clock, the whole language list and the region, and the verifier's photos permission, and it clears the location, which simctl cannot read back; a status bar override already in place is left alone and that step skipped — and uninstall the verifier if they installed it; a language change shows on that simulator's home screen until its next respring or boot). That simulator is left changed (see below). `SimulatorMirrorSessionLiveTests`, `SimulatorMediaLiveTests` and `SimulatorAppsLiveTests` ignore both and always create their own. |
| `DHP_DISABLE_SIMBRIDGE=1` / `DHP_SIMBRIDGE_ALLOW_UNTESTED=1` | Simulator-bridge gate for the app, the tests and `Scripts/ios-bridge-smoke.sh`: force the bridge off, or let it load on a CoreSimulator it was not verified on (an Xcode beta). |
| `DHP_DEVICEKIT_ROOT=<dir>` | The app reads simulators' Apple chrome from this folder instead of `/Library/Developer/DeviceKit`; an empty folder shows the vector body a Mac without Xcode's device chrome gets. |
| `DHP_DIAGNOSTIC_REPORTS_DIR=<dir>` | The app reads simulators' crash reports from this folder instead of `~/Library/Logs/DiagnosticReports` (it only reads it). |
| `DHP_LAUNCH_INACTIVE=1` | The app does not activate itself at launch and puts its windows behind the active app's, for live checks driven through accessibility while someone uses the Mac. |
| `DHP_MULTIWINDOW=0` | Turns off several device windows (on by default): ⇧⌘N for a new window, ⌘T for a new tab, "Open in New Window"/"Open in New Tab" on a sidebar row, window tabbing, one compact mirror per window, and a prompt before a window closes on a running recording. A device can be mirrored in one window at a time; the others offer Show Window and Move Here. Set to 0, the app is a single window. |

The live simulator test leaves nothing behind on the simulator it creates. A
simulator named by `DHP_SIM_UDID` is left changed: Settings is launched and
left on a sub-page, Safari opens example.com (fetched over the network), Home is
pressed, and `com.apple.coredevice.dtuhidd.active` is set to 1 until that
simulator reboots. That flag cuts legacy-Indigo input clients (older idb
and other tools) off from the simulator. Name only a simulator
nobody else is using.

The Android verifier app has its own unit tests; see
[android/verifier/README.md](../android/verifier/README.md). The iOS verifier
([ios/verifier/README.md](../ios/verifier/README.md)) is built for the simulator by
`ios/verifier/build.sh`; its registry is checked on the Mac by
`IOSVerifierRegistryTests` (part of `swift test`) and its round trips by
`IOSVerifierLiveTests` (behind `DHP_IOS_LIVE=1`). Both verifiers are kept in step
with the Controls rows by `controls-rows.json` at the repository root (schema 2: one
entry per `ControlsRow`, in order, with a key per platform the row is offered on),
which `ControlsRowManifestTests` checks against `ControlsRow` and the inspector labels.
