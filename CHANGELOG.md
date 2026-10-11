# Changelog

All notable changes to Device Hub Pro are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org).

## [Unreleased]

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
- In the 3D model, iPhone Duo's Tent showed its outer panel's interface upside down under the
  hinge: a tent is held as its outer side is seen now (landscape left), a laptop as before.
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
