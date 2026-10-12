import XCTest
@testable import DeviceHubProKit

/// What a user can see of themselves in a report, through the whole pipeline (collect, scrub, cut, render and
/// the issue link), for what the inventory cannot name when the report is made: a phone that was unplugged
/// since an error named it, a key line too long to keep whole, a name that is also a word of the schema.
///
/// The serials here are made up (no serial of a real phone is committed); the error text around them is
/// SOURCE-DERIVED: `AdbError.commandFailed` ("adb <arguments> failed (<status>): <message>", AdbClient.swift)
/// around the message adb prints for an unknown serial (`device '<serial>' not found`, `acquire_one_transport`
/// in the AOSP adb sources). The adb public key is the one of `api37-emulator/adb-core/shell-getprop.txt`.
final class ProblemReportPrivacyTests: XCTestCase {
    private let unplugged = "R58M12345AB"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func prepare(
        _ world: HermeticReportWorld,
        appState: ProblemReportAppState? = nil,
        subject: ProblemReport.Subject? = nil,
        recent: [ProblemReport.RecentProblem] = [],
        identifiers: RecentProblemIdentifiers = RecentProblemIdentifiers(),
        inputs: ProblemReportInputs? = nil
    ) async throws -> PreparedProblemReport {
        await ProblemReportBuilder.prepare(
            inputs: try inputs ?? world.inputs(producer: appState == nil ? .cli : .app),
            appState: appState,
            subject: subject,
            recentProblems: recent,
            recentIdentifiers: identifiers,
            now: now,
            reportID: "abcd1234"
        )
    }

    /// Everything the user can send: the Markdown (which holds the JSON) and the issue link.
    private func everything(of prepared: PreparedProblemReport) -> String {
        prepared.markdown + "\n" + ProblemReportIssueLink.link(for: prepared).url.absoluteString.removingPercentEncoding.orEmpty
    }

    private func errorAbout(_ serial: String) -> String {
        "adb -s \(serial) reboot failed (1): adb: device '\(serial)' not found"
    }

    // MARK: A phone that is not connected

    func testAnUnpluggedPhonesSerialInTheSubjectAndRecentProblemsNeverReachesTheReport() async throws {
        let world = try HermeticReportWorld()
        let message = errorAbout(unplugged)
        let prepared = try await prepare(
            world,
            subject: ProblemReport.Subject(message: message, occurredAt: now),
            recent: [ProblemReport.RecentProblem(at: now, message: message, details: ["stderr: \(message)"])]
        )
        // The phone that is connected (0a1b2c3d4e5f) is phone-1; the one that is not gets the next alias.
        XCTAssertEqual(prepared.report.subject?.message, "adb -s phone-2 reboot failed (1): adb: device 'phone-2' not found")
        XCTAssertEqual(prepared.report.recentProblems.first?.details, ["stderr: adb -s phone-2 reboot failed (1): adb: device 'phone-2' not found"])
        let text = everything(of: prepared)
        XCTAssertFalse(text.lowercased().contains(unplugged.lowercased()), "the serial left the Mac")
        XCTAssertFalse(text.lowercased().contains("0a1b2c3d4e5f"))
        XCTAssertTrue(ProblemReportIssueLink.link(for: prepared).url.absoluteString.contains("phone-2"), "the issue title says which phone")
    }

    func testTheSameWithTheAppsSnapshotListingNoPhone() async throws {
        let world = try HermeticReportWorld()
        let state = ProblemReportAppState(devices: [AndroidDevice(serial: "emulator-5554", state: "device")], preferences: .sample)
        let message = errorAbout(unplugged)
        let prepared = try await prepare(
            world,
            appState: state,
            subject: ProblemReport.Subject(message: message, occurredAt: now),
            recent: [ProblemReport.RecentProblem(at: now, message: message)]
        )
        XCTAssertEqual(prepared.report.subject?.message, "adb -s phone-1 reboot failed (1): adb: device 'phone-1' not found")
        XCTAssertFalse(everything(of: prepared).lowercased().contains(unplugged.lowercased()))
    }

    /// An error that names a phone where adb does not put a serial ("on <serial>") is covered by the
    /// identifiers the problem log kept when it was recorded: the phone's group (its USB serial, its Wi-Fi
    /// serial and its hardware serial are one phone) and the name its owner gave an iPhone.
    func testIdentifiersKeptWithAnEarlierErrorScrubItWhereItStandsAlone() async throws {
        let world = try HermeticReportWorld()
        let recent = [
            ProblemReport.RecentProblem(at: now, message: "Could not open the link on \(unplugged): no activity found"),
            ProblemReport.RecentProblem(at: now, message: "Could not restart Emre\u{2019}s iPhone: the device is locked"),
            ProblemReport.RecentProblem(at: now, message: "Lost 192.168.1.5:5555 and then HWSERIAL0099"),
        ]
        let identifiers = RecentProblemIdentifiers(
            phones: [[unplugged, "192.168.1.5:5555", "HWSERIAL0099"]],
            secrets: ["Emre\u{2019}s iPhone"]
        )
        let prepared = try await prepare(world, recent: recent, identifiers: identifiers)
        XCTAssertEqual(prepared.report.recentProblems.map(\.message), [
            "Could not open the link on phone-2: no activity found",
            "Could not restart \u{2039}redacted\u{203A}: the device is locked",
            "Lost phone-2 and then phone-2",
        ])
        let text = everything(of: prepared)
        for leaked in [unplugged, "192.168.1.5", "HWSERIAL0099", "Emre\u{2019}s iPhone"] {
            XCTAssertFalse(text.contains(leaked), leaked)
        }
    }

