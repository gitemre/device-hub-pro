import Foundation
import GRPCCore
import GRPCProtobuf

/// Streams the emulator's audio output as 48 kHz stereo signed-16-bit PCM.
///
/// The emulator only emits packets while something is actually playing (UI
/// sounds, music, calls); silence produces no traffic. A stream that fails or
/// ends reconnects with capped backoff until `stop()`; failures, and packets
/// in a format other than the one requested, land in `lastError`.
public final class AudioStream: @unchecked Sendable {
    public let port: Int

    /// The format every delivered chunk has; the player is built for it.
    public static let sampleRate = 48_000
    public static let channelCount = 2

    /// Backoff between reconnects.
    static let reconnectPolicy = ReconnectPolicy(
        delays: [.milliseconds(500), .seconds(1), .seconds(2), .seconds(5)],
        maxAttempts: 4
    )

    private let stateLock = NSLock()
    private var task: Task<Void, Never>?
    private var status = AudioStreamStatus()

    public init(port: Int) {
        self.port = port
    }

    deinit {
        task?.cancel()
    }

    public var lastError: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return status.lastError
    }

    /// Stream attempts since `start()` (test seam for the reconnect loop).
    var attempts: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return status.attempts
    }

    /// Starts delivering PCM chunks on a background callback. The task holds
    /// only the port and its status, never the stream object.
    public func start(onChunk: @escaping @Sendable (Data) -> Void) {
        stop()
        let status = AudioStreamStatus()
        let port = self.port
        let newTask = Task.detached {
            await Self.run(port: port, status: status, onChunk: onChunk)
        }
        stateLock.lock()
        self.status = status
        task = newTask
        stateLock.unlock()
    }

    public func stop() {
        stateLock.lock()
        let old = task
        task = nil
        stateLock.unlock()
        old?.cancel()
    }

    static let requestedFormat = Android_Emulation_Control_AudioFormat.with {
        $0.samplingRate = UInt64(sampleRate)
        $0.channels = .stereo
        $0.format = .audFmtS16
        $0.mode = .modeRealTime
    }

    /// Whether a packet's format is the one the player expects. A packet
    /// without format information is taken as the requested format.
    static func matchesRequestedFormat(_ format: Android_Emulation_Control_AudioFormat) -> Bool {
        guard format.samplingRate != 0 else { return true }
        return format.samplingRate == requestedFormat.samplingRate
            && format.channels == requestedFormat.channels
            && format.format == requestedFormat.format
    }

    private static func run(
        port: Int,
        status: AudioStreamStatus,
        onChunk: @escaping @Sendable (Data) -> Void
    ) async {
        var failures = 0
        while !Task.isCancelled {
            status.attemptStarted()
            let delivered = DeliveredCounter()
            do {
                // A connection of its own: the long-lived stream must not sit
                // on the shared control channel.
                try await EmulatorControl.withClient(port: port) { controller in
                    try await controller.streamAudio(requestedFormat, options: .emulatorFrames) { response in
                        for try await packet in response.messages {
                            guard !packet.audio.isEmpty else { continue }
                            guard matchesRequestedFormat(packet.format) else {
                                // Played as 48 kHz stereo S16 it would come out
                                // at the wrong pitch and speed.
                                status.failed(
                                    "audio: the emulator sent \(packet.format.samplingRate) Hz "
                                        + "\(packet.format.channels) \(packet.format.format), "
                                        + "not 48000 Hz stereo S16; skipping it"
                                )
                                continue
                            }
                            if delivered.increment() == 1 {
                                status.recovered()
                            }
                            onChunk(packet.audio)
                        }
                    }
                }
                if Task.isCancelled { return }
                status.failed("audio: the emulator ended the stream")
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                status.failed("audio: \(error)")
            }

            if delivered.value > 0 {
                failures = 0
            }
            failures += 1
            let delay = reconnectPolicy.delay(attempt: min(failures, reconnectPolicy.maxAttempts))
                ?? .seconds(5)
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
        }
    }
}

/// One `start()`'s error and attempt count.
final class AudioStreamStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var _lastError: String?
    private var _attempts = 0

    var lastError: String? { lock.withLock { _lastError } }
    var attempts: Int { lock.withLock { _attempts } }

    func attemptStarted() { lock.withLock { _attempts += 1 } }
    func failed(_ message: String) { lock.withLock { _lastError = message } }
    /// Audio flows again after a reconnect.
    func recovered() { lock.withLock { _lastError = nil } }
}

private final class DeliveredCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    /// Counts one packet; returns the new total.
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
