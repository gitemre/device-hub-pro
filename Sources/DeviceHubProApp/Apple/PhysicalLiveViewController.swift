import AppKit
import Foundation
import Observation
import os
import DeviceHubProKit

/// What a selected physical iPhone's stage shows and why (Phase
/// 9D): the live screen over USB, a self-refreshing screenshot preview where
/// the live capture cannot run, or the static panel. Pure, so every edge is
/// tested without a device.
struct PhysicalViewPlan: Equatable {
    enum Mode: Equatable {
        /// The public CoreMediaIO + AVFoundation capture of `captureDeviceID`
        /// (USB only): live, view only.
        case live(captureDeviceID: String)
        /// Repeated `devicectl device capture screenshot` calls: view only,
        /// about one picture every 1.5 s, over any transport.
        case screenshots
        /// The private CoreDevice media stream (opt-in native live view, USB):
        /// live, view only, no Camera permission and no AVFoundation.
        case nativeLive
        /// The static panel (glyph, state, Take Screenshot).
        case staticPanel

        var isLive: Bool {
            if case .live = self { return true }
            return self == .nativeLive
        }
    }

    /// Why the live capture is not what the stage shows.
    enum Note: Equatable {
        /// Nothing to say: the live capture runs (or the device is not
        /// usable yet, which the stage's own state explains).
        case none
        /// The Live View switch is off.
        case liveViewOff
        /// The device is not connected by USB (Wi-Fi): the capture needs the
        /// cable.
        case notWired
        /// USB, but macOS exposes no capture device for it (locked, or not
        /// yet enumerated).
        case noCaptureDevice
        /// The Camera permission was not asked yet; the prompt is coming.
        case cameraPending
        /// The Camera permission was denied or is restricted.
        case cameraDenied
        /// The live capture ended (unplugged, a runtime error); `String` is
        /// the reason.
        case liveFailed(String)
        /// Another window shows this device's screen (one capture per
        /// device).
        case shownElsewhere
    }

    var mode: Mode
    var note: Note
    /// The Camera permission must be asked now (once, when the user starts
    /// the live view).
    var needsCameraRequest = false

    static let cameraDeniedText =
        "Allow Device Hub Pro under System Settings › Privacy & Security › Camera to see the screen live."
    static let cameraSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
    static let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    static let microphoneDeniedText =
        "Allow Device Hub Pro under System Settings › Privacy & Security › Microphone to hear the iPhone."

    /// The stage's line for `note`; nil when there is nothing to add.
    var noteText: String? {
        switch note {
        case .none, .liveViewOff, .cameraPending: nil
        case .notWired: "Connect the cable to see the screen live."
        case .noCaptureDevice: "The screen isn't available for live capture yet. Unlock the device and keep the cable connected."
        case .cameraDenied: Self.cameraDeniedText
        case .liveFailed(let reason): "The live view stopped: \(reason)"
        case .shownElsewhere: "This device's screen is shown in another window."
        }
    }

    /// Whether the stage offers the button that opens the Camera pane of
    /// System Settings.
    var offersCameraSettings: Bool { note == .cameraDenied }

    /// What the stage shows for the inputs.
    ///
    /// - The device must be listed, enabled and Ready (paired, connected,
    ///   Developer Mode on), and "Show physical Apple devices" on; else the
    ///   static panel.
    /// - Live needs Live View on, a wired transport, a capture device that
    ///   maps to this device, the Camera permission, and no earlier failure
    ///   of the live capture in this connection.
    /// - Where live is not possible the fallback is the screenshot preview
    ///   (Auto-refresh on and the device supporting screenshots), else the
    ///   static panel.
    static func make(
        entry: ApplePhysicalEntry?,
        showsPhysicalDevices: Bool,
        liveViewOn: Bool,
        autoRefreshOn: Bool,
        screenshotSupported: Bool,
        authorization: CaptureAuthorization,
        captureDevice: PhysicalCaptureDevice?,
        liveFailure: String?,
        nativeLive: Bool = false,
        nativePreferred: Bool = false
    ) -> PhysicalViewPlan {
        guard showsPhysicalDevices, let entry, entry.isEnabled, entry.state == .ready else {
            return PhysicalViewPlan(mode: .staticPanel, note: .none)
        }
        let fallback: Mode = autoRefreshOn && screenshotSupported ? .screenshots : .staticPanel
        guard liveViewOn else { return PhysicalViewPlan(mode: fallback, note: .liveViewOff) }
        // The native live view needs no Camera permission and no cable (it rides the
        // CoreDevice tunnel); it stands in for the capture.
        if nativeLive { return PhysicalViewPlan(mode: .nativeLive, note: .none) }
        guard entry.device.transport == "wired" else { return PhysicalViewPlan(mode: fallback, note: .notWired) }
        // The native option is on but the stream is down: the capture only if the
        // Camera is already allowed; never a prompt, else the screenshot preview.
        if nativePreferred, authorization != .authorized { return PhysicalViewPlan(mode: fallback, note: .none) }
        if let liveFailure { return PhysicalViewPlan(mode: fallback, note: .liveFailed(liveFailure)) }
        switch authorization {
        case .denied, .restricted:
            return PhysicalViewPlan(mode: fallback, note: .cameraDenied)
        case .notDetermined:
            return PhysicalViewPlan(mode: fallback, note: .cameraPending, needsCameraRequest: true)
        case .authorized:
            guard let captureDevice else { return PhysicalViewPlan(mode: fallback, note: .noCaptureDevice) }
            return PhysicalViewPlan(mode: .live(captureDeviceID: captureDevice.uniqueID), note: .none)
        }
    }
}

