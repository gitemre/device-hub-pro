import XCTest
import DeviceHubProKit
@testable import DeviceHubProApp

/// Rotate for a physical Android phone: the pose cycle, the settings put
/// back, and the stage's wrapper for a display that keeps its rotation.
@MainActor
final class PhysicalPhoneRotationTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("DeviceHubProKitTests/Fixtures/physical-xiaomi", isDirectory: true)

    /// A phone with auto-rotate on and user rotation 0 whose display stays at
    /// rotation 0 (`mCurrentOrientation=0`, a phone with the MIUI
    /// launcher in front).
    private func makeFake() throws -> FakeAdbHandle {
        try FakeAdbHandle([
            .init("settings get system accelerometer_rotation",
                  stdoutFile: Self.fixtures.appendingPathComponent("settings-get-accelerometer_rotation.txt")),
            .init("settings get system user_rotation",
                  stdoutFile: Self.fixtures.appendingPathComponent("settings-get-user_rotation.txt")),
            .init("dumpsys display", output: "    mCurrentOrientation=0\n"),
        ])
    }

    private func controller(adb: AdbClient, serial: String) -> MirrorController {
        let context = ActiveDeviceContext()
        context.serial = serial
        let mirror = MirrorController(adbClient: adb, context: context, status: StatusCenter(), perfLog: nil)
        mirror.physicalRotationPoll = .zero
        return mirror
    }

    /// The `<setting> <value>` of every `settings put` (the restore).
    private func puts(_ calls: [String]) -> [String] {
        calls.filter { $0.contains("settings put") }
            .map { $0.split(separator: " ").suffix(2).joined(separator: " ") }
    }

    /// The pose each `cmd window user-rotation lock` pinned.
    private func locks(_ calls: [String]) -> [String] {
        calls.filter { $0.contains("cmd window user-rotation lock") }
            .map { String($0.split(separator: " ").last ?? "") }
    }

    /// The original settings survive a crash: a new session (a relaunched
    /// app) finds the record and puts the phone's own values back.
    func testARecordLeftByACrashIsRestoredOnTheNextSession() async throws {
        let defaults = UserDefaults.scratch()
        let store = AndroidRotationRecordStore(defaults: defaults)
        let fake = try makeFake()
        let first = controller(adb: fake.client, serial: "S1")
        first.rotationStore = store
        await first.rotatePhysicalPhone(.left, adb: fake.client, serial: "S1")
        XCTAssertNotNil(store.record(for: "S1"), "kept on disk once the first Rotate read it")

        // The app died here: a fresh controller, the same store.
        let relaunched = controller(adb: fake.client, serial: "S1")
        relaunched.rotationStore = store
        let before = fake.calls.count
        relaunched.restorePendingRotation(serial: "S1")
        await relaunched.takeRotationRestore()?.value
        XCTAssertFalse(puts(Array(fake.calls.dropFirst(before))).isEmpty, "the phone's own settings go back")
        try await waitUntil { store.record(for: "S1") == nil }
    }

    /// A put-back the phone refuses keeps the record on disk; a later session
    /// of that phone retries it and, once the phone takes it, removes it.
    func testAFailedRestoreKeepsTheRecordUntilALaterSessionPutsItBack() async throws {
        let store = AndroidRotationRecordStore(defaults: .scratch())
        let refusing = try FakeAdbHandle([
            .init("settings get system accelerometer_rotation",
                  stdoutFile: Self.fixtures.appendingPathComponent("settings-get-accelerometer_rotation.txt")),
            .init("settings get system user_rotation",
                  stdoutFile: Self.fixtures.appendingPathComponent("settings-get-user_rotation.txt")),
            .init("dumpsys display", output: "    mCurrentOrientation=0\n"),
            .init("settings put system", output: "", exitCode: 1),
        ])
        let first = controller(adb: refusing.client, serial: "S1")
        first.rotationStore = store
        await first.rotatePhysicalPhone(.left, adb: refusing.client, serial: "S1")
        let record = try XCTUnwrap(store.record(for: "S1"), "Rotate wrote the record")

        first.stopSession(cause: .userStop)
        await first.takeRotationRestore()?.value
        XCTAssertFalse(puts(refusing.calls).isEmpty, "the put-back was tried")
        XCTAssertEqual(store.record(for: "S1"), record, "a refused put-back keeps the record")

        // A new controller with the same store retries, and the phone takes it.
        let accepting = try makeFake()
        let second = controller(adb: accepting.client, serial: "S1")
        second.rotationStore = store
        second.restorePendingRotation(serial: "S1")
        await second.takeRotationRestore()?.value
        XCTAssertEqual(Array(puts(accepting.calls).suffix(2)), ["user_rotation 0", "accelerometer_rotation 1"])
        try await waitUntil { store.record(for: "S1") == nil }
    }

    func testAPressReadsTheSettingsOnceThenPinsEachPose() async throws {
        let fake = try makeFake()
        let mirror = controller(adb: fake.client, serial: "S1")
        await mirror.rotatePhysicalPhone(.left, adb: fake.client, serial: "S1")
        XCTAssertEqual(mirror.physicalPoseTurns, 1)
        while mirror.stagePose.isAnimating { try await Task.sleep(for: .milliseconds(20)) }
        await mirror.rotatePhysicalPhone(.left, adb: fake.client, serial: "S1")
        XCTAssertEqual(mirror.physicalPoseTurns, 2)
        let calls = fake.calls
        XCTAssertEqual(calls.filter { $0.contains("settings get system accelerometer_rotation") }.count, 1)
        XCTAssertEqual(locks(calls), ["1", "2"])
        XCTAssertTrue(calls.allSatisfy { $0.hasPrefix("-s S1 ") }, "every call names the serial")
    }

    /// The display stayed at 0, so the whole frame turns by the pose.
    func testADisplayThatKeepsItsRotationLeavesTheFrameTurnedByThePose() async throws {
        let fake = try makeFake()
        let mirror = controller(adb: fake.client, serial: "S1")
        for expected in [1, 2, 3, 0] {
            while mirror.stagePose.isAnimating { try await Task.sleep(for: .milliseconds(20)) }
            await mirror.rotatePhysicalPhone(.left, adb: fake.client, serial: "S1")
            XCTAssertEqual(mirror.physicalPoseTurns, expected)
            XCTAssertEqual(TextureRotation.normalized(mirror.stagePose.targetTurns), expected)
        }
    }

    func testRightTurnsGoTheOtherWay() async throws {
        let fake = try makeFake()
        let mirror = controller(adb: fake.client, serial: "S1")
        await mirror.rotatePhysicalPhone(.right, adb: fake.client, serial: "S1")
        XCTAssertEqual(mirror.physicalPoseTurns, 3)
        XCTAssertEqual(locks(fake.calls).last, "3")
    }

    func testResidualTurnsAreThePoseRelativeToTheDisplay() {
        XCTAssertEqual(MirrorController.residualTurns(pose: 1, display: 1), 0)
        XCTAssertEqual(MirrorController.residualTurns(pose: 2, display: 0), 2)
        XCTAssertEqual(MirrorController.residualTurns(pose: 0, display: 1), 3)
        XCTAssertEqual(MirrorController.residualTurns(pose: 3, display: 2), 1)
    }

    func testEndingTheSessionPutsTheOriginalSettingsBack() async throws {
        let fake = try makeFake()
        let mirror = controller(adb: fake.client, serial: "S1")
        await mirror.rotatePhysicalPhone(.left, adb: fake.client, serial: "S1")
        mirror.stopSession(cause: .userStop)
        await mirror.takeRotationRestore()?.value
        XCTAssertNil(mirror.physicalPoseTurns)
        XCTAssertEqual(Array(puts(fake.calls).suffix(2)), ["user_rotation 0", "accelerometer_rotation 1"])
        // Nothing left to put back at the next teardown.
        let before = fake.calls.count
        mirror.stopSession(cause: .userStop)
        XCTAssertNil(mirror.takeRotationRestore())
        XCTAssertEqual(fake.calls.count, before)
    }

    func testAMirrorThatNeverRotatedChangesNothingAtTheEnd() async throws {
        let fake = try makeFake()
        let mirror = controller(adb: fake.client, serial: "S1")
        mirror.stopSession(cause: .quit)
        XCTAssertNil(mirror.takeRotationRestore())
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testAWatchOrTVDoesNotRotate() async throws {
        let fake = try makeFake()
        let mirror = controller(adb: fake.client, serial: "S1")
        mirror.deviceFormFactor = { _ in .wear }
        await mirror.rotatePhysicalPhone(.left, adb: fake.client, serial: "S1")
        XCTAssertNil(mirror.physicalPoseTurns)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    /// A physical scrcpy frame carries rotation 0 whatever the display does, so
    /// a landscape frame's touch point maps to itself (the frame is already
    /// the display's own orientation).
    func testALandscapeScrcpyFrameMapsTouchesUnchanged() {
        let p = TouchMapping.nativePoint(x: 2000, y: 300, frameWidth: 2400, frameHeight: 1080, rotation: 0)
        XCTAssertEqual(p.x, 2000)
        XCTAssertEqual(p.y, 300)
    }
}

/// A fake `adb` for these app tests (the kit's `FakeAdb` lives in another test
/// target): a shell script that traces its argv and answers the first rule
/// whose text is in it.
final class FakeAdbHandle {
    let client: AdbClient
    private let traceURL: URL

    struct Rule {
        let match: String
        let stdoutFile: URL?
        let output: String
        let exitCode: Int
        init(_ match: String, stdoutFile: URL) { self.match = match; self.stdoutFile = stdoutFile; self.output = ""; self.exitCode = 0 }
        init(_ match: String, output: String, exitCode: Int = 0) {
            self.match = match; self.stdoutFile = nil; self.output = output; self.exitCode = exitCode
        }
    }

    init(_ rules: [Rule]) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeAdbHandle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        traceURL = dir.appendingPathComponent("trace.txt")
        var script = "#!/bin/sh\nargs=\"$*\"\necho \"$args\" >> '\(traceURL.path)'\n"
        for rule in rules {
            let body = rule.stdoutFile.map { "cat '\($0.path)'" } ?? "printf '%s' '\(rule.output)'"
            script += "case \"$args\" in *'\(rule.match)'*) \(body); exit \(rule.exitCode);; esac\n"
        }
        script += "exit 0\n"
        let exe = dir.appendingPathComponent("adb")
        try script.write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        client = AdbClient(adbURL: exe)
    }

    var calls: [String] {
        ((try? String(contentsOf: traceURL, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }
}

@MainActor
final class RotationRecordAliasTests: XCTestCase {
    /// A Rotate recorded under the USB serial is found again from the phone's
    /// other transports: its mDNS name (which carries the serialno) and an
    /// ip:port the inventory folds into the same row. Another phone's record
    /// never matches.
    func testARecordIsFoundFromTheSamePhonesOtherTransports() {
        let store = AndroidRotationRecordStore(defaults: .scratch())
        let saved = AndroidPhoneRotation.Saved(accelerometer: "1", user: "0")
        store.set(saved, for: "R58M12345AB")
        store.set(saved, for: "OTHERPHONE1")
        let mdns = "adb-R58M12345AB-yXk7tu._adb-tls-connect._tcp"

        XCTAssertEqual(store.keys(samePhoneAs: mdns, aliases: [:]), ["R58M12345AB"])
        XCTAssertEqual(store.keys(samePhoneAs: "192.168.1.42:40001", aliases: ["192.168.1.42:40001": mdns]), ["R58M12345AB"])
        XCTAssertEqual(store.keys(samePhoneAs: "192.168.1.42:40001", aliases: [:]), [], "an unknown ip:port matches nothing")
        XCTAssertEqual(store.keys(samePhoneAs: "R58M12345AB", aliases: [:]), ["R58M12345AB"])
    }
}
