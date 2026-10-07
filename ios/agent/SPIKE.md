# Spike: input control of a physical iPhone through a public XCTest runner

Date 2026-09-29. Branch `spike/iphone-xcuitest-agent`. Test device: the dedicated test iPhone (iPhone 12,
iOS 27.0, wired, paired, Developer Mode on, no passcode). Xcode 27.0 (27A266a), macOS 27. Spike code only;
nothing under `Sources/` was touched and nothing is wired into the app.

## Verdict

Feasible, and it works end to end with public API only. Tap, double tap, long press, swipe/drag, typing, home
and volume buttons, rotation, screenshots all worked on the first real run, over the CoreDevice tunnel, bound
to the tunnel address only, token-protected. The price is latency and a few structural limits:

- a tap costs about 0.45 s (foreground app as coordinate reference) to 0.64 s (Springboard as reference), a
  swipe 0.8 to 1.3 s, and on the home screen 1.1 s and 2.7 s. That is fine for click-through control and
  scripted flows, not for interactive dragging, scrolling by mouse wheel or a smooth "live" feel;
- no multi-touch with positional control, no incremental (press, move, move, release) gestures;
- the phone must be unlocked; it needs a signed runner (Xcode, a development profile, Developer Mode).

No prompt appeared on the phone at any point (no "Enable UI Automation", no Local Network dialog). Nothing had
to be tapped. The phone's screenshots show a purple "screen sharing" pill in the status bar; it is still there
after the runner stopped, so it is not caused by the runner.

## What is in `ios/agent/`

| File | What |
|---|---|
| `gen_project.py` | writes `DeviceHubProAgent.xcodeproj` (pbxproj + shared scheme); no third-party generator. The repo's `.gitignore` excludes `*.xcodeproj`, so the project is not committed; `build.sh` runs the generator |
| `Host/AgentHostApp.swift` | tiny SwiftUI host app (the runner needs one). Also a measurement surface: full-screen colour flips on tap, a tap counter that stores the phone-clock time of the last touch, a text field, all orientations |
| `Tests/AgentServer.swift` | HTTP/1.1 server on `NWListener`, keep-alive, token check, tunnel-only binding |
| `Tests/AgentActions.swift` | endpoint handlers (public XCTest API only) |
| `Tests/DeviceHubProAgentUITests.swift` | the single long-running `testServe()` |
| `build.sh` | `xcodebuild build-for-testing`, team and UDID on the command line only |
| `client/agentclient.py`, `client/bench.py`, `client/security_check.py` | stdlib client, latency benchmark, the three security checks |

No signing team, identity, profile, UDID, address or token is stored anywhere in the repo.

### API

All requests need the header `X-DeviceHubPro-Token`. Points are in the phone's portrait space unless noted.

