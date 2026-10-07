import AppKit
import CoreMedia
import CoreVideo
import Darwin
import Metal
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// Opt-in memory soak of the app's hot pipelines, headless: no window, no
/// simulator, no device. Skipped unless `DHP_SOAK=1`:
///
///     DHP_SOAK=1 DHP_SOAK_SECONDS=60 swift test --filter MemorySoakTests
///
/// Each scenario drives one pipeline for `DHP_SOAK_SECONDS` (default 60)
/// and prints a `SOAK` line with the process footprint
/// (`MemoryFootprint.current()`, the number macOS's out-of-memory dialog
/// uses) every `DHP_SOAK_SAMPLE` seconds (default 10), then asserts the
/// footprint stopped growing: the last sample may not exceed the sample at
/// 40% of the run by more than `growthAllowanceMB`. `vmmap --summary` rows
/// (IOSurface, CoreAnimation, malloc) are printed at the start and the end.
///
/// Scenarios: the renderer's upload path fed 1206x2622 BGRA pixel buffers at
/// 60 fps (the simulator mirror) by a consumer that keeps up, by a slow one
/// and by one that stalls; the same for 1080x2400 RGBA byte frames (the
/// emulator's raw transport); the replay ring fed at 30 fps through the frame
/// feed's conversion; a logcat stream with a fast producer; and the catalog's
/// previews of every installed SDK skin.
@MainActor
final class MemorySoakTests: XCTestCase {
    static let growthAllowanceMB = 120.0

    private var seconds: Double {
        // Never longer than 30 s per scenario.
        min(Double(ProcessInfo.processInfo.environment["DHP_SOAK_SECONDS"] ?? "") ?? 30, 30)
    }

    private var sampleEvery: Double {
        Double(ProcessInfo.processInfo.environment["DHP_SOAK_SAMPLE"] ?? "") ?? 10
    }

