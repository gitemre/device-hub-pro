import Accelerate
import AVFoundation
import Observation
import Synchronization
import os
import DeviceHubProKit

/// Plays the emulator's audio stream (48 kHz stereo S16 PCM) through
/// `AVAudioEngine`.
///
/// Nothing fails silently: an engine that cannot start, a stream failure
/// (`AudioStream.lastError`, checked every second while playing) and an
/// output device the engine cannot restart on land in `problem` — observable
/// — and in `onProblem`, and are logged. When the output route changes
/// (AirPods connect, the default device switches) the engine stops itself;
/// the player restarts it on the new route. Chunks are converted to the
/// engine's standard Float32 format, chunks of a stopped or restarted stream
/// are dropped, and at most `maxQueuedFrames` wait to play, so latency stays
/// bounded after a stall. Exactly silent chunks (the emulator streams
/// zeros while nothing plays) are dropped on the stream's thread, so an idle
/// mirror schedules no audio at all.
@MainActor
@Observable
final class AudioPlayer {
    /// Why in-app audio is not playing, if anything; nil while healthy.
    private(set) var problem: String?
    /// Called with every new `problem`, for a status line or alert.
    @ObservationIgnored var onProblem: ((String) -> Void)?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private var stream: AudioStream?
    @ObservationIgnored private var isConfigured = false
    /// Whether the engine is running, kept here rather than read per chunk:
    /// `AVAudioEngine.isRunning` asks the output device over IPC, and doing
    /// that for every 10 ms chunk cost several percent of a core at idle.
    /// Set by `startEngine`, cleared by `stop` and by a configuration change
    /// (the engine has already stopped itself when that arrives).
    @ObservationIgnored private var engineRunning = false
    /// Bumped by every start and stop: chunks still queued as main-actor
    /// tasks for an older stream are dropped instead of scheduled.
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var healthTask: Task<Void, Never>?
    /// Frames scheduled but not yet played, for the current stream only
    /// (a restart gets a fresh counter, so late completions of the old
    /// stream's buffers cannot skew it).
    @ObservationIgnored private var queued = QueuedFrames()
    /// Chunks dropped because the queue was full (a stalled output).
    @ObservationIgnored private(set) var droppedChunks = 0

    private static let log = Logger(subsystem: "io.github.gitemre.devicehubpro", category: "audio")

    /// The player node's format: the engine's standard deinterleaved Float32
    /// at the stream's rate and channel count. Connecting interleaved Int16
    /// straight to the mixer is a common cause of engine start failures.
    nonisolated static let format = AVAudioFormat(
        standardFormatWithSampleRate: Double(AudioStream.sampleRate),
        channels: AVAudioChannelCount(AudioStream.channelCount)
    )!

    /// At most 200 ms of audio waits to play; newer chunks beyond it are
    /// dropped rather than piling up behind a stalled output.
    nonisolated static let maxQueuedFrames = AudioStream.sampleRate / 5

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    var isRunning: Bool {
        stream != nil
    }

    func start(port: Int) {
        stop()
        configureIfNeeded()
        guard startEngine() else { return }

        generation &+= 1
        let generation = generation
        queued = QueuedFrames()
        let stream = AudioStream(port: port)
        self.stream = stream
        stream.start { [weak self] data in
            guard !Self.isSilent(data) else { return }
            Task { @MainActor in
                self?.enqueue(data, generation: generation)
            }
        }
        watch(stream, generation: generation)
    }

    func stop() {
        generation &+= 1
        healthTask?.cancel()
        healthTask = nil
        stream?.stop()
        stream = nil
        player.stop()
        if engineRunning {
            engine.stop()
            engineRunning = false
        }
        problem = nil
    }

