import CoreVideo
import Foundation
import Synchronization

// The view-only live screen of a USB-connected iPhone or iPad:
// the public CoreMediaIO + AVFoundation screen capture path. Nothing here is private
// API and nothing here sends input; the phone's screen only comes in.

// MARK: - The capture seam

/// Where the Camera permission stands (`AVAuthorizationStatus` for video).
public enum CaptureAuthorization: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

/// One capture device macOS exposes for a connected iOS device, as
/// `AVCaptureDevice` describes it. Plain values, so the matching and the
/// stage's decisions are tested without hardware.
public struct PhysicalCaptureDevice: Sendable, Equatable, Hashable {
    /// `AVCaptureDevice.uniqueID`.
    public let uniqueID: String
    /// `AVCaptureDevice.localizedName`.
    public let localizedName: String
    /// `AVCaptureDevice.modelID`.
    public let modelID: String
    /// Whether the device carries audio with its screen: a `.muxed` device
    /// (an iPhone or iPad) or one that lists the `.audio` media type. A
    /// video-only device (a webcam, another video-only source) has none, and
    /// no audio output is ever added for it.
    public let hasAudio: Bool

    public init(uniqueID: String, localizedName: String, modelID: String, hasAudio: Bool = false) {
        self.uniqueID = uniqueID
        self.localizedName = localizedName
        self.modelID = modelID
        self.hasAudio = hasAudio
    }
}

/// Why a running capture ended.
public enum PhysicalCaptureEnd: Sendable, Equatable {
    /// The device went away (`AVCaptureDevice.wasDisconnectedNotification`):
    /// unplugged, or the phone locked its screen off the wire.
    case disconnected
    /// The capture session failed (`AVCaptureSession` runtime error).
    case failed(String)
}

/// A capture that was made and can be started and stopped.
public protocol PhysicalCaptureRunning: AnyObject, Sendable {
    /// Starts delivering frames. Returns at once or blocks briefly; the
    /// caller never runs it on the main thread.
    func start()
    /// Stops delivering and releases the capture. Idempotent.
    func stop()
}

/// What the app needs of CoreMediaIO and AVFoundation, behind one seam so no
/// test ever reaches a capture device or the Camera permission.
public protocol PhysicalScreenCaptureProviding: Sendable {
    /// Sets `kCMIOHardwarePropertyAllowScreenCaptureDevices` to 1 on
    /// `kCMIOObjectSystemObject` (the public CoreMediaIO switch that makes
    /// macOS expose each USB-connected iOS device as a capture device).
    /// Once per process; later calls do nothing. The app calls it only while
    /// "Show physical Apple devices" is on.
    func allowScreenCaptureDevices()
    /// The external capture devices that carry a screen now (needs
    /// `allowScreenCaptureDevices()` first, and a run loop to have
    /// discovered them).
    func captureDevices() -> [PhysicalCaptureDevice]
    /// The Camera permission now.
    var authorization: CaptureAuthorization { get }
    /// Asks for the Camera permission (the system prompt, once per install).
    func requestAccess() async -> Bool
    /// The Microphone permission now: the phone's audio is captured through
    /// the muxed device's audio output, which macOS guards with it (Phase
    /// 9E-1). Without it a live session runs video only.
    var audioAuthorization: CaptureAuthorization { get }
    /// Asks for the Microphone permission (the system prompt, once per
    /// install).
    func requestAudioAccess() async -> Bool
    /// Makes a capture of `uniqueID` that delivers BGRA frames through
    /// `onFrame` on its own serial queue and reports its end through
    /// `onEnd`; `onDrop` counts a frame the capture discarded because the
    /// consumer was late. With `onAudio` non-nil the capture also adds an
    /// audio output to the same session and delivers the phone's audio
    /// through it, on a serial queue of its own; nil adds none (the caller
    /// passes it only for a device that carries audio).
    func makeCapture(
        uniqueID: String,
        onFrame: @escaping @Sendable (CVPixelBuffer) -> Void,
        onAudio: (@Sendable (PhysicalAudioChunk) -> Void)?,
        onDrop: @escaping @Sendable () -> Void,
        onEnd: @escaping @Sendable (PhysicalCaptureEnd) -> Void
    ) throws -> any PhysicalCaptureRunning
    /// Calls `handler` when a capture device appears or disappears; the
    /// observation lasts while the returned token is alive.
    func observeDeviceChanges(_ handler: @escaping @Sendable () -> Void) -> AnyObject
}

