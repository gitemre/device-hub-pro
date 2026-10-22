# Changelog

All notable changes to Device Hub Pro are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org).

## [Unreleased]

## [1.2.0] - 2026-10-22

### Added

- New: Device Hub Pro runs on macOS 15 Sequoia. It needed macOS 26 before.
- On macOS 15 the app uses the classic look instead of Liquid Glass.
- iOS simulator touch input needs Xcode 27, and iPhone Duo needs Xcode 27.1. Both need macOS 26.6.

## [1.1.4] - 2026-10-16

### Fixed

- A simulator's live view showed 57 frames a second and skipped one in 21. Now it shows all 60.

## [1.1.3] - 2026-10-15

### Added

- A problem report describes a foldable simulator a window shows: the hinge angle, posture and
  hold, the panel the app takes as lit and the one the live view shows, the last read of the two
  panels' screenshots (content and brightness), the stage's view and whether the screens are
  stuck; its summary has a line for it, and stuck screens are a known problem with their fix.
  Crash reports of a simulator's home screen, Safari and wallpaper are listed by name and date.
- A foldable simulator's pill keeps Device Hub's hinge slider (the system slider) in view at the
  right end of its capsule, past Closed, Partially Open, Open, Laptop and Tent: Device Hub shows
  it only while Option (⌥) is held, in place of the postures. Option now only turns Rotate left,
  with Device Hub's left-turn glyph.
- A 3D button after Rotate on that pill shows and hides the turnable 3D model, as View ▸ Show 3D
  Model does (it is lit while the model is on, and offered while the device frame is shown).
- In a narrow window the foldable's capsule gives up Laptop and Tent, then the slider, then the
  3D button, then Save Replay (which stays in Record's right-click menu), and the compact window
  scales the pill to fit.
- The compact window shows iPhone Duo in the same 3D model as the main window (front-on, turnable
  with View ▸ Show 3D Model), with its fold animations, touches on the lit screen and the hinge
  slider's live fold, where it drew the flat 2D frame. The window opens at Device Hub's 696 × 784
  for iPhone Duo and keeps that size as the device folds, unfolds or is turned, the model in it
  fitted as in the main window; a size you drag it to is kept for as long as the window lives.
  Every other device keeps Device Hub's 258 × 587.
- A zoomed iPhone Duo moves round the stage with ⌥⌘-drag or a scroll, as the 2D stage does.

### Changed

- iPhone Duo folds as Xcode 27.1's Device Hub draws it: the outer screen faces you up to 55°
  (43° closing), then the device turns once to its inner screen, held as the book the hinge is
  heading for; it no longer turns the whole closed device as it opens.
- The pill's posture glyphs turn with the device (Device Hub's landscape set), and a foldable's
  Rotate turns right, as Device Hub's does; the 3D device turns in Device Hub's 0.55 s.
- Tent and Laptop move in one go (turn, tip and hinge together), the lit screen facing you the
  whole way: no more tumbling, and Laptop no longer opens flat first. Laptop lies on its flat half,
  the one with the outer screen on its back, and stands the camera half up as its lid (it lay on
  the camera bump).
- The screen folding away keeps its last picture sharp, as in Device Hub.
- The 3D iPhone Duo folds at Device Hub's pace: its hinge trails the simulator's a little and it
  slides to its new place after the fold, where it used to snap shut and jump there.
- Closed, Partially Open and Open keep a foldable turned the way it is held, as Device Hub does
  (they turned it upright before); a turned, half-open device is a book seen from the front, a
  laptop only when Laptop is chosen.
- The hinge slider is Device Hub's width (84 pt for 180°), and dragging it folds the 3D model at the
  display's rate: the fold is recorded when the knob is let go, not at every degree.
- The first tap after a foldable folds onto its other screen answers at once (about 0.2 s): the new
  screen's session takes the input connection the last one had open, where it used to open its own
  on that tap and wait about a second.
- Laptop chosen from Tent lights the inner screen: the hinge folds to 30° first, as the simulator
  kept the outer screen lit (and the inner one black) when it opened straight from the tent.
- The 3D device model takes about a third less memory (about 1.8 GB instead of 2.7 GB on a
  full-screen stage): it is drawn at 1.5× the screen's pixels with 4× multisampling instead of 2×.

### Fixed

