# Features

The full feature reference for Device Hub Pro. The [README](../README.md) has the short tour.

## First run on a Mac without the Android SDK

When no `adb` can be found, the window shows a **Set up Android tools** card:

- **Install Android Tools…** downloads Google's official command-line tools, platform-tools
  and emulator into `~/Library/Android/sdk` (Android Studio's default folder, so Studio can
  share them). It needs no administrator rights and downloads nothing until you accept
  Google's license. If the Mac has no Java runtime, it offers to download Eclipse Temurin
  into the app's own folder.
- **Locate SDK…** points the app at an SDK folder you already have.
- **I use Android Studio…** opens the Android Studio download page.

When the tools are installed, the app offers to create your first emulator.

## Permissions macOS may ask for

- **Local Network**, when you pair or use a wireless Android device. The app asks only when
  you need it, not at launch.
- **Camera** and **Microphone**, only for the standard iPhone live view.
  The default native live view needs neither.
- **Desktop, Documents and Downloads folders**, to save screenshots and recordings and to
  read APKs.

## Everything it does


- **Devices and AVDs.** The sidebar lists running devices and installed AVDs (the
  Pixel Devices catalog built from the SDK's skins is under + ▸ Browse Catalog…). AVDs are created from any catalog
  skin; missing system images download in-app through sdkmanager (license acceptance
  and progress included), which needs the SDK's command-line tools and a Java runtime.
  A new AVD never overwrites an existing one: names are checked case-insensitively
  against the AVD folder and a free name is suggested. New Emulator… and the Pixel pages
  enforce each profile's minimum API (read from the SDK's bundled device definitions,
  `<d:api-level>`; Pixel 10 family 36.1, Pixel 9 Pro Fold 35, Pixel Fold 34): images below it
  read "Requires API X+", Create stays disabled for them and the default is the newest
  image that fits (a download when none is installed); with no cmdline-tools or no entry for
  the profile everything is allowed. A new phone emulator defaults to a Google APIs image,
  where every Controls row works; Play Store images stay selectable (they cannot be rooted,
  so the rows that need root are not shown on them). Create (New Emulator…, the catalog, the setup card's
  "Create an Emulator…") never locks the window: the sheet closes at once and the system
  image download and the avdmanager create run in a background queue
  (`AvdCreationQueue`). The sidebar shows a "Creating" placeholder row per emulator (name,
  "Downloading Android 17… 34%", a thin progress bar, Cancel; a failure stays on the row
  with Retry) and a toolbar Downloads button opens a popover with every running download,
  the "Download More System Images…" sheet's included. One sdkmanager install runs at a time
  app-wide, so the next shows "Waiting" and starts by itself; creates run one at a time. The
  Pixel page's "Download & Create & Start" queues the same way and starts the AVD when it
  is ready, so leaving the page no longer cancels the download. Rows carry Rename…, Reset
  Content and Settings…, Remove… (the AVD moves to the macOS Trash) and Show in Finder,
  plus the All Devices / Simulators / Physical Devices filter. `ANDROID_AVD_HOME`,
  `ANDROID_USER_HOME`, `ANDROID_EMULATOR_HOME` and `ANDROID_SDK_HOME` are honoured.
- **Hot-plug and reconnect.** The list follows `adb track-devices -l` (polling is only
  a fallback while the tracker is retried every 30 s). A pulled cable tears the mirror
  down and leaves a "disconnected" row; a returning device reconnects automatically
  with a capped backoff. Stop Mirror ends that episode, so a replugged device does not
  auto-resume.
