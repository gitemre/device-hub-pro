import Darwin
import Foundation
import XCTest
@testable import DeviceHubProKit

/// Memory soak of the simulator mirror session against a real simulator,
/// behind `DHP_IOS_LIVE=1` and `DHP_SOAK=1`:
///
///     DHP_IOS_LIVE=1 DHP_SOAK=1 DHP_SOAK_SECONDS=240 \
///         swift test --filter SimulatorSoakLiveTests
///
/// It creates its own iPhone in a private device set (`LiveTestSimulators`:
/// never one of the machine's simulators) and deletes it with its set and log
/// folder afterwards. With Settings open it alternates dragging (the
/// screen changes at up to 60 fps) with 15 s of idle home-screen clock, for
/// `DHP_SOAK_SECONDS` (default and maximum 30), printing a `SOAK-SIM` line with
/// this process's footprint, the session's counters and the `vmmap --summary`
/// IOSurface row every `DHP_SOAK_SAMPLE` seconds (default 10). Then it
/// starts and stops the session 20 times and checks the bridge registered and
/// unregistered the same number of screens and the footprint came back.
final class SimulatorSoakLiveTests: XCTestCase {
    static let growthAllowanceMB = 120.0

    private var seconds: Double {
        min(Double(ProcessInfo.processInfo.environment["DHP_SOAK_SECONDS"] ?? "") ?? 30, 30)
    }

    private var sampleEvery: Double {
        Double(ProcessInfo.processInfo.environment["DHP_SOAK_SAMPLE"] ?? "") ?? 10
    }

    func testTheSimulatorMirrorDoesNotGrow() async throws {
        guard ProcessInfo.processInfo.environment["DHP_SOAK"] == "1" else {
            throw XCTSkip("memory soak runs only with DHP_SOAK=1")
        }
        if let free = MemoryFootprint.systemFreePercent(), free < 30 {
            throw XCTSkip("memory soak needs 30% of the Mac's memory free (now \(free)%)")
        }
        let toolchain = try await LiveTestSimulators.toolchain()
        let installed = BridgeCompatibility.installedCoreSimulatorVersion()
        guard BridgeCompatibility.verdict(coreSimulatorVersion: installed).allowsBridge else {
            throw XCTSkip("the bridge is off on CoreSimulator \(installed ?? "?")")
        }
        let simulators = try LiveTestSimulators.Session(toolchain: toolchain)
        do {
            try await soak(simulators)
        } catch {
            let leftovers = await simulators.tearDown()
            XCTAssertEqual(leftovers, [])
            throw error
        }
        let leftovers = await simulators.tearDown()
        XCTAssertEqual(leftovers, [])
    }

