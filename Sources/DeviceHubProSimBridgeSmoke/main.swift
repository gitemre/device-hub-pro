// DeviceHubProSimBridgeSmoke: drives the private simulator bridge end to end
// against one booted simulator and reports what worked, with numbers. A debug
// tool for Scripts/ios-bridge-smoke.sh and the yearly Xcode-beta check; it is
// never packaged.
//
//   DeviceHubProSimBridgeSmoke --udid <UDID> [--set <device-set-path>] [--seconds 10] [--out <dir>]
//
// It loads the bridge through DeviceHubProKit (exactly as the app will), then:
//  1. registers the main-screen callbacks and animates the screen (launches
//     Settings) until the first frame arrives, and checks it is BGRA;
//  2. reads `com.apple.coredevice.dtuhidd.active` before any input;
//  3. drags Settings up and down for --seconds while counting frames (the
//     first drag opens the lazy dtuhidd connection);
//  4. reads the flag again;
//  5. taps a Settings row and checks it navigated: a frame within 1 s, the
//     IOSurface seed moved, and the screen changed;
//  6. opens https://example.com, then presses Home and checks the screen
//     changed (PNGs of before and after land in --out when given).
//
// The checks include the plan's T3 bounds for turning the live canvas on:
// the first frame within 3 s and the dtuhidd barrier within 2 s.
//
// On a CoreSimulator the bridge was not verified on (an Xcode beta) the
// version gate fails the run unless DHP_SIMBRIDGE_ALLOW_UNTESTED=1 is set.
//
// Every bridge call runs on one serial queue, never the main queue; the
// bridge would stop the process otherwise. The last line is
// `SMOKE-RESULT <json>`; the exit status is 0 when every check passed.

import DeviceHubProKit
import CoreGraphics
import Foundation
import ImageIO
import IOSurface
import Synchronization
import UniformTypeIdentifiers

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Arguments

struct Options {
    var udid = ""
    var deviceSetPath: String?
    var seconds = 10.0
    var outputDirectory: URL?
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = CommandLine.arguments.dropFirst()
    func value(_ flag: String) -> String {
        guard let next = arguments.popFirst() else {
            FileHandle.standardError.write(Data("missing value for \(flag)\n".utf8))
            exit(2)
        }
        return next
    }
    while let argument = arguments.popFirst() {
        switch argument {
        case "--udid": options.udid = value(argument)
        case "--set": options.deviceSetPath = value(argument)
        case "--seconds": options.seconds = Double(value(argument)) ?? 10
        case "--out": options.outputDirectory = URL(fileURLWithPath: value(argument), isDirectory: true)
        default:
            FileHandle.standardError.write(Data("unknown argument \(argument)\nusage: DeviceHubProSimBridgeSmoke --udid <UDID> [--set <path>] [--seconds 10] [--out <dir>]\n".utf8))
            exit(2)
        }
    }
    guard !options.udid.isEmpty else {
        FileHandle.standardError.write(Data("--udid is required\n".utf8))
        exit(2)
    }
    return options
}

// MARK: - Helpers

func nowNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

func milliseconds(since start: UInt64) -> Double { Double(nowNanoseconds() - start) / 1e6 }

func fourCC(_ value: OSType) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> OSType($0)) & 0xFF) }
    return String(bytes: bytes, encoding: .ascii) ?? String(value, radix: 16)
}

func percentile(_ values: [Double], _ fraction: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
}

func log(_ line: String) {
    print(line)
}

/// Collects a child's output while it runs.
final class OutputCollector: Sendable {
    private let data = Mutex(Data())
    /// Signalled at end of file: every writer closed the pipe.
    let drained = DispatchSemaphore(value: 0)

    func append(_ chunk: Data) { data.withLock { $0.append(chunk) } }
    var text: String { String(decoding: data.withLock { $0 }, as: UTF8.self) }
}