- **Push payloads and profiles on iOS simulators (drag and drop).** Xcode 27's Device Hub
  dropped Simulator.app's drag and drop of `.apns` payloads and certificates; Device Hub Pro
  has them back (drop on the stage or a sidebar row, or Send Files…, ⇧⌘U). A `.apns`
  file is sent with `simctl push <udid> <bundle id> <file>`: the bundle id is the
  payload's `Simulator Target Bundle` key, and a file without one asks which installed
  app gets it (once per drop); several files go in order, and a payload that is not
  valid push JSON is explained by name. `.cer` / `.crt` / `.der` / `.pem` are trusted
  as root certificates (`simctl keychain add-root-cert`) after a confirmation. simctl
  has no command that installs a `.mobileconfig` profile, so a dropped profile gives
  up the certificates in it (root, PKCS#1 and PEM payloads, signed profiles too),
  which are trusted the same way after the same question; other payloads (Wi-Fi, VPN …)
  are left out and the drop overlay says so. An Android device answers a `.apns` drop
  with "Push notifications can't be sent to Android this way", a physical iPhone
  with "Push payloads and profiles can't be sent to a physical iPhone with public
  tools"; neither runs a command.
- **Push library, saved deep links and Launch with Options.** Device ▸ Push Notification…
  has built-in templates (simple alert, title / subtitle / body, badge, sound, silent
  `content-available`, rich `mutable-content` with a category) and a library of named
  payloads (name, bundle id, payload; save, update, rename, duplicate, delete) kept in
  `~/Library/Application Support/DeviceHubPro/push-library.json`. The editor turns smart
  quotes and dashes off (pasted curly quotes are straightened), the payload is checked
  as JSON before it is sent and the problem is shown under the editor, and
  Device ▸ Resend Last Push repeats the last push (`last-push.json`). Open URL… (the
  simulator's and Android's) has a saved-links menu beside the recents: named links,
  grouped by app (the scheme is suggested), added, edited, duplicated and deleted in
  Manage Saved Links… (`deep-links.json`). An app's menu in a simulator's Apps list has
  Launch with Options…: arguments (one per line), environment variables (`KEY=value`
  per line, validated, passed as `SIMCTL_CHILD_<KEY>`), wait for debugger
  (`simctl launch --wait-for-debugger`) and terminate the running instance first
  (`--terminate-running-process`); the last options are remembered per bundle id
  (`launch-options.json`). Streaming the app's stdout / stderr into the log pane is not
  offered: the simulator log pane reads the unified log, not a launch's console.
- **Emulator lifecycle.** Emulators started from Device Hub Pro Quick Boot from the AVD's
  snapshot, like Android Studio; they cold-boot only after an automatic display repair
  or when a powered-off emulator is powered on. Shut Down (Device ▸ Shut Down, ⌘.) asks the emulator to shut
  down through its console so the snapshot is saved (this can take about a minute; the
  status line counts the seconds). Emulators started elsewhere are never force-killed
  by Shut Down. Emulators launched by the app use token-authenticated gRPC.
- **Mirroring.** Emulators stream over the emulator's gRPC API. On emulator
  **37.2.3 or newer** frames come through shared memory (MMAP) by default; older
  emulators, and any MMAP failure, fall back to raw frames automatically
  (`DHP_DISABLE_MMAP=1` forces raw frames). MMAP frame files live in a private
  folder of the per-user temporary directory and are removed when the stream ends.
  Settings ▸ Emulator offers "Update the emulator to …" (through sdkmanager, with no
  emulator running) while the installed one is older than 37.2.3 and a newer one is
  available, because raw frames cost far more memory and CPU than MMAP.
  Settings ▸ Android system images lists the installed images with their size; Remove…
  uninstalls one through sdkmanager after saying what it frees and which emulators are built
  on it (they stop starting until it is downloaded again); an emulator running on it blocks
  the removal.
  Physical devices mirror through scrcpy's server protocol over adb (MediaCodec H.264
  → VideoToolbox → Metal, zero-copy); mirroring wakes the phone's screen, and slow
  wireless-adb links are tolerated. The Metal view draws only when a new frame
  arrives.
- **Input.** Emulators get gRPC touch including multi-touch; a two-finger trackpad
  scroll becomes one touch stroke that starts outside Android's gesture zones and
  only after the touch slop, so short nudges never tap. Physical devices use scrcpy's
  control socket: multi-touch, keys, text, real wheel scrolling, and right-click as
  Back (which also wakes the screen); `adb shell input` is the fallback. Text with
  non-ASCII characters (Turkish letters, emoji) is pasted through the device
  clipboard: on emulators the clipboard is restored afterwards, on phones each paste
  is acknowledged before the next. Control-key combinations and function keys are not
  typed as text.
- **Port forwarding and a device shell (Android).** Device ▸ Port Forwarding… lists the
  device's `adb forward` and `adb reverse` rules with Add and Remove (every call names the
  device's serial). Device ▸ Shell… runs `adb -s <serial> shell <command>` one command at a
  time (not a terminal: nothing typed reaches a running command), with ↑/↓ history, Cancel
  and an output cap of 2 MB (oldest lines dropped). 
- **Wireless pairing.** File ▸ Pair Nearby Device… runs Android 11+'s pairing-code
  handshake. The connect port can stay empty: adb discovers it over mDNS. A pair whose
  connect fails keeps the pairing and offers Connect with a corrected port.