/// The provider a build that must never reach hardware gets (tests, and any
/// environment made without one): no devices, no permission, no capture, no
/// CoreMediaIO call.
public struct InertScreenCaptureProvider: PhysicalScreenCaptureProviding {
    public init() {}
    public func allowScreenCaptureDevices() {}
    public func captureDevices() -> [PhysicalCaptureDevice] { [] }
    public var authorization: CaptureAuthorization { .denied }
    public func requestAccess() async -> Bool { false }
    public var audioAuthorization: CaptureAuthorization { .denied }
    public func requestAudioAccess() async -> Bool { false }
    public func makeCapture(
        uniqueID: String,
        onFrame: @escaping @Sendable (CVPixelBuffer) -> Void,
        onAudio: (@Sendable (PhysicalAudioChunk) -> Void)?,
        onDrop: @escaping @Sendable () -> Void,
        onEnd: @escaping @Sendable (PhysicalCaptureEnd) -> Void
    ) throws -> any PhysicalCaptureRunning {
        throw PhysicalScreenCaptureError.unavailable
    }
    public func observeDeviceChanges(_ handler: @escaping @Sendable () -> Void) -> AnyObject { NSObject() }
}

public enum PhysicalScreenCaptureError: Error, Equatable, CustomStringConvertible {
    /// No capture is available in this build.
    case unavailable
    /// `AVCaptureDevice(uniqueID:)` knows no such device.
    case deviceNotFound
    /// The capture session refused the device's input or the video output.
    case cannotAddInput(String)

    public var description: String {
        switch self {
        case .unavailable: "Live capture is not available."
        case .deviceNotFound: "The iPhone's screen is no longer available for capture."
        case .cannotAddInput(let reason): "The capture session could not use the iPhone's screen: \(reason)"
        }
    }
}

// MARK: - Matching a capture device to a listed phone

/// Maps a capture device to the physical device the user enabled.
///
/// **What was measured** (Xcode 27, macOS 27, the dedicated test iPhone 12 on
/// USB, 2026-09-29): `AVCaptureDevice.uniqueID` is an uppercase 36-character
/// UUID (version 4) that equals no key of the phone's CoreDevice list entry
/// (not the hardware UDID in any form, not the CoreDevice identifier, not
/// the ECID); `localizedName` is the phone's name, `modelID` is "iOS Device",
/// `deviceType` is `.external`, the media type is `.muxed`.
///
/// **UDID first.** The match still compares the hardware UDID with the
/// `uniqueID` in the forms it can take (case and dashes ignored), in case a
/// macOS release names the capture device by it. **Name and model when no
/// capture device carries the UDID** (what happens today), and then only for
/// one unambiguous pair: the capture device's name is the listed device's
/// name, its model identifier is compatible, no other capture device has that
/// name and no other listed device does. A capture device that maps to no
/// enabled, listed device is never returned.
public enum PhysicalCaptureMatcher {
    /// How a capture device was tied to the phone.
    public enum Basis: Sendable, Equatable {
        case uniqueID
        case nameAndModel
    }

    public struct Match: Sendable, Equatable {
        public let device: PhysicalCaptureDevice
        public let basis: Basis
    }

