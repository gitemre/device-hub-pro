# Troubleshooting

**Wireless Android devices never appear** (`adb mdns services` lists nothing, `adb connect
<ip:port>` says "No route to host" while `nc -z <ip> <port>` works). macOS gives the adb
server (`adb fork-server`) the Local Network permission of whatever process first started it.
A server started by a tool without that permission (a bare `.build/debug/DeviceHubPro` without
the app bundle's Info.plist, an `xctest` run, another IDE or terminal) can neither browse
mDNS nor reach LAN addresses. The app detects this itself: it browses
`_adb-tls-connect._tcp` and `_adb-tls-pairing._tcp` with its own permission
(`NSBonjourServices` in `packaging/Info.plist`), and when a service it has seen for more than
6 s is missing from `adb mdns services` on two checks in a row (or a failed `adb connect`
says "No route to host" for an address the app reaches itself) it runs `adb kill-server` and
`adb start-server` from its own process, at most once per 2 minutes and never while a
recording or an install runs. A banner says "Device Hub Pro restarted adb so it can reach Wi-Fi
devices"; emulators and USB devices reconnect on their own. By hand: `adb kill-server && adb
start-server` from a terminal that has the permission.

None of this runs at launch. macOS asks "Allow Device Hub Pro to find devices on local networks?" the
first time the app browses Bonjour or the adb server it started joins the mDNS group, so a
first-time user would be asked before doing anything. Until a wireless need arrives (the Pair
Nearby Device sheet's Android tile, a wireless device that is already connected, or a Mac that
used wireless debugging before: `AppPreferences.localNetworkInUse`) the app starts adb with
`ADB_MDNS=0` (no mDNS discovery, `AdbMdnsPolicy`) and does not start the Bonjour browse
(`AdbServerRecovery.wantLocalNetwork()`); the first need removes the variable, starts the
browse and restarts an adb server the app itself started without mDNS. An `ADB_MDNS` in the
launch environment is left alone, and an adb server another tool started is never restarted for
this.

If you denied Local Network access to Device Hub Pro, nothing can fix it from inside the app: the
Pair Nearby Device sheet shows "Allow Device Hub Pro under System Settings › Privacy & Security ›
Local Network" with a button that opens that pane. The app never changes the setting.

**A Xiaomi phone mirrors but ignores clicks** (USB or Wi-Fi; logcat shows `scrcpy` failing
with `SecurityException: Injecting input events requires ... INJECT_EVENTS`). MIUI and
HyperOS keep a second switch behind USB debugging: Settings › Additional settings ›
Developer options › **USB debugging (Security settings)** (`persist.security.adbinput`,
`adb -s <serial> shell getprop persist.security.adbinput` prints `0` while it is off). The
app reads it when a mirror starts and when the scrcpy server reports the refusal, and shows
"This Xiaomi phone blocks input from the Mac" over the stage with a Check Again button.
Turn the option on (MIUI asks to sign in to a Mi account and may turn it off again after a
restart); no restart of the mirror is needed. Clicks are still sent while blocked, and a
click re-checks the property at most once every 3 s, so the line clears by itself.

## Reporting a problem

Help ▸ Report a Problem… (and the Report… button of an error alert that has Show Details, such as
an emulator that did not start) checks this Mac for causes we know, with the fix, and makes a
report to paste into a GitHub issue. It lists the Mac, the Android and Xcode tools, the emulators
and what they answered, the app's recent errors (kept in
`~/Library/Logs/DeviceHubPro/recent-problems.json`, with the serials of the phones that were
connected when each error was shown, so the report can leave them out after you unplug a phone)
and the end of the emulator logs; it leaves out your user name, Mac name, serial numbers,
addresses and tokens, and you can read all of it first.
To look at the emulators it reads the device list the app already has and runs only
`adb -s emulator-N emu avd name` and two `getprop` reads, on emulators only, never on a phone, and
only while an adb server of the same adb is already running on the port adb will use (and
`ADB_SERVER_SOCKET` is not set): it never starts or restarts one.
(`dhp-report collect`, the maintainers' command-line version, also runs `adb devices -l` under the
same rule.) Nothing is sent: Open GitHub Issue copies the report and opens the form in your
browser. Maintainers read a report with `dhp-report` ([CONTRIBUTING.md](../CONTRIBUTING.md)).

## Stop Xcode opening Device Hub on Run

Xcode 27.1 adds a Developer Tools ▸ Device Hub setting that controls whether Device Hub
opens when you run an app from Xcode (reported for 27.1; not verified here, and the exact
wording of the setting may differ). If you prefer to watch and drive the app in Device Hub Pro,
turn that setting off in Xcode and keep Device Hub Pro open beside it: it lists the same
simulators and the Android devices Xcode does not know about, and Xcode's own Run still
installs and launches the app on the simulator you picked. This repository does not change
any Xcode setting.

Two private preferences exist for sharing simulators with Device Hub. They are undocumented
and may change between Xcode releases. **Device Hub Pro has not verified them, and nothing in
this repository writes them.**

- `shutdownStartedDevicesOnQuit`, in the `com.apple.dt.Devices` domain (Device Hub's own).
  Quitting Device Hub can shut down the simulators it started, which would close their
  windows in other tools; set to `false` they keep running. Quit Device Hub first:

  ```sh
  defaults write com.apple.dt.Devices shutdownStartedDevicesOnQuit -bool false
  ```

- `DVTiPhoneSimulatorAlwaysLaunchInCoreSimulatorSession`, in the `com.apple.dt.Xcode`
  domain. Stops Xcode opening Device Hub when you run an app; Xcode then boots the
  simulator without a window of its own. Quit Xcode first. With it on, boot the target
  simulator before pressing Run, or Xcode may shut it down when you press Stop:

  ```sh
  defaults write com.apple.dt.Xcode DVTiPhoneSimulatorAlwaysLaunchInCoreSimulatorSession -bool true
  ```

Neither README documents an undo command. Deleting the key restores the default
(standard `defaults` behaviour, not something those projects state):
`defaults delete com.apple.dt.Devices shutdownStartedDevicesOnQuit` and
`defaults delete com.apple.dt.Xcode DVTiPhoneSimulatorAlwaysLaunchInCoreSimulatorSession`.