- **Controls.** Battery level/charging, battery saver, airplane mode, Wi-Fi,
  Bluetooth, mobile data and Data Saver; location spoofing (the one Location menu below);
  volume; rotation (the fold strip under a foldable emulator handles posture and hinge; telephony, sensors, emulator
  pause and the fingerprint touch are in the Device menu, the fingerprint touch in the panel's Biometrics group too; a
  simulator's Settings panel is Device Hub's three cards followed by collapsed groups); appearance, text size, reduce
  motion, TalkBack, colour filters, contrast and developer toggles. The device settings are in the Device menu as
  well, on every platform: Accessibility, Appearance, Location, Sound, Language (with 24-hour time), Time Zone and
  Clean Status Bar (a simulator adds Face ID, push, permissions and Open URL), so each has a menu path and a key where
  one exists. An item the device has no hardware for is left out, read from the device itself (`pm list features`): no
  fingerprint touch on a Wear OS watch, no telephony, Shake or Split Screen on a TV. Rows show what the device
  actually does: Force RTL applies at once on Android 8+ (the language list is pushed
  again, as Developer options does) and shows "Restart pending" if that push did not
  take; Force RTL before Android 8 reads
  "Applies after the device restarts" or "Restart pending";
  Battery saver is disabled while a charger is connected (with Turn Charging Off on
  emulators); a reading the device did not give shows as unknown instead of Off.
  Emulator-only sections are hidden for physical devices. On resizable AVDs
  (`hw.resizable.configs` in `config.ini`) the toolbar's Resize mode button and Device ▸
  Enter Resize Mode offer the emulator's display presets (the New Emulator menus do not
  offer the Resizable profile).
- **Language & time.** A Controls group for emulators and phones; a row is hidden
  when the device lacks its mechanism. Language is a searchable picker over the
  device's own language list (Android 8+), with suggested languages and Restore,
  which puts back the list from before the first change. A bundled `app_process`
  helper dex pushes the list the way Settings does (lists, `-u-` regional
  preferences, a new primary language); on Android 16 QPR2 (API 36.1) and newer,
  `cmd locale set-device-locale` takes a single listed language that keeps the
  primary language, and is the fallback when the helper fails. The helper's source
  and reproducible build are in `Sources/DeviceHubProKit/Controls/LocaleHelper/` and
  `Scripts/build-locale-helper.sh`. Date & time and Time zone (Android 9+) turn
  their automatic switch off by itself: Time zone's list starts with Automatic, which
  turns it back on, and Date & time shows a small Reset to automatic button while the
  time is set by hand. On a phone, a clock change asks first. 24-hour time is locale default, 12-hour or 24-hour. Each write is read back
  from where Android applies it.