/// Whether the workspace's audio policy lets a physical iPhone's audio play:
/// the emulator audio setting and, with multiple
/// windows, the key window. Pure data; `DeviceWorkspace.physicalAudioPolicy`
/// decides it.
enum PhysicalAudioPolicy: Equatable {
    /// Audio may play (Settings' mode is not Disabled, and this workspace is
    /// the focused one, or multi-window is off).
    case plays
    /// Settings' emulator audio mode is Disabled.
    case disabledInSettings
    /// Another window is the key window and plays its own device's audio.
    case otherWindowFocused
}

/// Runs a physical device's view-only screen for the workspace whose window
/// shows it.
///
/// **When it runs.** A session exists only while the device is selected in
/// this workspace, listed, enabled and Ready, "Show physical Apple devices"
/// is on and the workspace's window is visible (`isWindowVisible`
/// occlusion gating) when it starts. It stops on deselect, on window
/// close (the workspace's `.windowClosed` teardown), on "Stop Using This
/// Device", when the preference goes off, when the phone is unplugged
/// (`AVCaptureDevice.wasDisconnectedNotification`) and at quit. One session
/// per device: the begin hub's `WorkspaceRegistry` claim refuses a device
/// another window already shows.
///
/// **CoreMediaIO.** `allowScreenCaptureDevices()` runs only when the
/// preference is on and the selected device is enabled, wired, and Live View
/// is on: never at launch otherwise.
///
/// **Which picture.** `PhysicalViewPlan.make`: live over USB with the Camera
/// permission; else the screenshot preview; else the static panel. A live
/// capture that ends falls back to the preview and is not retried until a
/// capture device appears or disappears, or Live View is turned off and on.
///
/// **Audio.** A live session whose capture device carries audio
/// (`PhysicalCaptureDevice.hasAudio`, a muxed device) gets a
/// `PhysicalAudioSink` (the real one is `PhysicalAudioPlayer`) once the
/// Microphone permission is granted; a device without audio gets none, so no
/// audio output is ever added for it, and neither does a session while the
/// permission is undecided (video only; the prompt is asked once and the
/// session is replaced by one with audio when it is granted) or denied (the
/// stage says where to allow it).
/// `applyAudio()` switches the sink on only while the workspace's policy
/// allows it (`audioPolicy`), the user has not muted it and the window is
/// visible; the workspace calls it on every policy change (a session start,
/// a focus change, a change of Settings' audio mode).
///
/// The controller holds no reference to the model: the begin and teardown
/// hubs and the inputs come through hooks the workspace sets.
@MainActor
@Observable
final class PhysicalLiveViewController {
    /// What the controller reads to decide.
    struct Inputs: Equatable {
        /// The selected physical device, when the selection is one.
        var entry: ApplePhysicalEntry?
        /// Every listed physical device (the name fallback of the matching
        /// needs them all).
        var listed: [ApplePhysicalDevice] = []
        var isWindowVisible = true
        var showsPhysicalDevices = false
        var liveViewOn = true
        /// The opt-in native live view is on and not switched off by the kill switch.
        var nativeLiveViewOn = false
        var autoRefreshOn = true
        var screenshotSupported = true
    }