/// Runs a command synchronously with a deadline; the simulator's own tools only.
/// The pipe drains in the background, so a child that hangs with its output
/// open still times out (a screenshot with the screen off blocked simctl for
/// 61 s in the spike). On timeout the child gets SIGTERM, then SIGKILL after 2 s.
func run(_ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval = 60) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice
    let output = OutputCollector()
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if chunk.isEmpty {
            handle.readabilityHandler = nil
            output.drained.signal()
        } else {
            output.append(chunk)
        }
    }
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do {
        try process.run()
    } catch {
        pipe.fileHandleForReading.readabilityHandler = nil
        return (-1, "\(error)")
    }
    var timedOut = false
    if exited.wait(timeout: .now() + timeout) == .timedOut {
        timedOut = true
        process.terminate()
        if exited.wait(timeout: .now() + 2) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            exited.wait()
        }
    }
    // A grandchild that inherited the pipe can hold it open past the exit;
    // take what arrived by then.
    _ = output.drained.wait(timeout: .now() + 2)
    pipe.fileHandleForReading.readabilityHandler = nil
    if timedOut {
        return (-2, "timed out after \(timeout) s: \(output.text)")
    }
    return (process.terminationStatus, output.text)
}

/// The simulator's view of its screen, recorded from the bridge callbacks.
final class ScreenRecorder: Sendable {
    struct State {
        var surface: SimulatorSurface?
        var surfaceEvents = 0
        var nilSurfaceEvents = 0
        var propertiesEvents: [SimulatorScreenProperties] = []
        var frameTimes: [UInt64] = []
        var copies = 0
        var tornCopies = 0
        var copyNanoseconds: UInt64 = 0
        var buffer: UnsafeMutableRawPointer?
        var bufferSize = 0
        var callbackOnMain = 0
    }

    let state = Mutex(State())

