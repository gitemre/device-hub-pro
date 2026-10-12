import XCTest
@testable import DeviceHubProKit

/// What the scrubber takes out. The captures are the fixtures of the other
/// suites (their personal values are already placeholders: the macOS user is
/// `testeruser` in the adb fixtures and `aqauser001` in the app log); the other
/// inputs are written here, to name what each pass must and must not touch.
final class ProblemReportScrubberTests: XCTestCase {
    private func scrubber(
        home: String = "/Users/testeruser",
        user: String = "testeruser",
        fullName: String = "",
        hosts: [String] = [],
        secrets: [String] = [],
        identifiers: [String: String] = [:]
    ) -> ProblemReportScrubber {
        ProblemReportScrubber(
            identity: ScrubIdentity(homePath: home, userName: user, fullName: fullName, hostNames: hosts),
            secrets: secrets,
            identifiers: identifiers
        )
    }

    // MARK: Home folder and user name

    func testEveryFormOfTheHomeFolderBecomesATilde() {
        var scrubber = scrubber()
        let forms = [
            "/Users/testeruser/Library/Android/sdk",
            "/private/Users/testeruser/Library/Android/sdk",
            "/System/Volumes/Data/Users/testeruser/Library/Android/sdk",
            "file:///Users/testeruser/Library/Android/sdk",
            "\\/Users\\/testeruser\\/Library\\/Android\\/sdk",
        ]
        for form in forms {
            let result = scrubber.scrub("path \(form) end")
            XCTAssertFalse(result.contains("testeruser"), form)
            XCTAssertTrue(result.hasPrefix("path ~"), "\(form) -> \(result)")
        }
        XCTAssertEqual(scrubber.scrub("/Users/testeruser2/x"), "/Users/testeruser2/x", "another user's folder is not ours")
        XCTAssertEqual(
            scrubber.scrub("/var/folders/ab/cd1EFgh_2/T/devicehubpro-logcat-tests/fake-adb"),
            "$TMPDIR/devicehubpro-logcat-tests/fake-adb"
        )
        XCTAssertEqual(scrubber.removed["homePath"], forms.count + 1)
    }

    func testTheUserNameIsReplacedWhereItIsAnchored() {
        var scrubber = scrubber(home: "/Users/elsewhere", user: "testeruser")
        XCTAssertEqual(scrubber.scrub("/Users/TesterUser/Library"), "~/Library", "case-insensitive")
        XCTAssertEqual(scrubber.scrub("/tmp/android-testeruser/emu-crash.db"), "/tmp/android-<user>/emu-crash.db")
        XCTAssertEqual(scrubber.scrub("testeruser@Macmini"), "<user>@<host>", "the host after the user is the Mac's name")
        XCTAssertEqual(scrubber.scrub("owner testeruser logged in"), "owner <user> logged in", "a long name is replaced as a word")
        XCTAssertEqual(scrubber.scrub("testerusers"), "testerusers", "not inside another word")
        XCTAssertEqual(scrubber.removed["userName"], 4)
        XCTAssertEqual(scrubber.removed["hostName"], 1)
    }

    func testAShortUserNameIsReplacedOnlyWhereItIsAnchored() {
        var scrubber = scrubber(home: "/Users/dev", user: "dev")
        XCTAssertEqual(scrubber.scrub("/Users/dev/x and dev@host and android-dev"), "~/x and <user>@<host> and android-<user>")
        XCTAssertEqual(scrubber.scrub("a dev tools build of the developer kit"), "a dev tools build of the developer kit")
    }

    func testTheRecordedProcessListAndDiscoveryFileLoseTheUserName() throws {
        var scrubber = scrubber()
        for name in ["api37-emulator/adb-core/host-ps-axo-pid-command.txt", "api37-emulator/adb-core/emulator-discovery-pid.ini"] {
            let text = try ProblemReportFixtures.text(name)
            XCTAssertTrue(text.contains("testeruser"), "the capture holds the placeholder name")
            let result = scrubber.scrub(text)
            XCTAssertFalse(result.contains("testeruser"), name)
            XCTAssertTrue(result.contains("~/device-hub-pro/spike"), name)
        }
        // The router in `--host-dns=192.168.1.1` is on the local network.
        XCTAssertFalse(scrubber.scrub("--host-dns=192.168.1.1").contains("192.168.1.1"))
    }