    /// What the stage shows now.
    private(set) var plan = PhysicalViewPlan(mode: .staticPanel, note: .none)
    /// The Camera permission as last read.
    private(set) var authorization: CaptureAuthorization = .notDetermined
    /// "about every 1.5 s" from the preview's measured cadence.
    private(set) var cadenceText: String?
    /// The running session's last error, read on the health poll.
    private(set) var sessionError: String?
    /// The device whose screen another window shows.
    private(set) var claimedElsewhere: String?
    /// The running live session carries the phone's audio.
    private(set) var hasAudio = false
    /// The user muted the phone's audio in the banner (kept across sessions
    /// of this workspace).
    private(set) var isAudioMuted = false
    /// The phone's audio is being played now.
    private(set) var audioIsPlaying = false
    /// What the workspace's audio policy said at the last `applyAudio()`.
    private(set) var audioPolicy: PhysicalAudioPolicy = .plays
    /// The Microphone permission as last read, meaningful while the live
    /// capture device carries audio.
    private(set) var audioAuthorization: CaptureAuthorization = .authorized
    /// The live capture device carries audio (a muxed device).
    private(set) var deviceCarriesAudio = false

    @ObservationIgnored var inputs: @MainActor () -> Inputs = { Inputs() }
    /// The workspace's audio policy for a physical phone's audio.
    @ObservationIgnored var audioPolicyProvider: @MainActor () -> PhysicalAudioPolicy = { .plays }
    /// Makes the sink that plays a live session's audio (the real player;
    /// tests hand in a fake).
    @ObservationIgnored var makeAudioSink: @MainActor () -> any PhysicalAudioSink = { PhysicalAudioPlayer() }
    /// Starts `session` for `device` through the workspace's begin hub;
    /// false when another workspace holds the device.
    @ObservationIgnored var beginSession: @MainActor (
        _ session: any MirrorSessionProtocol,
        _ device: DeviceRef,
        _ capabilities: DeviceCapabilities
    ) -> Bool = { _, _, _ in false }
    @ObservationIgnored var tearDownSession: @MainActor (_ cause: MirrorController.MirrorTeardownCause) -> Void = { _ in }
    @ObservationIgnored var activeSession: @MainActor () -> (any MirrorSessionProtocol)? = { nil }
    /// Makes the native live view's session for a device (the workspace's real
    /// one, or a fake); nil means it is not available, and the capture is used.
    @ObservationIgnored var makeNativeSession: (@MainActor (_ entry: ApplePhysicalEntry) -> (any PhysicalViewSession)?)?
    /// The screenshot preview's capture for a device (through the
    /// inventory's client); nil when the device cannot be asked.
    @ObservationIgnored var screenshotCapture: @MainActor (_ udid: String) -> PhysicalScreenshotSession.Capture? = { _ in nil }
    /// A fresh `devicectl` screenshot, for Take Screenshot before the first
    /// frame.
    @ObservationIgnored var deviceScreenshot: @MainActor (_ udid: String) async -> Data? = { _ in nil }
    /// Puts the Apple chrome upright before a new session and turns it with
    /// the device (`SimulatorCanvasController.devicePose`).
    @ObservationIgnored var resetPose: @MainActor () -> Void = {}
    /// Starts reading the Apple chrome of a listed phone's model (the stage
    /// draws the phone in it), so it is ready before the phone is selected;
    /// false while the model's device type is not known yet (asked again on
    /// the next reconcile).
    @ObservationIgnored var prefetchChrome: @MainActor (_ productType: String) -> Bool = { _ in false }
    @ObservationIgnored private var prefetchedChromes: Set<String> = []
    @ObservationIgnored var settlePose: @MainActor (_ turns: Int, _ animated: Bool) -> Void = { _, _ in }
    @ObservationIgnored var openURL: @MainActor (_ url: URL) -> Void = { url in NSWorkspace.shared.open(url) }
    @ObservationIgnored var flash: @MainActor (_ message: String) -> Void = { _ in }
    /// The preferences behind `setLiveView(_:)` and `setAutoRefresh(_:)`.
    @ObservationIgnored var setLiveViewPreference: @MainActor (_ on: Bool) -> Void = { _ in }
    @ObservationIgnored var setAutoRefreshPreference: @MainActor (_ on: Bool) -> Void = { _ in }
    /// The workspace's "Control this iPhone", which the commands below drive.
    @ObservationIgnored weak var control: PhysicalControlController?
    /// The workspace's capture flow (`takeScreenshot()`).
    @ObservationIgnored var captureScreenshot: @MainActor () async -> Void = {}
    /// The view changed (a reconcile ran): "Control this iPhone" follows the
    /// session it drives (`PhysicalControlController.syncWithView`).
    @ObservationIgnored var viewChanged: @MainActor () -> Void = {}
    /// The Apple chrome's quarter turns the phone itself reported while
    /// Control is on (the capture only says landscape or portrait, not which
    /// landscape); nil while there is none.
    @ObservationIgnored var knownChromeTurns: @MainActor () -> Int? = { nil }
    /// The picture's shape changed (portrait to landscape or back): Control
    /// asks the phone which way it turned.
    @ObservationIgnored var frameShapeChanged: @MainActor () -> Void = {}
    /// The preview's smallest gap between two captures (tests shorten it).
    @ObservationIgnored var previewInterval: Duration = PhysicalScreenshotSession.minimumInterval
    /// How often the capture devices are looked at again while a wired,
    /// authorized phone has none yet: macOS enumerates a phone's screen a
    /// moment after the CoreMediaIO switch is set, and the connect
    /// notification may already have passed.
    @ObservationIgnored var lookupRetryInterval: Duration = .seconds(1)
    static let maximumLookupRetries = 15