    /// The frame path the canvas session will take: copy the live surface
    /// under its read lock and count copies whose seed moved (torn).
    func handle(_ event: SimulatorScreenEvent) {
        let onMain = Thread.isMainThread
        state.withLock { state in
            if onMain { state.callbackOnMain += 1 }
            switch event {
            case .surfaceChanged(let surface):
                state.surfaceEvents += 1
                if surface == nil { state.nilSurfaceEvents += 1 }
                state.surface = surface
            case .propertiesChanged(let properties):
                state.propertiesEvents.append(properties)
            case .frame:
                state.frameTimes.append(nowNanoseconds())
                guard let surface = state.surface?.surface else { return }
                let size = surface.bytesPerRow * surface.height
                if state.bufferSize < size {
                    state.buffer?.deallocate()
                    state.buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 64)
                    state.bufferSize = size
                }
                let start = nowNanoseconds()
                surface.lock(options: .readOnly, seed: nil)
                let before = surface.seed
                memcpy(state.buffer, surface.baseAddress, size)
                let after = surface.seed
                surface.unlock(options: .readOnly, seed: nil)
                state.copyNanoseconds += nowNanoseconds() - start
                state.copies += 1
                if before != after { state.tornCopies += 1 }
            }
        }
    }

    var frameCount: Int { state.withLock { $0.frameTimes.count } }
    var lastFrameTime: UInt64? { state.withLock { $0.frameTimes.last } }
    var surface: SimulatorSurface? { state.withLock { $0.surface } }
    func frameTimes() -> [UInt64] { state.withLock { $0.frameTimes } }

    /// Waits until `count` frames arrived, or the deadline passed.
    func waitForFrames(atLeast count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if frameCount >= count { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return frameCount >= count
    }

    /// Waits until no frame arrived for `quiet` seconds (the screen settled).
    @discardableResult
    func waitForIdle(quiet: TimeInterval = 0.5, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let quietNanoseconds = UInt64(quiet * 1e9)
        while Date() < deadline {
            let last = lastFrameTime ?? 0
            if last == 0 || nowNanoseconds() - last >= quietNanoseconds { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }
}

/// A copy of the surface as a CGImage (BGRA, premultiplied first, little endian).
func snapshot(_ surface: SimulatorSurface) -> CGImage? {
    let raw = surface.surface
    raw.lock(options: .readOnly, seed: nil)
    let data = Data(bytes: raw.baseAddress, count: raw.bytesPerRow * raw.height)
    raw.unlock(options: .readOnly, seed: nil)
    guard let provider = CGDataProvider(data: data as CFData),
          let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
    return CGImage(width: raw.width, height: raw.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: raw.bytesPerRow,
                   space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

/// Sampled pixel statistics of an image: the non-black share, and the share of
/// samples that differ from `other` by more than a small threshold.
func sampledPixels(_ image: CGImage) -> [UInt8] {
    let width = 60, height = 130
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    pixels.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return pixels
}

func nonBlackShare(_ samples: [UInt8]) -> Double {
    var count = 0
    for index in stride(from: 0, to: samples.count, by: 4) where Int(samples[index]) + Int(samples[index + 1]) + Int(samples[index + 2]) > 24 {
        count += 1
    }
    return Double(count) / Double(samples.count / 4)
}

func differingShare(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var count = 0
    for index in stride(from: 0, to: a.count, by: 4) {
        let delta = abs(Int(a[index]) - Int(b[index])) + abs(Int(a[index + 1]) - Int(b[index + 1])) + abs(Int(a[index + 2]) - Int(b[index + 2]))
        if delta > 48 { count += 1 }
    }
    return Double(count) / Double(a.count / 4)
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    if CGImageDestinationFinalize(destination) { log("  wrote \(url.path)") }
}

// MARK: - The run

enum Bounds {
    /// T3 (the tier that turns the live canvas on): the first frame within 3 s.
    static let firstFrameMilliseconds = 3000.0
    /// T3: the dtuhidd readiness barrier answers within 2 s.
    static let barrierMilliseconds = 2000.0
    /// The share of sampled pixels a navigating tap must change. A status-bar
    /// clock tick changes well under 1 %; the Settings row tapped below opened
    /// a sub-page that changed 7 % (2026-09-25, iPhone 17 Pro, iOS 27.0, tr_TR).
    static let tapChangedShare = 0.02
}

struct Check: Encodable {
    let name: String
    let passed: Bool
    let detail: String
}

final class Report: @unchecked Sendable {
    // Only touched from the session queue.
    var checks: [Check] = []
    var numbers: [String: Double] = [:]
    var facts: [String: String] = [:]

    func check(_ name: String, _ passed: Bool, _ detail: String) {
        checks.append(Check(name: name, passed: passed, detail: detail))
        log("\(passed ? "PASS" : "FAIL") \(name): \(detail)")
    }
}

func smoke(_ options: Options, report: Report) throws {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let address = SimulatorAddress(udid: options.udid, deviceSetPath: options.deviceSetPath)
    let bridge = LiveSimulatorBridge()
    var environment = ProcessInfo.processInfo.environment
    environment["DEVELOPER_DIR"] = bridge.developerDir
    let realSimctl = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl"
    let simctl = FileManager.default.isExecutableFile(atPath: realSimctl) ? realSimctl : "/usr/bin/xcrun"
    func simctlArguments(_ rest: [String]) -> [String] {
        (simctl == "/usr/bin/xcrun" ? ["simctl"] : []) + (options.deviceSetPath.map { ["--set", $0] } ?? []) + rest
    }
    func simctlRun(_ rest: [String], timeout: TimeInterval = 60) -> (status: Int32, output: String) {
        run(simctl, simctlArguments(rest), environment: environment, timeout: timeout)
    }
    func dtuhiddActive() -> String {
        let result = simctlRun(["spawn", options.udid, "notifyutil", "-g", "com.apple.coredevice.dtuhidd.active"], timeout: 30)
        let value = result.output.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? "?"
        return result.status == 0 ? value : "error(\(result.status)): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    log("simulator: \(address)")
    log("developer dir: \(bridge.developerDir), simctl: \(simctl)")

    // 1. The gate: no dlopen before the installed version is allowed.
    let installed = BridgeCompatibility.installedCoreSimulatorVersion()
    let verdict = BridgeCompatibility.verdict(coreSimulatorVersion: installed)
    report.facts["coreSimulatorInstalled"] = installed ?? "nil"
    report.facts["compatibility"] = "\(verdict)"
    report.check("compatibility", verdict.allowsBridge, "installed CoreSimulator \(installed ?? "?") → \(verdict)")
    guard verdict.allowsBridge else { return }

    // 2. Load.
    var start = nowNanoseconds()
    let loadInfo = try bridge.load()
    report.numbers["loadMs"] = milliseconds(since: start)
    report.facts["coreSimulatorLoaded"] = loadInfo.coreSimulatorVersion ?? "nil"
    log(String(format: "loaded CoreSimulator %@ in %.1f ms; SimulatorKit mapped: %@",
               loadInfo.coreSimulatorVersion ?? "?", report.numbers["loadMs"]!, loadInfo.simulatorKitLoaded ? "yes" : "no"))

    // 3. The screen.
    start = nowNanoseconds()
    let screen = try bridge.makeScreen(for: address)
    report.numbers["screenResolveMs"] = milliseconds(since: start)
    let properties = screen.initialProperties
    report.facts["screenProperties"] = "type=\(properties.screenType) id=\(properties.screenID) uiOrientation=\(properties.uiOrientation) pixels=\(properties.pixelWidth)x\(properties.pixelHeight)"
    log(String(format: "screen resolved in %.1f ms: %@", report.numbers["screenResolveMs"]!, report.facts["screenProperties"]!))
    report.check("screenType0", properties.screenType == 0, "screenType \(properties.screenType)")

    let input = bridge.makeInput(for: address)
    report.check("inputLazy", !input.isConnected, "input created, connected=\(input.isConnected)")

    let recorder = ScreenRecorder()
    start = nowNanoseconds()
    try screen.start { event in recorder.handle(event) }
    report.numbers["registerMs"] = milliseconds(since: start)
    let surfaceDeadline = Date().addingTimeInterval(3)
    while recorder.surface == nil && Date() < surfaceDeadline { Thread.sleep(forTimeInterval: 0.005) }
    report.numbers["surfaceAfterRegisterMs"] = milliseconds(since: start)
    guard let surface = recorder.surface ?? (try? screen.currentSurface()) else {
        report.check("surface", false, "no framebuffer surface within 3 s")
        screen.stop()
        return
    }
    report.facts["surface"] = "id=\(surface.surfaceID) \(surface.width)x\(surface.height) '\(fourCC(surface.pixelFormat))' bytesPerRow=\(surface.bytesPerRow)"
    log("surface: \(report.facts["surface"]!)")

    // Animate: launch Settings, then wait for the first presented frame.
    let framesBefore = recorder.frameCount
    start = nowNanoseconds()
    let launch = simctlRun(["launch", options.udid, "com.apple.Preferences"])
    log("simctl launch com.apple.Preferences → \(launch.status) \(launch.output.trimmingCharacters(in: .whitespacesAndNewlines))")
    let gotFrame = recorder.waitForFrames(atLeast: framesBefore + 1, timeout: 15)
    report.numbers["firstFrameMs"] = gotFrame ? Double((recorder.frameTimes().dropFirst(framesBefore).first ?? 0) - start) / 1e6 : -1
    let isBGRA = surface.pixelFormat == 0x4247_5241
    let firstFrameMs = report.numbers["firstFrameMs"]!
    report.check("firstFrame", gotFrame && isBGRA && surface.width > 0 && firstFrameMs <= Bounds.firstFrameMilliseconds,
                 String(format: "%@ after launch in %.0f ms (T3: ≤ %.0f ms); %dx%d '%@'", gotFrame ? "frame" : "NO frame",
                        firstFrameMs, Bounds.firstFrameMilliseconds, surface.width, surface.height, fourCC(surface.pixelFormat)))
    // Settings draws its list a moment after the launch animation settles.
    Thread.sleep(forTimeInterval: 2)
    recorder.waitForIdle(quiet: 0.8, timeout: 15)
    if let image = snapshot(surface) {
        let share = nonBlackShare(sampledPixels(image))
        report.numbers["firstFrameNonBlackShare"] = share
        report.check("frameNotBlack", share > 0.2, String(format: "%.0f%% of sampled pixels are not black", share * 100))
        if let directory = options.outputDirectory { writePNG(image, to: directory.appendingPathComponent("01-settings.png")) }
    }

    // 4. dtuhidd.active before any input.
    let activeBefore = dtuhiddActive()
    report.facts["dtuhiddActiveBefore"] = activeBefore
    report.check("dtuhiddInactiveBeforeInput", activeBefore == "0", "com.apple.coredevice.dtuhidd.active = \(activeBefore) before the first input")

    // 5. Drag for --seconds; the first send opens the lazy connection.
    start = nowNanoseconds()
    try input.send(.touch(x: 0.5, y: 0.7, phase: .began))
    report.numbers["firstSendMs"] = milliseconds(since: start)
    if let connect = input.lastConnectReport {
        report.numbers["hidConnectAttempts"] = Double(connect.attempts)
        report.numbers["hidBarrierMs"] = connect.barrierMilliseconds
        report.numbers["hidConnectTotalMs"] = connect.totalMilliseconds
        log(String(format: "dtuhidd connected lazily on the first send: attempts=%d barrier=%.1f ms total=%.1f ms",
                   connect.attempts, connect.barrierMilliseconds, connect.totalMilliseconds))
    }
    report.check("hidConnected", input.isConnected, "connected=\(input.isConnected) after the first send")
    let barrierMs = input.lastConnectReport?.barrierMilliseconds ?? -1
    report.check("hidBarrier", barrierMs >= 0 && barrierMs <= Bounds.barrierMilliseconds,
                 String(format: "barrier answered in %.1f ms (T3: ≤ %.0f ms) after %d attempt(s)",
                        barrierMs, Bounds.barrierMilliseconds, input.lastConnectReport?.attempts ?? 0))
    var sendTimes: [UInt64] = []
    var perSecond: [Int] = []
    let dragFramesStart = recorder.frameCount
    let dragStart = nowNanoseconds()
    var lastTick = dragStart
    var lastTickFrames = dragFramesStart
    var upward = true
    var firstGesture = true
    // Alternate up and down drags; always end on a downward one, so the list
    // is back at its top for the tap below.
    while Double(nowNanoseconds() - dragStart) / 1e9 < options.seconds || !upward {
        let (from, to) = upward ? (0.7, 0.3) : (0.3, 0.7)
        if !firstGesture { try input.send(.touch(x: 0.5, y: from, phase: .began)) }
        firstGesture = false
        for step in 1...15 {
            let y = from + (to - from) * Double(step) / 15
            sendTimes.append(nowNanoseconds())
            try input.send(.touch(x: 0.5, y: y, phase: .moved))
            Thread.sleep(forTimeInterval: 0.016)
        }
        try input.send(.touch(x: 0.5, y: to, phase: .ended))
        upward.toggle()
        if nowNanoseconds() - lastTick >= 1_000_000_000 {
            let frames = recorder.frameCount
            perSecond.append(frames - lastTickFrames)
            lastTickFrames = frames
            lastTick = nowNanoseconds()
        }
    }
    let dragSeconds = Double(nowNanoseconds() - dragStart) / 1e9
    let dragFrames = recorder.frameCount - dragFramesStart
    let frameTimes = recorder.frameTimes()
    var latencies: [Double] = []
    var frameIndex = dragFramesStart
    for sent in sendTimes {
        while frameIndex < frameTimes.count && frameTimes[frameIndex] <= sent { frameIndex += 1 }
        if frameIndex < frameTimes.count { latencies.append(Double(frameTimes[frameIndex] - sent) / 1e6) }
    }
    let dragFPS = Double(dragFrames) / dragSeconds
    report.numbers["dragSeconds"] = dragSeconds
    report.numbers["dragFrames"] = Double(dragFrames)
    report.numbers["dragFPS"] = dragFPS
    report.numbers["dragToFrameP50Ms"] = percentile(latencies, 0.5) ?? -1
    report.numbers["dragToFrameP95Ms"] = percentile(latencies, 0.95) ?? -1
    // Frame pacing while dragging (the canvas box's "scroll p50 ≤ 17.5 ms"):
    // the interval between consecutive published frames of the drag.
    let dragFrameTimes = Array(frameTimes.dropFirst(dragFramesStart))
    let intervals = zip(dragFrameTimes.dropFirst(), dragFrameTimes).map { Double($0 - $1) / 1e6 }
    report.numbers["dragFrameIntervalP50Ms"] = percentile(intervals, 0.5) ?? -1
    report.numbers["dragFrameIntervalP95Ms"] = percentile(intervals, 0.95) ?? -1
    report.facts["dragFramesPerSecond"] = perSecond.map(String.init).joined(separator: ",")
    report.check("dragFrames", dragFPS >= 10,
                 String(format: "%d frames in %.1f s = %.1f fps while dragging (per second: %@); move→next frame p50 %.1f ms, p95 %.1f ms",
                        dragFrames, dragSeconds, dragFPS, report.facts["dragFramesPerSecond"]!,
                        report.numbers["dragToFrameP50Ms"]!, report.numbers["dragToFrameP95Ms"]!))
    let copyState = recorder.state.withLock { ($0.copies, $0.tornCopies, $0.copyNanoseconds) }
    report.numbers["copies"] = Double(copyState.0)
    report.numbers["tornCopies"] = Double(copyState.1)
    report.numbers["averageCopyMs"] = copyState.0 > 0 ? Double(copyState.2) / Double(copyState.0) / 1e6 : -1
    log(String(format: "frame copies so far: %d, torn (seed moved during the copy): %d, average copy %.3f ms",
               copyState.0, copyState.1, report.numbers["averageCopyMs"]!))

    // 6. dtuhidd.active after.
    let activeAfter = dtuhiddActive()
    report.facts["dtuhiddActiveAfter"] = activeAfter
    log("com.apple.coredevice.dtuhidd.active = \(activeAfter) after input")

    // 7. A tap navigates. On a phone (portrait, narrower than 3:5)
    // (0.5, 0.62) is inside the grouped rows below the account card of a
    // fresh iPhone 17 Pro, so the tap opens a settings page. An iPad's
    // Settings is a split view where that point falls between two cards of
    // the detail pane, so there the tap goes to a sidebar row below General
    // (Accessibility on a fresh iPad Pro 13-inch), which swaps the detail
    // pane. A status-bar clock tick also moves the seed, so the seed alone
    // proves nothing: the first frame must follow within 1 s and the screen
    // must change by more than a clock tick could.
    recorder.waitForIdle(quiet: 1.0, timeout: 15)
    let beforeTap = snapshot(surface)
    let seedBefore = surface.seed
    let tapFrames = recorder.frameCount
    let isTablet = surface.height > 0 && Double(surface.width) / Double(surface.height) > 0.6
    let tapPoint = isTablet ? (x: 0.15, y: 0.31) : (x: 0.5, y: 0.62)
    report.facts["tapPoint"] = String(format: "%.2f,%.2f (%@)", tapPoint.x, tapPoint.y, isTablet ? "tablet" : "phone")
    start = nowNanoseconds()
    try input.send(.touch(x: tapPoint.x, y: tapPoint.y, phase: .began))
    Thread.sleep(forTimeInterval: 0.06)
    try input.send(.touch(x: tapPoint.x, y: tapPoint.y, phase: .ended))
    let tapFrame = recorder.waitForFrames(atLeast: tapFrames + 1, timeout: 3)
    let tapLatency = tapFrame ? Double((recorder.frameTimes().dropFirst(tapFrames).first ?? start) - start) / 1e6 : -1
    Thread.sleep(forTimeInterval: 0.5)
    recorder.waitForIdle(quiet: 0.8, timeout: 5)
    let seedAfter = surface.seed
    let afterTap = snapshot(surface)
    let tapChanged = (beforeTap.flatMap { before in afterTap.map { differingShare(sampledPixels(before), sampledPixels($0)) } }) ?? 0
    report.numbers["tapToFrameMs"] = tapLatency
    report.numbers["tapChangedShare"] = tapChanged
    report.facts["tapSeeds"] = "\(seedBefore)→\(seedAfter)"
    report.check("tapNavigates",
                 seedAfter != seedBefore && tapLatency >= 0 && tapLatency < 1000 && tapChanged > Bounds.tapChangedShare,
                 String(format: "seed %u → %u; first frame %.1f ms after the tap-down; %.1f%% of sampled pixels changed (> %.0f%%)",
                        seedBefore, seedAfter, tapLatency, tapChanged * 100, Bounds.tapChangedShare * 100))
    if let directory = options.outputDirectory, let afterTap {
        writePNG(afterTap, to: directory.appendingPathComponent("02-after-tap.png"))
    }

    // 8. Open a page (more animation), then Home.
    let openFrames = recorder.frameCount
    let open = simctlRun(["openurl", options.udid, "https://example.com"])
    log("simctl openurl https://example.com → \(open.status) \(open.output.trimmingCharacters(in: .whitespacesAndNewlines))")
    _ = recorder.waitForFrames(atLeast: openFrames + 1, timeout: 10)
    // Safari's first launch shows a black page until its web process draws.
    Thread.sleep(forTimeInterval: 4)
    recorder.waitForIdle(quiet: 1.0, timeout: 20)
    report.numbers["openURLFrames"] = Double(recorder.frameCount - openFrames)
    let beforeHome = snapshot(surface)
    if let directory = options.outputDirectory, let beforeHome { writePNG(beforeHome, to: directory.appendingPathComponent("03-before-home.png")) }
    let homeFrames = recorder.frameCount
    start = nowNanoseconds()
    try input.send(.button(.home, isDown: true))
    Thread.sleep(forTimeInterval: 0.08)
    try input.send(.button(.home, isDown: false))
    try input.flush(timeout: .seconds(2))
    _ = recorder.waitForFrames(atLeast: homeFrames + 1, timeout: 5)
    Thread.sleep(forTimeInterval: 1)
    recorder.waitForIdle(quiet: 0.8, timeout: 10)
    let afterHome = snapshot(surface)
    if let directory = options.outputDirectory, let afterHome { writePNG(afterHome, to: directory.appendingPathComponent("04-after-home.png")) }
    let homeFrameCount = recorder.frameCount - homeFrames
    let changed = (beforeHome.flatMap { before in afterHome.map { differingShare(sampledPixels(before), sampledPixels($0)) } }) ?? 0
    report.numbers["homeFrames"] = Double(homeFrameCount)
    report.numbers["homeChangedShare"] = changed
    report.check("homeWorks", homeFrameCount > 0 && changed > 0.2,
                 String(format: "%d frames after Home; %.0f%% of sampled pixels changed (Safari → home screen)", homeFrameCount, changed * 100))

    // 9. Tear down and account.
    screen.stop()
    input.disconnect()
    let events = recorder.state.withLock { ($0.surfaceEvents, $0.nilSurfaceEvents, $0.propertiesEvents.count, $0.callbackOnMain) }
    report.numbers["surfaceEvents"] = Double(events.0)
    report.numbers["propertiesEvents"] = Double(events.2)
    report.check("callbacksOffMain", events.3 == 0, "\(events.3) screen callbacks ran on the main thread")
    let diagnostics = LiveSimulatorBridge.diagnostics
    let registers = diagnostics.screenRegistrations, unregisters = diagnostics.screenUnregistrations
    report.check("registerBalance", registers == unregisters && registers > 0, "\(registers) registrations, \(unregisters) unregistrations")
    report.check("noExceptions", diagnostics.exceptions == 0,
                 "\(diagnostics.exceptions) NSExceptions caught in \(diagnostics.guardedCalls) guarded private calls")
    // No check for the main-queue rule: a violation stops the process, so
    // reaching this line is the proof.
    report.numbers["bridgeEntryPoints"] = Double(diagnostics.entryPoints)
    report.numbers["guardedCalls"] = Double(diagnostics.guardedCalls)
    log("\(diagnostics.entryPoints) bridge entry points, each asserted off the main queue")
    let simulatorKit = diagnostics.simulatorKitLoaded
    report.facts["simulatorKitLoaded"] = simulatorKit ? "yes" : "no"
    report.check("simulatorKitNotNeeded", !simulatorKit, "SimulatorKit mapped into the process: \(simulatorKit ? "yes" : "no")")
}

// MARK: - main

let options = parseOptions()
let report = Report()
let session = DispatchQueue(label: "com.devicehubpro.simbridge-smoke.session", qos: .userInitiated)
session.async {
    do {
        try smoke(options, report: report)
    } catch {
        report.check("noErrors", false, "\(error)")
    }
    struct Result: Encodable {
        let passed: Bool
        let checks: [Check]
        let numbers: [String: Double]
        let facts: [String: String]
    }
    let passed = !report.checks.isEmpty && report.checks.allSatisfy(\.passed)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = (try? encoder.encode(Result(passed: passed, checks: report.checks, numbers: report.numbers, facts: report.facts)))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    print("SMOKE-RESULT \(json)")
    exit(passed ? 0 : 1)
}
dispatchMain()