    /// `emulator-app-log.log` is a real log of the app's emulator with two scrubs
    /// (the macOS user name is `aqauser001`; the adb public key is a run of `A`
    /// with its real `=` ending) and the lines after "Boot completed" cut
    /// (Fixtures/problem-report/README.md).
    func testTheAppsEmulatorLogKeepsItsDiagnosticLines() throws {
        var scrubber = scrubber(home: "/Users/aqauser001", user: "aqauser001")
        let result = scrubber.scrub(try ProblemReportFixtures.text("problem-report/emulator-app-log.log"))
        XCTAssertFalse(result.contains("aqauser001"))
        XCTAssertTrue(result.contains("Started GRPC server at 127.0.0.1:8554, security: Local, auth: +token"), "loopback stays")
        XCTAssertTrue(result.contains("Advertising in: ~/Library/Caches/TemporaryItems/avd/running/pid_86704.ini"))
        XCTAssertTrue(result.contains("Found systemPath ~/Library/Android/sdk/system-images/android-36/google_apis/arm64-v8a/"))
        XCTAssertTrue(result.contains("Storing crashdata in: /tmp/android-<user>/emu-crash-36.6.11.db"))
        XCTAssertTrue(result.contains("Sending adb public key [<base64>"), "the key is a token")
        XCTAssertTrue(result.contains("<base64> <user>@unknown]"), "the key's comment keeps what says nothing about the Mac")
        XCTAssertTrue(result.contains("Android emulator version 36.6.11.0 (build_id 15507667)"), "a version is not an address")
        XCTAssertTrue(result.contains("Selecting Vulkan device: Apple M4 Pro, Version: 1.1.323"))
    }

    // MARK: Names

    func testTheFullNameIsFoundIgnoringCaseAndDiacritics() {
        var scrubber = scrubber(fullName: "Barış Öztürk")
        XCTAssertEqual(scrubber.scrub("Barış Öztürk"), "<name>")
        XCTAssertEqual(scrubber.scrub("BARIŞ"), "<name>")
        XCTAssertEqual(scrubber.scrub("barış"), "<name>")
        XCTAssertEqual(scrubber.scrub("Baris"), "<name>")
        XCTAssertEqual(scrubber.scrub("Oztürk"), "<name>")
        XCTAssertEqual(scrubber.scrub("ÖZTÜRK"), "<name>")
        XCTAssertEqual(scrubber.scrub("BARIŞ ÖZTÜRK"), "<name>")
        // A decomposed form (s + combining cedilla).
        XCTAssertEqual(scrubber.scrub("Barış".decomposedStringWithCanonicalMapping), "<name>")
        XCTAssertEqual(scrubber.scrub("Hello Barış Öztürk!"), "Hello <name>!")
        XCTAssertEqual(scrubber.scrub("Barista"), "Barista", "a word that only starts like a name")
        XCTAssertGreaterThanOrEqual(scrubber.removed["fullName"] ?? 0, 9)
    }

    func testTheMacsNamesAreOneHostEach() {
        var scrubber = scrubber(
            fullName: "Emre Öztürk",
            hosts: ["Emre\u{2019}s Mac mini", "Emres-Mac-mini", "Emres-Mac-mini.local"]
        )
        XCTAssertEqual(scrubber.scrub("Computer: Emre\u{2019}s Mac mini"), "Computer: <host>")
        XCTAssertEqual(scrubber.scrub("Computer: Emre's Mac mini"), "Computer: <host>", "a straight apostrophe too")
        XCTAssertEqual(scrubber.scrub("user@Emres-Mac-mini.local"), "user@<host>")
        XCTAssertEqual(scrubber.scrub("Emres-Mac-mini"), "<host>")
        XCTAssertEqual(scrubber.removed["hostName"], 4)
    }