    /// The wait before native retry number `attempt` (1 based): 3 s, 6 s, 12 s, then 30 s.
    static func nativeRetryDelay(attempt: Int) -> Duration {
        switch attempt {
        case ...1: .seconds(3)
        case 2: .seconds(6)
        case 3: .seconds(12)
        default: .seconds(30)
        }
    }

    @ObservationIgnored private let provider: any PhysicalScreenCaptureProviding
    @ObservationIgnored private var captureDevices: [PhysicalCaptureDevice] = []
    @ObservationIgnored private var changeToken: AnyObject?
    /// Why the live capture ended for a device, by hardware UDID, until a
    /// capture device appears or disappears or Live View is toggled.
    @ObservationIgnored private var liveFailures: [String: String] = [:]
    /// Why the native live view ended for a device: the capture is used instead
    /// until Live View or the native option is toggled.
    @ObservationIgnored private var nativeFailures: [String: String] = [:]
    @ObservationIgnored private var lastNativeOn = false
    /// Failed native attempts in a row, by hardware UDID; a frame clears it.
    @ObservationIgnored private var nativeAttempts: [String: Int] = [:]
    @ObservationIgnored private var nativeRetryTask: Task<Void, Never>?
    @ObservationIgnored private var nativeFallbackFlashed = false
    /// Waits out a native retry's delay (tests drive it).
    @ObservationIgnored var retrySleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    @ObservationIgnored private var requestedCamera = false
    @ObservationIgnored private var requestedMicrophone = false
    @ObservationIgnored private var lookupRetryTask: Task<Void, Never>?
    @ObservationIgnored private var lookupRetries = 0
    @ObservationIgnored private var lastLiveViewOn = true
    @ObservationIgnored private var frameObservation: FrameObservation?
    @ObservationIgnored private let lastLandscape = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    init(provider: any PhysicalScreenCaptureProviding) {
        self.provider = provider
    }

    // MARK: - Reading

    /// The physical view session that shows `udid` and runs.
    func session(for udid: String) -> (any PhysicalViewSession)? {
        guard let session = activeSession() as? any PhysicalViewSession,
              PhysicalDeviceOptIn.normalize(session.hardwareUDID) == PhysicalDeviceOptIn.normalize(udid),
              session.isRunning
        else { return nil }
        return session
    }

    /// Whether the stage of `udid` draws a live or preview session.
    func showsSession(for udid: String) -> Bool {
        session(for: udid) != nil
    }

    // MARK: - Reconciling