| Endpoint | Notes |
|---|---|
| `GET /status` | uptime, orientation, output volume, iOS version |
| `GET /screen` | UIScreen bounds (the runner sees a 320x480 compat space, do not use), Springboard frame 390x844 pt, screenshot 1170x2532 px at 3x |
| `POST /tap {x,y}` | optional `doubleTap:1`, `hold:<seconds>`, `ref` (bundle id; wins), `refs` (candidate bundle ids in priority order: the runner uses the sticky last foreground one if still in front, else the first in front, else Springboard; a scan that found no app in front is not repeated for the same `refs` within 1 s, so repeated home-screen taps go straight to Springboard). Returns `t0` (phone clock), `ref` (id used) and `timing {resolveMs, actionMs}` (monotonic). The Mac's `refs` are device-generic: `device info apps --include-all-apps` (else the developer apps) plus the common Apple ids, up to 400; an answer of Springboard with refs sent reloads that list in the background (at most once per 10 s) and an app answer moves that app to the front |
| `POST /swipe {x1,y1,x2,y2,duration}` | `press(forDuration:0.05, thenDragTo:, withVelocity: distance/duration, thenHoldForDuration:0)`; accepts `ref`/`refs` and answers `ref` and `timing` like `/tap` |
| `POST /type {text,bundleId}` | `typeText` on the named app. 409 if that app shows no keyboard |
| `POST /button {name}` | `home`, `volumeUp`, `volumeDown` |
| `GET /orientation`, `POST /orientation {value}` | portrait, portraitUpsideDown, landscapeLeft, landscapeRight, faceUp, faceDown |
| `GET /screenshot[?format=jpeg&q=]` | `XCUIScreen.main.screenshot()`, PNG or JPEG |
| `POST /stop` | ends the test cleanly |
| spike helpers | `POST /launch {bundleId}` (activate), `GET /probe?x&y` (pixel colour of a fresh on-device screenshot), `GET /host` (host app's counter and field), `GET /foreground?ids=` (which of these apps is in the foreground), `GET /ifaddrs` (addresses of the phone, for the LAN check), optional `ref` (bundle id used as the coordinate reference) |

Every action runs inside `XCTExpectFailure` so an XCTest issue becomes an HTTP 500 with the message instead of
ending the long-running test (without it a failed `typeText` ended the test).

## Security design and verification

Constraints, all implemented and checked:

1. **Tunnel only.** The Mac reads `connectionProperties.tunnelIPAddress` from `devicectl device info details`
   (an `fd..::/8` ULA) and passes it as `TEST_RUNNER_DHP_BIND`. The runner looks the address up with
   `getifaddrs` (it must exist on the phone; it sits on `utun22`, the device end of the tunnel), then sets
   `NWParameters.requiredLocalEndpoint = host:port` of exactly that address. It also pins `requiredInterface`
   when Network.framework lists the interface; here it did not (`pinnedInterface=false`), so the binding to the
   one local address is what protects the port. If the address is missing, the listener fails, or it is not
   ready within 10 s, the test fails with `AGENT_FATAL` and stops. There is no code path that binds anything
   else. Defence in depth: a connection whose peer is not in `fd00::/8` is closed before a byte is read.
2. **Token.** 32 random bytes hex (256 bit), made by the Mac client per launch, passed as
   `TEST_RUNNER_DHP_TOKEN`, compared in constant time; the runner refuses to start with fewer than 32
   characters. Never logged or printed. It travels only in the runner's environment (visible to processes of the
   same Mac user for the runner's lifetime, like any environment variable).
3. **Lifetime.** `DHP_MAX_SECONDS` watchdog (default 3600, the spike ran 3000) and `POST /stop`. The runner
   ran only while measuring and is stopped.

Results (`client/security_check.py`, run against the live runner):

- (a) **Answers on the tunnel address:** HTTP 200 in 33 ms.
- (b) **Does not answer on any other address of the phone**, 2 s timeout, TCP port 8765. The phone's Wi-Fi
  (`en0`) IPv4, its link-local IPv6 and its three global IPv6 addresses, and the USB link (`en2`) IPv4: all
  "Connection refused" (the phone answers with a reset, so they are reachable and not listening). Control: the
  Mac reaches the phone's Wi-Fi IPv4 (ICMP ping 0 % loss) and its lockdown port 62078 connects, so the refusal
  is not a network artefact. The other link-local addresses (utun, awdl, llw, nan, anpi) gave "No route to
  host" or a timeout from the Mac; they are not routable from the Mac, so those results are weaker evidence,
  but the listener has one local address and none of them is it.
- (c) **No token or a wrong or empty token: 401**, for `GET /status`, `POST /tap` and `POST /stop`, and the
  runner was still running afterwards (the unauthorised `/stop` did nothing).

## Measurements

Warm runs, USB-C cable, phone unlocked and awake, keep-alive HTTP/1.1, 20 repetitions each. Times are the
request round trip from the Mac unless noted. (median / p90 / max)

| Operation | Result |
|---|---|
| `GET /status` keep-alive | 4.9 / 8.0 / 26.7 ms |
| `GET /status` new connection | 7.0 / 16.3 / 34.8 ms |
| `POST /tap` (host app in front, Springboard reference) | 640 / 753 / 1149 ms |
| `tap()` call to touch received by the app (both on the phone clock) | 386 / 522 / 904 ms |
| tap request to first changed frame (polling a 0.2 s on-device probe, so up to 0.2 s pessimistic) | 791 / 887 / 1304 ms |
| `POST /tap` with the foreground app as reference (10 runs) | median 455 ms (Springboard: 735 to 761 ms) |
| `POST /swipe` 300 pt in 0.25 s (host app) | 1261 / 1371 / 1464 ms; foreground app as reference 763 ms (Springboard 1121 to 1131 ms) |
| `POST /type` 20 characters | 996 / 1072 / 1134 ms (about 50 ms per character; all 400 characters arrived) |
| `POST /button home` | 490 / 498 / 505 ms |
| `POST /button volumeUp` or `volumeDown` | 246 / 250 / 252 ms (10 pairs; volume 0.700 before and after) |
| `POST /orientation landscapeLeft` | 398 / 403 / 469 ms; read back correctly 20 of 20 |
| `GET /orientation` | 19 / 27 / 123 ms |
| `POST /orientation portrait` | 351 / 372 / 382 ms |
| `GET /screenshot` PNG, host app (flat colours) | 124 / 133 / 173 ms, 156 KiB, 7.9 frames/s sequential |
| `GET /screenshot` JPEG q 0.5, host app | 147 / 157 / 164 ms, 134 KiB, 6.7 frames/s |
| `GET /screenshot` PNG, home screen (wallpaper) | 250 / 252 / 287 ms, 2.7 MiB, 4.0 frames/s |
| `GET /screenshot` JPEG q 0.5, home screen | 233 / 237 / 293 ms, 236 KiB, 4.2 frames/s |
| tap on home screen | median 1126 ms |
| swipe on home screen (page flip) | median 2734 ms |
| `GET /foreground?ids=` (5 ids) | 4 to 9 ms |

Start-up: `xcodebuild test-without-building` to first answered `GET /status`: 4.2 to 6.2 s with both apps already
installed (three runs); the first run, which installed the host app and the runner, took about 55 s. Build
(`build-for-testing`, signed): about 1 minute.

Robustness:

- **Another app comes to front:** launching Safari through the runner, then tapping and screenshotting: fine,
  the runner keeps serving (it is a background test process, not tied to the foreground app).
- **Idle 10 minutes:** `/status` every minute, 10 of 10 answered (18 to 27 ms), screenshots at 0, 3, 5 and 10
  minutes identical and valid. The phone never locked itself during the ten minutes (default auto-lock did not
  fire; the runner's automation session evidently keeps the display on), so nothing more can be said here.
- **Screen lock: not tested.** XCTest has no public way to lock the phone (no power button in
  `XCUIDevice.Button`), and this spike may not press it. The runner can only start on an unlocked phone. Apple
  Expect UI automation to fail on a locked phone (not verified) and treat lock as "the runner stops being
  useful until someone unlocks"; check `GET /status` plus a probe before relying on it. Open.
- **Cable unplug and replug, tunnel address stability:** out of scope, open. If the address changes the runner
  keeps listening on the old one and the Mac must relaunch it with the new address.

## Findings and limits

- **Coordinate reference matters.** `XCUICoordinate` resolves its element first: Springboard's accessibility tree
  is big (the home screen especially), so every tap and swipe pays an extra snapshot. With the foreground app as
  reference a tap is 455 ms instead of 740 ms and a swipe 760 ms instead of 1130 ms. Springboard is always
  reported `runningForeground`, so the foreground app is the first non-Springboard candidate in
  `GET /foreground?ids=` whose state is foreground; the Mac would supply the candidate list (bundle ids from
  `devicectl device info apps`, which lists only developer-installed and removable apps, so system apps must
  be added explicitly). A background app as reference has a meaningless frame.
- **Never create `XCUIApplication(bundleIdentifier:)` for the runner's own bundle id.** The tap hung, then
  `XCUIDevice.orientation` waited 60 s per call for the runner to go idle (it never does, it is running the
  server), and the runner had to be killed (Ctrl-C to xcodebuild ended it cleanly).
- **Typing** needs the bundle id of the app that owns the keyboard (`typeText` on that app). With Springboard as
  the target it answers 409 in the runner's check (no keyboard) because Springboard does not own the keyboard.
- **Rotation works** through `XCUIDevice.shared.orientation`, unlike `devicectl device orientation set` (see
 , which does not rotate on this phone). The screenshot then has swapped point dimensions
  (844x390); the runner's `/screen` values in points follow the current orientation. `tap` and `swipe`
  coordinates are in the current interface orientation of the reference app, not fixed portrait space; the
  client must swap when it has rotated. The phone lying flat reads `faceUp` from `GET /status`; that is the
  physical orientation and can change the reported value right after a set, so verify the read-back.
- **Multi-touch:** none with positional control. `XCUIElement.pinch(withScale:velocity:)` and `rotate` exist but
  act at an element's centre. **Streaming drags:** none; the drag is one atomic synthesized event with a
  start, an end and a velocity. Scroll-wheel and mouse-drag mapping have to become flicks.
- **Buttons:** only home, volume up and volume down are public. Volume changes the phone's real volume
  (restored here). No lock, no app switcher, no Siri, no side button.
- **Screenshot format:** `XCUIScreen.main.screenshot()`; PNG of a busy screen is 2.7 MiB and 4 fps; JPEG is
  no faster on device (encoding) but 10x smaller. This is not a live-view replacement; the CoreMediaIO capture
  of stays the live view and the runner supplies input only.
- **Local Network permission:** no dialog appeared for the listener on the tunnel address.
- **An XCTest issue used to end the whole long-running test.** `XCTExpectFailure` around each action fixes
  that. Timeouts inside XCTest (idle waits) can still block the main thread for minutes.

## Setup needs

- Xcode 27 with the iPhoneOS SDK; a development identity and a development provisioning profile covering the
  phone. The wildcard profile on this Mac (`iOS Team Provisioning Profile: *`) was picked up by automatic
  signing with `DEVELOPMENT_TEAM=<team> CODE_SIGN_STYLE=Automatic` on the command line, no
  `-allowProvisioningUpdates`, no Apple ID prompt.
- Developer Mode on (already on), phone paired, phone unlocked and awake.
- The bundle identifiers are `com.devicehubpro.agent.host` and `com.devicehubpro.agent.uitests(.xctrunner)`. Both apps
  are installed by `xcodebuild test-without-building` and stay installed afterwards.
- `TEST_RUNNER_DHP_BIND`, `TEST_RUNNER_DHP_TOKEN` (and optionally `_PORT`, `_MAX_SECONDS`, `_IDLE_SECONDS`: the runner ends itself after that many seconds, default 90, with no authorized request; 0 turns it off; the Mac's 5 s `/status` poll keeps a live session alive) in the
  environment of `xcodebuild`; `-only-testing:DeviceHubProAgentUITests/DeviceHubProAgentUITests/testServe`.

## Recommendation for Device Hub Pro

Worth integrating as an opt-in "Control this iPhone" mode, clearly separate from the view-only live view of
, and only on the enabled test device.

1. **Launch and keep.** A Kit `IPhoneAgentSession` builds the runner once (a cached signed build keyed by Xcode
   and app version, `build.sh`), then per session: read the tunnel address (`devicectl device info details`),
   generate the token, start `xcodebuild test-without-building` with the two environment variables as a child
   process, poll `GET /status` until ready (about 5 s warm), and keep the process. On quit, on a window
   detaching, or on an error: `POST /stop`, then terminate the child (SIGINT). Show the user that the runner is
   on (and the phone shows its own purple indicator). Relaunch on a failed `/status`; if the tunnel address
   changed, relaunch with the new one.
2. **Map input.** Stage click to `/tap` (double click to `doubleTap`, press and hold to `hold`), a drag to one
   `/swipe` sent on mouse-up with the drag's start, end and duration (no live tracking), scroll wheel to a
   short `/swipe`, keys to `/type` when the foreground app shows a keyboard (send characters in batches),
   special keys to `/button`, rotate to `/orientation` with the client swapping the point space. Coordinates
   are scaled from the mirror's pixel size to points (390x844 on this phone; ask `/screen`). Serialise actions:
   the runner handles one at a time on its main thread, and the queue delay is the latency.
3. **Speed.** Track the foreground app (poll `GET /foreground` for the known bundle ids, or after each launch
   the app started) and pass it as `ref` (a `ref` field per request); fall back to Springboard. Expect 0.45 to
   0.75 s per tap, more on the home screen. Set expectations in the UI (a busy indicator on the stage while a
   gesture is in flight).
4. **Fall back.** If the runner is not built, the profile does not cover the phone, Developer Mode is off, the
   phone is locked or `/status` fails, keep the current view-only behaviour and say why. Never fall back to a
   wider bind address, a Wi-Fi address or an unauthenticated mode. Never use the private CoreDevice
   remote-input path.
5. **Open before building it:** behaviour on a locked phone and after unplug and replug (address stability),
   whether a second window or a second phone needs a second port (the code takes `DHP_PORT`), long runs
   (hours) for leaks, a signed distribution story for users who are not the developer (each user needs a
   provisioning profile that includes their phone, so this is realistic for developers, not for casual users),
   and a keyboard/foreground-app probe that does not need a candidate list.

## State left on the phone

Portrait, home screen (first page), runner stopped (no XCTRunner process). The host app
`com.devicehubpro.agent.host` and the runner `com.devicehubpro.agent.uitests.xctrunner` are still installed, next to the
existing verifier. Safari was opened once (an existing page; two taps landed on that page) and then left. The
field text typed into the host app lives only in that app's memory. Every command sent to the phone is logged in
`DeviceHubPro-private/phase9e/commands.log`.
