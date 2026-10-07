import XCTest
@testable import DeviceHubProKit

/// Speed and latency shaping with tc in the guest: the netem arguments,
/// the readings, and the exact adb argv of apply, clear, root and unroot.
/// Fixtures under `Fixtures/api35-emulator/shaping` are real captures from
/// a scratch API 35 google_apis emulator (emulator 36.6.11, userdebug).
final class NetworkShapingTests: XCTestCase {
    private let serial = "emulator-5584"

    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/api35-emulator/shaping", isDirectory: true)

    private static func text(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    private var probeCall: String { "-s \(serial) shell \(ShapingReading.probeScript)" }

    // MARK: - Profiles

    func testTheProbeScriptIsTheOneCaptured() throws {
        XCTAssertEqual(try Self.text("probe.command.txt"), ShapingReading.probeScript)
    }

    /// A 35-200 ms round trip is 58.75 ms +- 41.25 ms in each direction, the
    /// arguments the capture applied; 200 ms flat is 100 ms each way.
    func testLatencyIsSplitBetweenTheDirections() {
        let profile = ShapingProfile(latency: LatencyPreset.gprs.latency)
        XCTAssertEqual(profile.netemArguments(.upload), ["netem", "limit", "10000", "delay", "58750us", "41250us"])
        XCTAssertEqual(profile.netemArguments(.download), profile.netemArguments(.upload))
        let fixed = ShapingProfile(latency: ConnectionLatency(minimumMs: 200, maximumMs: 200))
        XCTAssertEqual(fixed.netemArguments(.upload), ["netem", "limit", "10000", "delay", "100000us"])
    }

    func testSpeedSetsTheRatePerDirectionAndASaneQueue() {
        let gprs = ShapingProfile(speed: .gprs)
        XCTAssertEqual(gprs.netemArguments(.upload), ["netem", "limit", "5", "rate", "28800bit"])
        XCTAssertEqual(gprs.netemArguments(.download), ["netem", "limit", "5", "rate", "57600bit"])
        // The queue also holds what the delay line carries.
        let lte = ShapingProfile(speed: .lte, latency: ConnectionLatency(minimumMs: 100, maximumMs: 100))
        XCTAssertEqual(lte.netemArguments(.download), ["netem", "limit", "15138", "delay", "50000us", "rate", "173000000bit"])
        let loss = ShapingProfile(lossPercent: 2.5)
        XCTAssertEqual(loss.netemArguments(.upload), ["netem", "limit", "10000", "loss", "2.5%"])
    }

    func testANeutralProfileNeedsNoQdisc() {
        XCTAssertTrue(ShapingProfile.neutral.isNeutral)
        XCTAssertNil(ShapingProfile.neutral.netemArguments(.upload))
        XCTAssertNil(ShapingProfile.neutral.netemArguments(.download))
        // 0:500 and 500:200 delay nothing.
        XCTAssertTrue(ShapingProfile(latency: ConnectionLatency(minimumMs: 500, maximumMs: 200)).isNeutral)
        XCTAssertFalse(ShapingProfile(speed: .gsm).isNeutral)
    }

    /// SOURCE-DERIVED: external/qemu android/emu/cmdline/include/android/network/constants.h
    /// (ANDROID_NETWORK_LIST_MODES, emu-master-dev), kbit/s.
    func testSpeedPresetsAreTheEmulatorsOwn() {
        let rows: [(NetworkSpeed, Double, Double)] = [
            (.gsm, 14.4, 14.4), (.hscsd, 14.4, 57.6), (.gprs, 28.8, 57.6), (.umts, 384, 384),
            (.edge, 473.6, 473.6), (.hsdpa, 5760, 13980), (.lte, 58000, 173000), (.evdo, 75000, 280000),
        ]
        for (speed, up, down) in rows {
            XCTAssertEqual(speed.uploadKbit, up, "\(speed)")
            XCTAssertEqual(speed.downloadKbit, down, "\(speed)")
        }
        XCTAssertNil(NetworkSpeed.full.downloadKbit)
        XCTAssertEqual(NetworkSpeed.gprs.label, "GPRS · 57.6 kbit/s down, 28.8 kbit/s up")
        XCTAssertEqual(NetworkSpeed.umts.label, "UMTS · 384 kbit/s")
        XCTAssertEqual(NetworkSpeed.hsdpa.label, "HSDPA · 13.98 Mbit/s down, 5.76 Mbit/s up")
        XCTAssertEqual(NetworkSpeed.matching(download: 57600, upload: 28800), .gprs)
        XCTAssertEqual(NetworkSpeed.matching(download: nil, upload: nil), .full)
        XCTAssertNil(NetworkSpeed.matching(download: 1_000_000, upload: 1_000_000))
    }

    // MARK: - Readings

    func testAnUnrootedPlainDevice() throws {
        let reading = ShapingReading.parse(try Self.text("probe-unrooted-plain.txt"))
        XCTAssertEqual(reading.debuggable, true)
        XCTAssertFalse(reading.isRoot)
        XCTAssertEqual(reading.routeInterface, "wlan0")
        XCTAssertFalse(reading.isShaping)
        XCTAssertEqual(reading.speed, .full)
        XCTAssertEqual(reading.latency, .off)
    }

    func testBothDirectionsAreReadBack() throws {
        let reading = ShapingReading.parse(try Self.text("probe-rooted-shaped.txt"))
        XCTAssertTrue(reading.isRoot)
        XCTAssertEqual(reading.routeInterface, "wlan0")
        XCTAssertEqual(reading.shapedInterface, "wlan0")
        XCTAssertEqual(reading.netem.map(\.device), ["ifb0", "wlan0"])
        XCTAssertEqual(reading.netem.first?.rateBitsPerSecond, 1_000_000)
        // tc prints tenths (58.7, 41.2): the ends round back to 35 and 200.
        XCTAssertEqual(reading.latency, LatencyPreset.gprs.latency)
        XCTAssertNil(reading.speed, "1 Mbit is no emulator preset")
        XCTAssertTrue(reading.isPlaced(for: ShapingProfile(latency: LatencyPreset.gprs.latency)))
    }

    func testAReadingMatchesWhatWasAskedFor() throws {
        let latency = ShapingReading.parse(try Self.text("probe-rooted-shaped-latency-gprs.txt"))
        XCTAssertEqual(latency.speed, .full)
        XCTAssertTrue(latency.matches(ShapingProfile(latency: LatencyPreset.gprs.latency)))
        XCTAssertFalse(latency.matches(ShapingProfile(latency: LatencyPreset.gsm.latency)))
        XCTAssertFalse(latency.matches(ShapingProfile(speed: .gprs, latency: LatencyPreset.gprs.latency)))

        let speed = ShapingReading.parse(try Self.text("probe-rooted-shaped-speed-gprs.txt"))
        XCTAssertEqual(speed.speed, .gprs)
        XCTAssertEqual(speed.latency, .off)
        XCTAssertTrue(speed.matches(ShapingProfile(speed: .gprs)))
        XCTAssertFalse(speed.matches(ShapingProfile(speed: .edge)))
    }

    func testTheShapingIsMisplacedWhenTheRouteMoved() throws {
        var reading = ShapingReading.parse(try Self.text("probe-rooted-shaped.txt"))
        let profile = ShapingProfile(latency: LatencyPreset.gprs.latency)
        reading.routeInterface = "eth0"
        XCTAssertFalse(reading.isPlaced(for: profile))
        reading.routeInterface = nil
        XCTAssertFalse(reading.isPlaced(for: profile))
    }

    func testLossAndTinyRatesParse() throws {
        let lines = try Self.text("qdisc-show-loss.txt").components(separatedBy: .newlines)
        let netem = lines.compactMap(NetemQdisc.parse(line:))
        XCTAssertEqual(netem, [NetemQdisc(device: "wlan0", delayMs: 150, jitterMs: 0, lossPercent: 2.5, rateBitsPerSecond: 14400)])
        XCTAssertEqual(NetemQdisc.bitsPerSecond("173Mbit"), 173_000_000)
        XCTAssertEqual(NetemQdisc.bitsPerSecond("57.6Kbit"), 57_600)
        XCTAssertEqual(NetemQdisc.milliseconds("150us"), 0.15)
    }

    /// SOURCE-DERIVED variant of the capture: a data path on another
    /// interface changes only the `dev` word of `ip route get`.
    func testTheRouteInterfaceFollowsTheDefaultRoute() throws {
        let moved = try Self.text("probe-unrooted-plain.txt").replacingOccurrences(of: "dev wlan0 table", with: "dev eth0 table")
        XCTAssertEqual(ShapingReading.parse(moved).routeInterface, "eth0")
        let noRoute = "@@devicehubpro:shape:route\nRTNETLINK answers: Network is unreachable\n@@devicehubpro:shape:qdisc\n"
        XCTAssertNil(ShapingReading.parse(noRoute).routeInterface)
    }

    func testANonDebuggableBuildReadsAsNotRootable() {
        let reading = ShapingReading.parse("@@devicehubpro:shape:debuggable\n0\n@@devicehubpro:shape:uid\n2000\n")
        XCTAssertEqual(reading.debuggable, false)
        XCTAssertEqual(ShapingReading.parse("").debuggable, nil)
    }

    func testOnlyEmulatorsAreShaped() {
        XCTAssertTrue(NetworkShaper.isSupportedSerial("emulator-5554"))
        XCTAssertFalse(NetworkShaper.isSupportedSerial("R5CT1234567"))
        XCTAssertFalse(NetworkShaper.isSupportedSerial("192.168.1.20:5555"))
    }

    // MARK: - Apply and clear

    private func shaper(_ adb: FakeAdb) -> NetworkShaper {
        NetworkShaper(adb: adb.client, sleep: { _ in })
    }

    func testApplyShapesBothDirections() async throws {
        let adb = try FakeAdb([.init("@@devicehubpro:shape:", output: try Self.text("probe-rooted-plain.txt"))])
        let profile = ShapingProfile(speed: .gprs, latency: LatencyPreset.gprs.latency)
        _ = try await shaper(adb).apply(profile, serial: serial)
        let shell = "-s \(serial) shell"
        let egress = "netem limit 5 delay 58750us 41250us rate 28800bit"
        let ingress = "netem limit 6 delay 58750us 41250us rate 57600bit"
        XCTAssertEqual(adb.calls, [
            probeCall,
            "\(shell) tc qdisc replace dev wlan0 root \(egress)",
            "\(shell) ip link set ifb0 up",
            "\(shell) tc filter del dev wlan0 ingress pref 49000",
            "\(shell) tc filter add dev wlan0 ingress protocol all pref 49000 u32 match u32 0 0 action mirred egress redirect dev ifb0",
            "\(shell) tc qdisc replace dev ifb0 root \(ingress)",
            probeCall,
        ])
    }

    /// Shaping left on an interface the route no longer uses is removed.
    func testApplyMovesShapingToTheRouteInterface() async throws {
        let onEth = try Self.text("probe-rooted-shaped.txt")
            .replacingOccurrences(of: "dev wlan0 root refcnt 2 limit", with: "dev eth0 root refcnt 2 limit")
        let adb = try FakeAdb([.init("@@devicehubpro:shape:", output: onEth)])
        _ = try await shaper(adb).apply(ShapingProfile(latency: LatencyPreset.gprs.latency), serial: serial)
        let shell = "-s \(serial) shell"
        XCTAssertEqual(Array(adb.calls[1...2]), [
            "\(shell) tc qdisc del dev eth0 root",
            "\(shell) tc filter del dev eth0 ingress pref 49000",
        ])
        XCTAssertTrue(adb.calls.contains("\(shell) tc qdisc replace dev wlan0 root netem limit 10000 delay 58750us 41250us"))
    }

    func testClearRemovesEverythingAndIsIdempotent() async throws {
        let shaped = try FakeAdb([
            .init("tc qdisc del", stderr: try Self.text("tc-del-missing.stderr.txt"), exitCode: 2),
            .init("@@devicehubpro:shape:", output: try Self.text("probe-rooted-shaped.txt")),
        ])
        try await shaper(shaped).clear(serial: serial)
        let shell = "-s \(serial) shell"
        XCTAssertEqual(shaped.calls, [
            probeCall,
            "\(shell) tc qdisc del dev wlan0 root",
            "\(shell) tc filter del dev wlan0 ingress pref 49000",
            "\(shell) tc qdisc del dev ifb0 root",
            "\(shell) ip link set ifb0 down",
        ], "a delete that finds nothing is not an error")

        let clean = try FakeAdb([.init("@@devicehubpro:shape:", output: try Self.text("probe-rooted-cleared.txt"))])
        try await shaper(clean).clear(serial: serial)
        XCTAssertEqual(clean.calls, [
            probeCall,
            "\(shell) tc filter del dev wlan0 ingress pref 49000",
            "\(shell) ip link set ifb0 down",
        ])
    }

    func testANeutralProfileClears() async throws {
        let adb = try FakeAdb([.init("@@devicehubpro:shape:", output: try Self.text("probe-rooted-shaped.txt"))])
        _ = try await shaper(adb).apply(.neutral, serial: serial)
        XCTAssertTrue(adb.calls.contains("-s \(serial) shell tc qdisc del dev wlan0 root"))
        XCTAssertFalse(adb.calls.contains { $0.contains("qdisc replace") })
    }

    func testApplyWithoutARouteFails() async throws {
        let noRoute = "@@devicehubpro:shape:debuggable\n1\n@@devicehubpro:shape:uid\n0\n@@devicehubpro:shape:route\nRTNETLINK answers: Network is unreachable\n@@devicehubpro:shape:qdisc\n"
        let adb = try FakeAdb([.init("@@devicehubpro:shape:", output: noRoute)])
        do {
            _ = try await shaper(adb).apply(ShapingProfile(speed: .gsm), serial: serial)
            XCTFail("no route")
        } catch let error as ShapingError {
            XCTAssertEqual(error, .noRoute)
        }
    }

    func testAFailingTcCommandIsReported() async throws {
        let adb = try FakeAdb([
            .init("qdisc replace", stderr: "RTNETLINK answers: Invalid argument\n", exitCode: 2),
            .init("@@devicehubpro:shape:", output: try Self.text("probe-rooted-plain.txt")),
        ])
        do {
            _ = try await shaper(adb).apply(ShapingProfile(speed: .gsm), serial: serial)
            XCTFail("tc failed")
        } catch ShapingError.commandFailed(let detail) {
            XCTAssertTrue(detail.contains("Invalid argument"), detail)
        }
    }

    // MARK: - Root

    /// A stateful adb: `root` makes `id -u` answer 0, `unroot` undoes it.
    private func statefulAdb(rootRefused: Bool = false, startsRoot: Bool = false, reverseList: String = "") throws -> (AdbClient, () -> [String]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShapingAdb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("calls.log")
        let state = directory.appendingPathComponent("root")
        if startsRoot { try Data("1".utf8).write(to: state) }
        let rootBranch = rootRefused
            ? "echo 'adbd cannot run as root in production builds' >&2; exit 1"
            : "echo 'restarting adbd as root'; echo 1 > '\(state.path)'"
        let script = """
        #!/bin/sh
        echo "$*" >> '\(log.path)'
        case "$*" in
        *"reverse --list") printf '%s' '\(reverseList)' ;;
        *" unroot") echo 'restarting adbd as non root'; rm -f '\(state.path)' ;;
        *" root") \(rootBranch) ;;
        *"id -u") if [ -f '\(state.path)' ]; then echo 0; else echo 2000; fi ;;
        esac
        exit 0
        """
        let executable = directory.appendingPathComponent("adb")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let calls: () -> [String] = {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        return (AdbClient(adbURL: executable), calls)
    }

    func testRootingRestartsAdbdOnceAndWaitsForIt() async throws {
        let (client, calls) = try statefulAdb()
        let shaper = NetworkShaper(adb: client, rootWait: 3, sleep: { _ in })
        let first = try await shaper.ensureRoot(serial: serial)
        XCTAssertEqual(first, .restartedAsRoot)
        XCTAssertEqual(calls(), [
            "-s \(serial) shell id -u",
            "-s \(serial) reverse --list",
            "-s \(serial) root",
            "-s \(serial) wait-for-device",
            "-s \(serial) shell id -u",
        ])
        let second = try await shaper.ensureRoot(serial: serial)
        XCTAssertEqual(second, .alreadyRoot, "an adbd that is root is not restarted")
        XCTAssertEqual(calls().count, 6)
    }

    /// The adbd restart drops `adb reverse` rules: they are read before
    /// the restart and added again after it, for root and for unroot.
    /// (SOURCE-DERIVED list format: one `<serial> <remote> <local>` line per rule.)
    func testReverseRulesSurviveTheAdbdRestart() async throws {
        let list = "(reverse) tcp:8081 tcp:8081\n(reverse) tcp:9000 tcp:9001\n"
        let (client, calls) = try statefulAdb(reverseList: list)
        let shaper = NetworkShaper(adb: client, rootWait: 3, sleep: { _ in })
        _ = try await shaper.ensureRoot(serial: serial)
        XCTAssertEqual(Array(calls().suffix(2)), [
            "-s \(serial) reverse tcp:8081 tcp:8081",
            "-s \(serial) reverse tcp:9000 tcp:9001",
        ])
        try await shaper.dropRoot(serial: serial)
        XCTAssertEqual(Array(calls().suffix(2)), [
            "-s \(serial) reverse tcp:8081 tcp:8081",
            "-s \(serial) reverse tcp:9000 tcp:9001",
        ])
    }

    func testAnAdbdThatWasRootIsReportedAsSuch() async throws {
        let (client, calls) = try statefulAdb(startsRoot: true)
        let outcome = try await NetworkShaper(adb: client, rootWait: 3, sleep: { _ in }).ensureRoot(serial: serial)
        XCTAssertEqual(outcome, .alreadyRoot)
        XCTAssertEqual(calls(), ["-s \(serial) shell id -u"])
    }

    func testUnrootRestartsAdbdAndWaits() async throws {
        let (client, calls) = try statefulAdb(startsRoot: true)
        let shaper = NetworkShaper(adb: client, rootWait: 3, sleep: { _ in })
        try await shaper.dropRoot(serial: serial)
        XCTAssertEqual(calls(), [
            "-s \(serial) shell id -u",
            "-s \(serial) reverse --list",
            "-s \(serial) unroot",
            "-s \(serial) wait-for-device",
            "-s \(serial) shell id -u",
        ])
        try await shaper.dropRoot(serial: serial)
        XCTAssertEqual(calls().count, 6, "unrooting a shell adbd does nothing")
    }

    /// SOURCE-DERIVED: adb's `adb root` on a user build answers
    /// "adbd cannot run as root in production builds" and exits 1
    /// (packages/modules/adb client commandline).
    func testARefusedRootIsNotRootable() async throws {
        let (client, _) = try statefulAdb(rootRefused: true)
        do {
            _ = try await NetworkShaper(adb: client, rootWait: 3, sleep: { _ in }).ensureRoot(serial: serial)
            XCTFail("root was refused")
        } catch ShapingError.notRootable(let detail) {
            XCTAssertTrue(detail.contains("production builds"), detail)
        }
    }

    /// The real captures of `adb root` on the scratch emulator.
    func testRootAnswersAreTheCapturedOnes() throws {
        XCTAssertEqual(try Self.text("adb-root-success.stdout.txt"), "restarting adbd as root\n")
        XCTAssertEqual(try Self.text("adb-root-already.stdout.txt"), "adbd is already running as root\n")
    }
}
