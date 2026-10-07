# Device Hub Pro Verifier

A single-page Android app that shows one live row per Device Hub Pro Controls row, observed
through standard Android APIs. Change a setting in Device Hub Pro (Wi-Fi, Airplane mode, font
scale, sensors, location, telephony, …) and the matching row here flips within about a
second, with a highlight and a last-change time.

This is a developer verification tool: it reads and displays, it never writes and never
judges.

Rows observe the effect itself wherever an app can see it (the `debug.layout` property,
the app's own layout direction, the Wi-Fi service, `PowerManager`, …), not the settings
key Device Hub Pro wrote; the few whose effect only SystemUI draws show the key's value and say
so (see the honesty rule below). The rows are kept in step with Device Hub Pro's Controls rows by a
shared manifest, `controls-rows.json` at the repository root (schema 2): one entry per
`ControlsRow`, in order, with its label and, under its `android` key, the verifier rows
that observe it (a row without an `android` key is not offered on Android).
What only the Device menu carries (Sensors, Telephony, Emulator state; Fingerprint is a panel row
again, in Biometrics) is under `menuRows` in the same file, with the same `android` keys, so its
verifier rows stay mapped; Wi-Fi verbose logging and Mobile data always active were removed
from Device Hub Pro, and so were their rows here.
`ControlsRowManifestTests` (Swift) checks it against `ControlsRow` and the inspector labels,
`ControlsRowsManifestTest` (JUnit) the `android` keys against this app's registry, so a
missing, extra or renamed row fails a test on either side.

## Build and install

JDK: Android Studio's bundled JBR. adb: the SDK's platform-tools.

```sh
cd android/verifier
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
ANDROID_SERIAL=emulator-5554 ./gradlew :app:installDebug
```

`installDebug` installs on every attached device unless `ANDROID_SERIAL` names one; a phone
plugged in for another reason is not a place to install. In Android Studio: open
`android/verifier`, pick the device and press Run. One command (build + install + permissions +
launch) on one device:

```sh
./install.sh emulator-5554        # or ANDROID_SERIAL=emulator-5554 ./install.sh
```

`install.sh` builds with `assembleDebug` and installs with `adb -s <serial>`: Gradle's
`installDebug` would install on every attached device, phones included. The serial is
required even with one device attached, so the script never falls back to a phone; without
it the script lists the attached devices and exits.

## Permissions

The panel requests its runtime permissions itself; the same grants from adb (add
`-s <serial>` to each, as `install.sh` does):

```sh
adb shell pm grant com.devicehubpro.verifier android.permission.ACCESS_FINE_LOCATION
adb shell pm grant com.devicehubpro.verifier android.permission.READ_PHONE_STATE
adb shell pm grant com.devicehubpro.verifier android.permission.READ_PHONE_NUMBERS
adb shell pm grant com.devicehubpro.verifier android.permission.READ_CALL_LOG
adb shell pm grant com.devicehubpro.verifier android.permission.RECEIVE_SMS
adb shell pm grant com.devicehubpro.verifier android.permission.BODY_SENSORS
adb shell pm grant com.devicehubpro.verifier android.permission.BLUETOOTH_CONNECT   # API 31+
```

`ACCESS_WIFI_STATE` and `ACCESS_NETWORK_STATE` are normal install-time permissions and need
no grant. A missing permission renders that row as "Permission required — tap to grant";
tapping the row opens the system dialog.

## Using it during verification

1. Install on the emulator or device; open the app and keep it foreground.
2. Change a row in Device Hub Pro's Controls inspector.
3. Watch the verifier: the row value flips, flashes, and stamps its last-change time.

Sections mirror the Device Hub Pro groups (Language & time, Status bar, the two conditions groups and the URL row come last here); emulator-only sections (Location, Sensors, Telephony,
Advanced, Foldable, Form factor, Network conditions) hide on physical devices and are listed in a
"Hidden on this device" footer. Rows whose hardware is absent read "Not on this device".
Shell commands (`getprop` when the property API is refused) run off the main thread.

**Honesty rule:** rows tagged "Key value" (Show taps, Show background
ANRs, Reduce Motion, Increase Contrast, Color Filter,
Automatic date & time, Automatic time zone, Demo mode) prove that the written value
reached the device. The two automatic switches take effect in the time detectors, a system API apps cannot query; their effect
shows in the Date & time and Time zone rows. Their visible effect is drawn by SystemUI, so confirm it on the
device screen or through the Device Hub Pro mirror. The rows whose Android mechanism is not a
settings key observe that mechanism instead: Show Borders reads the `debug.layout` property
every app reads, Force RTL the layout direction this app runs with, the Wi-Fi rows the Wi-Fi
service, Battery saver `PowerManager`. Color Filter
is drawn by SurfaceFlinger at composition, which apps cannot read either (screenshots
are taken before it): confirm them on a phone's own screen, because the emulator draws them
wrongly and screenshots, recordings and the mirror may leave them out.

## Smoke checklist

| Device Hub Pro action | Expected verifier change |
|---|---|
| Network ▸ Wi-Fi off/on | Wi-Fi `Off` / `On` |
| Network ▸ Bluetooth off/on | Bluetooth `Off` / `On` |
| Network ▸ Airplane mode on | Airplane mode `On` |
| Network ▸ Mobile data off/on | Mobile data `Off` / `On` (needs READ_PHONE_STATE) |
| Network ▸ Data Saver on | Data Saver `On` |
| Power ▸ Battery 42 % | Battery `42 %` |
| Power ▸ Charging on | Charging `Charging` |
| Power ▸ Charging off, then Battery saver on | Battery saver `On` (with Charging on, Device Hub Pro disables its Battery saver switch, says why and offers Turn Charging Off; the verifier reads `Off (charging — Android refuses battery saver)`) |
| Location ▸ set a location | Location `lat, lng · HH:mm:ss` |
| Device ▸ Sensors… ▸ set Acceleration | Acceleration values move |
| Device ▸ Simulate ▸ Incoming Call… | `Ringing · <number>`, then last-call history |
| Device ▸ Simulate ▸ Incoming SMS… | sender, text and time |
| Device ▸ Simulate ▸ Phone Number… | Phone number matches (emulator images only; needs READ_PHONE_NUMBERS) |
| Device ▸ Simulate ▸ Fingerprint Touch | row records `Succeeded` while the prompt is up |
| Device ▸ Simulate ▸ Pause / Resume Emulator | on resume, "Pause detected: no ticks for N s" when the clocks moved |
| Stage fold strip (Closed / Half / Opened, angle slider) | Posture (`Closed` below 30°, `Half` to 150°, `Opened` above) and hinge degrees move |
| Resize mode ▸ a preset (toolbar button or Device ▸ Enter Resize Mode; resizable AVDs only, those with `hw.resizable.configs`) | Preset shows the new window size |
| Display ▸ Appearance Dark | Appearance `Dark` and the verifier goes dark |
| Display ▸ Text Size Largest | Text Size `1.30×` and the text grows (up to `2.00×` on Android 14+) |
| Display ▸ Reduce Motion on | `On (all animation scales are 0)`, flashes stop animating |
| Display ▸ Show Borders on | Show Borders `On (debug.layout = true)` and the verifier's rows draw layout bounds |
| Display ▸ Sound | the music volume matches |
| Accessibility ▸ TalkBack on | TalkBack `On (touch exploration active)` (if Device Hub Pro cannot read the enabled accessibility services it refuses to write, so this row does not change) |
| Accessibility ▸ Color Filter Grayscale | Color Filter `Grayscale · mode 0` (key value) |
| Accessibility ▸ Color Filter None | Color Filter `None` |
| Accessibility ▸ Increase Contrast on | Increase Contrast `On` (key value) |
| Language & time ▸ Force RTL on | `RTL · forced` at once: Device Hub Pro pushes the current languages again, as Developer options does (Android 8+). If that push fails (or before Android 8), `LTR · requested, not applied yet (applies after a restart)` while Device Hub Pro's row shows "Restart pending" |
| Debug ▸ Show taps / Show background ANRs | `On` (key values; check the screen) |
| Language & time ▸ Language tr-TR | Language `tr-TR · LTR` (the verifier relaunches; the status-bar clock switches to 24-hour `13:22` at once) |
| Language & time ▸ Language ar-EG, then Restore | Language `ar-EG · RTL`, then back to the list Device Hub Pro captured |
| Language & time ▸ Date & time +1 hour, Set | Date & time `… · 1 h ahead of network time`; Automatic date & time `Off` (key value); Reset to automatic puts it back on |
| Language & time ▸ Time zone Asia/Tokyo | Time zone `Asia/Tokyo · GMT+09:00`; Automatic time zone `Off` (key value) |
| Language & time ▸ Time zone ▸ Automatic (after a zone was chosen) | Time zone back to the network's (the Mac's on an emulator); no "Time zone changed" notification left behind |
| Language & time ▸ 24-hour time 24-hour | `24-hour (time_12_24 = 24)`; Locale default → `12-hour (language default)` on en-US (the status bar follows at the next minute) |
| Clean status bar on | Demo mode `On (sysui_tuner_demo_on = 1)` (key value); the status bar shows 9:41, full Wi-Fi, 100 %; the Battery, Charging and Date & time rows do not move. Demo mode off → `Off` |
| Network ▸ Wi-Fi off, Mobile data on (the caption under Speed names the path) | Data path `Mobile data · shaped by the emulator` (on Wi-Fi it reads `Wi-Fi · not shaped`: the emulator's Wi-Fi goes through netsimd, outside the shaper) |
| Network conditions ▸ Connection latency GSM (on mobile data) | Connection latency from `≈ 40 ms` to several hundred ms (median of three TCP connects to 8.8.8.8:53; IPv4 only) |
| Network conditions ▸ Metered mobile data off (on mobile data) | `Off (temporarily not metered) · isActiveNetworkMetered = true` |
| Network conditions ▸ Reset conditions | every row above back: latency ≈ 40 ms, in service, metered, Wi-Fi again if Use Mobile Data switched it off |
| Network conditions ▸ Use Mobile Data and Connection latency GSM, then stop the mirror (or quit Device Hub Pro, or Stop the AVD and start it again) | Data path `Wi-Fi · not shaped` again and Connection latency back to ≈ 40 ms: a disconnect puts back what Device Hub Pro changed, before a Stop shuts the VM down |
| App conditions ▸ Target app `com.devicehubpro.verifier`, leave the verifier (Home), Simulate low memory ▸ Send, reopen it | Simulate low memory `COMPLETE (80) at … · lastTrimLevel 80` (`RUNNING_CRITICAL (15)` when the verifier stayed in front) |
| App conditions ▸ Kill process with the verifier in the background, then reopen it from Recents | Kill process `Killed in the background ([KILL BACKGROUND] kill background) at … · pid N · activity restored from saved state` |
| URL `devicehubpro-verifier://link/check?q=a b&x=ü` ▸ Open | Last link shows it verbatim `· BROWSABLE · from com.android.shell` (`· onNewIntent` when the verifier was already on top or in the background) |
| URL `devicehubpro-verifier://nodefault/x` | nothing here (the filter has no DEFAULT); Device Hub Pro's URL caption names `com.devicehubpro.verifier/.MainActivity` and says its filter lacks `android.intent.category.DEFAULT` |

## Adding a row

1. Add a `read(Context): Reading` function (framework call, system property or settings
   key — whatever Android itself reads) next to the section it belongs to — for example
   `RowsNetwork.kt`.
2. Add a `VerifierRow` entry to that section's row list in the same file, or use
   `keyToggleRow(...)` for a plain settings toggle. Its title is the Controls row's label,
   verbatim.
3. Map it under the row's `android` key in the root `controls-rows.json` (one entry per
   Device Hub Pro `ControlsRow`, in order; `label` there overrides the shared label on Android; a
   row no verifier row can observe maps to `[]` and says why in `why`). Both
   test suites check that file: `swift test --filter ControlsRowManifestTests` against
   `ControlsRow` and the inspector labels, `./gradlew :app:testDebugUnitTest`
   (`ControlsRowsManifestTest`) against this registry — no verifier row without a Controls
   row, no mapped row missing, mirrored titles verbatim.