    private func configureIfNeeded() {
        guard !isConfigured else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.format)
        // Delivered on the main queue; the engine has already stopped itself.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.outputRouteChanged()
            }
        }
        isConfigured = true
    }

    /// Starts the engine and the player; reports and returns false when the
    /// engine cannot start.
    private func startEngine() -> Bool {
        do {
            try engine.start()
        } catch {
            engineRunning = false
            report("In-app audio could not start: \(error.localizedDescription)")
            return false
        }
        engineRunning = true
        player.play()
        return true
    }

    /// The output device changed and the engine stopped itself. Buffers
    /// queued for the old route are dropped and the engine restarts on the
    /// new one; the stream itself keeps running.
    private func outputRouteChanged() {
        engineRunning = false
        guard stream != nil else { return }
        player.stop()
        queued = QueuedFrames()
        engine.connect(player, to: engine.mainMixerNode, format: Self.format)
        if startEngine() {
            Self.log.info("audio output changed; engine restarted")
        }
    }

    /// Checks the stream's error once a second while this stream plays.
    private func watch(_ stream: AudioStream, generation: UInt64) {
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.generation == generation else { return }
                self.noteStreamError(stream.lastError)
            }
        }
    }

    /// Mirrors `AudioStream.lastError` into `problem`: a failure is
    /// reported once, and cleared when the reconnecting stream recovers —
    /// unless the engine itself is down, which stays reported.
    func noteStreamError(_ error: String?) {
        if let error {
            report(error)
        } else if problem != nil, engineRunning {
            problem = nil
        }
    }

    private func report(_ message: String) {
        guard problem != message else { return }
        problem = message
        Self.log.error("\(message, privacy: .public)")
        onProblem?(message)
    }

    private func enqueue(_ data: Data, generation: UInt64) {
        // A chunk of a stream that was stopped or replaced, or one arriving
        // while the engine is down (scheduling and `play()` on a stopped
        // engine can raise an Objective-C exception): drop it.
        guard generation == self.generation, stream != nil, engineRunning,
              let buffer = Self.makeBuffer(from: data)
        else {
            return
        }
        let frames = Int(buffer.frameLength)
        let queued = queued
        guard queued.reserve(frames, limit: Self.maxQueuedFrames) else {
            droppedChunks += 1
            return
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            queued.release(frames)
        }
        if !player.isPlaying {
            player.play()
        }
    }

    /// Interleaved little-endian S16 PCM → a deinterleaved Float32 buffer in
    /// `format`. Nil when `data` holds less than one frame.
    nonisolated static func makeBuffer(from data: Data) -> AVAudioPCMBuffer? {
        let channels = AudioStream.channelCount
        let bytesPerFrame = channels * MemoryLayout<Int16>.size
        let frames = data.count / bytesPerFrame
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = buffer.floatChannelData
        else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        // Deinterleave and convert with vDSP: one strided Int16 → Float pass
        // and one scale per channel instead of a per-sample loop. Arm64 Macs
        // are little-endian, so the wire's S16LE is the native layout; an
        // unaligned `Data` is copied once so vDSP gets aligned Int16s.
        var scale = Float(1) / 32768
        let convert = { (samples: UnsafePointer<Int16>) in
            for channel in 0..<channels {
                vDSP_vflt16(samples + channel, vDSP_Stride(channels), destination[channel], 1, vDSP_Length(frames))
                vDSP_vsmul(destination[channel], 1, &scale, destination[channel], 1, vDSP_Length(frames))
            }
        }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress, Int(bitPattern: base) % MemoryLayout<Int16>.alignment == 0 {
                convert(base.assumingMemoryBound(to: Int16.self))
            } else {
                let aligned = [UInt8](raw)
                aligned.withUnsafeBytes { convert($0.baseAddress!.assumingMemoryBound(to: Int16.self)) }
            }
        }
        return buffer
    }

    /// Whether a chunk is exact digital silence (all zero bytes). Scanned a
    /// word at a time on the stream's thread.
    nonisolated static func isSilent(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            let wordSize = MemoryLayout<UInt64>.size
            var offset = 0
            while offset + wordSize <= raw.count {
                if raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self) != 0 { return false }
                offset += wordSize
            }
            while offset < raw.count {
                if raw[offset] != 0 { return false }
                offset += 1
            }
            return true
        }
    }
}

/// Frames scheduled on the player and not yet played. Reserved on the main
/// actor, released from the audio render thread's completion callbacks.
final class QueuedFrames: Sendable {
    private let frames = Mutex(0)

    /// Reserves `count` frames unless that would exceed `limit`. A chunk
    /// larger than `limit` on its own is still taken when nothing is queued.
    func reserve(_ count: Int, limit: Int) -> Bool {
        frames.withLock { queued in
            guard queued == 0 || queued + count <= limit else { return false }
            queued += count
            return true
        }
    }

    func release(_ count: Int) {
        frames.withLock { $0 = max(0, $0 - count) }
    }

    var count: Int { frames.withLock { $0 } }
}