    // MARK: Identifiers and secrets

    func testIdentifiersKeepOneAliasAcrossFields() {
        var scrubber = scrubber(identifiers: [
            "0a1b2c3d4e5f": "phone-1", "192.168.1.5:5555": "phone-1", "E3B0C442-98FC-1C14-9AFB-F4C8996FB924": "sim-1",
        ])
        XCTAssertEqual(
            scrubber.scrub("serial 0a1b2c3d4e5f / 192.168.1.5:5555 / again 0A1B2C3D4E5F"),
            "serial phone-1 / phone-1 / again phone-1"
        )
        XCTAssertEqual(scrubber.scrub("device E3B0C442-98FC-1C14-9AFB-F4C8996FB924 booted"), "device sim-1 booted")
        XCTAssertEqual(scrubber.removed["phoneSerial"], 3)
        XCTAssertEqual(scrubber.removed["udid"], 1)
    }

    func testSecretsAreRedactedWhateverTheirCase() {
        var scrubber = scrubber(secrets: ["ABCDE12345", "ab"])
        XCTAssertEqual(scrubber.scrub("team abcde12345 and AB"), "team \u{2039}redacted\u{203A} and AB", "a two-character value is too short to be a secret")
        XCTAssertEqual(scrubber.removed["secret"], 1)
    }

    func testMdnsServiceNamesLoseTheirSerial() {
        var scrubber = scrubber(identifiers: ["0A1B2C3D4E5F60718": "phone-1"])
        XCTAssertEqual(
            scrubber.scrub("adb-0A1B2C3D4E5F60718-aB3dE5._adb-tls-connect._tcp"),
            "adb-phone-1._adb-tls-connect._tcp"
        )
        // The recorded `adb mdns services` line (a placeholder serial).
        let listing = (try? ProblemReportFixtures.text("api37-emulator/adb-core/adb-mdns-services.txt")) ?? ""
        let result = scrubber.scrub(listing)
        XCTAssertFalse(result.contains("0A1B2C3D4E5F60718"))
        XCTAssertTrue(result.contains("adb-phone-1"))
        XCTAssertTrue(result.contains("<lan-ip-1>:5555"))

        // A phone the table does not know gets the next alias, the same one again.
        var other = self.scrubber(identifiers: ["x1y2z3w4": "phone-1"])
        XCTAssertEqual(other.scrub("adb-NEWSERIAL99-Qq12Ww._adb-tls-pairing._tcp"), "adb-phone-2._adb-tls-pairing._tcp")
        XCTAssertEqual(other.scrub("adb-NEWSERIAL99-Zz00Xx._adb-tls-connect._tcp"), "adb-phone-2._adb-tls-connect._tcp")
    }

    // MARK: Addresses and tokens

    func testOnlyLocalNetworkAddressesAreAliased() {
        var scrubber = scrubber()
        XCTAssertEqual(scrubber.scrub("127.0.0.1:8554 and 0.0.0.0 and 10.0.2.15 and 10.0.2.2"), "127.0.0.1:8554 and 0.0.0.0 and 10.0.2.15 and 10.0.2.2")
        XCTAssertEqual(
            scrubber.scrub("connect 192.168.1.5:5555, then 192.168.1.9, then 192.168.1.5 again"),
            "connect <lan-ip-1>:5555, then <lan-ip-2>, then <lan-ip-1> again"
        )
        XCTAssertEqual(scrubber.scrub("172.20.1.1 10.1.2.3 169.254.3.4 100.80.1.1"), "<lan-ip-3> <lan-ip-4> <lan-ip-5> <lan-ip-6>")
        XCTAssertEqual(scrubber.scrub("172.15.1.1 and 8.8.8.8"), "172.15.1.1 and 8.8.8.8", "not private")
        XCTAssertEqual(scrubber.scrub("emulator.version=37.2.8.0 and 300.1.1.1"), "emulator.version=37.2.8.0 and 300.1.1.1", "a version is not an address")
        XCTAssertEqual(scrubber.removed["lanAddress"], 7)
    }