- **Network and app conditions.** Network conditions (emulators only): speed (the
  emulator's GSM, HSCSD, GPRS, UMTS, EDGE, HSDPA, LTE and EVDO rates, or Full),
  connection latency (GPRS/UMTS, EDGE/HSCSD and GSM presets, or a custom range),
  metered mobile data and Reset conditions (a caption under Speed names the data
  path being shaped; for offline testing use Network ▸ Airplane
  mode, Wi-Fi and Mobile data). Speed and latency are applied inside
  the device with `tc netem`, in both directions, on whichever interface carries
  the traffic (Wi-Fi or mobile data; the shaping follows the data path when it
  moves). The emulator console's own `network speed` throttles nothing and its
  `network delay` holds only new connection setups, so Device Hub Pro does not use them.
  `tc` needs root: Device Hub Pro runs `adb root` when you pick a condition (it restarts
  adbd; logcat reconnects) and `adb unroot` when conditions reset, unless the device
  was root already. Only a debuggable build allows that (a Google APIs image, not
  Play Store, `ro.debuggable=1`), so on Play Store images, user builds and physical
  phones the Speed and Connection latency rows are not shown. The latency is the
  added round trip, half in each direction. Disconnecting, quitting
  or Shut Down puts back what Device Hub Pro changed. App conditions (any device) act on a
  target app: Simulate low memory (Android 6+: one Send button that sends
  RUNNING_CRITICAL to an app in the foreground and COMPLETE to one in the
  background, gated like the activity manager; a refusal shows its reason) and
  Kill process (only while the app is in the background), confirmed by the pid
  and, on Android 11+, by Android's exit record.
- **Clean status bar.** One switch, a plain row at the bottom of the Controls panel
  (Android 6+ emulators and phones; a simulator has the same switch above Reset to
  Defaults, and a Device menu item), that freezes the status bar for store screenshots
  with SystemUI's demo mode, the mechanism behind Developer options ▸ System UI demo
  mode: 9:41, full Wi-Fi and signal, battery 100 % not charging, notification icons
  hidden where Android supports it. Off ends it. Apps still see the real time, battery
  and network. `am broadcast` answers the same whether SystemUI took a command or
  not, so each write is read back from SystemUI: the switch from `dumpsys
  DemoModeController` (Android 12+; before that it shows the key Device Hub Pro wrote) and
  the battery from `BatteryController` (Android 13+). From Android 14 the demo mobile
  icon follows the real connection, so it is hidden; where SystemUI lists no demo
  handler for notification icons (the API 37 emulator), they stay. A phone maker's
  status bar may ignore demo mode. Turning
  it off, disconnecting, Shut Down and quit end Device Hub Pro's demo mode, realign SystemUI's
  battery and put `sysui_demo_allowed` and `sysui_tuner_demo_on` back. A put-back
  that could not reach the device is kept (per AVD, or per serial for a phone) and
  runs on its next session, also after a relaunch. Demo mode someone else turned
  on is left on at disconnect.
- **Colour filters.** Controls ▸ Accessibility has Color Filter (Device Hub's None,
  Grayscale, Red/Green (Protanopia), Green/Red (Deuteranopia) and Blue/Yellow
  (Tritanopia)), on emulators and phones with Android 7+. It writes Android's Color
  correction settings for the user on screen (`accessibility_display_daltonizer` and
  its `_enabled` switch; an
  inversion set elsewhere still shows in the captions). None turns only the switch off
  and keeps the mode, as Settings does; the Intensity setting is never written. Each
  write is read back from SurfaceFlinger's colour matrix for the first enabled
  physical display (`dumpsys SurfaceFlinger --comp-displays`, Android 13+), and
  from the settings on Android 7–12L. A caption says when another colour transform
  (Night Light, Extra dim) is on too, or when the screen is off. A Developer options
  ▸ Simulate color space simulation reads "Simulated", and a mode Settings does not
  offer reads "Mode N". Screenshots leave the filter out and the emulator draws it
  wrongly, so check the look on a phone's own screen. Nothing is put back on
  disconnect: these are persistent accessibility settings.
- **Link URL.** One row, a plain row at the bottom of the Controls panel (any Android
  device, a simulator and a physical iPhone alike), above Clean status bar: a URL field
  with the saved-links bookmark menu, the recent-links menu (the last 10 links opened
  from this Mac, with Clear Recents) and an Open button. On Android the link is opened
  as an `ACTION_VIEW` intent with `am start -W`, always with `CATEGORY_BROWSABLE` the
  way a browser click sends it and never aimed at one app, so the system resolves it
  like a real tap. It is sent exactly as typed: Device Hub Pro quotes it for the device
  shell and escapes non-ASCII bytes so they arrive unchanged (up to 30,000 bytes after
  escaping, 3,700 before Android 7). From Android 7 the URL caption previews the app
  that will open it and how many can (`cmd package resolve-activity` and
  `query-activities`); when no app opens it, the caption names an activity whose
  filter lacks `CATEGORY_DEFAULT`. Open reports what Android did: the activity it
  started with the launch kind and time, a reused screen or a task brought to the
  front (the app then gets the link only through `onNewIntent`, and only for a
  singleTop or singleTask activity), the chooser, no handler, or a refusal. With no
  answer within adb's 30 s bound it says so, and the link is not added to Recents. The
  row writes no settings, so nothing is put back. 
- **Location.** One menu, the same on Android emulators and iOS simulators: None,
  Device Hub's fourteen places, a Trips section (City Run, City Bicycle Ride, Freeway
  Drive) and Custom Location…, a sheet for a coordinate or a route between two points
  at a speed. A simulator runs Apple's own scenarios (`simctl location run`) and routes
  (`simctl location start`). An emulator has no scenarios, so Device Hub Pro plays routes of
  its own over the emulator's gRPC `setGps` at about 1 Hz (a run at 3 m/s, a bicycle
  ride at 6 m/s, a freeway drive at 30 m/s, repeating around Apple Park in Cupertino:
  these waypoints are Device Hub Pro's own, derived from the names and speeds, not Apple's),
  until you pick another location, None, or the device changes. Android cannot clear a
  fix, so None only stops a route and leaves the last position. A physical iPhone keeps
  its own subset (places and coordinates through devicectl).
