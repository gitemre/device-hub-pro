# Contributing to Device Hub Pro

Thanks for helping. Bug reports, fixes, device captures and documentation are all welcome.

## Before you start

- **Bugs:** open an issue with the bug report form. Include the macOS version, the device
  (emulator, phone model, simulator or iPhone) and what the log pane or Console showed.
- **Features:** open an issue first so we can agree on the shape before you write code.
- **Security problems:** do not open an issue; see [SECURITY.md](SECURITY.md).

## Build, test, run

You need macOS 26 or later and Xcode 26+ (or the Command Line Tools with a Swift 6.1+
toolchain). From the repository root:

```sh
swift build
swift test --skip IntegrationTests   # unit suites; no emulator is touched
.build/debug/DeviceHubPro            # opens the app and brings it to the front
```

A plain `swift test` also runs live tests against an online emulator, which change its
state. The switches that choose or skip devices, and what each live test leaves behind, are
in [docs/testing.md](docs/testing.md); read it before running the suite with a phone
attached. With `DHP_LAUNCH_INACTIVE=1` the app does not take focus, which helps when you
test while using the Mac.

To build the packaged app and a disk image: `Scripts/package-app.sh --dmg` (ad hoc signed,
for your own Mac). Signing, notarization and releases are in
[docs/distribution.md](docs/distribution.md).

## Pull requests

- Keep a pull request to one change, and add or update tests with it.
- Run `swift test --skip IntegrationTests` before you push; every test must pass.
- Commit subjects are lowercase [conventional commits](https://www.conventionalcommits.org):
  `fix: …`, `feat: …`, `docs: …`, `refactor: …`, `test: …`.
- A change you can see in the app needs a before/after screenshot in the pull request.
- A user-visible change gets a line in [CHANGELOG.md](CHANGELOG.md) under `Unreleased`.

## House rules

[AGENTS.md](AGENTS.md) holds the project's rules for people and coding agents alike. The ones
that matter most:

- **Devices.** An action that reaches a device acts only on the device selected in the
  sidebar. Tests and scripts never run `adb` against a phone without `-s <serial>`, and never
  touch a phone or simulator they did not create or were not pointed at.
- **Fixtures are real.** Test fixtures under `Tests/DeviceHubProKitTests/Fixtures/` are real
  captures from devices and tools; never invent device output. Replace personal identifiers
  (serials, user names, home paths, LAN addresses) with same-length placeholders.
- **Apple tooling.** simctl always gets an explicit UDID, never `booted`. Physical iPhones
  are reached only through the reviewed `devicectl` shapes listed in AGENTS.md.
- **Controls rows.** A change that adds or alters a Controls row updates
  `controls-rows.json` and the verifier apps (`android/verifier`, `ios/verifier`).

## Gotchas

- The app target claims `-platform_version macos 26.0 27.0` in `linkerSettings`
  (Package.swift) on purpose. Without it, `LC_BUILD_VERSION` names the deployment
  target (26.0) as the SDK instead of the SDK the app is built with. Do not remove
  it. Its first number must equal `platforms` and `LSMinimumSystemVersion` in
  `packaging/Info.plist`: `DeploymentTargetTests` (`swift test`) and
  `Scripts/package-app.sh` check all three. Keep the second number in sync with the
  toolchain's SDK.
- If an Xcode ⌘R run behaves unlike the source, the build was stale: Product → Clean
  Build Folder, or rebuild with
  `xcodebuild -quiet -scheme DeviceHubPro -configuration Debug -destination 'platform=macOS' build`.
- `Scripts/parity-check.sh` (pixels) and `Scripts/perf-check.sh` (performance)
  measure the **running** app, so rebuild and relaunch before trusting results
  (see [Scripts/README.md](Scripts/README.md)).
- An emulator started with `-no-window` and no `-gpu` flag renders in software;
  mirror numbers from it describe the emulator, not the app (`perf-check.sh` fails its
  `emulator-gpu-host` check on such a run).

## Repository layout

```
Sources/DeviceHubProKit/     UI-free kit: adb, AVDs, SDK, gRPC controls, mirror engine,
                             scrcpy, input, capture/recording, logcat, simctl/devicectl
Sources/DeviceHubProApp/     SwiftUI app: device browser, stage, Metal mirror, inspector
Sources/DeviceHubProSimBridge/        the private simulator bridge (see its PROVENANCE.md)
Sources/DeviceHubProNativeMirror/     the native iPhone live view
Tests/DeviceHubProKitTests/  kit unit and live tests; Fixtures/ holds real captures
                             (redactions noted in the tests that load them)
Tests/DeviceHubProAppTests/  app and model unit tests
android/verifier/            on-device Controls verification app (Kotlin, Gradle)
ios/verifier/                its iOS twin for the simulator (SwiftUI, built by build.sh)
ios/agent/                   the XCTest input runner for a physical iPhone
fastinput/                   the vendored fast-input helper (see its PROVENANCE.md)
controls-rows.json           the Controls rows per platform, shared by the verifiers' tests
Scripts/                     packaging, release, pixel-parity, performance and motion tools
packaging/                   Info.plist, entitlements, icon and bundled licenses
docs/                        features, troubleshooting, testing, performance, distribution
```

## License

By contributing you agree that your contribution is licensed under the
[MIT License](LICENSE).
