import Foundation

/// Health signals from the device watcher's transport.
public enum DeviceWatcherHealth: Sendable, Equatable {
    /// `track-devices` exited; attempt N to restart it is pending.
    case restarting(attempt: Int)
    /// `track-devices` could not be kept alive; polling `devices -l` instead.
    case degraded
}

public enum DeviceWatcherEvent: Sendable {
    case snapshot(devices: [AndroidDevice], degraded: Bool)
    case health(DeviceWatcherHealth)
}

/// Restart schedule for the `track-devices` child: `delays[failures - 1]`,
/// capped at the last entry; after `degradedAfterFailures` consecutive failed
/// starts the watcher degrades to polling instead of spinning, and retries
/// `track-devices` every `degradedRetryInterval` so a recovered adb brings
/// hot-plug tracking back without an app restart.
public struct DeviceWatcherRestartPolicy: Sendable, Equatable {
    public var delays: [Duration]
    public var degradedAfterFailures: Int
    public var degradedRetryInterval: Duration

    public init(
        delays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(5)],
        degradedAfterFailures: Int = 3,
        degradedRetryInterval: Duration = .seconds(30)
    ) {
        self.delays = delays
        self.degradedAfterFailures = degradedAfterFailures
        self.degradedRetryInterval = degradedRetryInterval
    }

    public func delay(afterFailures failures: Int) -> Duration {
        guard !delays.isEmpty else { return .seconds(5) }
        return delays[min(max(failures, 1) - 1, delays.count - 1)]
    }

    public func shouldDegrade(afterFailures failures: Int) -> Bool {
        failures >= degradedAfterFailures
    }
}

/// Watches `adb track-devices -l` and publishes device snapshots.
///
/// The child speaks adb's host protocol unchanged: every change arrives as a
/// length-prefixed frame holding the complete `devices -l` list (see
/// `AdbHostFrameDecoder`), so each frame is a full, detailed snapshot and no
/// extra `devices -l` read is needed. Frames are debounced so a rapid
/// unplug/replug burst coalesces into one emission ("the last frame wins").
/// The adb CLI is used rather than a raw socket to the server because it
/// starts the server when none runs and honors the adb environment
/// (`ANDROID_ADB_SERVER_PORT`, `ADB_SERVER_SOCKET`) exactly like every other
/// adb call the app makes.
///
/// When the child dies (adb server restart) it is restarted with capped
/// backoff; a child that delivers no frame within `firstFrameTimeout` counts
/// as a failed start. After repeated failed starts the watcher polls
/// `devices -l` every `pollInterval` with `degraded: true` snapshots — a
/// failed poll emits nothing, so the last list stands — and retries
/// `track-devices` every `restartPolicy.degradedRetryInterval`. Polling
/// pauses while a retry waits for its first frame, so a retry gets only
/// `degradedFirstFrameTimeout`: adb answers a new tracker at once, and a
/// wedged server must not cost the full `firstFrameTimeout` of device
/// updates on every retry.
public final class DeviceWatcher: @unchecked Sendable {
    private let adbURL: URL
    private let restartPolicy: DeviceWatcherRestartPolicy
    private let debounce: Duration
    private let pollInterval: Duration
    private let firstFrameTimeout: Duration
    private let degradedFirstFrameTimeout: Duration

    /// Guards the fields below, and is never held across a `yield` or a
    /// task's `cancel()`. `stop()` takes it, and `stop()` also runs as the
    /// stream's `onTermination`: inside the consumer's cancellation, with
    /// that task's status-record lock held. A `yield` that resumes the
    /// waiting consumer needs that same status-record lock, so a yield under
    /// this lock deadlocks against a consumer being cancelled — the hang in
    /// `DeviceLifecycleCoordinator.stop()`.
    private let lock = NSLock()
    /// Serializes emissions: each one takes its event and yields it with this
    /// held, so events leave in the order their content was taken. Held
    /// across `yield`, so nothing a cancellation handler can reach —
    /// `stop()`, `events()` — ever takes it.
    private let emissionLock = NSLock()
    private var continuation: AsyncStream<DeviceWatcherEvent>.Continuation?
    private var watchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var decoder = AdbHostFrameDecoder()
    private var frameReceived = false
    /// Bumped per `track-devices` child, so a previous child still draining
    /// after its run ended can never feed the current run's decoder.
    private var runGeneration = 0
    private var pendingSnapshot: [AndroidDevice]?

