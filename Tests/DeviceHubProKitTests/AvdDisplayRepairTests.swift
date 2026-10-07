import XCTest
@testable import DeviceHubProKit

final class AvdDisplayRepairTests: XCTestCase {
    private var avdHome: URL!

    override func setUp() {
        super.setUp()
        avdHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: avdHome, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: avdHome)
        super.tearDown()
    }

    private func writeConfig(_ text: String, avdName: String = "Test") {
        let dir = avdHome.appendingPathComponent("\(avdName).avd", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(
            to: dir.appendingPathComponent("config.ini"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func readConfig(avdName: String = "Test") -> String? {
        try? String(
            contentsOf: avdHome
                .appendingPathComponent("\(avdName).avd", isDirectory: true)
                .appendingPathComponent("config.ini"),
            encoding: .utf8
        )
    }

    private func skin(display: CGSize) -> ResolvedSkin {
        ResolvedSkin(
            name: "test",
            directory: avdHome,
            source: .skinName,
            variants: [
                SkinVariant(
                    id: "default",
                    directory: avdHome,
                    layout: SkinLayoutFile(
                        portrait: SkinDisplay(
                            displaySize: display,
                            origin: .zero,
                            layoutSize: display,
                            backgroundImage: nil,
                            maskImage: nil,
                            orientation: .portrait
                        ),
                        landscape: nil
                    )
                )
            ]
        )
    }

    func testMatchingDisplayNeedsNoRepair() {
        writeConfig("hw.lcd.width=2208\nhw.lcd.height=1840\n")
        let before = readConfig()

        XCTAssertNil(AvdDisplayRepair.diagnose(
            avdName: "Test",
            skin: skin(display: CGSize(width: 2208, height: 1840)),
            avdHome: avdHome
        ))
        XCTAssertEqual(
            AvdDisplayRepair.repair(
                avdName: "Test",
                skin: skin(display: CGSize(width: 2208, height: 1840)),
                avdHome: avdHome
            ),
            .alreadyMatches
        )
        XCTAssertEqual(readConfig(), before)
    }

    func testRepairsHeightOnlyAndPreservesEverythingElse() {
        let original = """
            # A comment
            hw.lcd.width=2208
            hw.lcd.height=2092

            hw.displayRegion.0.1.height=2092
            hw.device.name=pixel_fold

            """
        writeConfig(original)

        let result = AvdDisplayRepair.repair(
            avdName: "Test",
            skin: skin(display: CGSize(width: 2208, height: 1840)),
            avdHome: avdHome
        )
        XCTAssertEqual(
            result,
            .repaired(
                from: CGSize(width: 2208, height: 2092),
                to: CGSize(width: 2208, height: 1840)
            )
        )

        // Only the LCD height line changed; comments, blank lines, the cover
        // region and the trailing newline are byte-identical.
        XCTAssertEqual(
            readConfig(),
            original.replacingOccurrences(of: "hw.lcd.height=2092", with: "hw.lcd.height=1840")
        )
        XCTAssertTrue(readConfig()?.contains("hw.displayRegion.0.1.height=2092") ?? false)

        // The backup holds the original bytes.
        let backup = try? String(
            contentsOf: avdHome
                .appendingPathComponent("Test.avd", isDirectory: true)
                .appendingPathComponent(AvdDisplayRepair.backupFileName),
            encoding: .utf8
        )
        XCTAssertEqual(backup, original)
    }

    func testRepairsWidthDeviation() {
        writeConfig("hw.lcd.width=1000\nhw.lcd.height=2280\n")
        let result = AvdDisplayRepair.repair(
            avdName: "Test",
            skin: skin(display: CGSize(width: 1080, height: 2280)),
            avdHome: avdHome
        )
        XCTAssertEqual(
            result,
            .repaired(
                from: CGSize(width: 1000, height: 2280),
                to: CGSize(width: 1080, height: 2280)
            )
        )
        XCTAssertEqual(readConfig(), "hw.lcd.width=1080\nhw.lcd.height=2280\n")
    }

    func testBothAxesDifferingIsUnsupported() {
        writeConfig("hw.lcd.width=1080\nhw.lcd.height=2400\n")
        XCTAssertNil(AvdDisplayRepair.diagnose(
            avdName: "Test",
            skin: skin(display: CGSize(width: 2208, height: 1840)),
            avdHome: avdHome
        ))
        XCTAssertEqual(
            AvdDisplayRepair.repair(
                avdName: "Test",
                skin: skin(display: CGSize(width: 2208, height: 1840)),
                avdHome: avdHome
            ),
            .unsupported
        )
        XCTAssertEqual(readConfig(), "hw.lcd.width=1080\nhw.lcd.height=2400\n")
    }

    func testMissingLcdKeysAreUnsupported() {
        writeConfig("hw.device.name=pixel_fold\n")
        XCTAssertEqual(
            AvdDisplayRepair.repair(avdName: "Test", skin: skin(display: CGSize(width: 1, height: 1)), avdHome: avdHome),
            .unsupported
        )
    }

    func testMissingSkinIsUnsupported() {
        writeConfig("hw.lcd.width=2208\nhw.lcd.height=2092\n")
        XCTAssertNil(AvdDisplayRepair.diagnose(avdName: "Test", skin: nil, avdHome: avdHome))
        XCTAssertEqual(
            AvdDisplayRepair.repair(avdName: "Test", skin: nil, avdHome: avdHome),
            .unsupported
        )
        XCTAssertEqual(readConfig(), "hw.lcd.width=2208\nhw.lcd.height=2092\n")
    }

    func testMissingConfigIsUnsupported() {
        XCTAssertEqual(
            AvdDisplayRepair.repair(
                avdName: "Absent",
                skin: skin(display: CGSize(width: 1, height: 1)),
                avdHome: avdHome
            ),
            .unsupported
        )
    }

    func testSecondRepairKeepsOriginalBackup() {
        writeConfig("hw.lcd.width=2208\nhw.lcd.height=2092\n")
        let fold = skin(display: CGSize(width: 2208, height: 1840))
        XCTAssertEqual(
            AvdDisplayRepair.repair(avdName: "Test", skin: fold, avdHome: avdHome),
            .repaired(
                from: CGSize(width: 2208, height: 2092),
                to: CGSize(width: 2208, height: 1840)
            )
        )

        // Something rewrites the config again; the next repair must still
        // restore the very first bytes.
        writeConfig("hw.lcd.width=2208\nhw.lcd.height=2000\n")
        XCTAssertEqual(
            AvdDisplayRepair.repair(avdName: "Test", skin: fold, avdHome: avdHome),
            .repaired(
                from: CGSize(width: 2208, height: 2000),
                to: CGSize(width: 2208, height: 1840)
            )
        )
        XCTAssertTrue(AvdDisplayRepair.restoreBackup(avdName: "Test", avdHome: avdHome))
        XCTAssertEqual(readConfig(), "hw.lcd.width=2208\nhw.lcd.height=2092\n")
    }

    func testRestoreWithoutBackupFails() {
        writeConfig("hw.lcd.width=1\nhw.lcd.height=1\n")
        XCTAssertFalse(AvdDisplayRepair.hasBackup(avdName: "Test", avdHome: avdHome))
        XCTAssertFalse(AvdDisplayRepair.restoreBackup(avdName: "Test", avdHome: avdHome))
        XCTAssertFalse(AvdDisplayRepair.restoreDisplaySize(avdName: "Test", avdHome: avdHome))
    }

    /// Undoing the repair must not revert edits made since the backup (the
    /// backup is the first one ever taken): only the LCD keys go back.
    func testRestoreDisplaySizeKeepsLaterEdits() {
        writeConfig("hw.lcd.width=2208\r\nhw.lcd.height=2092\r\nhw.ramSize=2048\r\n")
        let fold = skin(display: CGSize(width: 2208, height: 1840))
        _ = AvdDisplayRepair.repair(avdName: "Test", skin: fold, avdHome: avdHome)
        XCTAssertTrue(AvdDisplayRepair.hasBackup(avdName: "Test", avdHome: avdHome))
        // The user raises the RAM afterwards.
        writeConfig("hw.lcd.width=2208\r\nhw.lcd.height=1840\r\nhw.ramSize=4096\r\n")

        XCTAssertTrue(AvdDisplayRepair.restoreDisplaySize(avdName: "Test", avdHome: avdHome))

        XCTAssertEqual(readConfig(), "hw.lcd.width=2208\r\nhw.lcd.height=2092\r\nhw.ramSize=4096\r\n")
    }

    func testPreservesCRLFLineEndings() {
        writeConfig("hw.lcd.width=2208\r\nhw.lcd.height=2092\r\n")
        XCTAssertEqual(
            AvdDisplayRepair.repair(
                avdName: "Test",
                skin: skin(display: CGSize(width: 2208, height: 1840)),
                avdHome: avdHome
            ),
            .repaired(
                from: CGSize(width: 2208, height: 2092),
                to: CGSize(width: 2208, height: 1840)
            )
        )
        XCTAssertEqual(readConfig(), "hw.lcd.width=2208\r\nhw.lcd.height=1840\r\n")
    }
}
