# AGENTS.md

Device Hub Pro is a macOS SwiftPM app (macOS 26+, Swift 6.1): an Android device manager
inspired by Xcode's Device Hub that works alongside it. `Sources/DeviceHubProKit` is
UI-free kit logic; `Sources/DeviceHubProApp` is the SwiftUI app. These rules apply to
people and coding agents alike.

## Commands (run from the repo root)

| Task | Command |
|---|---|
| Build | `swift build` |
| Test (all) | `swift test` (live tests run against an online emulator; switches in `docs/testing.md`) |
| Test (app suite only) | `swift test --filter DeviceHubProAppTests` |
| Run | `.build/debug/DeviceHubPro` (self-activates; with `DHP_LAUNCH_INACTIVE=1` it does not, and its windows open behind the active app's, for live checks while someone uses the Mac) |
| Pixel-parity harness | `bash Scripts/parity-check.sh` (app must be running; see `Scripts/README.md`) |
| Performance harness | `bash Scripts/perf-check.sh` (app must be running; see `docs/performance.md`) |
| Rebuild the Xcode product | `xcodebuild -quiet -scheme DeviceHubPro -configuration Debug -destination 'platform=macOS' build` |

## Project rules

- Commit subjects are lowercase conventional: `fix:`, `feat:`, `docs:`.
- Commit only when asked. Run `swift test` before committing.
- Parity changes record the measurement in `ParityMetrics.swift` (or `MotionMetrics.swift`) next to
  the constant they set, and keep `Scripts/parity-check.sh` passing.
- A change that adds or alters a Controls row updates its entry in the root
  `controls-rows.json` (schema 2: one entry per `ControlsRow`, in order, with a key per
  platform the row is offered on) and adds or updates the verifier row each key maps:
  `android/verifier` for `android` (build/run: `android/verifier/README.md`), `ios/verifier`
  for `ios` (build/run: `ios/verifier/README.md`; a verifier row whose Controls row is not
  mapped yet is listed in its `Registry.awaitingControlsRow`). The Swift
  (`ControlsRowManifestTests`), JUnit (`ControlsRowsManifestTest`) and iOS registry
  (`IOSVerifierRegistryTests`) suites all check that manifest.
- Controls and features that cannot work on the selected device are not shown (no disabled
  placeholders or "not available" notes).
- An action that reaches a device (menu item, shortcut, Controls row, capture, sheet) acts on
  the selected row's device only: gate it on `DeviceWorkspace.menuTargetSerial` (Android) or
  `contextIsSelection`, never on `workspace.context.serial` / `context.device` alone. The
  context keeps the last mirrored device while a stopped or other-tab row is selected.
- Do not remove the `-platform_version macos 26.0 27.0` linker flag in `Package.swift`
  (LC_BUILD_VERSION would otherwise claim the deployment target as the SDK, not the SDK the app
  is built with). Keep the minimum equal to `platforms` and to `LSMinimumSystemVersion` in
  `packaging/Info.plist` (`DeploymentTargetTests` checks the three, and that this file and
  `CONTRIBUTING.md` quote the flag exactly as `Package.swift` spells it), and the SDK number in
  sync with the toolchain.

## Fixtures

- Test fixtures are real captures from devices and tools (adb, the emulator, the SDK, real
  APKs, simctl, devicectl) under `Tests/DeviceHubProKitTests/Fixtures/`; never invent device
  output. Keep them byte-exact with two exceptions, both noted in the test that loads the
  fixture: replace personal identifiers (serials, user names, home paths, LAN addresses,
  signing teams, UDIDs) with same-length placeholders (the macOS user name becomes
  `aqauser001`), and trim lines or bytes the test does not need.
- When a capture is impossible, derive it from the tool's source and mark the test
  `SOURCE-DERIVED` with that source. Other markers: `PRIVATE-API <runtime build>` for a
  capture that relies on undocumented behaviour (pair it with a live canary test), and
  `HELP-DERIVED <Xcode build>` for argv and error mapping taken from `simctl help` /
  `devicectl … -h` (never an invented JSON body).
- Never commit binary-inspection material from Apple's frameworks or tools (disassembly,
  instruction addresses, class dumps, symbol listings) to comments, tests or docs, and never
  mark such findings `SOURCE-DERIVED`: write the behaviour and "established against Xcode
  <version> (<framework> <version>)" instead.