- A locked iPhone Duo opened (or closed) with the hinge slider kept the stage on the other panel,
  the 3D model showing the device from behind: locked, the simulator dims its lock screen on the
  panel that is not lit (65/255 beside the lit one's 137), and two panels that both showed
  something did not tell the lit one. The brighter one now counts as lit when it is at least 1.6
  times as bright.
- When a fold leaves both of iPhone Duo's panels dark for several seconds (a hung foreground app
  kept the simulator's display change waiting, both panels dark at 180° for half an hour), a
  "Screens Not Responding" banner over the pill locks and wakes the simulator with a click, which
  lets the change go ahead.
- iPhone Duo's 3D screen kept its last picture for good once the stage had been left and shown
  again (a simulator shut down and booted again, say), while the 2D stage was live: the new view's
  renderer never took the drawables of the panel's old texture, so every frame found none. The
  panels now take new textures when another renderer draws the scene, and a panel whose frames
  keep finding no drawable takes a new texture by itself.
- A simulator shut down and booted again within seconds elsewhere (Xcode's Device Hub shuts down
  the simulators it started when it quits) no longer leaves the stage at "The live view is not
  running" or shows it stopped while it runs: the simulator watcher now publishes a new boot even
  when both reads said Booted, the app's own list reads no longer leave the watcher behind, and a
  live session that saw its simulator go makes the app follow the next boot to ready. A connected
  input channel of the boot that ended is no longer handed to the next session.
- The 3D iPhone Duo no longer jumps while the hinge slider is dragged or a preset runs: every
  motion of the model now moves on the display's own frames (it ran off a 16 ms timer that beat
  against them, so many frames showed nothing moving and then it leapt), the model follows the
  knob's exact angle instead of whole degrees, and the display link rests while the stage is idle.
  The hinge's angle readout no longer redraws the whole stage for each degree, and the stage no
  longer reads Xcode's CoreSimulator plist from disk dozens of times a frame.