    override nonisolated func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["DHP_SOAK"] == "1" else {
            throw XCTSkip("memory soak runs only with DHP_SOAK=1")
        }
        if let free = MemoryFootprint.systemFreePercent(), free < 30 {
            throw XCTSkip("memory soak needs 30% of the Mac's memory free (now \(free)%)")
        }
    }

    // MARK: - Renderer upload path

    func testRendererWithAConsumerThatKeepsUp() async throws {
        try await renderer(name: "renderer-keeps-up", pixelBuffers: true, consumerInterval: .milliseconds(16), hold: .milliseconds(4))
    }

    func testRendererWithASlowConsumer() async throws {
        try await renderer(name: "renderer-slow-consumer", pixelBuffers: true, consumerInterval: .milliseconds(200), hold: .milliseconds(150))
    }

    func testRendererWhileTheMainThreadStalls() async throws {
        try await renderer(name: "renderer-stalled", pixelBuffers: true, consumerInterval: nil, hold: .zero)
    }

    func testRendererWithByteFrames() async throws {
        try await renderer(name: "renderer-byte-frames", pixelBuffers: false, consumerInterval: .milliseconds(16), hold: .milliseconds(4))
    }

    private func renderer(
        name: String,
        pixelBuffers: Bool,
        consumerInterval: Duration?,
        hold: Duration
    ) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let store = FrameStore()
        let uploader = MirrorFrameUploader(device: device) {}
        uploader.attach(store)
        let observation = store.observe { [weak uploader] in uploader?.frameArrived() }
        defer { withExtendedLifetime(observation) {} }

        let producer = SyntheticProducer(
            store: store,
            width: pixelBuffers ? 1206 : 1080,
            height: pixelBuffers ? 2622 : 2400,
            pixelBuffers: pixelBuffers,
            framesPerSecond: 60
        )
        producer.start()
        defer { producer.stop() }

        let consumer = Task { @MainActor in
            guard let consumerInterval else { return }
            while !Task.isCancelled {
                if let frame = uploader.acquire() {
                    try? await Task.sleep(for: hold)
                    uploader.release(frame)
                }
                try? await Task.sleep(for: consumerInterval)
            }
        }
        defer { consumer.cancel() }

        try await observe(name) {
            "frames \(producer.produced)"
        }
    }

    // MARK: - Replay ring through the frame feed

    func testReplayRingFedThroughTheFrameFeed() async throws {
        let width = 1206
        let height = 2622
        let ring = ReplayBuffer(windowSeconds: 30, targetFPS: 30, width: width, height: height)
        let pool = BGRAPixelBufferPool(width: width, height: height)
        let store = FrameStore()
        let producer = SyntheticProducer(store: store, width: width, height: height, pixelBuffers: true, framesPerSecond: 30)
        let feedQueue = DispatchQueue(label: "soak.feed", qos: .utility)
        let fed = Counter()
        let task = Task.detached {
            while !Task.isCancelled {
                if let frame = store.current {
                    feedQueue.async {
                        guard let buffer = MediaCaptureController.feedPixelBuffer(from: frame, pool: pool) else { return }
                        ring.ingest(buffer, at: CMTime(seconds: ProcessInfo.processInfo.systemUptime, preferredTimescale: 600))
                        fed.increment()
                    }
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
        producer.start()
        defer { producer.stop(); task.cancel() }
        try await observe("replay-ring-30s-window") { "fed \(fed.value)" }
    }

    // MARK: - Logcat

    func testLogcatStreamAtAHighRate() async throws {
        try await logcat(name: "logcat-valid-lines", script: """
            #!/usr/bin/perl
            $| = 0; my $i = 0;
            while (1) { $i++; print "10-04 12:00:00.000  1000  1000 I Soak: line $i of a very chatty application writing a typical message\\n"; }
            """)
    }

    func testLogcatStreamWithLinesThatAreNotLogcat() async throws {
        try await logcat(name: "logcat-unparsed-lines", script: """
            #!/usr/bin/perl
            $| = 0; my $i = 0;
            while (1) { $i++; print "  at com.example.Frame.method$i(Frame.java:$i) continuation text without any header\\n"; }
            """)
    }

    private func logcat(name: String, script: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("soak-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let adb = directory.appendingPathComponent("adb")
        try script.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        let stream = LogcatStream(adbURL: adb, serial: "soak-serial")
        stream.start()
        defer { stream.stop() }
        // A reader like the log pane's: it copies the history every half second.
        let reader = Task.detached {
            while !Task.isCancelled {
                _ = stream.snapshot().count
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { reader.cancel() }
        try await observe(name) {
            let entries = stream.snapshot()
            let longest = entries.map { $0.message.utf8.count }.max() ?? 0
            return "entries \(entries.count) longest message \(longest) bytes"
        }
    }

    // MARK: - Catalog previews

    func testCatalogPreviewsOfEverySkin() async throws {
        let skins = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Android/sdk/skins")
        let entries = SkinResolver.catalog(skinsDirectory: skins)
        guard !entries.isEmpty else { throw XCTSkip("no SDK skins installed") }
        let cache = SkinThumbnailCache()
        let before = MemoryFootprint.current() ?? 0
        var rendered = 0
        var peak = before
        for entry in entries {
            for variant in entry.variants {
                _ = await cache.renderedImage(for: variant)
                rendered += 1
                peak = max(peak, MemoryFootprint.current() ?? 0)
            }
        }
        let after = MemoryFootprint.current() ?? 0
        print("SOAK catalog-previews skins \(entries.count) variants \(rendered) cache \(cache.previewBytes >> 20) MB " +
              "footprint before \(MemoryFootprint.megabytes(before)) peak \(MemoryFootprint.megabytes(peak)) after \(MemoryFootprint.megabytes(after))")
        XCTAssertLessThanOrEqual(cache.previewBytes, 64 << 20, "the preview budget")
        // A second pass over the same skins is served from the cache.
        for entry in entries {
            for variant in entry.variants { _ = cache.image(for: variant) }
        }
        let again = MemoryFootprint.current() ?? 0
        print("SOAK catalog-previews second pass footprint \(MemoryFootprint.megabytes(again))")
    }

    // MARK: - Sampling

    /// Samples the footprint while the scenario runs, then asserts it flat.
    private func observe(_ name: String, detail: @escaping @Sendable () -> String) async throws {
        let seconds = self.seconds
        let sampleEvery = self.sampleEvery
        let start = Date()
        Self.report(name, "start", Self.vmmapRows())
        var samples: [(t: Double, mb: Double)] = []
        var next = 0.0
        while Date().timeIntervalSince(start) < seconds {
            let elapsed = Date().timeIntervalSince(start)
            if let reason = MemoryFootprint.soakAbortReason() {
                XCTFail("\(name): \(reason)")
                return
            }
            if elapsed >= next {
                let mb = Double(MemoryFootprint.current() ?? 0) / 1_048_576
                samples.append((elapsed, mb))
                Self.report(name, String(format: "t=%3.0fs footprint %.1f MB", elapsed, mb), detail())
                next += sampleEvery
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        let last = Double(MemoryFootprint.current() ?? 0) / 1_048_576
        samples.append((seconds, last))
        Self.report(name, String(format: "end footprint %.1f MB", last), Self.vmmapRows())
        let reference = samples.first { $0.t >= seconds * 0.4 }?.mb ?? last
        XCTAssertLessThanOrEqual(last - reference, Self.growthAllowanceMB, "\(name): footprint kept growing (\(reference) MB at 40%, \(last) MB at the end)")
    }

    private static func report(_ name: String, _ line: String, _ detail: String) {
        print("SOAK \(name) \(line) \(detail)")
    }

    /// The `vmmap --summary` rows that matter, for this process.
    static func vmmapRows() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
        process.arguments = ["--summary", String(getpid())]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "(vmmap unavailable)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let wanted = ["IOSurface", "CoreAnimation", "MALLOC_LARGE", "MALLOC_SMALL", "VM_ALLOCATE", "Physical footprint:"]
        return text.split(separator: "\n")
            .filter { line in wanted.contains { line.hasPrefix($0) } }
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).prefix(5).joined(separator: " ") }
            .joined(separator: " | ")
    }
}

/// Counts from any thread.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// Puts a frame into a store at a fixed rate from a timer queue: a pooled
/// BGRA pixel buffer (what the simulator and scrcpy sessions publish) or a
/// byte frame (the emulator's raw transport), its content changing every frame.
private final class SyntheticProducer: @unchecked Sendable {
    private let store: FrameStore
    private let width: Int
    private let height: Int
    private let pixelBuffers: Bool
    private let framesPerSecond: Int
    private let queue = DispatchQueue(label: "soak.producer", qos: .userInteractive)
    private let pool: BGRAPixelBufferPool?
    private var timer: DispatchSourceTimer?
    private let counter = Counter()
    private var sequence: UInt32 = 0

    var produced: Int { counter.value }

    init(store: FrameStore, width: Int, height: Int, pixelBuffers: Bool, framesPerSecond: Int) {
        self.store = store
        self.width = width
        self.height = height
        self.pixelBuffers = pixelBuffers
        self.framesPerSecond = framesPerSecond
        self.pool = pixelBuffers ? BGRAPixelBufferPool(width: width, height: height) : nil
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / framesPerSecond))
        timer.setEventHandler { [self] in produce() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func produce() {
        sequence &+= 1
        if pixelBuffers {
            guard let buffer = pool?.makeBuffer() else { return }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(sequence & 0xFF), CVPixelBufferGetBytesPerRow(buffer) * height)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            store.put(Frame(pixelBuffer: buffer, seq: sequence) { _ in nil })
        } else {
            let data = Data(repeating: UInt8(sequence & 0xFF), count: width * height * 4)
            store.put(Frame(data: data, width: width, height: height, seq: sequence))
        }
        counter.increment()
    }
}