## Android devices

- Never run adb against a phone you were not asked to use; pass `-s <serial>` explicitly.
  `DHP_SCRCPY_SERIAL` pins the scrcpy / physical-path tests (they use a phone only when it is
  named there) and the language-time and conditions tests (they skip when it names a phone).
  The other live tests take the first online emulator whatever the pin, and
  `testLogcatStreamReceivesEntries` reads logcat from any online device, phones included: with
  a phone attached that is not yours to use, add `--skip testLogcatStreamReceivesEntries`.
- The live tests leave emulator state changed (list in `docs/testing.md`). To keep a run off an
  emulator someone else is using, add `--skip IntegrationTests` (it covers every
  emulator-driving class); `DHP_ADB=/nonexistent` does not, because the adb locator falls back
  to the SDK copy and `IntegrationTests` reaches the emulator's gRPC port without adb.
- Pairing a phone (Pair Nearby Device sheet) uses adb's wireless-debugging commands only:
  `adb mdns services`, `adb pair <host:port> <password or code>` and `adb connect <host:port>`,
  against the endpoint the phone announced and only for a phone the user pairs in the sheet
  (QR scan or code; the QR path waits for a `_adb-tls-pairing._tcp` service named exactly as
  its own code, `WirelessQRPairing.swift`). Tests use a fake adb.
- Send Files to Android goes through `adb -s <serial> push` into a folder of the shared
  storage (`AndroidSendDestination`, Downloads by default) and a MediaStore scan
  (`content call --uri content://media/external/file --method scan_file`, measured on API 35).

## iOS simulators

- Never pass `booted`, `all` or `unavailable` to simctl, in code, tests or by hand: always an
  explicit UDID. Call the real binaries (`AppleToolchain`), never the `xcrun` wrappers, which
  can run `xcodebuild -runFirstLaunch`.
- iOS live tests create their own simulator only through `LiveTestSimulators`, in a private
  `simctl --set` under the temporary directory, and delete the device, the set folder and its
  `~/Library/Logs/CoreSimulator/<UDID>` folder afterwards. Never boot, erase or delete a
  simulator you did not create; at most one booted test simulator at a time.
- devicectl only with `--device <UDID>`, where `simctl list` printed that UDID (CoreDevice does
  not see private sets, so devicectl live tests need a default-set simulator named in
  `DHP_SIM_UDID`). Never `devicectl manage …` against a simulator, and never idevice*,
  pymobiledevice3 or go-ios.
- Send Files to a simulator: photos, videos and contact cards go through `simctl addmedia`;
  any other file or folder is copied into the Files app's `File Provider Storage` (the
  `group.com.apple.FileProvider.LocalStorage` group from `simctl get_app_container <udid>
  com.apple.DocumentsApp groups`) or an app's `Documents`.
- Never install Xcode betas on a development Mac (CoreSimulator is system-wide); run beta
  smoke tests on a separate volume or a VM.

## Physical iPhones

Tests and agents use only the dedicated test iPhone whose hardware UDID is named in
`DHP_IPHONE_UDID`, never any other phone, and never run the app GUI against a phone that is not
that one. Never print the UDID, the team identifier or a signing identity into a committed
file, a test name or a log you keep. Fixtures in `Fixtures/ios27-device/` are the scrubbed
captures. A device build of the verifier comes from
`ios/verifier/build.sh --device --profile … --identity …` (it never installs).

- **Listing.** devicectl runs against a physical device only through
  `ApplePhysicalDeviceLister` and `DevicectlPhysicalClient`. `devicectl list devices` appears
  only inside the lister, behind a `PhysicalDeviceOptIn` (no opt-in, no call;
  `AppleSourceGuardTests` and `ApplePhysicalDeviceLister.listCallCount` pin both). The
  preference "Show physical Apple devices" (`AppPreferences.showPhysicalAppleDevices`) is off
  by default and off means zero `list devices` calls. On, `ApplePhysicalInventory` shows every
  physical device, but no other command reaches a device until the user enabled THAT device
  ("Use This Device…", persisted by hardware UDID). `ApplePhysicalInventory.client(for:)` is
  the only way to a `DevicectlPhysicalClient` (a test scans for it; `manage pair` below is the
  one other place that makes a client). An agent-driven run of the app sets
  `DHP_IPHONE_UDID=<test iPhone's UDID>`, which restricts the app to that one device and counts
  it as enabled; it does not turn the preference on. Never select a physical device on launch
  or on appearance, never start trust or Developer Mode from the app.
