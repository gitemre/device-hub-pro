import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// The banner state of `XiaomiInputMonitor` with a fake property read and a
/// fake clock.
@MainActor
final class XiaomiInputMonitorTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000)
    private var answers: [String?] = []
    private var reads = 0
    private var serverSignalCleared = 0

    private func makeMonitor() -> XiaomiInputMonitor {
        let monitor = XiaomiInputMonitor()
        monitor.now = { [unowned self] in clock }
        monitor.readProbe = { [unowned self] _ in
            reads += 1
            return answers.isEmpty ? nil : answers.removeFirst()
        }
        monitor.clearServerSignal = { [unowned self] in serverSignalCleared += 1 }
        return monitor
    }

    private static let off = "V816\nOS1.0\n0\n"
    private static let on = "V816\nOS1.0\n1\n"

    func testBeginningASessionOnABlockedPhoneShowsTheBanner() async {
        answers = [Self.off]
        let monitor = makeMonitor()
        monitor.begin(serial: "SERIAL")
        await settle()
        XCTAssertTrue(monitor.isBlocked)
    }

    func testAPhoneWithTheSwitchOnShowsNothing() async {
        answers = [Self.on]
        let monitor = makeMonitor()
        monitor.begin(serial: "SERIAL")
        await settle()
        XCTAssertFalse(monitor.isBlocked)
    }

    func testTheServerSignalBlocksAndASuccessfulRecheckClears() async {
        answers = [Self.on, Self.on]
        let monitor = makeMonitor()
        monitor.begin(serial: "SERIAL")
        await settle()
        let clearedAtBegin = serverSignalCleared
        monitor.observe(injectionDenied: true)
        XCTAssertTrue(monitor.isBlocked)
        clock.addTimeInterval(4)
        monitor.noteClick()
        await settle()
        XCTAssertFalse(monitor.isBlocked)
        XCTAssertEqual(serverSignalCleared, clearedAtBegin + 1, "the remembered refusal is forgotten")
    }

    func testClicksRecheckAtMostOnceEveryThreeSeconds() async {
        answers = [Self.off, Self.off, Self.off, Self.on]
        let monitor = makeMonitor()
        monitor.begin(serial: "SERIAL")
        await settle()
        XCTAssertEqual(reads, 1)

        clock.addTimeInterval(1)
        monitor.noteClick()
        monitor.noteClick()
        await settle()
        XCTAssertEqual(reads, 1, "inside the interval: no read")
        XCTAssertTrue(monitor.isBlocked)

        clock.addTimeInterval(2.5)
        monitor.noteClick()
        await settle()
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(monitor.isBlocked, "still off")

        clock.addTimeInterval(3)
        monitor.noteClick()
        await settle()
        XCTAssertEqual(reads, 3)
        XCTAssertTrue(monitor.isBlocked)

        clock.addTimeInterval(3)
        monitor.noteClick()
        await settle()
        XCTAssertEqual(reads, 4)
        XCTAssertFalse(monitor.isBlocked, "turned on: the banner clears")
    }

    func testClicksNeverReadWhileNotBlocked() async {
        answers = [Self.on]
        let monitor = makeMonitor()
        monitor.begin(serial: "SERIAL")
        await settle()
        clock.addTimeInterval(10)
        monitor.noteClick()
        await settle()
        XCTAssertEqual(reads, 1)
    }

    func testCheckAgainReadsAtOnceAndAFailedReadKeepsTheState() async {
        answers = [Self.off, nil, Self.on]
        let monitor = makeMonitor()
        monitor.begin(serial: "SERIAL")
        await settle()
        monitor.checkAgain()
        await settle()
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(monitor.isBlocked, "a failed read changes nothing")
        monitor.checkAgain()
        await settle()
        XCTAssertFalse(monitor.isBlocked)
    }

    func testResetClearsTheBanner() async {
        answers = [Self.off]
        let monitor = makeMonitor()
        monitor.begin(serial: "SERIAL")
        await settle()
        monitor.reset()
        XCTAssertFalse(monitor.isBlocked)
        monitor.observe(injectionDenied: true)
        XCTAssertFalse(monitor.isBlocked, "no session, no banner")
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}
