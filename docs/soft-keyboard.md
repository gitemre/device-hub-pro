# Android soft keyboard while Keyboard Capture is off

Requirement: with Keyboard Capture off the device's own
full on-screen keyboard must show (so a tester can see fields hidden under
it); with capture on, typing from the Mac keyboard works as before. iOS
needed no change (measured).

## Mechanism

`SoftKeyboardLease` (Kit) / `AppModel+SoftKeyboard.swift` (app): while the
stage shows an emulator and capture is off, the secure setting
`show_ime_with_hard_keyboard` is 1. Capture on, another selection and quit
put back the value read before the first write (a missing key is deleted
again). All steps are idempotent: it reads first, writes only a value that
differs, and keeps the first reading as the original. Phones are not touched.
No AVD restart, no `config.ini` change.

## Hint

The first time the user turns Keyboard Capture off while an emulator is on
the stage, a one-time popover on the toolbar toggle says: "Keyboard Capture
is off: type with the emulator's own keyboard. If the keyboard shows only its
toolbar, choose ≡ ▸ Show on-screen keyboard (Alt+K)." (`softKeyboardHintShown`
in preferences; `SoftKeyboardHint`). While capture is off with an emulator
selected, the toggle's tooltip appends the same pointer. Phones and iOS get
neither.

## Live measurements, 2026-10-05

Scratch AVD (own `ANDROID_AVD_HOME`, headless, port 5600, deleted
afterwards): API 35 google_apis arm64, the stock keyboard, `hw.keyboard=yes`,
`hw.keyboard.lid=yes` (config copied from an DeviceHubPro-created AVD).
`getevent -p`: the emulator adds a `qwerty2` keyboard device (event12); the
multi-touch devices carry the only `SW` (lid) capability, 0000.

| `show_ime_with_hard_keyboard` | tap launcher search field | `dumpsys input_method` | screencap |
|---|---|---|---|
| 1 (image default) | keyboard opens | `mInputShown=true` | full keyboard (toolbar row, QWERTY, bottom row) |
| 1, after hardware keys through the emulator console (`emu event text hello`, `event send EV_KEY:...`) | stays | `mInputShown=true`; the typed text arrives | full keyboard still visible |
| 0 | field focused | `mInputShown=true` (stale flag) | no keyboard at all, only the nav bar's IME switcher |

So the setting is the live switch, and typing from the Mac keyboard does not
make the keyboard hide its keyboard. The floating toolbar seen with
capture off could not be reproduced on this image (it showed nothing at 0 and
the full keyboard at 1); it may come from an AVD or keyboard build whose
setting reads 0 or differs. If it still shows after this change, record
`adb shell settings get secure show_ime_with_hard_keyboard` and the keyboard
version for that AVD.

## Candidates not needed

(b) detaching the virtual keyboard at runtime, (c) the lid switch and (d)
switching IME were not tried: (a) works live and reverts cleanly. (e)
`hw.keyboard=no` for the next boot would also lose hardware key forwarding.

## Tests

`SoftKeyboardLeaseTests` (fake adb argv sequences: 0 to 1 and back, missing
key deleted, already-1 untouched, idempotence, sync, restore without lease).