- **Allowed devicectl shapes** (`DevicectlPhysicalClient.allowedCommandWords`, each in one fixed
  argument shape, pinned by `ApplePhysicalActionTests` and `AppleSourceGuardTests`):
  - reads: the nine `device info` commands (`details`, `apps` (also with
    `--include-default-apps` or `--include-all-apps`), `processes`, `displays`, `lockState`,
    `appearance`, `voiceover`, `ddiServices`, `audio`) and `device info files`;
  - `device install app`, `device uninstall app`, `device process launch|terminate|openURL`,
    `device capture screenshot|screen-record`, `device copy from`;
  - Controls (`DevicectlPhysicalControl`, each matched whole, tail checked flag by flag):
    `device settings appearance <one flag>`, `device settings voiceover --enable|--disable`,
    `device orientation get|set <pose>`, `device simulate location coordinate --latitude
    --longitude|clear`, `device process sendMemoryWarning --pid`, `device pasteboard copy
    --file <path>|paste`;
  - management (`DevicectlPhysicalManagement`, the right-click menu: Restart, Rename…, Collect
    sysdiagnose…, Unpair…): `device reboot`, `device rename --name <name>`, `device sysdiagnose
    --destination <folder>`, `manage unpair`; they run only through `PhysicalDeviceActions`,
    on an enabled device (paired and connected), behind a confirmation alert (Restart, Unpair);
  - `manage pair` (no options; `DevicectlPhysicalClient.pair()`, refused for a device that is
    paired already): only from `ApplePhysicalInventory.pairNearby`, which the Pair Nearby Device
    sheet calls when the user presses Pair on an iPhone the lister reported unpaired, and which
    enables that phone on success;
  - Send Files: `device copy to --device <CoreDevice identifier> --json-output <file> -q -t <s>
    --domain-type appDataContainer --domain-identifier <bundle id> --source <file or folder on
    the Mac> --destination <relative path in the app>` (`DevicectlPhysicalClient.copyTo`; other
    domains, an absolute or `..` destination, extra flags such as `--remove-existing-content`
    and several `--source`s are refused). Only from `SendFilesController`, for an enabled
    device, into the app the user picks (apps whose data container devicectl can write, in
    practice development builds) at `Documents/<name>`. Photos cannot be added to a physical
    iPhone with public tools;
  - the log pane's console launch: `device process launch --device <id> --console
    --terminate-existing --environment-variables <json> <bundle id>`, built only by
    `DevicectlPhysicalClient.consoleCommandLine` (`DevicectlPhysicalClient+Console.swift`;
    `--console` is spelled only there). The JSON may hold only `OS_ACTIVITY_DT_MODE`
    (`enable`, `YES`) and `OS_ACTIVITY_MODE` (`debug`); any other key or value is refused.
    `PhysicalConsoleLogStream` is the one runner, built only by
    `LogcatController+Physical.swift`, and only after the user presses Launch & Stream for an
    enabled device. Stop, leaving Log focus, another selection or quitting sends devicectl
    SIGINT, which ends the app session. Agents and tests launch only the host app
    (`com.devicehubpro.agent.host`) on the test iPhone;
  - `device notification observe` only from `TunnelLeaseKeeper` (see fast input below).

  `device sysdiagnose` is the one command that runs with administrator privileges: devicectl
  asks for the Mac's administrator password on a terminal for it, so the client runs that one
  validated argv through `DevicectlPrivilegedRunner` (`/usr/bin/osascript -e 'do shell script
  ... with administrator privileges'`, macOS's own dialog: the password never reaches Device Hub
  Pro) into a private temporary folder it hands back to the user (`chown -R`), then moves the
  files into the folder the user chose. `osascript` is spelled only in that file, used only by
  `DevicectlPhysicalClient` (`AppleSourceGuardTests`, `ApplePhysicalSysdiagnoseTests`). No other
  command is ever run privileged.

  Refused (`DevicectlPhysicalClient.refusedCommands`, and every other shape of the words
  above): `list` outside the lister, `manage` other than `unpair` and `pair`, `pairings`,
  `reset`, `settings` other than the two shapes above, `profile`, `notification` through the
  client, `simulate` other than the location shapes, `orientation rotate`, `pasteboard`
  (`info`, `monitor`, `transfer`, `sync-with-host`), `motion`, `appResize`, any HID /
  remote-input, media-stream or live-screen command, and any Developer Mode / trust / DDI flow.
  No test or agent runs a management, pairing or `copy to` command against a real device; the
  tests use a fake devicectl, so those shapes are HELP-DERIVED (Xcode 27.0 `devicectl
  <command> -h`).