    func testIPv6AndMacAddresses() {
        var scrubber = scrubber()
        XCTAssertEqual(scrubber.scrub("loopback ::1 and [::1]:8554"), "loopback ::1 and [::1]:8554")
        XCTAssertEqual(scrubber.scrub("link fe80::1c2d:3e4f:5a6b:7c8d end"), "link <ipv6> end")
        XCTAssertEqual(scrubber.scrub("tunnel fd12:3456:789a::1 end"), "tunnel <tunnel> end")
        XCTAssertEqual(scrubber.scrub("full 2001:0db8:85a3:0000:0000:8a2e:0370:7334 end"), "full <ipv6> end")
        XCTAssertEqual(scrubber.scrub("wifi aa:bb:cc:dd:ee:ff and AA-BB-CC-DD-EE-FF"), "wifi <mac> and <mac>")
        // Not addresses.
        let ordinary = "std::vector<android::emulation::control::SnapshotInfo> at 14:03:22 on 2026-10-12T14:03:22Z"
        XCTAssertEqual(scrubber.scrub(ordinary), ordinary)
        XCTAssertEqual(scrubber.removed["ipv6"], 3)
        XCTAssertEqual(scrubber.removed["macAddress"], 2)
    }

    func testEmailsTokensAndCredentials() {
        var scrubber = scrubber()
        XCTAssertEqual(scrubber.scrub("write to someone@example.com or a.b+c@mail.co.uk"), "write to <email> or <email>")
        XCTAssertEqual(
            scrubber.scrub("token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk end"),
            "token <token> end"
        )
        XCTAssertEqual(scrubber.scrub("proxy https://user:hunter2@proxy.example.com:3128/x"), "proxy https://<credentials>@proxy.example.com:3128/x")
        XCTAssertEqual(scrubber.removed["email"], 2)
        XCTAssertEqual(scrubber.removed["token"], 1)
        XCTAssertEqual(scrubber.removed["secret"], 1)
    }

    /// The adb public key the emulator prints at boot (a real line of the
    /// `getprop` capture) is a base64 run; a long path is not.
    func testTheAdbPublicKeyIsATokenAndAPathIsNot() throws {
        var scrubber = scrubber()
        let getprop = try ProblemReportFixtures.text("api37-emulator/adb-core/shell-getprop.txt")
        let line = try XCTUnwrap(getprop.components(separatedBy: "\n").dropFirst(292).first)
        XCTAssertTrue(line.hasPrefix("[ro.boot.qemu.adb.pubkey]"))
        let result = scrubber.scrub(line)
        XCTAssertTrue(result.hasPrefix("[ro.boot.qemu.adb.pubkey]: [<base64>"), result)
        XCTAssertFalse(result.contains("QAAAAKN67w"))

        let path = "/Applications/AndroidStudioPreview/Contents/MacOS"
        XCTAssertEqual(scrubber.scrub(path), path)
        XCTAssertEqual(scrubber.scrub("see /Applications/Android Studio Preview.app/Contents/plugins/android/lib/android.jar"),
                       "see /Applications/Android Studio Preview.app/Contents/plugins/android/lib/android.jar")
    }

    func testHardwareUdidsAndOtherUuids() {
        var scrubber = scrubber(identifiers: ["E3B0C442-98FC-1C14-9AFB-F4C8996FB924": "sim-1"])
        XCTAssertEqual(scrubber.scrub("00008030-001A3D2E0C47802E and da39a3ee5e6b4b0d3255bfef95601890afd80709"), "<udid> and <udid>")
        XCTAssertEqual(scrubber.scrub("E3B0C442-98FC-1C14-9AFB-F4C8996FB924"), "sim-1")
        XCTAssertEqual(
            scrubber.scrub("123E4567-E89B-12D3-A456-426614174000 / 223e4567-e89b-12d3-a456-426614174000 / 123e4567-e89b-12d3-a456-426614174000"),
            "<uuid-1> / <uuid-2> / <uuid-1>"
        )
    }

