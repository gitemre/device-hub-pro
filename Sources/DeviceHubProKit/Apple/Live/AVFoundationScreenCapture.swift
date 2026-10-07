@preconcurrency import AVFoundation
import CoreMediaIO
import CoreVideo
import Foundation
import Synchronization

/// The real CoreMediaIO + AVFoundation capture of a connected iOS device's
/// screen: the public screen capture path. `kCMIOHardwarePropertyAllowScreenCaptureDevices` is a public
/// CoreMediaIO header property; set to 1 on `kCMIOObjectSystemObject`, macOS
/// exposes each USB-connected iOS device as an `AVCaptureDevice` of type
/// `.external` with the `.muxed` media type (video and audio). Capturing
/// needs the Camera permission.
///
/// Nothing here uses a private framework, a CoreDevice media stream or a
/// tunnel, and nothing here can send input to the phone.
public struct AVFoundationScreenCaptureProvider: PhysicalScreenCaptureProviding {
    /// Whether the CoreMediaIO property was set in this process.
    private static let allowed = Mutex(false)

    public init() {}

    public func allowScreenCaptureDevices() {
        let first = Self.allowed.withLock { done -> Bool in
            if done { return false }
            done = true
            return true
        }
        guard first else { return }
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        // Best effort: without it the phone is simply not a capture device,
        // and the stage falls back to screenshots.
        _ = CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &allow
        )
    }

    public func captureDevices() -> [PhysicalCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: nil,
            position: .unspecified
        )
        return discovery.devices
            .filter { $0.hasMediaType(.muxed) || $0.hasMediaType(.video) }
            .map {
                PhysicalCaptureDevice(
                    uniqueID: $0.uniqueID,
                    localizedName: $0.localizedName,
                    modelID: $0.modelID,
                    hasAudio: $0.hasMediaType(.muxed) || $0.hasMediaType(.audio)
                )
            }
    }

    public var authorization: CaptureAuthorization { Self.authorization(for: .video) }

    public func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    public var audioAuthorization: CaptureAuthorization { Self.authorization(for: .audio) }

    public func requestAudioAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    private static func authorization(for type: AVMediaType) -> CaptureAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }

    public func makeCapture(
        uniqueID: String,
        onFrame: @escaping @Sendable (CVPixelBuffer) -> Void,
        onAudio: (@Sendable (PhysicalAudioChunk) -> Void)?,
        onDrop: @escaping @Sendable () -> Void,
        onEnd: @escaping @Sendable (PhysicalCaptureEnd) -> Void
    ) throws -> any PhysicalCaptureRunning {
        guard let device = AVCaptureDevice(uniqueID: uniqueID) else {
            throw PhysicalScreenCaptureError.deviceNotFound
        }
        return try AVFoundationScreenCapture(
            device: device,
            onFrame: onFrame,
            onAudio: onAudio,
            onDrop: onDrop,
            onEnd: onEnd
        )
    }

    public func observeDeviceChanges(_ handler: @escaping @Sendable () -> Void) -> AnyObject {
        DeviceChangeObservation(handler: handler)
    }
}

/// Keeps the connect and disconnect observers registered while it lives.
private final class DeviceChangeObservation: @unchecked Sendable {
    private var observers: [NSObjectProtocol] = []

    init(handler: @escaping @Sendable () -> Void) {
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in handler() })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

/// One `AVCaptureSession` of a device's screen: the device input and a
/// 32BGRA video data output that discards late frames, delivered on its own
/// serial queue. With `onAudio` and a device that carries audio (the muxed
/// device of an iPhone) an `AVCaptureAudioDataOutput` joins the session and
/// delivers the phone's linear PCM, in the device's own format, on a second
/// serial queue; a session that cannot take the audio output still runs
/// (video only).
private final class AVFoundationScreenCapture: NSObject, PhysicalCaptureRunning,
    AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable
{
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let deliveryQueue = DispatchQueue(label: "com.devicehubpro.physical-capture.frames", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.devicehubpro.physical-capture.audio", qos: .userInteractive)
    private let controlQueue = DispatchQueue(label: "com.devicehubpro.physical-capture.control", qos: .userInitiated)
    private let device: AVCaptureDevice
    private let onFrame: @Sendable (CVPixelBuffer) -> Void
    private let onAudio: (@Sendable (PhysicalAudioChunk) -> Void)?
    private let onDrop: @Sendable () -> Void
    private let onEnd: @Sendable (PhysicalCaptureEnd) -> Void
    /// Guards `stopped` and `observers`: `start` and `stop` run on the
    /// session's queue and on whichever thread stops it.
    private let lock = NSLock()
    private var stopped = false
    private var observers: [NSObjectProtocol] = []

    init(
        device: AVCaptureDevice,
        onFrame: @escaping @Sendable (CVPixelBuffer) -> Void,
        onAudio: (@Sendable (PhysicalAudioChunk) -> Void)?,
        onDrop: @escaping @Sendable () -> Void,
        onEnd: @escaping @Sendable (PhysicalCaptureEnd) -> Void
    ) throws {
        self.device = device
        self.onFrame = onFrame
        self.onAudio = onAudio
        self.onDrop = onDrop
        self.onEnd = onEnd
        super.init()
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw PhysicalScreenCaptureError.cannotAddInput(error.localizedDescription)
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input) else {
            throw PhysicalScreenCaptureError.cannotAddInput("the capture session refused the input")
        }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: deliveryQueue)
        guard session.canAddOutput(output) else {
            throw PhysicalScreenCaptureError.cannotAddInput("the capture session refused the video output")
        }
        session.addOutput(output)
        // Audio only where the device carries it (the input of a muxed
        // device supplies the audio connection) and the Microphone
        // permission is granted: an undecided or denied one is the caller's
        // to ask about, never triggered from here.
        if onAudio != nil, device.hasMediaType(.muxed) || device.hasMediaType(.audio),
           AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        {
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
            } else {
                audioOutput.setSampleBufferDelegate(nil, queue: nil)
            }
        }
    }

    func start() {
        let center = NotificationCenter.default
        let end = onEnd
        let deviceID = device.uniqueID
        let added = [
            center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil
            ) { notification in
                guard (notification.object as? AVCaptureDevice)?.uniqueID == deviceID else { return }
                end(.disconnected)
            },
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
            ) { notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                end(.failed(error?.localizedDescription ?? "unknown error"))
            },
        ]
        lock.lock()
        let alreadyStopped = stopped
        if !alreadyStopped { observers += added }
        lock.unlock()
        if alreadyStopped {
            added.forEach(center.removeObserver)
            return
        }
        controlQueue.async { [session] in
            session.startRunning()
        }
    }

    func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        let removed = observers
        observers = []
        lock.unlock()
        guard !wasStopped else { return }
        removed.forEach(NotificationCenter.default.removeObserver)
        output.setSampleBufferDelegate(nil, queue: nil)
        audioOutput.setSampleBufferDelegate(nil, queue: nil)
        // Synchronous on the control queue: the session is stopped when this
        // returns (the caller is already off the main thread).
        controlQueue.sync { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === audioOutput {
            if let onAudio, let chunk = PhysicalAudioChunk(sampleBuffer: sampleBuffer) {
                onAudio(chunk)
            }
            return
        }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame(buffer)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onDrop()
    }
}
