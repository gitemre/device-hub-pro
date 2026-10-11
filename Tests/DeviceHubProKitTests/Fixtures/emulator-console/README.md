# emulator-console

Real captures of the Android emulator's console (TCP `127.0.0.1:<console port>`) and of
`adb emu`, taken on 2026-10-12 to pin down what happens when the console asks for no
authentication (an EMPTY `~/.emulator_console_auth_token`, the documented way to switch console
auth off).

The bug they show is in adb's client (`client/console.cpp`, `adb_send_emulator_command`,
platform/packages/modules/adb): it sends `auth <token>\n` only when
`$HOME/.emulator_console_auth_token` is readable and non-empty, then the command, then `quit\n`,
and from the answer it always skips the first two `OK\r\n` and prints the rest. When the console
asks for no auth there is only one `OK` before the command's answer, so the second skip eats the
command's own answer: `adb -s emulator-5580 emu avd name` prints nothing and exits 0
(`adb-emu-avd-name-empty-token.stdout.txt`). The same happens when `$HOME` holds a non-empty token
but the emulator asks for no auth (`auth …` gets a `KO` line, which has no `OK`).

## Setup

- Mac: Apple silicon, macOS (Darwin 27.0.0, arm64).
- Emulator: `Android emulator version 36.6.11.0 (build_id 15507667)` (`Pkg.Revision=36.6.11`).
- System image: `system-images;android-36;google_apis;arm64-v8a`, `Pkg.Revision=7`
  (`BE2A.250530.026.F3`, build `13894323`, userdebug).
- adb: `Android Debug Bridge version 1.0.41`, `Version 37.0.0-14910828`.
- AVD `DHP_ConsoleCapture`, made for these captures with cmdline-tools 22.0
  `avdmanager create avd -n DHP_ConsoleCapture -k "system-images;android-36;google_apis;arm64-v8a" -d pixel_8_pro`
  in a private `ANDROID_AVD_HOME`; its `config.ini` placeholders `avd.id=<build>` and
  `avd.name=<build>` were set to the AVD name and `disk.dataPartition.path=<temp>` was removed.
