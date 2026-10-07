@preconcurrency import AVFoundation
import Foundation
import os
import DeviceHubProKit

/// Adapts the chunks of a phone's audio to what `AVAudioEngine` connects a
/// player node with: the standard deinterleaved Float32 format at the
/// chunk's own sample rate (the mixer resamples to the output device).
///
/// The capture delivers the phone's audio in the device's own linear PCM
/// (typically Int16 or Float32, 44.1 or 48 kHz, one or two channels). A chunk
/// already in the standard format passes through untouched; any other goes
/// through one `AVAudioConverter`, rebuilt whenever the format changes (the
/// phone switched output, a call changed the rate). More than two channels
/// are asked to fold to stereo; a format the converter refuses yields nil.
/// Used from one queue only.
final class PhysicalAudioAdapter {
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    /// The standard format `chunk` is played in, or nil for a format that
    /// cannot be played (no rate, no channels).
    static func playbackFormat(for source: AVAudioFormat) -> AVAudioFormat? {
        guard source.sampleRate > 0, source.channelCount > 0 else { return nil }
        return AVAudioFormat(
            standardFormatWithSampleRate: source.sampleRate,
            channels: min(source.channelCount, 2)
        )
    }

    /// `chunk` in its playback format; nil when it cannot be converted.
    func adapt(_ chunk: PhysicalAudioChunk) -> AVAudioPCMBuffer? {
        let input = chunk.buffer
        guard input.frameLength > 0, let target = Self.playbackFormat(for: input.format) else { return nil }
        if input.format == target { return input }
        if sourceFormat != input.format {
            sourceFormat = input.format
            targetFormat = target
            converter = AVAudioConverter(from: input.format, to: target)
        }
        guard let converter, let target = targetFormat,
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: input.frameLength)
        else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

/// Plays the audio of a physical iPhone's live view on the Mac
/// (`AVAudioEngine` + `AVAudioPlayerNode`), off the main thread.
///
/// **Threads.** Every method may be called from any thread. Chunks arrive on
/// the capture's audio queue; all the engine work runs on this player's own
/// serial queue, so neither the capture nor the main actor ever waits for the
/// audio device.
///
/// **Policy.** The player plays only while `setPlaying(true)` is in force (the
/// workspace's audio policy and the user's mute toggle decide, see
/// `PhysicalLiveViewController.applyAudio`). Off, chunks are dropped before
/// they reach the engine and the engine is released, so a muted phone holds
/// no output device. `stop()` (the session ended) releases the engine too and
/// leaves the player ready for a restarted session.
///
/// **Latency.** At most `maxQueuedSeconds` of audio waits to play; a chunk
/// that would exceed it is dropped, so an output that stalls (a route change,
/// a busy device) never builds up a delay against the picture. Chunks are
/// scheduled the moment they arrive: the picture is drawn as it arrives too,
/// so the two stay within the capture's own chunk size (tens of
/// milliseconds) of each other.
///
/// **Routes.** When the output route changes the engine stops itself; the
/// player restarts it on the new route and drops what was queued for the old
/// one.
final class PhysicalAudioPlayer: PhysicalAudioSink, @unchecked Sendable {
    /// The most audio that may wait to play.
    static let maxQueuedSeconds = 0.2

    private let queue = DispatchQueue(label: "io.github.gitemre.devicehubpro.physical-audio.player", qos: .userInteractive)
    private static let log = Logger(subsystem: "io.github.gitemre.devicehubpro", category: "physical-audio")

    // Queue only.
    private var playing = false
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var connectedFormat: AVAudioFormat?
    private var engineRunning = false
    private var configurationObserver: NSObjectProtocol?
    private let adapter = PhysicalAudioAdapter()
    private var queued = QueuedFrames()
    private var retryAt: ContinuousClock.Instant?
    private var droppedChunks = 0

    init() {}

    deinit {
        // No further work can be queued once the last reference is gone.
        tearDown()
    }

    // MARK: PhysicalAudioSink

    func play(_ chunk: PhysicalAudioChunk) {
        queue.async { [self] in
            guard playing else { return }
            playOnQueue(chunk)
        }
    }

    func setPlaying(_ playing: Bool) {
        queue.async { [self] in
            guard self.playing != playing else { return }
            self.playing = playing
            if !playing { tearDown() }
        }
    }

    func stop() {
        queue.async { [self] in
            tearDown()
        }
    }

    // MARK: Engine (queue only)

    private func playOnQueue(_ chunk: PhysicalAudioChunk) {
        guard let buffer = adapter.adapt(chunk) else {
            droppedChunks += 1
            return
        }
        guard prepareEngine(for: buffer.format), let node else { return }
        let frames = Int(buffer.frameLength)
        let limit = Int(buffer.format.sampleRate * Self.maxQueuedSeconds)
        let queued = queued
        guard queued.reserve(frames, limit: limit) else {
            droppedChunks += 1
            return
        }
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            queued.release(frames)
        }
        if !node.isPlaying { node.play() }
    }

    /// Makes the engine and node ready for `format`: creates them on the first
    /// chunk, reconnects the node when the format changed. False when the
    /// engine cannot run (retried at most once a second).
    private func prepareEngine(for format: AVAudioFormat) -> Bool {
        if let retryAt, ContinuousClock.now < retryAt { return false }
        if engine == nil {
            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            engine.attach(node)
            self.engine = engine
            self.node = node
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                self?.queue.async { self?.outputRouteChanged() }
            }
        }
        guard let engine, let node else { return false }
        if connectedFormat != format {
            node.stop()
            queued = QueuedFrames()
            engine.connect(node, to: engine.mainMixerNode, format: format)
            connectedFormat = format
        }
        if !engineRunning {
            do {
                try engine.start()
                engineRunning = true
                retryAt = nil
            } catch {
                Self.log.error("phone audio could not start: \(error.localizedDescription, privacy: .public)")
                retryAt = ContinuousClock.now + .seconds(1)
                return false
            }
        }
        return true
    }

    /// The output device changed and the engine stopped itself: what was
    /// queued for the old route is dropped and the next chunk restarts the
    /// engine on the new one.
    private func outputRouteChanged() {
        guard engine != nil else { return }
        engineRunning = false
        node?.stop()
        queued = QueuedFrames()
        if let engine, let node, let connectedFormat {
            engine.connect(node, to: engine.mainMixerNode, format: connectedFormat)
        }
        Self.log.info("phone audio output changed; engine restarts with the next chunk")
    }

    /// Releases the engine, the node and everything queued.
    private func tearDown() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        node?.stop()
        if engineRunning { engine?.stop() }
        engineRunning = false
        engine = nil
        node = nil
        connectedFormat = nil
        queued = QueuedFrames()
        retryAt = nil
    }
}