- **Clipboard.** Edit ▸ Send Clipboard, Get Clipboard and Use Shared Clipboard (automatic
  sync), for emulators, simulators and (over scrcpy's control channel) physical Android
  devices.
- **Capture.** The pill's camera (and ⇧⌘S) saves a screenshot at once, like Device
  Hub's: in the Mac's screenshot folder (the Desktop by default) as "Screenshot <device>
  <date> at <time>.png", with a "Screenshot Saved / Open in Finder" banner over the pill for
  about three seconds. The camera's right-click menu offers Annotate Screenshot… (arrow,
  rectangle, text, and redaction as an opaque black fill, saved through a save panel);
  Device ▸ Copy Screenshot (⇧⌘C) copies it, optionally composited into the device skin. Video recording (⇧⌘R) runs on the Mac from the mirror's frames:
  no length limit, works for emulators, ATD images and phones, no audio, letterboxed
  after a rotation or fold, written in 10 s fragments so a crash keeps what was
  recorded. A stopped recording is saved at once into the capture folder
  (Settings ▸ Screenshots ▸ Save in) with a "Recording Saved" banner, like a screenshot or a
  replay; the save panel opens only when no folder can take it, and a disconnect saves it
  the same way and says so. A replay buffer (15/30/60 s)
  saves the last seconds with ⌥⌘R or the clock button next to Record in the bottom pill
  (shown for Android devices and for a simulator on the live canvas; a one-time tip
  points at it after your first screenshot or recording); a saved replay shows the same
  thumbnail banner ("Replay Saved"). The simulator's ring encodes the live canvas scaled
  to fit 1080 × 1920 at 15 fps and pauses while the window is hidden or occluded; the
  view-only canvas and physical iPhones keep none. Settings ▸ Screenshots ▸ Save in picks the folder for
  screenshots and recordings (default: the Mac's screenshot folder, else the Desktop; a
  folder that disappeared falls back to the default). The banner after a screenshot or a
  recording shows a thumbnail you can drag out as the file itself (into Finder, Mail, a
  chat) and click to reveal in Finder.
- **Shortcuts that differ from Simulator.app.** Screenshot is ⇧⌘S here (Simulator.app: ⌘S),
  and a simulator's Face ID ▸ Authorized / Unauthorized items are ⌥⇧⌘M / ⌥⇧⌘N
  (Simulator.app: ⌥⌘M / ⌥⌘N). Simulator.app's
  Notification Center and Control Center shortcuts are not offered: no verified way to
  drive them from here yet (a top-edge swipe is available by hand on the live canvas).
- **Apps.** Installed apps with their real icons (adaptive icons composited the way
  the launcher shows them), launch, force stop, clear data, App Info and uninstall.
  Install accepts an `.apk` (test-only builds included), a bundletool `.apks` set (the
  variant matching the device, every module) or a folder of split APKs — drop them
  onto the mirror; the Apps `+` picker currently takes single APKs.
- **Logcat and diagnostics.** Live `adb logcat` with package follow (the app's main
  process while it runs, "waiting for process" otherwise, no history replay on
  restarts), level and tag/message filters over the retained history, Java crash
  highlighting, pause/clear and export. When a followed app restarts, a marker line separates
  its previous run from the new one, and the app picker refreshes while the log streams
  (an iOS simulator's list includes apps installed outside Device Hub Pro, such as from Xcode or
  `flutter run`). The diagnostics bundle zips the last five
  minutes of logcat byte for byte (the last 10 000 lines on Android 6), battery and
  memory dumps, `getprop` and `device.json`; a section that fails is written as
  `<name>.error.txt`.
