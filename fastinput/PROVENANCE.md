# fastinput provenance

The private CoreDevice HID input path of `ipb` backs the "fast input" mode for a physical
iPhone (see AGENTS.md, "Private APIs and kill switches"). The public-XCTest runner of `ios/agent` stays the
fallback.

- Upstream: https://github.com/ipbtools/ipb (MIT, copyright 2026 Borealin and ipbtools
  contributors; the licence text is `fastinput/LICENSE`, copied unchanged).
- Pinned commit: `f2e85a6d60c45f18e6f9f2a306f709ffb9710392` (reviewed 2026-09-30: no network
  access, no persistence).

## Files taken from upstream `Sources/`, unchanged unless noted

- `mercury_abi.S`, `universalhid_abi.S`, `uhid_request_abi.S`: assembly thunks that call the
  private Mercury / UniversalHID Swift ABI. They call private ABI and will break on Xcode
  updates; the live canary (`FastInputLiveTests`) is the tripwire.
- `mercury_glue.swift`: unchanged.
- `universalhid_glue.swift`: one provenance comment (an address list) replaced by a neutral
  comment, so no binary-inspection material is committed. One function added
  (2026-09-30, `uhid_make_keyboard_chord_hid_report`): upstream's keyboard report sets one usage
  bit, and a keyboard report is the whole key state (a bitmap of usages 1...0xE7, Shift included),
  so Shift plus a key needs two bits in one report; it builds on upstream's
  `makeKeyboardHIDReport` and its bit setter, nothing else.

## Written here

- `Sources/fastinput_main.m`: the resident helper, derived from `ipb_bench.m` (a benchmark
  written on top of upstream's report builder and sender, not part of upstream). It opens the
  UniversalHID service socket and the HID button socket once, finds the touchscreen service id
  from the connected descriptors, then serves the stdin/stdout line protocol described in its
  header. It prints no identifiers. Keyboard and App Switcher (2026-09-30), taken from upstream
  `bin/ipb` and `Sources/action_sender.m` as behaviour, not code: the `key` and `text` verbs send
  keyboard reports (`uhid_make_keyboard_hid_report`'s report shape) to the descriptor named
  "CoreDevice keyboard" (found in the same descriptor dump as the touchscreen, upstream's
  `keyboard` role) over the same UniversalHID socket; the usages are the standard USB HID keyboard
  page (`bin/ipb`'s `keyboard_usage` table: letters 0x04..., digits 0x1e..., punctuation 0x2d...,
  Return 0x28, Backspace 0x2a, Tab 0x2b, Shift 0xe1) laid out for the US layout, printable ASCII
  only. `button appSwitcher` is the button click upstream sends for its `recents`/`app-switcher`
  (`cd_recents_button`, vendor keyboard page 0xff01, usage 0x10, "verified 4/4 by screenshot on a
  12 mini, iOS 27.0" upstream), through the same button socket and press/release/barrier order as
  Home. Not taken: Siri (upstream sends Consumer 0xcf held 0.85 s; the runner keeps Siri until
  that is measured here), the digitizer swipe, pointer and scroll reports.
- Typing (2026-09-30): the `text` verb is US-layout and types wrong on any other hardware layout
  (Turkish Q: "i" typed "ı"), and pasting (`devicectl device pasteboard copy` plus Command+V) makes iOS
  ask "Allow Paste" every time, so the app uses neither. The `keys [<usage>...]` verb
  (`uhid_make_keyboard_set_hid_report`, added in `universalhid_glue.swift`, built on upstream's
  `makeKeyboardHIDReport` and its bit setter) sends one keyboard report with exactly those usages held
  plus a barrier; the Mac drives the held set, so the app forwards each Mac key as the same physical
  key (what Device Hub and Simulator do) and the phone's hardware keyboard layout makes the character.
  `key` and `text` stay for tests.
- Bottom-edge gestures (2026-09-30): the `edge down|move|up <x> <y>` verb opens a third CoreDevice
  connection for the feature `com.apple.coredevice.feature.remote.hid.digitizer` (the same
  `open_remote` as the touch and button sockets, optional: without it `edge` answers err 7) and
  calls the already vendored `coredevice_send_hid_digitizer_cgpoint` once per event, the way
  upstream `Sources/mirror.m` (commit f2e85a6) does for a mouse-down at y >= 1 - 0.02
  (`BottomEdgeFraction`): x and y normalised 0..1 (the same values it puts in the touch report),
  second point absent (tag 1), event type 0 start / 1 move / 2 end, edge 3 (bottom), no barrier.
  Upstream handles portrait only; the landscape mapping is unverified here. Upstream's evidence:
  the home swipe and, held, the App Switcher, as Device Hub does. Not yet measured here on a phone.
- Chrome buttons as real edges (2026-09-30): the `hid <page-hex> <usage-hex> down|up` verb sends one
  edge of any HID button through the same button socket: `coredevice_send_hid_button_custom` plus
  `coredevice_send_hid_button_barrier`, as upstream's `send_coredevice_button_click` (action_sender.m,
  commit f2e85a6) does for its two edges, where state 0 is the press (sent first, held for the click's
  hold time, 0.85 s for `cd_siri_button` = Consumer 0x0c / 0xcf) and state 1 the release (sent second).
  `down` is state 0, `up` is state 1; the caller holds the time between them, so a held side button
  (Siri) or a combination (side + volume up, screenshot) is the Mac's own down and up. The side button
  (Consumer 0x0c / 0x30) and the Action button (0x0b / 0x2d) have no upstream evidence; the
  Device Hub's chrome names them, and they are unmeasured on a phone here (Phase live test
  `testChromeButtons` measures the side button).
- `build.sh`: the flags of upstream's Makefile helper targets, into a given output directory.

## Native live view: `Sources/DeviceHubProNativeMirror`

Rewritten in ObjC from upstream `Sources/mirror.m` (same pinned commit, MIT, header comment in
`AQNativeMirrorSession.m`), not copied verbatim. Taken: the media-stream negotiation and socket
setup (`runMirror`), the in-process frame sink and the image-queue start hook (`InProcSink`,
`swz_iq_start`), the product-type screen table, and the content-rectangle detection (the padding
crop). Changed: no private framework is linked (dlopen / dlsym / `NSClassFromString`), frames go
to a latest-only handler on a private queue, state lives in a session object, a 12 s stall and
every stream error reach an error handler. Stripped: all HID and input code, the window and menus,
CSV output, screenshots, scrolling, the Xcode display-size database lookup and the command line.
It only receives frames; nothing is sent to the phone. The stream calls private, undocumented
services: the live canary `NativeMirrorLiveTests` is the tripwire.

## Not taken, on purpose

`bin/ipb` (its wrapper has destructive verbs), `action_sender.m` (upstream's one-shot command
line; the helper needs none of it), `video_stream.*`, the rest of `mirror.m` listed above,
`Experiments/`, `Formula/`, docs.