    private func soak(_ simulators: LiveTestSimulators.Session) async throws {
        let device = try await simulators.createDevice(name: "DeviceHubPro-MemorySoak")
        let udid = device.udid
        let simctl = simulators.simctl
        print("SOAK-SIM created \(udid)")
        try await simctl.bootStatus(udid: udid, bootIfNeeded: true)
        try await Task.sleep(for: .seconds(12))

        let bridge = LiveSimulatorBridge()
        let session = SimulatorMirrorSession(udid: udid, deviceSet: simulators.setDirectory, bridge: bridge, simctl: simctl)
        defer { session.stopAndWait() }
        // The renderer's side: it keeps the newest frame in hand.
        let held = HeldFrame()
        let observation = session.frames.observe { [weak session] in
            held.set(session?.frames.current)
        }
        defer { withExtendedLifetime(observation) {} }

        session.start()
        let first = await waitUntil(8) { session.frames.current != nil }
        XCTAssertTrue(first, "a first frame: \(session.lastError ?? "")")
        _ = try await simctl.launch(udid: udid, bundleIdentifier: "com.apple.Preferences")
        try await Task.sleep(for: .seconds(2))

        let start = Date()
        print("SOAK-SIM start footprint \(Self.footprint()) \(SoakVMMap.rows())")
        var next = 0.0
        var samples: [(t: Double, mb: Double)] = []
        let dragger = Task {
            var gesture = 0
            while !Task.isCancelled {
                let phase = Date().timeIntervalSince(start).truncatingRemainder(dividingBy: 45)
                if phase < 30 {
                    let (from, to) = gesture.isMultiple(of: 2) ? (1900.0, 800.0) : (800.0, 1900.0)
                    await Self.drag(session, x: 603, fromY: from, toY: to, steps: 24)
                    gesture += 1
                } else {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
        defer { dragger.cancel() }
        while Date().timeIntervalSince(start) < seconds {
            let elapsed = Date().timeIntervalSince(start)
            if let reason = MemoryFootprint.soakAbortReason() {
                XCTFail(reason)
                return
            }
            if elapsed >= next {
                let statistics = session.surfaceStatistics()
                let mb = Double(MemoryFootprint.current() ?? 0) / 1_048_576
                samples.append((elapsed, mb))
                print(String(format: "SOAK-SIM t=%3.0fs footprint %.1f MB published %d callbacks %d coalesced %d torn %d fps %.0f",
                             elapsed, mb, statistics.publishedFrames, statistics.frameCallbacks, statistics.coalescedCallbacks,
                             statistics.tornFrames, statistics.publishFPS))
                next += sampleEvery
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        dragger.cancel()
        let last = Double(MemoryFootprint.current() ?? 0) / 1_048_576
        print("SOAK-SIM end footprint \(String(format: "%.1f", last)) MB \(SoakVMMap.rows())")
        let reference = samples.first { $0.t >= seconds * 0.4 }?.mb ?? last
        XCTAssertLessThanOrEqual(last - reference, Self.growthAllowanceMB, "the mirror kept growing")
        XCTAssertNil(session.lastError)

        // Deselect and select again, as a user clicking between devices.
        let before = Double(MemoryFootprint.current() ?? 0) / 1_048_576
        let registeredBefore = LiveSimulatorBridge.diagnostics.screenRegistrations
        let unregisteredBefore = LiveSimulatorBridge.diagnostics.screenUnregistrations
        for _ in 0..<5 {
            session.start()
            let arrived = await waitUntil(5) { session.frames.current != nil }
            XCTAssertTrue(arrived)
            session.stopAndWait()
        }
        let after = Double(MemoryFootprint.current() ?? 0) / 1_048_576
        let diagnostics = LiveSimulatorBridge.diagnostics
        print(String(format: "SOAK-SIM 5 restarts footprint %.1f -> %.1f MB, screens registered %d unregistered %d",
                     before, after, diagnostics.screenRegistrations - registeredBefore, diagnostics.screenUnregistrations - unregisteredBefore))
        XCTAssertEqual(diagnostics.screenRegistrations - registeredBefore, diagnostics.screenUnregistrations - unregisteredBefore,
                       "every registered screen is unregistered")
        XCTAssertLessThanOrEqual(after - before, 80, "restarting the session leaks")
    }

    private static func footprint() -> String {
        MemoryFootprint.current().map(MemoryFootprint.megabytes) ?? "?"
    }

    private static func drag(_ session: SimulatorMirrorSession, x: Double, fromY: Double, toY: Double, steps: Int) async {
        session.send(TouchCommand(phase: .down, x: Int32(x), y: Int32(fromY), id: 1))
        for step in 1...steps {
            let y = fromY + (toY - fromY) * Double(step) / Double(steps)
            try? await Task.sleep(for: .milliseconds(16))
            session.send(TouchCommand(phase: .move, x: Int32(x), y: Int32(y), id: 1))
        }
        session.send(TouchCommand(phase: .up, x: Int32(x), y: Int32(toY), id: 1))
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private final class HeldFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: Frame?
    func set(_ frame: Frame?) { lock.withLock { self.frame = frame } }
}

/// `vmmap --summary` rows for this process.
enum SoakVMMap {
    static func rows() -> String {
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
        let wanted = ["IOSurface", "CoreAnimation", "MALLOC_LARGE", "VM_ALLOCATE", "Physical footprint:"]
        return text.split(separator: "\n")
            .filter { line in wanted.contains { line.hasPrefix($0) } }
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).prefix(5).joined(separator: " ") }
            .joined(separator: " | ")
    }
}