- **Log focus (⌥⌘L).** View ▸ Log Focus, the toolbar button or Reports ▸ Logs ▸ Focus
  turns the window into the phone (still interactive) on the left and a wide log pane
  on the right; the sidebar and inspector hide and Esc or the same button brings the
  previous layout back. One row per entry (time, coloured level badge, tag or process,
  message) in a table built for thousands of long lines, with a Wrap switch (or a
  sideways scroll), a detail strip with the selected line in full, copy selected / all
  visible, app (Android package or simulator process), level and text filters, Pause,
  Clear, Export, and a tail that follows until you scroll up ("Jump to latest" resumes
  it). Android devices and iOS simulators stream; a physical iPhone streams the console of
  one app (Launch & Stream in the pane: the app is launched through devicectl with its stdout
  and stderr bridged, so only that app's lines show, every one as Info, and stopping the
  stream ends the app's session).
- **Keyboard Capture (⌘K) and the soft keyboard.** Device ▸ Keyboard ▸ Keyboard Capture (also
  the toolbar's keyboard button) sends your Mac keyboard to the device. With capture off, an
  emulator shows its own full on-screen keyboard, so you can see fields hidden under it; turning
  capture on, selecting another device and quitting put the emulator's setting back (phones are
  not touched; see [docs/soft-keyboard.md](soft-keyboard.md)).
- **Stuck emulator screen.** When an emulator is running but never sends a frame, the stage says
  "The emulator isn't sending its screen" with Restart Emulator and Retry buttons.
- **Biometrics.** A simulator's Face ID / Touch ID match or non-match (⌥⇧⌘M / ⌥⇧⌘N) waits for
  the simulator's prompt and is sent when it appears, or at once when one is already up.
- **Shortcuts.** Device-menu shortcuts shared by the devices that have the item: Home ⇧⌘H,
  Rotate Left / Right ⌘← / ⌘→, Screenshot ⇧⌘S, Copy Screenshot ⇧⌘C, Record Screen ⇧⌘R, Save
  Replay ⌥⌘R, Shake ⌃⌘Z, Keyboard Capture ⌘K, Send Files ⇧⌘U, Shut Down ⌘. (a simulator's
  Force Shut Down ⌥⌘.), Toggle Appearance ⇧⌘A, text size ⌥⌘+ / ⌥⌘−, volume ⌘↑ / ⌘↓, and the
  same key for the same job on both kinds: Lock (simulator) and Power (emulator) ⌘L, Siri and
  Assistant ⌥⇧⌘H, Simulate Memory Warning and Simulate Low Memory ⇧⌘M, Authorized with Face ID
  and Fingerprint Touch ⌥⇧⌘M. An emulator adds Back ⌘[, Recents ⌘], Previous App ⌥⌘[ and
  Split Screen ⌥⌘S; a simulator adds Unauthorized with Face ID ⌥⇧⌘N and Slow Animations ⌥⌘T. ⌘←, ⌘→, ⌘↑, ⌘↓, ⌘[ and ⌘]
  act on the device only when no text field has the focus; in a text field they keep their
  editing meaning.
- **View menu and sidebar.** View ▸ Zoom In / Zoom Out / Zoom to Fit are ⌘+ / ⌘− / ⌘0, Hide
  Sidebar ⇧⌘L, Inspectors ▸ Settings, Reports and Info ⌥⌘1 / ⌥⌘2 / ⌥⌘3 and Show / Hide
  Inspector ⌘I. The sidebar sorts by Availability, Recent, Name, Fidelity, Platform or
  Operating System (View ▸ Sort By), filters to All Devices, Simulators or Physical Devices
  and can show or hide its groups (View ▸ Filter).
- **Wear OS, TV and Automotive emulators.** File ▸ New Emulator offers Phone, Tablet, Foldable,
  Wear OS, TV and Automotive, plus Browse Catalog…; a device that cannot rotate (TV, watch,
  car) has no Rotate items.
- **Updates and simulators on quit.** A packaged release has Device Hub Pro ▸ Check for Updates… and
  Settings ▸ Updates ▸ Automatically check for updates (on by default); a build from source
  has neither. Settings ▸ Simulators ▸ When Device Hub Pro quits chooses between shutting down the
  simulators it started and leaving them running; holding Option in the Device Hub Pro menu quits
  the other way. A simulator Device Hub Pro did not start is never shut down.
- **Skins and device frames.** The live mirror renders inside the AVD's own SDK skin
  (bezel, camera cutout, hinge) and follows folds; foldables have a stage strip with
  posture presets and a 0–180° hinge slider that moves the device while dragged.
- **Compact window.** The toolbar's compress button (Switch to compact window) shows the
  live mirror and its controls in a small window. Window ▸ Stay on Top keeps the window you are in (the compact
  window or a main window) above other windows; the choice is per window and new windows
  start with the last one set.
- **Scale modes.** View ▸ Physical Size (⌘1), Point Accurate (⌘2: one device point, or one
  dp on Android, per Mac point), Pixel Accurate (⌘3: one device pixel per Mac screen pixel,
  on the window's backing scale) and Fit Screen (⌘4) are Simulator.app's four modes; the
  active one is checked and kept while the window or the stream is resized. Device ▸ Shake
  (⌃⌘Z) shakes a simulator, and on an emulator jolts the virtual accelerometer.
- **Several devices at once.** ⌘-click, ⇧-click, ⇧-arrow or ⌘A in the sidebar select
  several devices, emulators, phones and iOS simulators mixed. Device ▸ Apply to Selected
  sets the appearance, text size, language, a saved location or a clean status bar on
  each of them, opens a link or installs a build (one per platform), and Device ▸
  Screenshot All Selected (⌥⇧⌘S) saves one PNG per device in a new folder. Four devices
  work at a time; one that is not running, or whose platform cannot take the action, is
  skipped with the reason, and the devices that failed are named together. 
- **Settings profiles** (a Device Hub Pro addition beyond Device Hub). Device ▸ Apply Profile
  applies a named set of settings (appearance, text size, Reduce Motion, Increase Contrast,
  Show Borders, screen reader, location, language, 24-hour time, clean status bar) to the
  device shown, or to every selected device, an emulator, a phone and a simulator mixed,
  through the same adb / simctl paths as the Controls rows and with no extra permission.
  Built in: Screenshots, Dark Mode, Accessibility Stress and Defaults (they can be
  duplicated, not changed). Save Current Settings as Profile… reads the device and keeps
  it; Manage Profiles… renames, duplicates and deletes. A setting a device cannot take is
  skipped and named in the result ("Not applied on iPhone 17: …"). Physical iPhones are
  not a target.
- **Simulator crash reports.** Diagnostics lists a simulator's crash reports (Device Hub
  says they are unavailable for simulators): the Mac's crash reporter keeps them in
  `~/Library/Logs/DiagnosticReports`, each naming its simulator. Newest first, with the
  process, time and exception; a runtime daemon's crash loop is one row with a count
  (an app's crashes stay one row each);
  "My app only" while the log follows an app; open in Console, show in Finder or copy.
  Reports are only read, never removed.
- **Physical iPhones and iPads (view and manage, opt-in).** Settings ▸ Physical Apple
  Devices ▸ "Show physical Apple devices" (off by default; off means the app never
  runs `devicectl list devices`). On, the sidebar lists the
  devices CoreDevice knows first in Available (the model, "iPhone 12", under the name), refreshed every 5 s while the app is active, and every one
  starts "Not enabled": Device Hub Pro sends a device nothing but that list until you choose
  Use This Device… (a confirmation names it; Stop Using This Device undoes it; the
  choice is kept by hardware UDID). Unpaired, disconnected and Developer Mode off rows
  say so with a hint: pairing, trust and Developer Mode are your own steps in Xcode,
  the app never starts them. A selected, enabled, Ready device shows its screen,
  **view only** (nothing you do on it reaches the phone: no touches, no keys, no
  buttons), in its Apple device chrome when Xcode ships one for its model. Connected by
  **USB**, it is the phone's live screen through the public CoreMediaIO + AVFoundation
  capture, and that needs **Camera
  access** for Device Hub Pro: the first time, macOS asks; if it was denied, the stage says
  "Allow Device Hub Pro under System Settings › Privacy & Security › Camera to see the screen
  live." beside a button that only opens that Settings pane (the app never changes a
  setting). Where the live screen is not available (Wi-Fi, no capture device, no Camera
  permission), or with **Live View** off, the stage shows a **self-refreshing screenshot
  preview** instead (a small line says "View only · refreshes about every 1.5 s", the measured
  pace of public `devicectl` screenshots, roughly 0.7 pictures a second over Wi-Fi); the
  **Auto-refresh** switch turns that off and leaves the static panel. Like Device Hub, the stage
  has nothing above the phone: **Live View**, **Auto-refresh** and **Control** are switches in the
  menus, and the pill is Home, Screenshot and Rotate (no Record button; Record Screen is in the
  Controls menu). A small status line appears only when something needs saying (Control starting or
  failed, the preview's pace, a permission hint).
  Either view runs only while the device is selected and its window is visible, and
  stops when you deselect it, close the window, choose Stop Using This Device, turn the
  setting off, unplug it or quit; one window shows a device at a time. Take Screenshot
  (saved at once like every other device's) uses the live
  frame while a view runs, else `devicectl`; Record works on the live or preview view
  (a whole recording of it, saved like any other device's); the static panel keeps Take
  Screenshot and Record Screen (10 s through `devicectl`) until the device reports it
  unsupported (the iPhone 12 on iOS 27 does). The live view also plays the phone's audio on the Mac,
  which needs **Microphone access** for Device Hub Pro (macOS asks once; if it was denied, the
  stage says where to allow it): a menu item mutes it, Settings ›
  Emulator › Audio set to Disabled silences it, with several windows only the active one
  plays, and recordings of the view have no sound. A turned phone turns its
  chrome to landscape left (the capture does not say which way it was turned). An Info
  card with Device Hub's rows (Name, OS; Capacity, ECID, Model, Product Type, Serial Number, UDID;
  Display, as the device reports them, re-read every 10 s while visible) and Edit Visibility,
  where pairing, connection, Developer Mode, Developer Disk Image, lock state and the OS build
  are ticked off by default. Once a device is enabled its Apps tab lists its apps with their
  real icons (fetched lazily, two at a time, cached under `~/Library/Caches/DeviceHubPro/icons`), a
  scope popup (User Apps, the default, or All Apps with the system apps) and Device Hub's row menu:
  Launch (replacing a running copy), Terminate while the app runs, Copy Bundle ID / Version,
  App Container ▸ Show Container Files… (a development build's data container, "Save to…"
  per file), Uninstall (confirmed); Install is `+` or a drop of a `.app` or `.ipa` on the stage or
  the tab, and opening a link is a menu action; Reports lists
  the device's report files newest first like Device Hub's Reports tab (a Filter field and
  a Crashes / Spins / Logs / Diagnostics pop-up; every `.ips` is a Log), with Open, Show in
  Finder and Save to… on a row. Its Controls tab offers the rows the
  phone's own CoreDevice capability list allows (on an iPhone 12 / iOS 27.0: Appearance,
  Liquid Glass, Text Size, Reduce Motion, Show Borders, Reduce Transparency, VoiceOver, Color
  Filter, Increase Contrast, a simulated Location the phone keeps until you choose None; its
  clipboard is on demand through the Device menu); a row the phone does not offer, or that does not work on
  it (Memory warning fails on that phone; Orientation turns the app in front but the phone never reports the pose back, so Rotate, in the stage pill and the Controls menu, is its surface and needs no Control), or that
  only reaches a simulator, is left out and named with its reason. Nothing is ever deleted on
  the device (only an app you confirm to uninstall goes). A physical device is never selected
  on its own. `DHP_IPHONE_UDID=<hardware UDID>` restricts
  the app to that one device, which then counts as enabled without the dialog (for
  runs driven by an agent on a dedicated test iPhone); it does not turn the setting on.
- **Controlling an iPhone.** With an enabled, Ready iPhone selected and its view showing, mouse,
  keyboard and the Home and volume buttons reach the phone by themselves: this "fast input" is on
  by default, starts when the view shows and stops with it. It uses a private Apple API that may
  break with Xcode updates; Settings ▸ Physical Apple Devices has a switch to turn it off. Keys
  are sent as physical keys, so set the iPhone's hardware keyboard layout to match the Mac's. If
  it cannot start, the status line under the phone says why and offers Retry. Clicks, drags and
  typing on the picture show a touch dot under the pointer, Controls ▸ Home, Siri, App Switcher
  and Rotate Left / Right press the phone's own buttons, and a landscape phone
  turns its chrome the right way.
  The fallback is a public XCTest input runner (`ios/agent`), which Siri, the App Switcher and
  typing that fast input cannot do start by themselves. It needs Xcode signed in with an Apple ID
  (Xcode ▸ Settings ▸ Accounts), a **development profile that covers the phone**, the phone
  unlocked and Developer Mode on; nothing is typed in Device Hub Pro: it reads the Apple Development
  team from the login keychain's certificates, asks once only if there are several, and
  remembers it. The first time Device Hub Pro builds and signs the small runner into
  `~/Library/Caches/DeviceHubPro/agent/` (about a minute; rebuilt only when its sources, the team,
  the phone or Xcode change) and installs it on the phone (about a minute more); later starts
  take a few seconds. The runner listens only on the phone's CoreDevice tunnel address and
  answers only requests that carry a fresh per-launch token. Each action takes about half a
  second, there is no multi-touch and no live dragging (a drag is one swipe sent on mouse-up),
  and the lock button has no public equivalent. Typing goes to the app that owns the keyboard;
  with none found the status line says "Tap a text field first". If anything fails, Control
  turns itself off and the status line says why; the picture stays. Control stops with the
  view. The phone shows its own "screen sharing" pill while the runner runs.
- **Keyboard.** The sidebar, the Apps list and the stage pill work from the keyboard;
  with macOS Keyboard navigation on, Tab reaches the Controls rows.
- **Several windows and tabs.** ⌘T opens a new tab and ⇧⌘N a new window (File menu), and a
  sidebar row's menu has Open in New Window and Open in New Tab. A device is mirrored in one
  window at a time.
- **Inspired by Xcode's Device Hub, works alongside it.** Device Hub Pro is an independent
  tool, not affiliated with Apple. Its shell (sidebar, toolbar, stage pill, inspector)
  follows Device Hub's look; the measured values live in
  `Sources/DeviceHubProApp/ParityMetrics.swift`, and the live pixel harness is
  `Scripts/parity-check.sh`.
