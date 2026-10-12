# Problem report fixtures

Captures for the problem report's tests (`Tests/DeviceHubProKitTests/ProblemReport/`),
taken on 2026-10-12 on the developer's Mac (macOS 27.0, Apple M4 Pro, Android SDK
platform-tools 37.0.0, emulator 36.6.11, Command-line Tools 22.0). Nothing here is
invented device output; every scrub is listed.

| File | Tool | What it is | Scrub |
|---|---|---|---|
| `sdk/platform-tools/source.properties` | the SDK | `Pkg.Revision=37.0.0` | none (byte for byte) |
| `sdk/emulator/source.properties` | the SDK | emulator 36.6.11, build 15507667 | none |
| `sdk/emulator/package.xml` | the SDK | trimmed to its `<revision>` element (the file's other lines are not needed; the test that loads it, `ProblemReportCollectorTests`, reads only the revision, as `EmulatorVersion.installedVersion` does) | trimmed |
| `sdk/cmdline-tools/latest/source.properties` | the SDK | Command-line Tools 22.0 | none |
| `emulator-app-log.log` | the emulator, started by Device Hub Pro | the first 110 lines of `~/Library/Logs/DeviceHubPro/devicehubpro-emulator-<avd>.log` of an API 36 foldable (a healthy start: "Found systemPath", "Storing crashdata", "Sending adb public key", "Using security allow list", "Started GRPC server ... auth: +token", "Advertising in", "Boot completed") | the user name became `aqauser001` (same length); the adb public key (a base64 run of 100+ characters) became a same-length run of `A`; the lines after "Boot completed" were cut |
| `discovery-token.ini` | the emulator | a `pid_*.ini` discovery file of an emulator Device Hub Pro launched (it carries `grpc.token`) | the token value became a same-length run of `x` inside the capture pipeline (it was never printed); the user name became `aqauser001` |
| `emulator-getprop-avd-name.txt` | `adb -s emulator-NNNN shell getprop ro.boot.qemu.avd_name` | raw stdout, on an online emulator only | none |
| `emulator-getprop-boot-completed.txt` | `adb -s emulator-NNNN shell getprop sys.boot_completed` | raw stdout, on an online emulator only | none |
| `emulator-emu-avd-name-silent.txt` | `adb -s emulator-NNNN emu avd name` | zero bytes, exit status 0: an emulator whose console printed nothing (a throwaway emulator of another session; the cause was not established here) | none |
| `emulator-emu-avd-name-silent.stderr.txt` | the same call | its standard error (empty) | none |

The empty-token capture of the console fix (`~/.emulator_console_auth_token` emptied) is
not here: replay that branch's capture when it lands, and take the cause from it.