- **Live screen.** A physical iPhone's screen is shown, view only, through the public
  CoreMediaIO + AVFoundation capture: the CoreMediaIO property
  `kCMIOHardwarePropertyAllowScreenCaptureDevices` set on `kCMIOObjectSystemObject` (only in
  `AVFoundationScreenCapture.swift`, called only by `PhysicalLiveViewController`, and only
  while "Show physical Apple devices" is on) and an `AVCaptureSession` on the phone's
  `.external` capture device. It needs the Camera permission (`NSCameraUsageDescription`, the
  Camera entitlement of a hardened build). A test never touches AVFoundation or CoreMediaIO
  (`PhysicalScreenCaptureProviding`, `InertScreenCaptureProvider`), and nothing in the app
  changes a macOS setting (the Camera pane is only opened). The screenshot preview
  (`PhysicalScreenshotSession`) uses the public `devicectl device capture screenshot`.
- **Control through the XCTest runner.** The public-XCTest runner of `ios/agent` is the input
  fallback, only for a device the user enabled and, for agents, only the test iPhone.
  `PhysicalControlSession` is the only code that drives it; `xcodebuild test-without-building`
  is spelled only in `PhysicalControlRunnerLauncher.swift` and `XcodebuildRunnerLauncher(` is
  made only by `PhysicalControlSession.live` (`AppleSourceGuardTests`,
  `PhysicalControlSourceGuardTests`). Binding and token rules are mandatory: the runner binds
  only to the device end of the CoreDevice tunnel (`fd00::/8`, from `details`), never Wi-Fi/LAN,
  no fallback; the Mac side refuses any other address (`PhysicalControlEndpoint`) and never
  sends a request without the launch's fresh token (at least 128 bits, compared in constant
  time by the runner); the token, the team, the UDID and the tunnel address are never logged,
  printed, committed or shown (messages are redacted; the team lives only in the app's
  preferences). The runner's spike helpers (`/launch`, `/probe`, `/host`, `/ifaddrs`,
  `/screenshot`) are never requested by the app. A live run takes the shared phone lock, needs
  an unlocked phone, drives only the host app or the home screen (never a third-party app's
  content), and restores portrait and the home screen; if Xcode asks for any credential, stop.

## Private APIs and kill switches

Each private-API path is vendored or wrapped at a pinned, reviewed revision with a
`PROVENANCE.md`, sits behind an environment kill switch and has a live canary test; the public
alternative stays the fallback.

- **Fast input on a physical iPhone** (`DHP_DISABLE_FAST_INPUT`): the private CoreDevice HID
  input path of `ipb` (vendored under `fastinput/`, MIT, `fastinput/PROVENANCE.md`), and its
  mirror (CoreDevice media-stream / AVConference path), the native live view that needs no
  Camera permission (`DHP_DISABLE_NATIVE_MIRROR`, `Sources/DeviceHubProNativeMirror`). Both are
  on by default (Settings and the kill switches turn them off). There is no "Control This
  iPhone" step: when the user has selected an enabled, ready iPhone and its live view shows,
  the fast input session starts by itself (`PhysicalControlController.autoStartIfWanted`) and
  stops with the view; it never runs on launch or appearance, never starts the XCTest runner on
  its own (the runner stays the lazy fallback for Siri, typing fast input cannot do and a
  failed fast input when a team is set), and a start failure shows in the status line with a
  Retry. Agents and tests use it only on the test iPhone, drive only the host app or the home
  screen, and never pair, trust, change Developer Mode or touch any other device. Besides the
  shapes above, exactly one more devicectl command may run, only from `TunnelLeaseKeeper`
  (never through the client, which keeps refusing `notification`): `devicectl device
  notification observe --device <CoreDevice identifier> --name <unique unposted name>
  --session-timeout <s> --timeout <s+5> --quiet` (HELP-DERIVED Xcode 27.0 27A266a), a resident
  child that only holds the tunnel lease open. The words `createservicesocket`,
  `universalhidservice` and that command appear only under `fastinput/` and
  `Sources/DeviceHubProKit/Apple/FastInput/` (`FastInputSourceGuardTests`).