    /// A hardware UDID with its case and dashes taken out: what two forms of
    /// the same UDID share.
    public static func canonical(_ udid: String) -> String {
        udid.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0 != "-" }
            .uppercased()
    }

    /// - Parameters:
    ///   - devices: the capture devices macOS exposes now.
    ///   - phone: the listed, enabled device.
    ///   - listed: every listed physical device (names must stay unambiguous
    ///     across them for the name fallback).
    public static func match(
        _ devices: [PhysicalCaptureDevice],
        for phone: ApplePhysicalDevice,
        among listed: [ApplePhysicalDevice]
    ) -> Match? {
        let wanted = canonical(phone.hardwareUDID)
        guard !wanted.isEmpty else { return nil }
        if let byID = devices.first(where: { canonical($0.uniqueID) == wanted }) {
            return Match(device: byID, basis: .uniqueID)
        }
        // The UDID mapping failed for this phone. It may still be the form
        // (an id that is not a UDID at all) that fails for every device, so
        // the fallback is strict: one name, one model, no other candidate.
        // A capture device that IS another listed phone's UDID is that
        // phone's, never this one's.
        let others = Set(listed.map { canonical($0.hardwareUDID) }.filter { $0 != wanted })
        let unclaimed = devices.filter { !others.contains(canonical($0.uniqueID)) }
        guard let name = phone.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        let sameName = unclaimed.filter { $0.localizedName.caseInsensitiveCompare(name) == .orderedSame }
        guard sameName.count == 1, let candidate = sameName.first,
              modelIsCompatible(candidate.modelID, phone: phone)
        else { return nil }
        let listedWithName = listed.filter {
            $0.name?.caseInsensitiveCompare(name) == .orderedSame
        }
        guard listedWithName.count == 1 else { return nil }
        return Match(device: candidate, basis: .nameAndModel)
    }

    /// A capture device's model identifier fits the phone when it names the
    /// phone's product type or marketing name, or is the generic identifier
    /// macOS gives an iOS device ("iOS Device", measured).
    static func modelIsCompatible(_ modelID: String, phone: ApplePhysicalDevice) -> Bool {
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty { return false }
        if let productType = phone.productType, model.caseInsensitiveCompare(productType) == .orderedSame { return true }
        if let marketing = phone.marketingName, model.caseInsensitiveCompare(marketing) == .orderedSame { return true }
        return model.lowercased().hasPrefix("ios device")
    }
}

// MARK: - The session

/// A live, view-only mirror of one iPhone or iPad over USB: the frames of its
/// AVFoundation capture device, published upright into a `FrameStore` so the
/// stage, capture, replay and recording work as for any session.
///
/// **Frames.** The capture delivers the screen as macOS screen capture delivers it,
/// upright for the phone's orientation (a turned phone delivers a landscape
/// frame), as 32BGRA pixel buffers. The buffer itself goes into the store
/// (`Frame(pixelBuffer:)`): the renderer samples it in place when it is
/// IOSurface-backed and reads RGBA bytes otherwise, and the bytes are made
/// only for a consumer that asks. `Frame.rotation` is always 0. A frame size
/// change (the phone turned) needs nothing here: the store and the renderer
/// take whatever size arrives.
///
/// **Pacing.** The capture discards late frames itself
/// (`alwaysDiscardsLateVideoFrames`); the session counts them as dropped.
///
/// **Audio.** With an `audioSink` the capture adds an audio output to the
/// same session and every chunk of the phone's audio goes to the sink (the
/// app's player, which the audio policy switches on and off); the sink is
/// stopped whenever the session stops or fails. Without one (a device that
/// carries no audio, or a build without a player) no audio output is added.
/// The recording of these frames stays video only.
///
/// **View only.** `supportsHardwareKeys` is false and every input method
/// drops its input: nothing reaches the phone.
///
/// **Lifecycle.** `start()` returns at once; the capture is made and started
/// on the session's own queue and a failure lands in `lastError`. A capture
/// that ends (the phone unplugged, a runtime error) stops the session and
/// leaves its message in `lastError`. `stop()` is idempotent.
public final class PhysicalScreenCaptureSession: MirrorSessionProtocol, PhysicalViewSession, @unchecked Sendable {
    /// The message a session leaves when its device went away.
    public static let disconnectedMessage = "The iPhone's screen is no longer available. Was it unplugged or locked?"

    public let hardwareUDID: String
    public let captureDeviceID: String
    /// Where the phone's audio goes; nil for a session without audio.
    public let audioSink: (any PhysicalAudioSink)?
    public let inputRoute = PhysicalInputRoute()
    public let frames = FrameStore()
    public var transport: MirrorTransport { .physicalScreenCapture }
    public var viewKind: PhysicalViewKind { .liveCapture }

    private let provider: any PhysicalScreenCaptureProviding
    private let queue = DispatchQueue(label: "com.devicehubpro.physical-capture.session", qos: .userInteractive)
    private let rgbaPool = RGBAFramePool()
    private let clock = ContinuousClock()
    private let state = Mutex(State())

    private struct State {
        var generation: UInt64 = 0
        var running = false
        var lastError: String?
        var capture: (any PhysicalCaptureRunning)?
        var seq: UInt32 = 0
        var published = 0
        var dropped = 0
        var firstFrameAt: ContinuousClock.Instant?
        var recentPublishes: [ContinuousClock.Instant] = []
    }

