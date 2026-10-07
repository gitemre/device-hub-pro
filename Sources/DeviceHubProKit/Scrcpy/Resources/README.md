# Vendored scrcpy server

`scrcpy-server` is the Android server from **scrcpy v3.1**, unmodified:

- Upstream release: <https://github.com/Genymobile/scrcpy/releases/tag/v3.1>
- Asset: `scrcpy-server-v3.1` (~90 KB, zip/jar containing `classes.dex`)
- Size: 90,640 bytes
- SHA-256: `958f0944a62f23b1f33a16e9eb14844c1a04b882ca175a738c16d23cb22b86c0`
- License: Apache-2.0 — the upstream `LICENSE` is committed as `LICENSE.scrcpy`.

`ScrcpyServer.bundledServerURL()` finds this file through
`ResourceBundleLookup`: first in the packaged app's
`Contents/Resources/DeviceHubPro_DeviceHubProKit.bundle`, then through
`Bundle.module` (as in `swift test`). `ResourceBundleLookupTests` covers
that order, and `ScrcpyServerTests.testBundledServerIsThePinnedAsset` pins
the file's size and digest.

## Transport choices

- **Push path:** `/data/local/tmp/scrcpy-server` (the client-side C code in
  scrcpy 3.1 uses `/data/local/tmp/scrcpy-server.jar`; the server accepts any
  class-path filename). The server's cleanup watchdog unlinks the jar right
  after startup, so it must be pushed before every launch.
- **Tunnel:** `tunnel_forward=true` with
  `adb forward tcp:<port> localabstract:scrcpy_<scid>`. The client only needs
  an outbound TCP connection (no local listener), and `adb reverse` — scrcpy's
  default — is known to fail over wireless `adb connect`, which also
  supports. The server listens on the abstract socket; the first byte it sends
  is the dummy byte that proves it is alive behind the tunnel. The launcher
  rejects reverse tunnelling and `audio=true`: it opens neither the reverse
  tunnel nor an audio socket, and the server would wait for them forever.
- **Sockets:** the video socket is connected first (it carries the dummy
  byte), then, with `control`, the control socket — the order the server's
  `DesktopConnection` accepts them in; the stream header follows only once
  every socket is connected. adb closes a forwarded connection at once while
  the device side is not listening yet, so only a closed connection is
  retried; one that stays open is already the server's video socket and is
  waited on for its dummy byte until the handshake deadline, however slow
  the tunnel (as scrcpy's `connect_and_read_byte` does). As in scrcpy's own
  client (`sc_adb_tunnel_close`), the forward is removed as soon as the
  sockets are connected: established connections survive the removal.
- **Socket name:** per-session — a random 31-bit `scid` is passed (the
  `scrcpy_<scid>` socket name, upstream's own scheme), so teardown kills only
  this mirror session's server (a scoped `pkill -f scid=<hex>`) and desktop scrcpy
  sessions on the same device are never collateral. Because the forward is
  gone once the session is connected, neither a client crash nor a quit
  leaves one behind; the server exits on its own when its sockets close, and
  the scoped `pkill` is the backstop. A quit while a launch is still in
  flight is covered by `PhysicalMirrorSession.stopAndWait`, which waits for
  the launch and tears its late connection down. Only a crash in the second
  or so between `adb forward` and the connect, or a quit whose
  `stopAndWait` bound runs out before that launch has connected, can still
  leave a forward (until an `adb kill-server`) and the local `adb shell`.
- **Console:** the server's stdout/stderr (the `adb shell` running
  `app_process`) are kept in a bounded ring (`ScrcpyServerLog`), and launch
  and stream errors quote its last lines. A server that exits before
  accepting the video socket fails the launch at once.
- **Options:** `audio=false`; `video_bit_rate`/`max_size`/`max_fps` are
  configurable. The shipped `.physicalMirror` tuning keeps the control socket
  (`control` is not sent, the server default), which also makes the server
  turn the screen on at start (`power_on`) and push the device clipboard;
  `control=false` sessions fall back to `adb shell input`. Server options are
  the `key=value` form introduced in 2.x and emitted in the same order as
  scrcpy's `app/src/server.c`.
- **Control protocol:** `ScrcpyControl.swift` serializes the v3.1 control
  messages byte for byte (`app/src/control_msg.c`, `ControlMessageReader.java`)
  and parses the device messages (`DeviceMessageWriter.java`);
  `ScrcpyControlTests` pins every layout. Text the server cannot type
  (Turkish letters, emoji) is pasted with SET_CLIPBOARD. The server injects
  `KEYCODE_PASTE` asynchronously and the app reads the clipboard only when it
  handles the key, so each paste carries a sequence and the input behind it
  waits for the server's ACK plus a short settle delay; keystrokes typed
  meanwhile go out together as the next paste. Device messages are parsed on
  the channel's reader thread and handed to callbacks on a separate queue,
  so app code never runs on the thread that holds the descriptor.