- **Simulator bridge** (`DHP_DISABLE_SIMBRIDGE`, `DHP_SIMBRIDGE_ALLOW_UNTESTED`):
  `Sources/DeviceHubProSimBridge`, provenance in its `PROVENANCE.md`.

## Test switches

- `DHP_IOS_DEVICE_LIVE=1` with `DHP_IPHONE_UDID=<hardware UDID>` runs `ApplePhysicalLiveTests`
  against the test iPhone (both are required, they skip otherwise; the test refuses unless the
  lister returns exactly that device as physical, paired and connected, and it only reads).
  With `DHP_IOS_DEVICE_VERIFIER_APP=<signed .app>` as well it also installs that verifier build,
  launches it, copies its `readings.json` out, terminates it and takes a screenshot, and leaves
  the phone as found. With those three switches `ApplePhysicalControlsLiveTests` changes every
  Controls row the phone offers, reads each back through the verifier and puts each back in a
  cleanup that runs however the steps ended (VoiceOver first); it never runs on a phone that is
  not the one named.
- `DHP_CONTROL_LATENCY=1` (`DHP_CONTROL_LATENCY_N`, default 20) adds
  `PhysicalControlLiveTests.testTapLatency` (taps only the host app's empty page; needs the
  control run's switches).
- `DHP_FAST_INPUT_LIVE=1` (with the two device switches; `DHP_FAST_INPUT_DIR` names
  `fastinput/`) runs `FastInputLiveTests`; with `DHP_IOS_TEAM_ID` and `DHP_IOS_AGENT_DIR` too,
  `testLandscapePanelMapping` measures the landscape panel rotation (the runner's
  `DHP_IDLE_SECONDS`, default 90, is set by the launcher).
- `DHP_NATIVE_MIRROR_LIVE=1` (with the two device switches) runs `NativeMirrorLiveTests`, the
  native live view canary (frames for 10 s, view only).
- `DHP_IOS_LIVE=1` runs the iOS live tests (they skip otherwise). `DHP_SIM_UDID=<udid>` names a
  default-set simulator for devicectl live tests (refused unless `simctl list` shows it) and,
  with `DHP_SIM_SET`, the simulator the bridge smoke tests drive. `DHP_SIMCTL` /
  `DHP_DEVICECTL` override the binaries.
- `DHP_SENDFILES_SERIAL` names an emulator made for `SendFilesLiveTests`;
  `DHP_SENDFILES_SIM_SET` / `_UDID` a booted simulator in a private set.
- `DHP_IOS_CAPTURE_DIR=<dir>` makes `SimulatorMirrorSessionLiveTests` (which always creates its
  own simulator) write the source of the `orientation-uiOrientation.txt` fixture.
  `DHP_IOS_VERIFIER_APP=<path>` hands `IOSVerifierLiveTests` and `AppleControlsLiveTests` a
  built verifier (they run `ios/verifier/build.sh` otherwise);
  `DHP_IOS_VERIFIER_READINGS_DIR=<dir>` keeps a failing round trip's readings.json and
  screenshot there.
- `DHP_DEVICEKIT_ROOT=<dir>` makes the app read simulators' Apple chrome from that folder
  instead of `/Library/Developer/DeviceKit` (an empty folder shows the vector-body fallback);
  `DHP_DIAGNOSTIC_REPORTS_DIR=<dir>` makes it read simulators' crash reports from that folder
  instead of `~/Library/Logs/DiagnosticReports` (read only; never delete a report).
