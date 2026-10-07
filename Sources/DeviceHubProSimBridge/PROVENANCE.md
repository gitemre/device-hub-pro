# DeviceHubProSimBridge: where each private name comes from

This target is the only Device Hub Pro code that names private CoreSimulator
selectors or libxpc simulator functions. This file records, for each one, where
we learned it: either a file in [facebook/idb](https://github.com/facebook/idb)
(MIT; credited in `THIRD_PARTY_NOTICES.md`) or "runtime-observed", meaning it
was read from this Mac's loaded frameworks (Objective-C runtime metadata and
type encodings) on **CoreSimulator 1171.7** (Xcode 27.0, 27A266a).

Rules the target follows:

- No Apple file is copied: no headers, class dumps, chrome, masks or
  binaries. `AQSBPrivateAPI.h` declares only the selectors below, written by
  hand; the argument and return types follow the runtime type encodings
  (`I` uint32, `S` uint16, `Q` uint64, `{CGSize=dd}`).
- Nothing private is linked. CoreSimulator is loaded with `dlopen`, classes are
  found with `objc_lookUpClass`, and the `*_4sim` functions with `dlsym`.
  `nm -u` on any product that contains the bridge must show no `_4sim` or
  `OBJC_CLASS_$_Sim` symbol.
- SimulatorKit is **not** loaded. All four mechanisms live in CoreSimulator
  (which re-exports CoreSimDeviceIO), libxpc and the public `mach_msg` (the
  GSEvents). Measured 2026-09-25: after a full smoke run (frames, drag, tap,
  Home), no SimulatorKit image was mapped into the process; nor after a
  `SimulatorMirrorSessionLiveTests` run (frames, touch, the HID keyboard,
  the orientation GSEvents in all four orientations, Home), which asserts it.
  The GSEvent lock (type 1014) was not part of that run.
- Every message to a private object runs inside `AQSBGuarded` (`@try`), and
  every public entry point asserts it is off the main queue.

idb references are to `facebook/idb` `main` as fetched on 2026-09-25; the line
numbers are from that fetch. The idb copies themselves are not part of this repository.

## Loading and finding a simulator (`AQSBLoader.m`)

| Name | Kind | Source |
|---|---|---|
| `/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator` | `dlopen` path | runtime-observed, CoreSimulator 1171.7 (the system-wide install; idb loads the same framework in `FBSimulatorControl/Utility/SimulatorControlFrameworkLoader.swift`) |
| `SimServiceContext`, `SimDevice` | classes (`objc_lookUpClass`) | idb `PrivateHeaders/CoreSimulator/SimServiceContext.h`, `SimDevice.h` |
| `+[SimServiceContext sharedServiceContextForDeveloperDir:error:]` | class method | idb `PrivateHeaders/CoreSimulator/SimServiceContext.h:35` |
| `-[SimServiceContext defaultDeviceSetWithError:]` | method | idb `PrivateHeaders/CoreSimulator/SimServiceContext.h:62` |
| `-[SimServiceContext deviceSetWithPath:error:]` | method | idb `PrivateHeaders/CoreSimulator/SimServiceContext.h:61` |
| `-[SimDeviceSet devices]` | method | idb `PrivateHeaders/CoreSimulator/SimDeviceSet.h:112` |
| `-[SimDevice UDID]`, `-name`, `-state`, `-stateString` | methods | idb `PrivateHeaders/CoreSimulator/SimDevice.h:61, 109, 111, 112` |
| `SimDevice.state == 3` means booted | value | runtime-observed, CoreSimulator 1171.7 (a booted device reads 3 with `stateString` "Booted"; `state` encodes as `Q`) |
| `CFBundleVersion` of the bundle defining `SimDevice` | public `NSBundle` API | — |

## Screen (`AQSBScreen.m`)