    public init(
        hardwareUDID: String,
        captureDeviceID: String,
        provider: any PhysicalScreenCaptureProviding,
        audioSink: (any PhysicalAudioSink)? = nil
    ) {
        self.hardwareUDID = hardwareUDID
        self.captureDeviceID = captureDeviceID
        self.provider = provider
        self.audioSink = audioSink
    }

    deinit {
        stop()
    }

    public var lastError: String? { state.withLock { $0.lastError } }
    public var isRunning: Bool { state.withLock { $0.running } }

    // MARK: Lifecycle

    public func start() {
        stop()
        let generation = state.withLock { state -> UInt64 in
            state.generation &+= 1
            state.running = true
            state.lastError = nil
            state.published = 0
            state.dropped = 0
            state.firstFrameAt = nil
            state.recentPublishes = []
            return state.generation
        }
        queue.async { [weak self] in
            self?.startCapture(generation: generation)
        }
    }

    public func stop() {
        let capture = state.withLock { state -> (any PhysicalCaptureRunning)? in
            state.generation &+= 1
            state.running = false
            let capture = state.capture
            state.capture = nil
            return capture
        }
        audioSink?.stop()
        guard let capture else { return }
        // Off the caller's thread: stopping an AVCaptureSession can wait for
        // the capture's own queue.
        queue.async { capture.stop() }
    }