    /// SOURCE-DERIVED: the error text of `AdbError.commandFailed` ("adb <arguments> failed
    /// (<status>): <message>", AdbClient.swift) around the message adb prints for an unknown
    /// serial (`device '<serial>' not found`, `acquire_one_transport` in the AOSP adb sources).
    /// The serials are made up; no capture of a phone's serial is committed.
    func testASerialAnErrorNamesIsRemovedWhetherOrNotThePhoneIsListed() {
        var scrubber = scrubber()
        let failed = "adb -s R58M12345AB reboot failed (1): adb: device 'R58M12345AB' not found"
        XCTAssertEqual(scrubber.scrub(failed), "adb -s phone-1 reboot failed (1): adb: device 'phone-1' not found")
        // The same phone keeps its alias, another gets the next one, and an emulator is no phone.
        XCTAssertEqual(scrubber.scrub("adb -s r58m12345ab shell id failed"), "adb -s phone-1 shell id failed")
        XCTAssertEqual(scrubber.scrub("adb -s 0a1b2c3d4e5f shell id failed"), "adb -s phone-2 shell id failed")
        XCTAssertEqual(scrubber.scrub("adb -s emulator-5554 emu avd name failed"), "adb -s emulator-5554 emu avd name failed")
        XCTAssertEqual(scrubber.scrub("adb: device 'emulator-5556' not found"), "adb: device 'emulator-5556' not found")
        XCTAssertEqual(scrubber.scrub("tar -s 5 and ls -s 12"), "tar -s 5 and ls -s 12", "under four characters is no serial")
        // Whatever follows -s is taken for a serial from four characters: too much removed is the safe side.
        XCTAssertEqual(scrubber.scrub("run -s words"), "run -s phone-3")
        XCTAssertEqual(scrubber.removed["phoneSerial"], 5)
    }