    /// Brings the running session in line with the inputs: starts, replaces
    /// or stops it. Called whenever an input changes (the selection, the
    /// window's visibility, the list, the switches, the permission, a
    /// capture device appearing).
    func reconcile() {
        let inputs = self.inputs()
        let entry = inputs.entry
        if inputs.showsPhysicalDevices {
            for case let type? in inputs.listed.map(\.productType) where !prefetchedChromes.contains(type) {
                if prefetchChrome(type) { prefetchedChromes.insert(type) }
            }
        }
        let wired = inputs.showsPhysicalDevices && inputs.liveViewOn
            && entry?.isEnabled == true && entry?.device.transport == "wired"
        // The native live view rides the CoreDevice tunnel, which a phone on the same
        // network has too (measured over Wi-Fi on 2026-10-01: 21 fps on a still screen,
        // as wired); only the CoreMediaIO capture needs the cable.
        let nativeReachable = wired || (inputs.showsPhysicalDevices && inputs.liveViewOn
            && entry?.isEnabled == true && entry?.device.transport == "localNetwork")
        if inputs.liveViewOn != lastLiveViewOn || inputs.nativeLiveViewOn != lastNativeOn {
            lastLiveViewOn = inputs.liveViewOn
            lastNativeOn = inputs.nativeLiveViewOn
            liveFailures.removeAll()
            nativeFailures.removeAll()
        }
        // While the native live view runs, nothing touches CoreMediaIO,
        // AVFoundation or the Camera permission.
        let nativeActive = nativeReachable && inputs.nativeLiveViewOn && makeNativeSession != nil
            && entry.map { nativeFailures[$0.udid] == nil } == true
        // With the native option on, the capture (and so the Camera prompt) is
        // reachable only while the Camera is already authorized.
        let nativePreferred = nativeReachable && inputs.nativeLiveViewOn && makeNativeSession != nil
        let captureAllowed = !nativePreferred || provider.authorization == .authorized
        let wantsLookup = wired && !nativeActive && captureAllowed
        if !nativePreferred {
            nativeRetryTask?.cancel()
            nativeRetryTask = nil
            nativeAttempts.removeAll()
            nativeFallbackFlashed = false
        }
        var captureDevice: PhysicalCaptureDevice?
        if wantsLookup {
            // Once per process (the provider keeps count), and only here.
            provider.allowScreenCaptureDevices()
            observeCaptureDevices()
            captureDevices = provider.captureDevices()
            if let entry {
                captureDevice = PhysicalCaptureMatcher.match(captureDevices, for: entry.device, among: inputs.listed)?.device
            }
        } else {
            changeToken = nil
            captureDevices = []
        }
        if !nativeActive { authorization = provider.authorization }
        if wantsLookup, captureDevice == nil, authorization != .denied, authorization != .restricted {
            scheduleLookupRetry()
        } else {
            lookupRetryTask?.cancel()
            lookupRetryTask = nil
            lookupRetries = 0
        }
        var next = PhysicalViewPlan.make(
            entry: entry,
            showsPhysicalDevices: inputs.showsPhysicalDevices,
            liveViewOn: inputs.liveViewOn,
            autoRefreshOn: inputs.autoRefreshOn,
            screenshotSupported: inputs.screenshotSupported,
            authorization: authorization,
            captureDevice: captureDevice,
            liveFailure: entry.flatMap { liveFailures[$0.udid] },
            nativeLive: nativeActive,
            nativePreferred: nativePreferred
        )
        if let entry, claimedElsewhere == entry.udid, next.mode != .staticPanel {
            // Another window holds the device: never a second session.
            next.note = .shownElsewhere
        }
        if next != plan { plan = next }
        if next.needsCameraRequest, !nativePreferred { requestCameraOnce() }
        noteAudioPermission(for: next, nativePreferred: nativePreferred)
        apply(next, inputs: inputs)
        applyAudio()
        viewChanged()
    }

    /// Reads the Microphone permission for a live plan whose capture device
    /// carries audio, and asks for it once when it is undecided. With the
    /// native live view preferred it never asks: a capture that stands in for
    /// a stalled native view (Camera already granted) runs without audio.
    private func noteAudioPermission(for plan: PhysicalViewPlan, nativePreferred: Bool) {
        var carries = false
        if case .live(let id) = plan.mode {
            carries = captureDevices.first { $0.uniqueID == id }?.hasAudio == true
        }
        if carries != deviceCarriesAudio { deviceCarriesAudio = carries }
        guard carries else { return }
        let status = provider.audioAuthorization
        if status != audioAuthorization { audioAuthorization = status }
        if status == .notDetermined, !nativePreferred { requestMicrophoneOnce() }
    }

    private func requestMicrophoneOnce() {
        guard !requestedMicrophone else { return }
        requestedMicrophone = true
        Task { [weak self] in
            guard let self else { return }
            _ = await self.provider.requestAudioAccess()
            self.reconcile()
        }
    }

    /// Whether the live capture of `captureDeviceID` carries the phone's
    /// audio: the device has it and the Microphone permission is granted.
    private func audioAllowed(for captureDeviceID: String) -> Bool {
        captureDevices.first { $0.uniqueID == captureDeviceID }?.hasAudio == true
            && provider.audioAuthorization == .authorized
    }

    /// Looks at the capture devices again shortly, a bounded number of times.
    private func scheduleLookupRetry() {
        guard lookupRetryTask == nil, lookupRetries < Self.maximumLookupRetries else { return }
        lookupRetryTask = Task { [weak self] in
            guard let interval = self?.lookupRetryInterval else { return }
            // Cancellation ends the wait; the check below then returns.
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, let self else { return }
            self.lookupRetryTask = nil
            self.lookupRetries += 1
            self.reconcile()
        }
    }