    /// Stops and returns once the capture itself has stopped, waiting at
    /// most `timeout`: the app's quit.
    public func stopAndWait(timeout: TimeInterval) {
        let capture = state.withLock { state -> (any PhysicalCaptureRunning)? in
            state.generation &+= 1
            state.running = false
            let capture = state.capture
            state.capture = nil
            return capture
        }
        audioSink?.stop()
        guard let capture else { return }
        let done = DispatchSemaphore(value: 0)
        queue.async {
            capture.stop()
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        state.withLock { $0.running && $0.generation == generation }
    }

    private func startCapture(generation: UInt64) {
        guard isCurrent(generation) else { return }
        let capture: any PhysicalCaptureRunning
        // Only a session with a sink asks the capture for audio.
        var onAudio: (@Sendable (PhysicalAudioChunk) -> Void)?
        if audioSink != nil {
            onAudio = { [weak self] chunk in self?.didCaptureAudio(chunk, generation: generation) }
        }
        do {
            capture = try provider.makeCapture(
                uniqueID: captureDeviceID,
                onFrame: { [weak self] buffer in self?.didCapture(buffer, generation: generation) },
                onAudio: onAudio,
                onDrop: { [weak self] in self?.didDrop(generation: generation) },
                onEnd: { [weak self] end in self?.didEnd(end, generation: generation) }
            )
        } catch {
            fail("\(error)", generation: generation)
            return
        }
        let kept = state.withLock { state -> Bool in
            guard state.running, state.generation == generation else { return false }
            state.capture = capture
            return true
        }
        guard kept else {
            capture.stop()
            return
        }
        capture.start()
    }

    private func fail(_ message: String, generation: UInt64) {
        let taken = state.withLock { state -> (owned: Bool, capture: (any PhysicalCaptureRunning)?) in
            guard state.running, state.generation == generation else { return (false, nil) }
            state.running = false
            state.generation &+= 1
            state.lastError = message
            let capture = state.capture
            state.capture = nil
            return (true, capture)
        }
        guard taken.owned else { return }
        audioSink?.stop()
        guard let capture = taken.capture else { return }
        queue.async { capture.stop() }
    }

    // MARK: Frames

    private func didCapture(_ buffer: CVPixelBuffer, generation: UInt64) {
        guard CVPixelBufferGetWidth(buffer) > 0, CVPixelBufferGetHeight(buffer) > 0 else { return }
        let now = clock.now
        let seq = state.withLock { state -> UInt32? in
            guard state.running, state.generation == generation else { return nil }
            state.seq &+= 1
            state.published += 1
            if state.firstFrameAt == nil { state.firstFrameAt = now }
            state.recentPublishes.append(now)
            if state.recentPublishes.count > 120 {
                state.recentPublishes.removeFirst(state.recentPublishes.count - 120)
            }
            return state.seq
        }
        guard let seq else { return }
        let pool = rgbaPool
        frames.put(Frame(pixelBuffer: buffer, seq: seq) { buffer in
            PhysicalMirrorSession.rgbaFrame(from: buffer, pool: pool)?.data
        })
    }

    private func didCaptureAudio(_ chunk: PhysicalAudioChunk, generation: UInt64) {
        guard isCurrent(generation) else { return }
        audioSink?.play(chunk)
    }

    private func didDrop(generation: UInt64) {
        state.withLock { state in
            guard state.running, state.generation == generation else { return }
            state.dropped += 1
        }
    }

    private func didEnd(_ end: PhysicalCaptureEnd, generation: UInt64) {
        switch end {
        case .disconnected: fail(Self.disconnectedMessage, generation: generation)
        case .failed(let message): fail("The iPhone's screen capture failed: \(message)", generation: generation)
        }
    }

    // MARK: Session surface

    /// Nothing to repair: frames come from a stream.
    public func resync() async {}

    public func stats() async -> MirrorStats {
        let now = clock.now
        return state.withLock { state in
            let lastSecond = state.recentPublishes.filter { $0.duration(to: now) < .seconds(1) }.count
            return MirrorStats(
                fps: Double(lastSecond),
                totalFrames: state.published,
                dropped: state.dropped,
                averageLatencyMs: 0
            )
        }
    }

    /// View only unless Control is on (`inputRoute`): then the stage's touches
    /// and keys reach the phone through the input runner.
    public func send(_ command: TouchCommand) { inputRoute.receive(contacts: [command]) }
    public func send(contacts: [TouchCommand]) { inputRoute.receive(contacts: contacts) }
    public func send(_ command: KeyboardCommand) { inputRoute.receive(command) }
    public var acceptsPhysicalKeys: Bool { inputRoute.acceptsPhysicalKeys }
    public func send(physical event: PhysicalKeyEvent) { inputRoute.receive(physical: event) }

    public func send(button: SimulatorHardwareButton, isDown: Bool) {
        inputRoute.receive(button: button, isDown: isDown)
    }

    public var acceptsButtons: Bool { inputRoute.acceptsButtons }
}

// MARK: - What the stage asks of a physical view session

/// How a physical device's screen reaches the stage.
public enum PhysicalViewKind: Sendable, Equatable {
    /// The public CoreMediaIO + AVFoundation capture (USB, live).
    case liveCapture
    /// The private CoreDevice media stream (opt-in; no Camera permission).
    case nativeLive
    /// Repeated `devicectl device capture screenshot` calls (any transport,
    /// about one picture every 1.5 s).
    case screenshots
}

/// A view-only session of a physical device's screen, whichever way it gets
/// the picture: the stage, the health poll and the lifecycle read this.
public protocol PhysicalViewSession: MirrorSessionProtocol, SimulatorButtonSending {
    /// The device's hardware UDID.
    var hardwareUDID: String { get }
    var viewKind: PhysicalViewKind { get }
    /// Where the stage's input goes while Control is on; empty,
    /// the view drops every input.
    var inputRoute: PhysicalInputRoute { get }
    /// The stage's pose (portrait, landscapeLeft, landscapeRight, portraitUpsideDown) the
    /// session itself tracks, nil when it does not: only the native stream, whose frames
    /// are always the portrait panel, tracks it and turns them with the frame. It is the
    /// device pose (Device Hub's model), whatever the interface does.
    var stagePose: PhysicalControlOrientation? { get }
    /// Whether the interface itself is turned to a landscape (false without tracking):
    /// only the home-indicator band depends on it.
    var interfaceIsLandscape: Bool { get }
    /// Calls `handler` when `stagePose` (or the interface) changes (a no-op without tracking).
    func observeStagePose(_ handler: @escaping @Sendable () -> Void)
    /// `devicectl device orientation set` put the device in `pose`: the stage takes it at
    /// once (a no-op without tracking).
    func noteTurn(to pose: PhysicalControlOrientation) async
}

extension PhysicalViewSession {
    public var stagePose: PhysicalControlOrientation? { nil }
    public var interfaceIsLandscape: Bool { false }
    public func observeStagePose(_ handler: @escaping @Sendable () -> Void) {}
    public func noteTurn(to pose: PhysicalControlOrientation) async {}
}