- iPhone Duo's 3D screen stayed black after the hinge slider opened it, or closed it part of the
  way: the simulator lights a panel by how the hinge moved (dragged a little at a time it kept the
  outer one lit up to 120°, dragged in one go it lit the inner one before 90°), and the app
  recorded the lit panel by the angle, so the stage faced the other, dark one (measured: 79° to
  107° and 150° back to 78° both showed the dark inner face). A move of a few degrees (the arrow
  keys, VoiceOver) now keeps the lit panel up to 120°, the app reads which panel is lit after every
  fold (presets, Laptop and Tent too, once their sweep is over; a read that cannot tell is tried
  again up to three times, and one asked for while another runs is no longer dropped), and a panel
  the stage shows that stays black for 0.3 s is read at once, not 0.5 s after the hinge stops
  (a screen that is black for good is read twice, until the hinge moves). The device faces the
  panel that is lit and turns to the other face when that changes, over the 0.55 s Device Hub
  takes, whenever the change comes; the presets turn as before. While the hinge slider is dragged the
  device faces the panel it is fed as long as that shows a picture; once it goes black the device
  turns by the hinge (Device Hub's 55° and 43°) and the stage moves to the other panel at once, a
  read confirming it after. Opened in one go it showed its black outer panel and the back of the
  other half for about a second, and a drag that closed it past the point where the guest lights
  the outer panel stayed dark for up to 6 s; now about 0.45 s of black (Device Hub's: 0.36 s), and a
  drag that keeps the outer panel lit shows its picture throughout.
- A panel of the 3D iPhone Duo could stay on its black placeholder: a picture the drawable queue
  had no room for is drawn again 30 ms later, a panel still waiting for its first picture gets the
  session's current frame again (a static screen sends none), a render that failed is asked for
  again, and a panel left dimmed while the stage was away goes dark.
- The 3D iPhone Duo vanished for about half a second whenever the zoom buttons changed the zoom
  from or to Zoom to Fit (and for a frame at wrong size after): the stage swapped between a scroll
  view and a plain layout, which made the model's view anew and loaded the model again. The zoom
  now scales the model inside one view that is never rebuilt, animated like the 2D stage's zoom,
  with Physical Size, Point Accurate and Pixel Accurate unchanged; the view stays the stage's size
  instead of growing with the zoom (its drawable was up to ten times the window), and a model
  larger than the stage runs behind the toolbar and the pill as before. The loaded model also outlives
  its view, so anything else that rebuilds the view (a new session, View ▸ Show 3D Model, the compact
  window closed and opened again within 20 seconds) shows it at once instead of after a reload. The
  main window hidden behind the compact window no longer draws the device a second time or copies
  the simulator's pictures into its model.
- View ▸ Device Color left the stage without iPhone Duo for about half a second while the other
  finish loaded: it now loads behind the one shown and takes its place when ready.
- A tap on iPhone Duo's screen just after a fold was lost (the simulator ignores touches while its
  hinge settles, a little longer than the fold looks); it is held and lands once the simulator
  takes touches again.
- The 3D iPhone Duo vanished for two or three frames each time a fold switched to the other screen,
  and closing it from open moved it sideways in its last frames.
- A stopped iPhone Duo showed a blank document as its picture on macOS 27.0.1, which knows the
  model but has no picture of it yet; the stopped page draws Xcode's device chrome instead until
  macOS has one.

## [1.1.2] - 2026-10-12

### Added

- **Help ▸ Report a Problem…** and a **Report…** button on error alerts with details: the sheet
  checks this Mac for causes we know (an emulator made by old Android tools, no hardware
  virtualization, a missing system image, a second adb, …) and shows each with its fix, and
  makes a report with the private details left out (user name, Mac name, serial numbers,
  addresses, tokens), ready to copy, save or open as a GitHub issue. Nothing is sent.

### Fixed

- An emulator now starts and mirrors on a Mac whose `~/.emulator_console_auth_token` is empty
  (the documented way to switch the emulator console's authentication off). `adb emu` prints
  nothing for such a console, so the app could not tell which emulator was which: Start waited
  three minutes for the VM and ended with "did not come online in time" (the VM left running,
  listed under its model name), and the mirror read "Emulator not responding" and "The emulator
  isn't sending its screen". The app now talks to the emulator's console itself, authenticating
  only when the console asks for it, and falls back to the emulator's own boot property for its
  AVD name; adb is asked only when the console cannot be reached.

## [1.1.1] - 2026-10-11

### Added

- **iPhone Duo (Xcode 27.1):** the stage's pill folds a foldable simulator as Device Hub's
  does (Closed, Partially Open and Open beside Rotate, with Laptop and Tent), Device ▸ Fold /
  Unfold and Orientation do it from the menu, and the stage follows the lit panel. Where Xcode
  ships Apple's 3D model of the device, the stage draws the live simulator in it as Device Hub
  does, from the front (its greys, its black round the panels, its size and place in each
  posture): the hinge folds on screen in step with the simulator's, the panel takes
  clicks, drags and typing, and its volume and side buttons move out under the pointer and press
  in on a click; View ▸ Show 3D Model lets the mouse turn and zoom it, and View ▸ Device Color
  picks its finish (Device Hub's dark one by default).
- **Keyboard settings,** as Device Hub has them: Capture keyboard shortcuts (⌘ shortcuts go
  to the device while the keyboard is captured), Secure keyboard entry, and Simulate hardware
  keyboard by default, with Device ▸ Keyboard ▸ Simulate Hardware Keyboard per simulator.
- **App Switcher** (⌃⇧⌘H) and **Action Button** in a simulator's Controls menu (the Action
  Button where the device has one).
- **Device ▸ Battery** for simulators: 100, 75, 50 or 25 % in the status bar.
- The iOS verifier gains Device & hardware rows: the hinge's status and angle, the size of the
  window (which panel of an iPhone Duo it is on), the app's state and the last key with its
  modifiers. A live test reads them back after each fold preset.

### Fixed

- An Android 17 emulator made with an older Android SDK (Command-line Tools 19 or earlier)
  failed to start on an Apple silicon Mac ("The emulator exited during startup", shown as
  API 0): those tools write its Android version as 0, and the emulator then runs it in software,
  which macOS refused. Start and Create put the version back from the system image. A start
  also stops early, with the reason, when the emulator's system image is missing or incomplete
  or built for Intel, and the startup alert names the software fallback when it happens.
- The iOS verifier recorded its deployment target as the SDK it was built with, so iPhone Duo
  showed it in a small compatibility window; it records the real SDK now.
- A simulator left Not Responding is looked at again on its own and goes live once it
  recovers.
- iPhone Duo on iOS 27.1 reads as ready (its boot ends in a data migration failure), and its
  status bar time is read.
- A foldable's fold is kept while the simulator stays booted, so quitting and opening the app
  shows it as it was left; one opened by something else shows its lit panel.

## [1.0.0] - 2026-10-08

The first public release of Device Hub Pro: one Mac app for Android emulators and phones,
iOS simulators and iPhones.

### Devices

- **One sidebar for every device:** running emulators, installed AVDs, USB and Wi-Fi
  Android phones, iOS simulators and connected iPhones, with search, sorting, groups,
  several windows and tabs.
- **Emulators:** create AVDs from the Pixel catalog, with system images downloaded in the
  background; start, cold boot, wipe, rename and delete them; remove system images you no
  longer need.
- **Wireless pairing** of Android phones by QR code or pairing code. A phone is followed
  between USB and Wi-Fi by itself.
- **Physical iPhones** (opt-in in Settings): a live view, input, apps, files, logs and
  device management for the phones you enable.

### Mirroring and input

- Emulators mirror at up to 60 fps through the emulator's shared-memory path; Android
  phones through scrcpy; iPhones through the native live view.
- Click, drag, scroll, type (including non-Latin text and the soft keyboard), hardware
  buttons, the navigation bar, rotation, folding and Wear OS, TV and Automotive emulators.

### Controls

- A Controls panel that reads each setting back from the device: appearance, text size,
  accessibility, network speed and latency, battery and charging, location, language and
  time, a clean status bar, colour filters, biometrics, app conditions and more.
- Every Controls row is also in the Device menu, with keyboard shortcuts shared between
  emulators and simulators.
- Settings profiles apply a saved set of settings to one or several devices.

### Apps and evidence

- Install APKs and app bundles by drag and drop; launch, stop, clear data and uninstall;
  open deep links; send push payloads, files and photos.
- Screenshots, screen recordings, replays, logcat and simulator logs with filters, crash
  reports and diagnostics bundles.

### Setup

- On a Mac without the Android SDK, **Install Android Tools…** downloads Google's official
  tools (and a Java runtime if needed) without administrator rights.
- In-app updates with Sparkle.