    func testAnUnpluggedPhoneKeepsOneAliasEverywhereAndNoOneIsReused() async throws {
        let world = try HermeticReportWorld()
        let one = "R58M12345AB", two = "ZX1G22ABCD"
        let recent = [
            ProblemReport.RecentProblem(at: now, message: errorAbout(two)),
            ProblemReport.RecentProblem(at: now, message: errorAbout(one)),
            ProblemReport.RecentProblem(at: now, message: errorAbout(two)),
        ]
        let prepared = try await prepare(world, recent: recent, identifiers: RecentProblemIdentifiers(phones: [[one], [two]]))
        let aliases = prepared.report.recentProblems.compactMap { problem in
            problem.message.split(separator: " ").dropFirst(2).first.map(String.init)
        }
        XCTAssertEqual(aliases.count, 3)
        XCTAssertEqual(aliases[0], aliases[2])
        XCTAssertNotEqual(aliases[0], aliases[1])
        XCTAssertFalse(aliases.contains("phone-1"), "phone-1 is the phone that is connected")
    }

    // MARK: A key in a line too long to keep

    /// Two lines the emulator writes at boot, 760 characters each (`Sending adb public key [...]` and
    /// `androidboot.qemu.adb.pubkey=...`), made of the key of the `getprop` capture, and the same with a key whose
    /// front has a `/` and no `+`: a front piece of it, cut at 150 characters before the scrubber ran, was not
    /// taken for a key. The collector now keeps long lines whole and the builder cuts them after it scrubbed.
    func testTheAdbKeyInALongLogLineIsGoneBeforeTheLineIsCut() async throws {
        let world = try HermeticReportWorld()
        let getprop = try ProblemReportFixtures.text("api37-emulator/adb-core/shell-getprop.txt")
        let property = try XCTUnwrap(getprop.components(separatedBy: "\n").dropFirst(292).first)
        XCTAssertTrue(property.hasPrefix("[ro.boot.qemu.adb.pubkey]: ["))
        // `<key> testeruser@unknown`, as the emulator writes it.
        let real = String(property.dropFirst("[ro.boot.qemu.adb.pubkey]: [".count).dropLast())
        XCTAssertTrue(real.hasSuffix(" testeruser@unknown"))
        let shaped = String(repeating: "Qk/9xZtLmN", count: 70) + "=" + " testeruser@emres-mbp.lan"

        let lines = [
            "INFO         | Boot started",
            "INFO         | Sending adb public key [\(real)]",
            "INFO         | Sending adb public key [\(shaped)]",
            "INFO         |   androidboot.qemu.adb.pubkey=\(real)",
            "INFO         |   androidboot.qemu.adb.pubkey=\(shaped)",
            "INFO         | Boot completed in 12 s",
        ]
        XCTAssertTrue(lines[1].count > 700 && lines[2].count > 700)
        let folder = world.home.appendingPathComponent("Library/Logs/DeviceHubPro", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: folder.appendingPathComponent("devicehubpro-emulator-Pixel_Test.log"), atomically: true, encoding: .utf8
        )

        let prepared = try await prepare(world)
        let tail = try XCTUnwrap(prepared.report.emulatorLogs.first)
        XCTAssertEqual(tail.lines.count, lines.count)
        let run = try NSRegularExpression(pattern: "[A-Za-z0-9+/]{40,}")
        for line in tail.lines {
            XCTAssertNil(run.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), "a key is left: \(line.prefix(120))")
            XCTAssertLessThanOrEqual(line.count, 150 + 3 + 200, "long lines are cut after scrubbing")
        }
        XCTAssertEqual(tail.lines[1], "INFO         | Sending adb public key [<base64> <user>@unknown]")
        XCTAssertEqual(tail.lines[2], "INFO         | Sending adb public key [<base64> <user>@<host>]", "the host of another Mac goes too")
        XCTAssertEqual(tail.lines[5], "INFO         | Boot completed in 12 s")
        let text = everything(of: prepared)
        XCTAssertFalse(text.contains("QAAAAKN67w"))
        XCTAssertFalse(text.contains("Qk/9xZtLmN"))
        XCTAssertFalse(text.contains("emres-mbp"))
        XCTAssertGreaterThanOrEqual(prepared.report.collection.removed["token"] ?? 0, 4)
    }

    // MARK: A name that is also a word of the schema

    func testAUsersNameThatIsASchemaWordLeavesTheReportReadable() async throws {
        let world = try HermeticReportWorld()
        try Data(" \n".utf8).write(to: world.home.appendingPathComponent(".emulator_console_auth_token"))
        var inputs = try world.inputs()
        inputs.identity = ScrubIdentity(
            homePath: world.home.path, userName: "testeruser", fullName: "Steve Blank", hostNames: ["Present", "Missing"]
        )
        let prepared = try await prepare(world, inputs: inputs)
        XCTAssertEqual(prepared.report.android.consoleTokenFile.state, .blank)
        XCTAssertEqual(prepared.report.app.kind, .cli)
        XCTAssertFalse(prepared.report.collection.notes.contains { $0.contains("could not be scrubbed") }, "the report was not replaced by an empty one")
        // And the markdown still reads back to the same report.
        let read = try XCTUnwrap(try ProblemReportParser.reports(in: prepared.markdown).first?.get())
        XCTAssertEqual(read.android.consoleTokenFile.state, .blank)
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