4. Add a line to the smoke checklist above; if the row needs a new permission, add it to
   `AndroidManifest.xml`, the `requiredPermissions` list in `MainActivity`, and the grant
   list in `install.sh`.

Unit tests (JDK: Android Studio's JBR — `/usr/libexec/java_home` may find no system JDK;
the SDK from `local.properties`, which is gitignored, or `ANDROID_HOME`). From a fresh
clone or worktree:

```sh
cd android/verifier
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
ANDROID_HOME=~/Library/Android/sdk ./gradlew :app:testDebugUnitTest
# add --offline when the Gradle caches are already populated
```

## Caveats

- `svc wifi disable` / `svc data disable` over wireless adb can drop the connection; use
  USB or the emulator for those rows.
- Fingerprint testing needs an enrolled fingerprint on the emulator (Settings ▸ Security);
  without one the row shows "No fingerprint enrolled" and the prompt records `Cancelled`.
- The Location row holds a GPS request while the panel is visible so injected fixes land.
- `getLine1Number()` is frequently empty on production images; the row says `Unreadable`
  instead of guessing.
- The `Key value` tag is deliberate: the verifier never claims to prove a SystemUI overlay.
- The Connection latency row opens a TCP connection to 8.8.8.8:53 every 3 s while the panel is
  visible (hence the `INTERNET` permission); it measures only the connect, which is all the
  emulator delays.
- The Links row describes the verifier itself: open one of its links from Device Hub Pro's URL row
  (`devicehubpro-verifier://link/…`; `devicehubpro-verifier://nodefault/…` only exercises Device Hub Pro's
  captions; Device Hub Pro always sends BROWSABLE, so the `internal` and `verifier.devicehubpro.test`
  filters are no longer reached from the app). `MainActivity` is `singleTop`, so `install.sh`'s final
  `am start -n` delivers onNewIntent (ignored: not a VIEW intent) when the verifier is already
  on top. Each VIEW intent is also logged under the tag `DeviceHubProVerifierLink`, which
  Device Hub Pro's live test reads.
- The App conditions rows describe the verifier itself: choose `com.devicehubpro.verifier` as
  Device Hub Pro's Target app. Exit records are read once per process, so reopen the verifier after
  a kill or crash to see them.
- The spec's physical-device pass (non-emulator rows, the emulator-only gating and the
  "Hidden on this device" footer) has not been run: no physical device was attached during
  this delivery. Run the smoke checklist on hardware before trusting those paths.
