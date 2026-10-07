import XCTest
@testable import DeviceHubProKit

/// `AvdConfig.hardwareKeyboard` and `setHardwareKeyboard` on real
/// `config.ini` files (`LogcatSdkApkFixtures`, `avd/`): `Pixel_9_Pro` as
/// avdmanager wrote it (`hw.keyboard=no`), `Pixel_9_Pro_Fold` and
/// `Pixel_Fold` as Android Studio did (`hw.keyboard=yes`). Writes work on
/// copies in a temporary AVD home.
final class AvdHardwareKeyboardConfigTests: XCTestCase {
    private var fixtureHome: URL { LogcatSdkApkFixtures.url("avd") }

    /// A temporary AVD home holding `Pixel_9_Pro.avd/config.ini` with
    /// `content`; returns the home and the config's URL.
    private func home(with content: String) throws -> (home: URL, config: URL) {
        let home = try LogcatSdkApkFixtures.temporaryDirectory(self, prefix: "avd-keyboard")
        let config = home.appendingPathComponent("Pixel_9_Pro.avd/config.ini")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: config)
        return (home, config)
    }

    func testTheRealConfigsReadAsTheirToolWroteThem() {
        XCTAssertEqual(AvdConfig.hardwareKeyboard(avdName: "Pixel_9_Pro", avdHome: fixtureHome), false)
        XCTAssertEqual(AvdConfig.hardwareKeyboard(avdName: "Pixel_9_Pro_Fold", avdHome: fixtureHome), true)
        XCTAssertEqual(AvdConfig.hardwareKeyboard(avdName: "Pixel_Fold", avdHome: fixtureHome), true)
        XCTAssertNil(AvdConfig.hardwareKeyboard(avdName: "No_Such_Avd", avdHome: fixtureHome))
    }

    /// Turning it on rewrites the one `hw.keyboard` line in place; the
    /// `hw.keyboard.charmap` and `hw.keyboard.lid` lines after it and every
    /// other byte stay. Turning it off again gives the original back.
    func testTurningTheKeyboardOnRewritesOnlyItsLine() throws {
        let original = try LogcatSdkApkFixtures.text("avd/Pixel_9_Pro.avd/config.ini")
        let (home, config) = try home(with: original)

        try AvdConfig.setHardwareKeyboard(true, avdName: "Pixel_9_Pro", avdHome: home)

        let written = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(original.contains("\nhw.keyboard=no\nhw.keyboard.charmap=qwerty2\nhw.keyboard.lid=yes\n"))
        XCTAssertEqual(written, original.replacingOccurrences(of: "\nhw.keyboard=no\n", with: "\nhw.keyboard=yes\n"))
        let before = original.split(separator: "\n", omittingEmptySubsequences: false)
        let after = written.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(before.count, after.count)
        XCTAssertEqual(zip(before, after).filter { $0 != $1 }.count, 1)
        XCTAssertEqual(AvdConfig.hardwareKeyboard(avdName: "Pixel_9_Pro", avdHome: home), true)

        try AvdConfig.setHardwareKeyboard(false, avdName: "Pixel_9_Pro", avdHome: home)
        XCTAssertEqual(try Data(contentsOf: config), Data(original.utf8))
    }

    /// A config without the key (the real one with its `hw.keyboard` line
    /// trimmed, which the test needs gone) reads as off, and turning it on
    /// appends the key at the end in the file's own line ending.
    func testAMissingKeyIsOffAndIsAppended() throws {
        let original = try LogcatSdkApkFixtures.text("avd/Pixel_9_Pro.avd/config.ini")
            .replacingOccurrences(of: "\nhw.keyboard=no\n", with: "\n")
        XCTAssertFalse(original.contains("hw.keyboard="))
        let (home, config) = try home(with: original)
        XCTAssertEqual(AvdConfig.hardwareKeyboard(avdName: "Pixel_9_Pro", avdHome: home), false)

        try AvdConfig.setHardwareKeyboard(true, avdName: "Pixel_9_Pro", avdHome: home)

        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), original + "hw.keyboard=yes\n")
    }

    /// CRLF and an unterminated last line survive (the real config with its
    /// line endings turned into CRLF and its final newline trimmed).
    func testLineEndingsAreKept() throws {
        let lf = try LogcatSdkApkFixtures.text("avd/Pixel_9_Pro.avd/config.ini")
        // "\r\n" is one Character: dropLast() drops the whole final CRLF.
        let crlf = String(lf.replacingOccurrences(of: "\n", with: "\r\n").dropLast())
        XCTAssertTrue(crlf.hasSuffix("vm.heapSize=256M"))
        let (home, config) = try home(with: crlf)

        try AvdConfig.setHardwareKeyboard(true, avdName: "Pixel_9_Pro", avdHome: home)
        XCTAssertEqual(
            try String(contentsOf: config, encoding: .utf8),
            crlf.replacingOccurrences(of: "\r\nhw.keyboard=no\r\n", with: "\r\nhw.keyboard=yes\r\n")
        )

        let trimmed = crlf.replacingOccurrences(of: "\r\nhw.keyboard=no\r\n", with: "\r\n")
        try Data(trimmed.utf8).write(to: config)
        try AvdConfig.setHardwareKeyboard(true, avdName: "Pixel_9_Pro", avdHome: home)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), trimmed + "\r\nhw.keyboard=yes\r\n")
    }

    /// The emulator's own boolean (`IniFile::getBool`): a value that "yes",
    /// "true" or "1" begins with is true and one that "no", "false" or "0"
    /// begins with is false, in any case, an empty value included; anything
    /// else is nil (the key's default).
    func testTheEmulatorsBooleans() {
        for value in ["yes", "YES", "Yes", "y", "ye", "true", "TRUE", "t", "1", ""] {
            XCTAssertEqual(EmulatorIni.boolean(value), true, value)
        }
        for value in ["no", "NO", "n", "false", "False", "f", "0"] {
            XCTAssertEqual(EmulatorIni.boolean(value), false, value)
        }
        for value in ["yess", "on", "off", "2", "10", "maybe", " yes"] {
            XCTAssertNil(EmulatorIni.boolean(value), value)
        }
    }

    /// The real `Pixel_9_Pro` config with its `hw.keyboard` line written
    /// other ways a hand edit can: each reads as the emulator reads it
    /// (spaces around the "=", any case, "1", a later line winning, a
    /// comment not counting, CRLF), and turning the keyboard on rewrites the
    /// spaced line too.
    func testTheKeyReadsAsTheEmulatorReadsIt() throws {
        let original = try LogcatSdkApkFixtures.text("avd/Pixel_9_Pro.avd/config.ini")
        XCTAssertTrue(original.contains("\nhw.keyboard=no\n"))
        let cases: [(line: String, on: Bool)] = [
            ("hw.keyboard = yes", true),
            ("\thw.keyboard\t=\tYES  ", true),
            ("hw.keyboard=1", true),
            ("hw.keyboard=", true),
            ("hw.keyboard=0", false),
            ("hw.keyboard=on", false),
            ("hw.keyboard=no\nhw.keyboard=yes", true),
            ("hw.keyboard=yes\nhw.keyboard=no", false),
            ("#hw.keyboard=yes", false),
            ("hw.keyboard=yes junk", false),
            ("hw.keyboard=yes\rjunk", false),
        ]
        for (line, on) in cases {
            let edited = try home(with: original.replacingOccurrences(of: "\nhw.keyboard=no\n", with: "\n\(line)\n"))
            XCTAssertEqual(AvdConfig.hardwareKeyboard(avdName: "Pixel_9_Pro", avdHome: edited.home), on, line.debugDescription)
        }

        let crlf = original.replacingOccurrences(of: "\n", with: "\r\n")
            .replacingOccurrences(of: "\r\nhw.keyboard=no\r\n", with: "\r\nhw.keyboard=yes\r\n")
        let crlfAvd = try home(with: crlf)
        XCTAssertEqual(AvdConfig.hardwareKeyboard(avdName: "Pixel_9_Pro", avdHome: crlfAvd.home), true)

        let spaced = try home(with: original.replacingOccurrences(of: "\nhw.keyboard=no\n", with: "\nhw.keyboard = no\n"))
        XCTAssertEqual(AvdConfig.hardwareKeyboard(avdName: "Pixel_9_Pro", avdHome: spaced.home), false)
        try AvdConfig.setHardwareKeyboard(true, avdName: "Pixel_9_Pro", avdHome: spaced.home)
        XCTAssertEqual(
            try String(contentsOf: spaced.config, encoding: .utf8),
            original.replacingOccurrences(of: "\nhw.keyboard=no\n", with: "\nhw.keyboard=yes\n")
        )
        XCTAssertEqual(AvdConfig.hardwareKeyboard(avdName: "Pixel_9_Pro", avdHome: spaced.home), true)
    }

    /// No config, no write: the key is never put into a file of its own.
    func testAMissingConfigIsNotCreated() throws {
        let home = try LogcatSdkApkFixtures.temporaryDirectory(self, prefix: "avd-keyboard-missing")
        XCTAssertThrowsError(try AvdConfig.setHardwareKeyboard(true, avdName: "Gone", avdHome: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Gone.avd/config.ini").path))
    }
}