| Name | Kind | Source |
|---|---|---|
| `-[SimDevice io]` | method | idb `PrivateHeaders/CoreSimulator/SimDevice.h:59` |
| `-[SimDeviceIOClient ioPorts]` | method | idb `PrivateHeaders/CoreSimulator/SimDeviceIOClient.h:25` |
| `-[<SimDeviceIOPortInterface> descriptor]` | method | idb `PrivateHeaders/CoreSimDeviceIO/SimDeviceIOPortInterface-Protocol.h:22` |
| `-[descriptor state]` | method | idb `FBSimulatorControl/Framebuffer/FramebufferSurface.swift:251-255` |
| `-[<SimDisplayDescriptorState> displayClass]`, class 0 = main display | method, value | idb `PrivateHeaders/CoreSimDeviceIO/SimDisplayDescriptorState-Protocol.h:21`; `FramebufferSurface.swift:260` |
| `-[<SimDisplayIOSurfaceRenderable> framebufferSurface]` | method | idb `PrivateHeaders/CoreSimDeviceIO/SimDisplayIOSurfaceRenderable-Protocol.h:47` |
| `-[<SimScreen> registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:]` | method | idb `PrivateHeaders/CoreSimDeviceIO/SimScreen-Protocol.h:38`; block shapes and the rollback-on-raise from `FramebufferSurface.swift` |
| `-[<SimScreen> unregisterScreenCallbacksWithUUID:]` | method | idb `PrivateHeaders/CoreSimDeviceIO/SimScreen-Protocol.h:44` |
| `-[<SimScreen> screenProperties]` | method | idb `PrivateHeaders/CoreSimDeviceIO/SimScreen-Protocol.h:37` |
| `-[<SimScreenProperties> screenType]` (`Q`) | method | runtime-observed, CoreSimulator 1171.7 |
| `-[<SimScreenProperties> screenID]` (`I`) | method | runtime-observed, CoreSimulator 1171.7 |
| `-[<SimScreenProperties> uiOrientation]` (`I`) | method | runtime-observed, CoreSimulator 1171.7 |
| `-[<SimScreenProperties> pixelSize]` (`{CGSize=dd}`) | method | runtime-observed, CoreSimulator 1171.7 |
| Callbacks arrive with `dispatch_sync` on the given queue; `surfacesChanged` fires once after registering and with `(nil, nil)` on shutdown | behaviour | idb `FBSimulatorControl/Framebuffer/FramebufferSurface.swift:43` (`clientQueue.sync`); runtime-observed, CoreSimulator 1171.7 |

## Input (`AQSBHID.m`)

| Name | Kind | Source |
|---|---|---|
| `-[SimDevice lookup:error:]` (returns a mach port, `I`) | method | idb `PrivateHeaders/CoreSimulator/SimDevice.h:131` |
| `xpc_endpoint_create_mach_port_4sim(port, 0, 0)` (returns +1, consumes the right) | libxpc function, `dlsym` | idb `FBSimulatorControl/XPC/SimulatorXPCConnection.swift:58` |
| `xpc_connection_enable_sim2host_4sim(connection)` | libxpc function, `dlsym` | idb `FBSimulatorControl/XPC/SimulatorXPCConnection.swift:60` |
| `xpc_connection_create_from_endpoint` | public libxpc API (`<xpc/connection.h>`) | — |
| `com.apple.coredevice.feature.remote.hid.digitizer` | service name | idb `FBSimulatorControl/HID/SimulatorDTUHIDTransport.swift:196` |
| `com.apple.CoreSimulator.SimError` 405 = the runtime does not vend the service | value | idb `FBSimulatorControl/XPC/SimulatorXPCConnection.swift:23-27` |
| Envelope `{messageType, isBarrier, featureIdentifier, payload}` | wire format | idb `FBSimulatorControl/HID/DTUHIDModels.swift:14-28` |
| `IndigoDigitizerEvent {pointOne:{x,y}, eventType 0/1/2, edge, target}` | wire format | idb `FBSimulatorControl/HID/DTUHIDModels.swift:48-70` |
| `pointTwo:{x,y}` beside `pointOne` for a two-finger contact sharing one `eventType`; omitted for one finger | wire format | idb `FBSimulatorControl/HID/DTUHIDModels.swift:48-70`, `SimulatorDTUHIDTransport.swift:335-345` (`sendTwoFingerTouch`) |
| `edge` values 0 none, 1 top, 2 left, 3 bottom, 4 right | value | idb `FBSimulatorControl/HID/SimulatorHIDTypes.swift:71-76` (`SimulatorHIDEdge`), `SimulatorDTUHIDTransport.swift:321-331`; runtime-observed, CoreSimulator 1171.7: the value is the panel's native edge and must ride on every event of the contact (a swipe up from the bottom went Home only with 3 on began, moved and ended; in landscape `uiOrientation` 4 only with 2) |
| `IndigoButtonEvent {usagePage, usageCode, state}`, state 1 down / 2 up | wire format | idb `FBSimulatorControl/HID/DTUHIDModels.swift:80`, `SimulatorDTUHIDTransport.swift` |
| `IndigoKeyboardButtonEvent {usageCode, state}` | wire format | idb `FBSimulatorControl/HID/DTUHIDModels.swift`, `SimulatorDTUHIDTransport.swift:362` |
| Readiness barrier: `IndigoKeyboardButtonEvent {usageCode 0, state 2}` with `isBarrier`, sent with reply | wire format | idb `FBSimulatorControl/HID/SimulatorDTUHIDTransport.swift:467-468` |
| Retry policy: 5 attempts, 4 s reply deadline, 4 s backoff, 0.2 s reply tail, lookup inside each attempt | behaviour | idb `FBSimulatorControl/HID/SimulatorDTUHIDTransport.swift:22-45` (`DTUHIDTiming`) |
| Home = consumer page 0x0C, usage 0x40 | value | idb `FBSimulatorControl/HID/SimulatorHIDButtonIdentity.swift:59`; verified on iOS 27.0 |
| Side/lock = 0x0C/0x30, Siri = 0x0C/0xCF, volume up/down = 0x0C/0xE9 and 0x0C/0xEA | values | idb `FBSimulatorControl/HID/SimulatorHIDButtonIdentity.swift:60-72`; runtime-observed on iOS 27.0: 0x30 locks and, pressed again, wakes; 0xE9/0xEA move `sim_volume` in the device's `var/run/simulatoraudio/audiosettings.plist` by one step; 0xCF showed nothing (Siri not set up) |
| Keyboard modifiers as their own usages (Left Shift 0xE1, Left Option 0xE2, Left GUI 0xE3), held around the key | value | USB HID Usage Tables 1.4, page 0x07 (public); runtime-observed, CoreSimulator 1171.7 (⌘A and ⌘C worked; ⌘V pastes only text copied inside the guest) |
| `com.apple.coredevice.dtuhidd.active` (read by the smoke tool, not the bridge) | notify key | runtime-observed, CoreSimulator 1171.7 (`notifyutil -g` read 0 before and 1 after the first connection) |