- The emulator ran with `HOME` set to a private folder (so the console read the token file from
  there, never the Mac user's own), `ANDROID_SDK_ROOT`/`ANDROID_HOME` the SDK, and
  `-avd DHP_ConsoleCapture -port 5580 -grpc 8690 -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect`
  (serial `emulator-5580`, console 5580, adb 5581, gRPC 8690).
  - **noauth**: `$HOME/.emulator_console_auth_token` exists and is EMPTY (0 bytes).
  - **auth**: `$HOME/.emulator_console_auth_token` holds 16 random characters, no newline.
- The console was read with a raw socket client: connect, read until the last complete line
  starts with `OK` or `KO` and nothing more arrives for 0.4 s (or EOF), keeping every byte.
  Each `*.bin` file is exactly the bytes received for one exchange.
- The `*-stream-*.bin` files are what adb's client reads: a fresh connection, the whole payload
  written at once as adb does (`[auth <token>\n]<command>\nquit\n`), read to EOF.
- The adb runs are `HOME=<home> adb -s emulator-5580 emu …`; the `.stdout.txt` files are adb's
  stdout byte-exact. Every adb run exited 0 with empty stderr.

## Console, noauth mode (empty token file)

All sent on ONE connection, in this order, after the greeting.

| File | Sent | Received |
|---|---|---|
| `noauth-greeting.bin` | (connect) | `Android Console: type 'help' for a list of commands\r\nOK\r\n` |
| `noauth-avd-name.bin` | `avd name\n` | `DHP_ConsoleCapture\r\nOK\r\n` |
| `noauth-avd-discoverypath.bin` | `avd discoverypath\n` | `<path of the discovery .ini>\r\nOK\r\n` (scrubbed) |
| `noauth-resize-display-no-index.bin` | `resize-display\n` | `KO usage: "resize-display <index>" 0: phone\t1: unfolded\t2: tablet\r\n` |
| `noauth-unknown-command.bin` | `devicehubpro-unknown\n` | `KO: unknown command, try 'help'\r\n` |
| `noauth-auth-wrong-token.bin` | `auth devicehubprofake\n` | `KO: unknown command, try 'help'\r\n` |
| `noauth-auth-empty-crlf.bin` | `auth \r\n` | `KO: unknown command, try 'help'\r\n` |
| `noauth-avd-name-crlf.bin` | `avd name\r\n` | `DHP_ConsoleCapture\r\nOK\r\n` |
| `noauth-quit.bin` | `quit\n` | nothing (0 bytes); the console then closes the connection (orderly EOF) |

`noauth-avd-grpc.bin` (`avd grpc\n` → `8690\r\nOK\r\n`) comes from a second noauth connection
after the greeting, on the same AVD relaunched in the same mode.

`noauth-kill.bin` was captured last, on a connection of its own (greeting read first, then
`kill\n`): `OK: killing emulator, bye bye\r\nOK\r\n`, then an orderly EOF (the VM exited).

Streams (adb's view):

| File | Payload written at once | Received to EOF |
|---|---|---|
| `noauth-stream-avd-name.bin` | `avd name\nquit\n` | greeting + `DHP_ConsoleCapture\r\nOK\r\n` |
| `noauth-stream-auth-wrong-token-avd-name.bin` | `auth devicehubprofake\navd name\nquit\n` | greeting + `KO: unknown command, try 'help'\r\n` + `DHP_ConsoleCapture\r\nOK\r\n` |

## Console, auth mode (16-character token)

One connection, in this order. The correct token is never recorded (the answers were checked
not to contain it); the wrong token is the fixed string `devicehubprofake`.

| File | Sent | Received |
|---|---|---|
| `auth-greeting.bin` | (connect) | `Android Console: Authentication required\r\n` `Android Console: type 'auth <auth_token>' to authenticate\r\n` `Android Console: you can find your <auth_token> in \r\n` `'<$HOME>/.emulator_console_auth_token'\r\n` `OK\r\n` (path scrubbed) |
| `auth-avd-name-before-auth.bin` | `avd name\n` | `DHP_ConsoleCapture\r\nOK\r\n` (answered before auth) |
| `auth-auth-wrong-token.bin` | `auth devicehubprofake\n` | `KO: authentication token does not match ~/.emulator_console_auth_token\r\n` |
| `auth-auth-correct-token.bin` | `auth <token>\n` | `Android Console: type 'help' for a list of commands\r\nOK\r\n` |
| `auth-avd-name.bin` | `avd name\n` | `DHP_ConsoleCapture\r\nOK\r\n` |
| `auth-quit.bin` | `quit\n` | nothing (0 bytes), then EOF |

A second auth-mode connection, greeting then (no auth sent):

| File | Sent | Received |
|---|---|---|
| `auth-avd-discoverypath-before-auth.bin` | `avd discoverypath\n` | the `avd` help text (pre-auth sub-commands `name` and `grpc` only) and `KO:  bad sub-command\r\n` (two spaces) |
| `auth-unknown-command-before-auth.bin` | `devicehubpro-unknown\n` | `KO: unknown command, try 'help'\r\n` |

and a third: `auth-avd-grpc-before-auth.bin`, `avd grpc\n` → `8690\r\nOK\r\n`.

Streams (adb's view):

| File | Payload | Received to EOF |
|---|---|---|
| `auth-stream-auth-avd-name.bin` | `auth <token>\navd name\nquit\n` | auth greeting + `Android Console: type 'help' for a list of commands\r\nOK\r\n` + `DHP_ConsoleCapture\r\nOK\r\n` |
| `auth-stream-avd-name-no-auth.bin` | `avd name\nquit\n` | auth greeting + `DHP_ConsoleCapture\r\nOK\r\n` |

## adb

| File | Emulator | `HOME` token file | Command | stdout |
|---|---|---|---|---|
| `adb-emu-avd-name-empty-token.stdout.txt` | noauth | empty | `adb -s emulator-5580 emu avd name` | empty |
| `adb-emu-avd-discoverypath-empty-token.stdout.txt` | noauth | empty | `adb -s emulator-5580 emu avd discoverypath` | empty |
| `adb-emu-avd-name-token-console-noauth.stdout.txt` | noauth | 16 bytes (the Mac user's own) | `adb -s emulator-5580 emu avd name` | empty |
| `adb-emu-avd-discoverypath-token-console-noauth.stdout.txt` | noauth | 16 bytes (the Mac user's own) | `adb -s emulator-5580 emu avd discoverypath` | empty |
| `adb-emu-avd-name-auth.stdout.txt` | auth | the matching token | `adb -s emulator-5580 emu avd name` | `DHP_ConsoleCapture\r\nOK\r\n` |
| `adb-emu-avd-discoverypath-auth.stdout.txt` | auth | the matching token | `adb -s emulator-5580 emu avd discoverypath` | `<path>\r\nOK\r\n` (scrubbed) |
| `adb-emu-avd-name-empty-token-console-auth.stdout.txt` | auth | empty | `adb -s emulator-5580 emu avd name` | empty |
| `adb-shell-getprop-ro.boot.qemu.avd_name.stdout.txt` | noauth | (any) | `adb -s emulator-5580 shell getprop ro.boot.qemu.avd_name` | `DHP_ConsoleCapture\n` |

## Scrubbing

Only paths were changed, each with a same-length placeholder (every file keeps its captured
length): the macOS user name → `aqauser001` and the capture session's folder id
(a UUID) → `00000000-0000-0000-0000-000000000000`. They occur only in the discovery-path and
token-path lines of `noauth-avd-discoverypath.bin`, `auth-greeting.bin`,
`auth-stream-auth-avd-name.bin`, `auth-stream-avd-name-no-auth.bin` and
`adb-emu-avd-discoverypath-auth.stdout.txt`. The private `HOME` was a temporary folder, so these
paths read `/private/tmp/…/home-noauth/…` rather than `/Users/<name>/…`; the discovery file lives
at `$HOME/Library/Caches/TemporaryItems/avd/running/pid_<pid>.ini`. Nothing else was edited or
trimmed.
