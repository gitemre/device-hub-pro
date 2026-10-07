# Changelog

All notable changes to Device Hub Pro are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org).

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