## Screen properties read again (`AQSBScreen.m`)

| Name | Kind | Source |
|---|---|---|
| `-[<SimScreen> screenProperties]` sent again after `start` (`currentProperties`) | method | idb `PrivateHeaders/CoreSimDeviceIO/SimScreen-Protocol.h:37`; runtime-observed, CoreSimulator 1171.7: it answers the orientation of the moment |
| `uiOrientation` 1 portrait, 3 content top at the panel's left, 4 at its right; a Face ID iPhone never reports 2 | value | runtime-observed, CoreSimulator 1171.7 (fixture `Tests/DeviceHubProKitTests/Fixtures/ios27-simulator/bridge/orientation-uiOrientation.txt`) |

## GSEvents (`AQSBPurple.m`)

| Name | Kind | Source |
|---|---|---|
| `PurpleWorkspacePort`, looked up with `-[SimDevice lookup:error:]` per send | service name | idb `FBSimulatorControl/HID/SimulatorPurpleHIDTransport.swift:86-90` |
| One mach message: `msgh_bits` `MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0)` (0x13), `msgh_size` 108 in a 112-byte buffer, `msgh_id` 0x7B, the GSEvent type at 0x18 ORed with the host flag 0x20000, `record_info_size` at 0x48, the record at 0x4C | wire format | idb `FBSimulatorControl/HID/SimulatorPurpleHID.swift:24-83` |
| Type 50 = device orientation changed, record = the orientation value (4 bytes) | value | idb `FBSimulatorControl/HID/SimulatorPurpleHID.swift:25, 33-50` |
| Orientation values 1 portrait, 2 portrait upside down, 3 and 4 the landscapes: 3 turns an iPhone's interface to `uiOrientation` 4 (island left), 4 to 3, as devicectl's `landscapeLeft` and `landscapeRight` do | value | idb `FBSimulatorControl/HID/SimulatorHIDTypes.swift:166-170`; runtime-observed, CoreSimulator 1171.7 (the same fixture; send ≈2 ms, `propertiesChanged` 10–40 ms later) |
| Type 1014 = lock device, no record | value | idb `FBSimulatorControl/HID/SimulatorPurpleHID.swift:26, 52-67`; runtime-observed, CoreSimulator 1171.7: sent without error, **no effect** on iOS 27.0 (the Kit locks with the side button) |
| `mach_msg(MACH_SEND_MSG \| MACH_SEND_TIMEOUT, …, 2000 ms)`; on `MACH_SEND_TIMED_OUT` nothing was queued | behaviour | idb `FBSimulatorControl/HID/SimulatorPurpleHIDTransport.swift:31-34, 81-116`; public `<mach/message.h>` |
| The lookup returns a send right the caller owns; `COPY_SEND` leaves it, so the bridge deallocates it after each send | behaviour | runtime-observed, CoreSimulator 1171.7 (the probe's count of this process's port names stayed flat over repeated sends, and every later lookup and send succeeded) |

## Not used, on purpose

- SimulatorKit (`SimDeviceLegacyHIDClient`, `IndigoHIDMessageFor*`,
  `SimDeviceScreen`): the legacy Indigo path is dead for keyboards on iOS 27
  guests, and nothing here needs it.
- `-ioSurface` and the single-surface callbacks: removed in CoreSimulator
  1155.4 (they raise "unrecognized selector").
- DTUHID's vendor-defined orientation event (`IndigoVendorDefinedEvent`,
  usage page 0xff61, usage 0x5b): the spike's message was accepted and
  nothing rotated; the GSEvent and devicectl both do.
- `-[SimDevice postDarwinNotification:error:]` (idb's shake): the public
  `simctl spawn <UDID> notifyutil -p com.apple.UIKit.SimulatorShake` does the
  same.