    public init(
        adbURL: URL,
        restartPolicy: DeviceWatcherRestartPolicy = DeviceWatcherRestartPolicy(),
        debounce: Duration = .milliseconds(300),
        pollInterval: Duration = .seconds(2),
        firstFrameTimeout: Duration = .seconds(15),
        degradedFirstFrameTimeout: Duration = .seconds(3)
    ) {
        self.adbURL = adbURL
        self.restartPolicy = restartPolicy
        self.debounce = debounce
        self.pollInterval = pollInterval
        self.firstFrameTimeout = firstFrameTimeout
        self.degradedFirstFrameTimeout = min(degradedFirstFrameTimeout, firstFrameTimeout)
    }

    /// The event stream. One watcher drives one stream; `start()` publishes to it.
    public func events() -> AsyncStream<DeviceWatcherEvent> {
        AsyncStream { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.stop() }
        }
    }

    public func start() {
        stop()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runLoop()
        }
        lock.lock()
        watchTask = task
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let task = watchTask
        let pendingDebounce = debounceTask
        watchTask = nil
        debounceTask = nil
        decoder = AdbHostFrameDecoder()
        frameReceived = false
        runGeneration += 1
        pendingSnapshot = nil
        lock.unlock()
        task?.cancel()
        pendingDebounce?.cancel()
    }

    // MARK: - Transport loop

    private func runLoop() async {
        var failures = 0
        var degraded = false
        while !Task.isCancelled {
            let deliveredFrames = await runTrackDevices(
                firstFrameTimeout: degraded ? degradedFirstFrameTimeout : firstFrameTimeout
            )
            if Task.isCancelled { return }
            if deliveredFrames {
                // A run that delivered frames ends the incident: its exit is
                // a fresh restart (adb server restart), not one more failure.
                failures = 0
                degraded = false
            }
            failures += 1
            if degraded {
                // A retry from polling mode that delivered nothing: back to
                // polling without re-announcing an incident that never ended.
                await poll(for: restartPolicy.degradedRetryInterval)
                continue
            }
            emit(.health(.restarting(attempt: failures)))
            if restartPolicy.shouldDegrade(afterFailures: failures) {
                degraded = true
                emit(.health(.degraded))
                await poll(for: restartPolicy.degradedRetryInterval)
                continue
            }
            // Best effort: sleep only fails on cancellation; the loop re-checks Task.isCancelled.
            try? await Task.sleep(for: restartPolicy.delay(afterFailures: failures))
        }
    }

    /// One `track-devices -l` child, until it exits, is stopped for sending
    /// something that is not adb framing, or delivers no frame within
    /// `firstFrameTimeout` (a wedged server). Returns whether any frame
    /// arrived. A frame still waiting in the debounce window is emitted
    /// before returning, so the run's last word is never lost.
    private func runTrackDevices(firstFrameTimeout: Duration) async -> Bool {
        let generation = beginRun()
        let adbURL = self.adbURL
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                // Best effort: a failed launch or a cancelled run both end
                // the run; the loop classifies it by whether frames arrived.
                _ = try? await ProcessRunner.streamChunks(
                    executable: adbURL,
                    arguments: ["track-devices", "-l"],
                    onChunk: { [weak self] chunk in
                        self?.ingest(chunk, generation: generation) ?? false
                    }
                )
            }
            group.addTask { [weak self] in
                // The first-frame watchdog: adb answers a new tracker with the
                // current list at once, so silence means a hung child. Once a
                // frame arrived it idles until the run ends.
                // Best effort: sleep only fails on cancellation (the run ended).
                try? await Task.sleep(for: firstFrameTimeout)
                guard let self, self.hasReceivedFrame() else { return }
                while !Task.isCancelled {
                    // Best effort: sleep only fails on cancellation, which ends the idle.
                    try? await Task.sleep(for: .seconds(3600))
                }
            }
            // Whichever finishes first ends the run: the child's exit, or the
            // watchdog giving up on it (cancelling the stream terminates it).
            await group.next()
            group.cancelAll()
        }
        flushPendingSnapshot()
        return hasReceivedFrame()
    }

    // NSLock is unavailable from async contexts, so the loop's critical
    // sections live in these synchronous helpers.

    private func beginRun() -> Int {
        lock.lock()
        defer { lock.unlock() }
        decoder = AdbHostFrameDecoder()
        frameReceived = false
        runGeneration += 1
        return runGeneration
    }

    private func hasReceivedFrame() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return frameReceived
    }

    /// Degraded mode: one `devices -l` read every `pollInterval` until
    /// `window` has elapsed. A failed read (daemon restarting, timeout,
    /// non-zero exit) emits nothing — an empty list would read as "every
    /// device unplugged" and tear sessions down.
    private func poll(for window: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: window)
        while !Task.isCancelled, clock.now < deadline {
            if let devices = await polledDevices() {
                emitSnapshot(devices, degraded: true)
            }
            // Best effort: sleep only fails on cancellation; the loop re-checks Task.isCancelled.
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func polledDevices() async -> [AndroidDevice]? {
        // Best effort: a failed or timed-out read is "no answer", not "no devices".
        guard let result = try? await ProcessRunner.run(
            executable: adbURL,
            arguments: ["devices", "-l"],
            timeout: .seconds(5)
        ), result.exitCode == 0 else { return nil }
        let output = result.standardOutputText
        // A real answer always carries the header, even with no devices.
        guard output.contains("List of devices attached") else { return nil }
        return AdbParsing.devices(from: output)
    }

    // MARK: - Frame ingest (reader thread)

    /// Feeds one stdout chunk to the decoder. Returns false — ending the run —
    /// when the bytes are not adb framing (the restart begins a fresh stream)
    /// or come from a child whose run is already over.
    private func ingest(_ chunk: Data, generation: Int) -> Bool {
        lock.lock()
        guard generation == runGeneration else {
            lock.unlock()
            return false
        }
        let payloads: [String]
        do {
            payloads = try decoder.append(chunk)
        } catch {
            lock.unlock()
            return false
        }
        if !payloads.isEmpty {
            frameReceived = true
        }
        lock.unlock()
        // Each frame is the complete list, so only the newest one matters.
        if let latest = payloads.last {
            scheduleEmit(of: AdbParsing.trackDevicesSnapshot(from: latest))
        }
        return true
    }

    /// Arms the coalescing window for the snapshot: the first frame of a
    /// quiet period starts the debounce timer, later frames only replace the
    /// pending content ("the last frame wins") and never push the timer back,
    /// so a continuous frame stream still emits once per window instead of
    /// starving the timer (spec §5.1: a fresh snapshot on every restart).
    private func scheduleEmit(of devices: [AndroidDevice]) {
        lock.lock()
        defer { lock.unlock() }
        pendingSnapshot = devices
        guard debounceTask == nil else { return }
        let debounce = self.debounce
        debounceTask = Task { [weak self] in
            // Best effort: sleep only fails on cancellation; the guard re-checks Task.isCancelled.
            try? await Task.sleep(for: debounce)
            guard let self, !Task.isCancelled else { return }
            self.flushPendingSnapshot()
        }
    }

    /// Closes the coalescing window and emits its snapshot, if any. Taking
    /// the snapshot and yielding it happen under `emissionLock`, so emissions
    /// leave in the order their content was taken: an older list can never be
    /// emitted after a newer one (a window flushed at run end and the timer
    /// that fires later find the same, already-taken slot). A snapshot taken
    /// just before `stop()` may still be yielded after it: `stop()` must not
    /// wait for a yield in flight (see `lock`).
    private func flushPendingSnapshot() {
        emissionLock.lock()
        defer { emissionLock.unlock() }
        lock.lock()
        let timer = debounceTask
        debounceTask = nil
        let devices = pendingSnapshot
        pendingSnapshot = nil
        let continuation = self.continuation
        lock.unlock()
        timer?.cancel()
        guard let devices else { return }
        continuation?.yield(.snapshot(devices: devices, degraded: false))
    }

    private func emitSnapshot(_ devices: [AndroidDevice], degraded: Bool) {
        emit(.snapshot(devices: devices, degraded: degraded))
    }

    private func emit(_ event: DeviceWatcherEvent) {
        emissionLock.lock()
        defer { emissionLock.unlock() }
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(event)
    }
}
