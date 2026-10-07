import XCTest
@testable import DeviceHubProKit

/// `.apns` push payload drops and `.mobileconfig` profile drops: reading the payload's target app, the `simctl push`
/// argv, the profile's certificates, the routing and the overlay words.
///
/// The payloads are written by hand in the shape `simctl help push` documents
/// (an `aps` object, the `Simulator Target Bundle` key); the profile is a plist
/// of the shape Apple documents for the certificate payloads. No capture of
/// either file exists; the live check that `simctl push` takes the key ran on a
/// private simulator (see the parity audit, SIM-17).
final class SendFilesPushAndProfileTests: XCTestCase {
    private static let udid = "F5DE19D7-2EB5-4EFC-A3ED-E6C3D7E6935B"

    private func file(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/drops/\(name)") }

    // MARK: .apns

    func testThePayloadsTargetBundleIsRead() throws {
        let text = #"{"Simulator Target Bundle": "com.example.app", "aps": {"alert": "Hi"}}"#
        let parsed = try SimulatorPushFile.parse(Data(text.utf8), name: "a.apns")
        XCTAssertEqual(parsed.bundleIdentifier, "com.example.app")
    }

    func testAPayloadWithoutATargetHasNoBundle() throws {
        let parsed = try SimulatorPushFile.parse(Data(#"{"aps": {"badge": 1}}"#.utf8), name: "a.apns")
        XCTAssertNil(parsed.bundleIdentifier)
    }

    func testProblemsReadAsSentences() {
        func failure(_ text: String) -> String {
            do {
                _ = try SimulatorPushFile.parse(Data(text.utf8), name: "x.apns")
                return "no failure"
            } catch { return "\(error)" }
        }
        XCTAssertTrue(failure("{nope").hasPrefix("“x.apns” is not a push payload. The payload is not JSON"))
        XCTAssertEqual(failure("[1]"), "“x.apns” is not a push payload. The payload must be a JSON object ({…}).")
        XCTAssertEqual(failure(#"{"title": 1}"#), "“x.apns” is not a push payload. The payload needs an \"aps\" object, as Apple's push service expects.")
        XCTAssertEqual(failure(""), "“x.apns” is not a push payload. Write a JSON payload first.")
        XCTAssertTrue(failure(#"{"Simulator Target Bundle": "has space", "aps": {}}"#).contains("is not a bundle identifier"))
        XCTAssertTrue(failure(#"{"Simulator Target Bundle": 7, "aps": {}}"#).contains("names “7”"))
        let big = #"{"aps": {"alert": ""# + String(repeating: "a", count: 5000) + #""}}"#
        XCTAssertTrue(failure(big).contains("a push takes at most 4096"))
    }

    func testReadingAFileFromDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("push-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let good = folder.appendingPathComponent("good.apns")
        try Data(#"{"Simulator Target Bundle": "com.example.app", "aps": {}}"#.utf8).write(to: good)
        XCTAssertEqual(try SimulatorPushFile.read(good).bundleIdentifier, "com.example.app")
        XCTAssertThrowsError(try SimulatorPushFile.read(folder.appendingPathComponent("missing.apns"))) {
            XCTAssertTrue("\($0)".hasPrefix("“missing.apns” could not be read"), "\($0)")
        }
    }

    func testPushArgvNamesTheFile() async throws {
        let fake = try FakeTool(name: "simctl", rules: [])
        let client = SimctlClient(simctlURL: fake.executableURL)
        try await client.push(udid: Self.udid, bundleIdentifier: "com.example.app", file: file("a b.apns"))
        XCTAssertEqual(fake.invocations, [["push", Self.udid, "com.example.app", "/tmp/drops/a b.apns"]])
        do {
            try await client.push(udid: "booted", bundleIdentifier: "com.example.app", file: file("a.apns"))
            XCTFail("a selector must be refused")
        } catch {}
        do {
            try await client.push(udid: Self.udid, bundleIdentifier: "-x", file: file("a.apns"))
            XCTFail("an option must be refused")
        } catch {}
        XCTAssertEqual(fake.invocations.count, 1)
    }

    /// `push <udid> <file>` of a payload without the key and no bundle argument
    /// (captured 2026-10-04, Xcode 27.0 27A266a, iOS 27.0, private device set; exit 22).
    /// With the key present and no bundle argument simctl took the key (it got as
    /// far as the app's notification permission, exit 211, the same answer as the
    /// explicit-bundle call: `simctl-push-not-authorized.stderr.txt`).
    func testAPayloadWithoutAnAppAndNoBundleIsSimctlsInvalidArgument() throws {
        let failure = SimctlErrors.failure(
            arguments: ["push", Self.udid, "plain.apns"],
            exitCode: 22,
            standardError: try SimctlFixtureTests.text("controls", "simctl-push-no-bundle.stderr.txt")
        )
        XCTAssertEqual(failure.kind, .invalidArgument)
        XCTAssertEqual(failure.error, SimctlErrorReference(domain: "NSPOSIXErrorDomain", code: 22))
        XCTAssertEqual(failure.message, "BundleID was not provided as an argument and payload does not contain 'Simulator Target Bundle' key")
    }

    // MARK: routing

    func testApnsFilesRouteToPushesInOrder() {
        let plan = SimulatorSendRouting.plan([file("b.apns"), file("notes.txt"), file("a.APNS"), file("Corp.mobileconfig")])
        XCTAssertEqual(plan.pushes, [file("b.apns"), file("a.APNS")])
        XCTAssertEqual(plan.files, [file("notes.txt")])
        XCTAssertEqual(plan.existing, [file("Corp.mobileconfig")])
        XCTAssertEqual(SimulatorDropRouting.route(file("Corp.mobileconfig")), .addProfile(file("Corp.mobileconfig")))
    }

    func testAPhysicalPhoneTakesNeitherPushesNorProfiles() {
        let plan = PhysicalSendRouting.plan([file("a.apns"), file("Corp.mobileconfig"), file("notes.txt"), file("Demo.app")])
        XCTAssertEqual(plan.unsupported, [file("a.apns"), file("Corp.mobileconfig")])
        XCTAssertEqual(plan.files, [file("notes.txt")])
        XCTAssertEqual(plan.existing, [file("Demo.app")])
    }

    // MARK: overlay words

    func testTheOverlayWords() {
        let simulator = SendFilesTarget.simulator(filesDestination: .filesApp, filesAppName: nil)
        XCTAssertEqual(
            SendFilesSummary.describe([file("a.apns")], target: simulator) { _ in "com.example.app" },
            "Send push notification to com.example.app"
        )
        XCTAssertEqual(
            SendFilesSummary.describe([file("a.apns")], target: simulator),
            "Send push notification to an app (choose one)"
        )
        XCTAssertEqual(
            SendFilesSummary.describe([file("a.apns"), file("b.apns")], target: simulator) { _ in "com.example.app" },
            "Send 2 push notifications to com.example.app"
        )
        XCTAssertEqual(
            SendFilesSummary.describe([file("a.apns"), file("b.apns")], target: simulator),
            "Send 2 push notifications"
        )
        XCTAssertEqual(
            SendFilesSummary.describe([file("Corp.mobileconfig")], target: simulator),
            "Trust the profile's certificates (a simulator can't install profiles)"
        )
        XCTAssertEqual(
            SendFilesSummary.describe([file("a.apns")], target: .android(destination: .downloads)),
            "Push notifications can't be sent to Android this way"
        )
        XCTAssertEqual(
            SendFilesSummary.describe([file("a.apns"), file("notes.txt")], target: .android(destination: .downloads)),
            "Push notifications can't be sent to Android this way, Copy 1 file to Downloads"
        )
        XCTAssertEqual(
            SendFilesSummary.describe([file("a.apns"), file("Corp.mobileconfig")], target: .physical(appName: nil)),
            "Push payloads and profiles can't be sent to a physical iPhone with public tools"
        )
    }

    // MARK: .mobileconfig

    private func plist(_ payloads: [[String: Any]], name: String? = "Corp") throws -> Data {
        var root: [String: Any] = [
            "PayloadType": "Configuration", "PayloadVersion": 1,
            "PayloadIdentifier": "com.example.profile", "PayloadUUID": UUID().uuidString,
            "PayloadContent": payloads,
        ]
        if let name { root["PayloadDisplayName"] = name }
        return try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    func testCertificatesAreTakenFromRootPkcs1AndPemPayloads() throws {
        let der = Data([0x30, 0x03, 0x02, 0x01, 0x01])
        let pem = Data("-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n".utf8)
        let data = try plist([
            ["PayloadType": "com.apple.security.root", "PayloadContent": der, "PayloadDisplayName": "Corp Root"],
            ["PayloadType": "com.apple.security.pkcs1", "PayloadContent": der],
            ["PayloadType": "com.apple.security.pem", "PayloadContent": pem],
            ["PayloadType": "com.apple.wifi.managed", "SSID_STR": "x"],
            ["PayloadType": "com.apple.wifi.managed"],
        ])
        let profile = try ConfigurationProfile.parse(plist: data, name: "Corp.mobileconfig")
        XCTAssertEqual(profile.displayName, "Corp")
        XCTAssertEqual(profile.certificates.map(\.fileExtension), ["cer", "cer", "pem"])
        XCTAssertEqual(profile.certificates.first?.name, "Corp Root")
        XCTAssertEqual(profile.otherPayloadTypes, ["com.apple.wifi.managed"])

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = try profile.writeCertificates(into: folder, profileName: "Corp.mobileconfig")
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Corp Root.cer", "Corp 2.cer", "Corp 3.pem"])
        XCTAssertEqual(try Data(contentsOf: urls[0]), der)
    }

    func testAProfileWithoutCertificatesSaysWhatItHas() throws {
        let data = try plist([["PayloadType": "com.apple.vpn.managed"]])
        XCTAssertThrowsError(try ConfigurationProfile.parse(plist: data, name: "Vpn.mobileconfig")) {
            XCTAssertEqual(
                "\($0)",
                "“Vpn.mobileconfig” holds no certificate. A simulator can't install configuration profiles; only the certificates in one can be trusted (this one has com.apple.vpn.managed)."
            )
        }
    }

    func testAPlistThatIsNoProfileIsRefused() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .xml, options: 0)
        XCTAssertThrowsError(try ConfigurationProfile.parse(plist: data, name: "x.mobileconfig")) {
            XCTAssertEqual("\($0)", "“x.mobileconfig” is not a configuration profile.")
        }
    }

    func testReadingFilesPlainAndGarbage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let good = folder.appendingPathComponent("good.mobileconfig")
        try plist([["PayloadType": "com.apple.security.root", "PayloadContent": Data([0x30, 0x00])]]).write(to: good)
        let read = try await ConfigurationProfile.read(good)
        XCTAssertEqual(read.certificates.count, 1)

        // Not a plist: handed to `security cms -D`, which refuses it.
        let junk = folder.appendingPathComponent("junk.mobileconfig")
        try Data("not a profile".utf8).write(to: junk)
        do {
            _ = try await ConfigurationProfile.read(junk)
            XCTFail("junk must be refused")
        } catch {
            XCTAssertEqual("\(error)", "“junk.mobileconfig” is not a configuration profile.")
        }
    }
}