    private func requestCameraOnce() {
        guard !requestedCamera else { return }
        requestedCamera = true
        Task { [weak self] in
            guard let self else { return }
            _ = await self.provider.requestAccess()
            self.reconcile()
        }
    }

    private func observeCaptureDevices() {
        guard changeToken == nil else { return }
        changeToken = provider.observeDeviceChanges { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A device came or went: the live capture may try again.
                self.liveFailures.removeAll()
                self.reconcile()
            }
        }
    }

    private func apply(_ plan: PhysicalViewPlan, inputs: Inputs) {
        guard let entry = inputs.entry, plan.mode != .staticPanel else {
            stopOurSession(cause: .userStop)
            return
        }
        // A hidden window (covered by another app, minimized) does not end a
        // running session: the stage stops uploading and drawing frames on
        // its own (`MirrorMetalView.isWindowVisible`) and keeps the last
        // texture, so coming back shows the picture at once. Tearing the
        // session down made the stage wait for a new first frame, which an
        // idle phone screen does not send, and flashed black. A session is
        // only not started while the window is hidden.
        if let current = activeSession() as? any PhysicalViewSession,
           PhysicalDeviceOptIn.normalize(current.hardwareUDID) == entry.udid,
           current.isRunning,
           isSession(current, satisfying: plan.mode)
        {
            return
        }
        guard inputs.isWindowVisible else { return }
        guard let session = makeSession(for: plan.mode, entry: entry) else {
            stopOurSession(cause: .userStop)
            return
        }
        resetPose()
        lastLandscape.withLock { $0 = nil }
        frameObservation = nil
        cadenceText = nil
        sessionError = nil
        let device = DeviceRef.physicalApple(entry.udid)
        guard beginSession(session, device, Self.capabilities) else {
            claimedElsewhere = entry.udid
            var shown = plan
            shown.note = .shownElsewhere
            self.plan = shown
            return
        }
        claimedElsewhere = nil
        observeOrientation(of: session)
    }

    /// What a physical view session offers: a picture, the screenshot and
    /// the recording of its frames. No input, no hardware keys.
    static let capabilities: DeviceCapabilities = [.mirror, .screenshot, .record]

    /// Whether `session` is what `mode` asks for: the same capture device,
    /// and audio exactly when the device and the permission allow it (a
    /// permission granted while a video-only session runs replaces it).
    private func isSession(_ session: any PhysicalViewSession, satisfying mode: PhysicalViewPlan.Mode) -> Bool {
        switch mode {
        case .live(let captureDeviceID):
            guard let live = session as? PhysicalScreenCaptureSession else { return false }
            return live.captureDeviceID == captureDeviceID
                && (live.audioSink != nil) == audioAllowed(for: captureDeviceID)
        case .screenshots:
            return session.viewKind == .screenshots
        case .nativeLive:
            return session.viewKind == .nativeLive
        case .staticPanel:
            return false
        }
    }

    private func makeSession(for mode: PhysicalViewPlan.Mode, entry: ApplePhysicalEntry) -> (any MirrorSessionProtocol)? {
        switch mode {
        case .live(let captureDeviceID):
            // Audio only for a capture device that carries it (a muxed
            // device) and once the Microphone permission is granted: a
            // video-only device gets no sink and no audio output.
            return PhysicalScreenCaptureSession(
                hardwareUDID: entry.udid,
                captureDeviceID: captureDeviceID,
                provider: provider,
                audioSink: audioAllowed(for: captureDeviceID) ? makeAudioSink() : nil
            )
        case .nativeLive:
            return makeNativeSession?(entry)
        case .screenshots:
            guard let capture = screenshotCapture(entry.udid) else { return nil }
            return PhysicalScreenshotSession(hardwareUDID: entry.udid, interval: previewInterval, capture: capture)
        case .staticPanel:
            return nil
        }
    }

    private func stopOurSession(cause: MirrorController.MirrorTeardownCause) {
        frameObservation = nil
        guard activeSession() is any PhysicalViewSession else { return }
        tearDownSession(cause)
    }

    // MARK: - Audio

    /// Brings the phone's audio in line with the policy: plays only while the
    /// workspace's policy allows it, the user has not muted it and the
    /// window is visible. Called after every reconcile and by the workspace
    /// whenever the policy may have changed.
    func applyAudio() {
        let session = activeSession() as? PhysicalScreenCaptureSession
        let sink = session?.isRunning == true ? session?.audioSink : nil
        let policy = audioPolicyProvider()
        let play = sink != nil && policy == .plays && !isAudioMuted && inputs().isWindowVisible
        sink?.setPlaying(play)
        if (sink != nil) != hasAudio { hasAudio = sink != nil }
        if policy != audioPolicy { audioPolicy = policy }
        if play != audioIsPlaying { audioIsPlaying = play }
    }

    /// What the stage says about the phone's audio when the Microphone
    /// permission keeps it silent; nil otherwise.
    var audioNoteText: String? {
        guard deviceCarriesAudio, plan.mode.isLive else { return nil }
        switch audioAuthorization {
        case .denied, .restricted: return PhysicalViewPlan.microphoneDeniedText
        case .notDetermined, .authorized: return nil
        }
    }

    /// Opens the Microphone pane of System Settings. Never changes a setting.
    func openMicrophoneSettings() {
        openURL(PhysicalViewPlan.microphoneSettingsURL)
    }

    /// The banner's speaker button.
    func toggleAudioMuted() {
        isAudioMuted.toggle()
        applyAudio()
    }

    // MARK: - Commands for menus and the pill

    // Device Hub keeps nothing above the phone: the three switches the old
    // banner held, and the actions the pill and the Controls menu offer, are
    // this API. It reads and writes the same preferences the banner did
    // (`liveViewEnabled` and `autoRefreshEnabled` default to on) and drives
    // the workspace's `PhysicalControlController`.

    /// Live View (the USB capture) is on.
    var liveViewEnabled: Bool { inputs().liveViewOn }
    /// Auto-refresh (the screenshot preview where live is not possible) is on.
    var autoRefreshEnabled: Bool { inputs().autoRefreshOn }
    /// "Control this iPhone" is on or starting.
    var controlEnabled: Bool { control?.isOn ?? false }

    func setLiveView(_ on: Bool) { setLiveViewPreference(on) }
    func setAutoRefresh(_ on: Bool) { setAutoRefreshPreference(on) }
    /// Turns Control on (building and starting the runner, progress in the
    /// status line) or off.
    func setControl(_ on: Bool) { control?.setOn(on) }
    /// Fast input carries the stage's input by itself (the preference is on
    /// and no kill switch); the "Control This iPhone" switch is only for when
    /// it does not.
    var inputIsAutomatic: Bool { control?.fastInputEnabled() ?? false }
    /// Why the stage's input is not reaching the iPhone; nil when it is.
    var inputFailure: String? { control?.inputFailure }
    /// Tries the automatic input again.
    func retryInput() { control?.retryInput() }

    /// Nil when Control is on or can be turned on; else the user-facing
    /// reason (no Development Team ID, the device is not ready, no picture
    /// showing). Home, Siri and the App Switcher are unavailable
    /// with it (it is their tooltip).
    var controlAvailability: String? {
        guard let control else { return "Control is not available." }
        return control.onDemandUnavailableReason
    }

    /// Home: through the on-demand fast input while Control is off, else Control starts on demand.
    func pressHome() {
        control?.pressFromMenu(.home)
    }

    /// Nil when Rotate can run (an enabled, ready iPhone; no Control needed).
    var rotationAvailability: String? {
        guard let control else { return "Control is not available." }
        return control.rotationUnavailableReason
    }

    /// A quarter turn through `devicectl device orientation set`; no runner, no Control.
    func rotate(left: Bool) {
        control?.rotate(left ? .left : .right)
    }

    /// The screenshot (the live or preview frame, else `devicectl`), through
    /// the workspace's capture flow.
    func takeScreenshot() {
        Task { await captureScreenshot() }
    }

    /// Siri, through the runner's public XCTest route (Control started on
    /// demand); a phone without it says so in the status line.
    func activateSiri() {
        control?.whenReady { $0.activateSiri() }
    }

    /// The App Switcher (a held swipe up from the bottom edge), Control
    /// started on demand.
    func showAppSwitcher() {
        control?.whenReady { $0.showAppSwitcher() }
    }

    // MARK: - Session health

    /// The health poll's read of the running session: its last error and the
    /// preview's measured cadence.
    func noteHealth(of session: any PhysicalViewSession) {
        guard activeSession() === session else { return }
        let error = session.lastError
        if error != sessionError { sessionError = error }
        if session.viewKind == .nativeLive, session.frames.currentSize != nil {
            // Frames flow: the backoff and the one-message latch start over.
            nativeAttempts.removeAll()
            nativeFallbackFlashed = false
        }
        let cadence = (session as? PhysicalScreenshotSession).flatMap {
            PhysicalScreenshotSession.cadenceText($0.measuredInterval)
        }
        if cadence != cadenceText { cadenceText = cadence }
    }

    /// The session stopped itself (the phone was unplugged, the capture
    /// failed): the workspace tears it down and the preview, if allowed,
    /// takes over.
    func sessionStopped(_ session: any PhysicalViewSession) {
        guard activeSession() === session else { return }
        let message = session.lastError
        let key = PhysicalDeviceOptIn.normalize(session.hardwareUDID)
        let native = session.viewKind == .nativeLive
        if native {
            nativeFailures[key] = message ?? "the stream ended"
            scheduleNativeRetry(key)
        } else if session.viewKind == .liveCapture {
            liveFailures[key] = message ?? "the capture ended"
        }
        let cause: MirrorController.MirrorTeardownCause =
            message == PhysicalScreenCaptureSession.disconnectedMessage ? .disconnected : .transportFatal
        frameObservation = nil
        tearDownSession(cause)
        if !native {
            flash("The live view of the iPhone stopped")
        } else if !nativeFallbackFlashed {
            nativeFallbackFlashed = true
            flash(provider.authorization == .authorized
                ? "The native live view stopped, using the standard live view"
                : "The native live view stopped, showing the preview until it is back")
        }
        reconcile()
    }

    /// Tries the native stream again after the backoff, while the device stays
    /// selected, wired and enabled (`reconcile` cancels it otherwise).
    private func scheduleNativeRetry(_ key: String) {
        let attempt = (nativeAttempts[key] ?? 0) + 1
        nativeAttempts[key] = attempt
        nativeRetryTask?.cancel()
        let delay = Self.nativeRetryDelay(attempt: attempt)
        nativeRetryTask = Task { [weak self] in
            guard let sleep = self?.retrySleep else { return }
            try? await sleep(delay)
            guard !Task.isCancelled, let self else { return }
            self.nativeRetryTask = nil
            self.nativeFailures[key] = nil
            self.reconcile()
        }
    }

    // MARK: - Screenshots

    /// The device's screen as a PNG: the running session's current frame (the
    /// live picture, or the preview's newest, at most a few seconds old), else a
    /// fresh `devicectl` screenshot. Nil when neither exists.
    func screenshotPNG(udid: String) async -> Data? {
        if let session = session(for: udid), let frame = session.frames.current {
            let png = await Task.detached(priority: .userInitiated) {
                FrameImage.pngData(from: frame)
            }.value
            if let png { return png }
        }
        return await deviceScreenshot(udid)
    }

    // MARK: - The Camera pane

    /// Opens the Camera pane of System Settings. Never changes a setting.
    func openCameraSettings() {
        openURL(PhysicalViewPlan.cameraSettingsURL)
    }

    // MARK: - Orientation

    /// The frames are upright for the phone's orientation, so a landscape
    /// frame means the phone lies on its side: the Apple chrome turns to
    /// landscape left (the capture does not say which way; a landscape right
    /// phone shows its chrome mirrored until CoreDevice reports the side).
    private func observeOrientation(of session: any MirrorSessionProtocol) {
        // A session that tracks its own interface orientation (the native view) also turns
        // between landscape sides, which the frame's shape does not show.
        (session as? any PhysicalViewSession)?.observeStagePose { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let turns = self.knownChromeTurns() else { return }
                self.settlePose(turns, true)
            }
        }
        let store = session.frames
        let lock = lastLandscape
        frameObservation = store.observe { [weak self, weak store] in
            guard let size = store?.currentSize else { return }
            let landscape = size.width > size.height
            let previous = lock.withLock { last -> Bool? in
                let previous = last
                last = landscape
                return previous
            }
            guard previous != landscape else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // With Control on, the phone says which landscape it is in
                // (right is 3 turns, left 1); else the capture's shape can
                // only say "left".
                var turns = landscape ? 1 : 0
                if let known = self.knownChromeTurns(), (known % 2 == 1) == landscape { turns = known }
                self.settlePose(turns, previous != nil)
                self.frameShapeChanged()
            }
        }
    }

    // MARK: - Ending

    /// Stops everything for good: the device-change observation and the
    /// session (the app quits, the window closes).
    func stop() {
        changeToken = nil
        frameObservation = nil
        lookupRetryTask?.cancel()
        lookupRetryTask = nil
        nativeRetryTask?.cancel()
        nativeRetryTask = nil
    }
}

/// Why a preview capture failed, in the words the stage shows.
struct PhysicalPreviewError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