    func testASerialNamedInOneStringIsRemovedFromTheOnesBeforeIt() throws {
        var report = sampleReport()
        report.subject = ProblemReport.Subject(
            message: "Could not open the link on R58M12345AB: no activity found",
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        report.recentProblems = [ProblemReport.RecentProblem(
            at: Date(timeIntervalSince1970: 1_800_000_000),
            message: "adb -s R58M12345AB reboot failed (1): adb: device 'R58M12345AB' not found"
        )]
        var scrubber = scrubber()
        let result = scrubber.scrub(report)
        XCTAssertEqual(result.subject?.message, "Could not open the link on phone-1: no activity found")
        XCTAssertEqual(result.recentProblems.first?.message, "adb -s phone-1 reboot failed (1): adb: device 'phone-1' not found")
        XCTAssertFalse(try result.jsonText().contains("R58M12345AB"))
        XCTAssertEqual(result.collection.removed["phoneSerial"], 3)

        // The numbering does not depend on the order a dictionary happens to give.
        for _ in 0..<5 {
            var again = self.scrubber()
            XCTAssertEqual(again.scrub(report), result)
        }
    }

    func testAnAddressWithAPortIsAPhoneWhateverItsRange() {
        var scrubber = scrubber()
        XCTAssertEqual(
            scrubber.scrub("connect 203.0.113.7:5555 failed, again 203.0.113.7:37123 and 203.0.113.9:5555"),
            "connect <ip-1>:5555 failed, again <ip-1>:37123 and <ip-2>:5555"
        )
        // Not a phone: the adb server and the emulator's own network, loopback, a version.
        let kept = "adb 127.0.0.1:5037 and 10.0.2.2:5555 and 0.0.0.0:80 and version 37.2.8.0 and 203.0.113.7"
        XCTAssertEqual(scrubber.scrub(kept), kept)
        XCTAssertEqual(scrubber.removed["ipAddress"], 3)
    }

    func testTheHostAfterTheUserNameGoesWhateverItIs() {
        var scrubber = scrubber(home: "/Users/aqauser001", user: "aqauser001", hosts: ["Known-Mac"])
        XCTAssertEqual(scrubber.scrub("aqauser001@emres-mbp.lan"), "<user>@<host>", "a DHCP name the Mac's own names do not hold")
        XCTAssertEqual(scrubber.scrub("[key aqauser001@MacBook-Pro-van-Emre.fritz.box]"), "[key <user>@<host>]")
        XCTAssertEqual(scrubber.scrub("aqauser001@unknown and aqauser001@localhost"), "<user>@unknown and <user>@localhost")
        XCTAssertEqual(scrubber.scrub("aqauser001@Known-Mac"), "<user>@<host>")
        XCTAssertEqual(scrubber.scrub("sent by aqauser001@."), "sent by <user>@.", "no host follows")
    }

    /// An adb key made on another Mac (a migrated `~/.android`) carries that
    /// Mac's user and host: the comment after the key goes whoever wrote it.
    func testTheCommentAfterAnAdbKeyNamesNoOneElse() {
        var scrubber = scrubber()
        let key = String(repeating: "Qk9xZtLm", count: 90) + "="
        XCTAssertEqual(scrubber.scrub("Sending adb public key [\(key) john@Johns-MacBook-Air]"), "Sending adb public key [<base64> <user>@<host>]")
        XCTAssertEqual(scrubber.scrub("androidboot.qemu.adb.pubkey=\(key) john@Johns-MacBook-Air.local"), "androidboot.qemu.adb.pubkey=<base64> <email>")
        XCTAssertEqual(scrubber.scrub("[\(key) john@unknown]"), "[<base64> <user>@unknown]")
        XCTAssertEqual(scrubber.scrub("[\(key) <user>@unknown]"), "[<base64> <user>@unknown]", "already scrubbed")
        XCTAssertEqual(scrubber.scrub("mail john@Johns-MacBook-Air"), "mail john@Johns-MacBook-Air", "only a key has this comment")
    }

    /// A long run is a token even when only its front is left (a cut at a
    /// storage limit): nothing legitimate is a hundred characters of base64
    /// without a separator.
    func testALongRunIsATokenEvenWithoutAPlusOrAnEquals() {
        var scrubber = scrubber()
        let piece = String(repeating: "Qk/9xZtL", count: 15)
        XCTAssertEqual(piece.count, 120)
        XCTAssertEqual(scrubber.scrub("key [\(piece)"), "key [<base64>")
        let shorter = String(repeating: "Qk/9xZtL", count: 14)
        XCTAssertEqual(scrubber.scrub("key [\(shorter)"), "key [\(shorter)", "below that it may be a path")
    }

    // MARK: The report's own words

    /// A surname that is also a word of the schema ("Blank" is a token file state) must
    /// not turn `"state": "blank"` into `"<name>"`: the scrubbed report is decoded again.
    func testNamesNeverRewriteTheSchemasOwnWords() throws {
        var report = sampleReport()
        report.android.consoleTokenFile.state = .blank
        report.app.kind = .cli
        report.producer = .cli
        var scrubber = scrubber(user: "present", fullName: "Steve Blank Cli", hosts: ["missing", "empty"])
        let result = scrubber.scrub(report)
        XCTAssertEqual(result.android.consoleTokenFile.state, .blank)
        XCTAssertEqual(result.producer, .cli)
        XCTAssertEqual(result.app.kind, .cli)
        XCTAssertEqual(result.mac.macOS, "27.0", "the rest of the report came through")
        XCTAssertFalse(result.collection.notes.contains { $0.contains("could not be scrubbed") })

        // Free text is still scrubbed.
        XCTAssertEqual(scrubber.scrub("Steve Blank wrote this"), "<name> <name> wrote this")
    }

    /// Whatever the user and the Mac are called, each value of each enum comes back as it was.
    func testEveryEnumValueSurvivesAHostileIdentity() throws {
        let words = ProblemReport.enumRawValues.sorted()
        XCTAssertTrue(words.contains("notAFile"))
        XCTAssertTrue(words.contains("answered"))
        var scrubber = scrubber(user: "answered", fullName: words.joined(separator: " "), hosts: words)
        for state in ProblemReport.TokenState.allCases {
            for (index, image) in ProblemReport.ImageState.allCases.enumerated() {
                var report = sampleReport()
                report.android.consoleTokenFile.state = state
                report.android.avds = [ProblemReport.Avd(
                    name: "Pixel", image: image, contentFolder: ProblemReport.ContentFolder.allCases[index % ProblemReport.ContentFolder.allCases.count]
                )]
                report.producer = .cli
                report.app.kind = .development
                report.app.location = .translocated
                let result = scrubber.scrub(report)
                XCTAssertEqual(result.android.consoleTokenFile.state, state)
                XCTAssertEqual(result.android.avds.first?.image, image)
                XCTAssertEqual(result.android.avds.first?.contentFolder, report.android.avds.first?.contentFolder)
                XCTAssertEqual(result.producer, .cli)
                XCTAssertEqual(result.app.kind, .development)
                XCTAssertEqual(result.app.location, .translocated)
                XCTAssertEqual(result.mac.macOS, "27.0", "an empty report would mean the scrub failed")
            }
        }
    }

    // MARK: A whole report

    func testEveryStringOfAReportIsScrubbedAndTheCountsAreRecorded() throws {
        var report = sampleReport()
        report.subject = ProblemReport.Subject(
            message: "Couldn\u{2019}t reach 192.168.1.5:5555 for /Users/testeruser/x", occurredAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        report.android.avds = [ProblemReport.Avd(name: "Pixel_8_Pro", imageSysdir: "/Users/testeruser/sdk/system-images/x")]
        report.recentProblems = [ProblemReport.RecentProblem(
            at: Date(timeIntervalSince1970: 1_800_000_000), message: "ABCDE12345 failed", details: ["me@example.com"]
        )]
        var scrubber = scrubber(secrets: ["ABCDE12345"])
        let result = scrubber.scrub(report)
        let json = try result.jsonText()
        for leaked in ["testeruser", "192.168.1.5", "ABCDE12345", "me@example.com"] {
            XCTAssertFalse(json.contains(leaked), leaked)
        }
        XCTAssertEqual(result.subject?.message, "Couldn\u{2019}t reach <lan-ip-1>:5555 for ~/x")
        XCTAssertEqual(result.android.avds.first?.imageSysdir, "~/sdk/system-images/x")
        XCTAssertEqual(result.recentProblems.first?.details, ["<email>"])
        XCTAssertEqual(result.collection.removed["homePath"], 4, "the subject, the image folder, the token file and the AVD home")
        XCTAssertEqual(result.collection.removed["lanAddress"], 1)
        XCTAssertEqual(result.collection.removed["email"], 1)
        XCTAssertEqual(result.collection.removed["secret"], 1)
        XCTAssertEqual(result.id, report.id)
        XCTAssertEqual(result.createdAt, report.createdAt)
    }

    private func sampleReport() -> ProblemReport {
        ProblemReport(
            id: "abcd1234",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            producer: .app,
            app: ProblemReport.AppInfo(kind: .packaged),
            mac: ProblemReport.MacInfo(macOS: "27.0", appleSilicon: true),
            android: ProblemReport.AndroidInfo(
                consoleTokenFile: ProblemReport.TokenFileInfo(path: "/Users/testeruser/.emulator_console_auth_token", state: .present),
                avdHome: ProblemReport.AvdHomeInfo(path: "/Users/testeruser/.android/avd", exists: true)
            ),
            apple: ProblemReport.AppleInfo()
        )
    }
}
