# physical-xiaomi

Real captures from a Xiaomi phone over USB, taken once. Exactly three read-only commands ran, each with
`adb -s <serial>`:

| File | Command |
|---|---|
| `shell-dumpsys-display.txt` | `adb shell dumpsys display` |
| `shell-getprop-ro.product.model.txt` | `adb shell getprop ro.product.model` |
| `shell-getprop-ro.build.version.sdk.txt` | `adb shell getprop ro.build.version.sdk` |

The two `getprop` files are byte-exact (`2209116AG`, API `33`).

`shell-dumpsys-display.txt` is trimmed, as `AGENTS.md` allows: it keeps only
lines 70–71 of the 97,332-byte dump, byte-exact (the `Display Devices:
size=1` header and the one `DisplayDeviceInfo{…}` line, which is all
`DisplayShape.parse` reads). Everything else was dropped because the test
does not need it and because it held personal data: the Wi-Fi display
adapter's remembered and available displays (TV names and their MAC
addresses) and process ids. The kept lines hold no serial, user name, network
name, MAC or IP address, so nothing in them was replaced. The panel's
`uniqueId` (`local:<physical display id>`) and `address {port=…, model=…}` are
the display hardware's ids, not the phone user's, and stay as captured. The
display name is the phone's Turkish locale string for "Built-in Screen".

sha256 of the kept lines: `d2075f45843617a7…`; of the full dump (not
committed): `13e866ab69779310…`.

Loaded by `PhysicalXiaomiDisplayShapeTests`.

## devices-l-wireless-twice.txt

`adb devices -l` captured on 2026-10-01, read-only, after the phone was
paired over Wi-Fi: the same phone is listed twice (adb's `ip:port` connect and
its mDNS auto-connect entry), beside an emulator. Replaced with same-length
placeholders, as `AGENTS.md` allows: the phone's `ro.serialno` (12 chars,
`aqaserial001`) in the mDNS name and the LAN address (13 chars,
`198.51.100.11`); the port, model and transport ids are as captured. Its
`ro.serialno` was read once, read-only (`adb -s <serial> shell getprop
ro.serialno`): the same value as in the mDNS name. Loaded by
`AndroidDeviceGroupingTests`.

## shell-getprop-miui-adbinput-off.txt

Captured 2026-10-01, read-only, with `adb -s <serial> shell "getprop
ro.miui.ui.version.name; getprop ro.mi.os.version.name; getprop
persist.security.adbinput"` (`XiaomiInputBlock.probeScript`): byte-exact,
`V816`, `OS1.0` (HyperOS) and `0`, the Security-settings switch off. Holds no
identifier. Loaded by `XiaomiInputBlockTests`.

## logcat-scrcpy-inject-denied.txt

The line the scrcpy server logged on this phone while its mirror showed the
screen but every click was dropped (logcat, tag `scrcpy`). Abridged: the
`...` marks parts of the line elided; the words
around them are as logged. Holds no identifier. Loaded by
`XiaomiInputBlockTests`.

## Rotation settings (2026-10-01)

Captured for the phone-rotation work, each with
`adb -s <serial> exec-out settings get system <key>` (byte-exact; the phone had
auto-rotate on and user rotation 0):

| File | Key |
|---|---|
| `settings-get-accelerometer_rotation.txt` | `accelerometer_rotation` (`1`) |
| `settings-get-user_rotation.txt` | `user_rotation` (`0`) |
| `settings-get-unset.txt` | a key the phone does not have (`null`) |

A live round trip of `accelerometer_rotation 0` with `user_rotation 0...3`
showed the window manager accept every value (`mUserRotationMode=USER_ROTATION_LOCKED`,
`mUserRotation=ROTATION_0/90/180/270`) while the MIUI launcher, which asks for
portrait, kept the display at rotation 0 in all four.
