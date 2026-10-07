import ImageIO
import XCTest
@testable import DeviceHubProKit

/// The APK icon pipeline against real bytes: `aapt2 dump badging` output
/// (build-tools 37.0.0), `unzip -Z1` listings, compiled adaptive-icon XML
/// and `resources.arsc`, from APKs pulled read-only off an API 37 emulator
/// (see `LogcatSdkApkFixtures`). Expected values come from `aapt2 dump
/// xmltree` / `aapt2 dump resources` of the same APKs (kept next to them).
///
/// `BookmarkProvider.apk` (AOSP, 21 KB) is the complete APK: a raster icon
/// at three densities and a platform-built `resources.arsc` whose type
/// chunks use 16-bit offsets and whose entries are all compact
/// (`FLAG_COMPACT`), as every system app built since Android 14.
final class ApkRealOutputTests: XCTestCase {
    private let bookmarkProvider = "BookmarkProvider.apk"
    private let bookmarkIconID: UInt32 = 0x7F01_0000

    // MARK: - aapt2 dump badging

    func testBadgingOfAnAdaptiveIconApp() throws {
        let badging = try LogcatSdkApkFixtures.text("aapt2-dump-badging-Camera2.txt")
        XCTAssertEqual(ApkIconParsing.iconPath(fromBadging: badging), "res/mipmap-anydpi-v21/logo_camera_color.xml")
        XCTAssertEqual(ApkIconParsing.metadata(fromBadging: badging), ApkMetadata(
            package: "com.android.camera2",
            versionCode: "20002000",
            versionName: "2.0.002",
            label: "Camera"
        ))
    }

    /// aapt2 resolves density 320 to the hdpi file when no xhdpi exists.
    func testBadgingWithLegacyDrawableDensities() throws {
        let badging = try LogcatSdkApkFixtures.text("aapt2-dump-badging-MusicFX.txt")
        XCTAssertEqual(ApkIconParsing.iconPath(fromBadging: badging), "res/drawable-hdpi-v4/icon.png")
        XCTAssertEqual(ApkIconParsing.metadata(fromBadging: badging), ApkMetadata(
            package: "com.android.musicfx",
            versionCode: "10400",
            versionName: "1.4",
            label: "MusicFX"
        ))
    }

    /// An app without an icon prints `icon=''` and no `application-icon-*`.
    func testBadgingWithoutAnIcon() throws {
        let badging = try LogcatSdkApkFixtures.text("aapt2-dump-badging-BasicDreams.txt")
        XCTAssertNil(ApkIconParsing.iconPath(fromBadging: badging))
        XCTAssertEqual(ApkIconParsing.label(fromBadging: badging), "Basic Daydreams")
    }

    /// The Device Hub Pro verifier (AGP-built): every real density names the
    /// adaptive XML, plus the 65534 (anydpi) pseudo-density.
    func testBadgingOfTheVerifierApp() throws {
        let badging = try LogcatSdkApkFixtures.text("aapt2-dump-badging-verifier.txt")
        XCTAssertEqual(ApkIconParsing.iconPath(fromBadging: badging), "res/mipmap-anydpi-v26/ic_launcher.xml")
        XCTAssertEqual(ApkIconParsing.metadata(fromBadging: badging), ApkMetadata(
            package: "com.devicehubpro.verifier",
            versionCode: "1",
            versionName: "1.0",
            label: "Device Hub Pro Verifier"
        ))
    }

    /// aapt2 37 prints labels unescaped: localized labels carry apostrophes
    /// (`'Comunicacions de l'operador'`); the default label still wins.
    func testBadgingLabelsWithApostrophes() throws {
        let badging = try LogcatSdkApkFixtures.text("aapt2-dump-badging-CarrierDefaultApp.txt")
        XCTAssertEqual(ApkIconParsing.label(fromBadging: badging), "Carrier Communications")
        XCTAssertEqual(ApkIconParsing.iconPath(fromBadging: badging), "res/mipmap/ic_launcher_android.png")

        let catalan = try XCTUnwrap(
            badging.split(separator: "\n").first { $0.hasPrefix("application-label-ca:") }.map(String.init)
        )
        XCTAssertEqual(catalan, "application-label-ca:'Comunicacions de l'operador'")
        XCTAssertEqual(ApkIconParsing.label(fromBadging: catalan), "Comunicacions de l'operador")
    }

    // MARK: - unzip -Z1

    /// Camera2's mipmaps are shortcut artwork (`ic_launcher_gallery`) and the
    /// adaptive foreground layer; neither is a launcher icon, so the scan
    /// yields nothing and the XML's layers are resolved instead.
    func testMipmapScanOfARealListingSkipsNonLauncherArtwork() throws {
        let listing = try LogcatSdkApkFixtures.text("unzip-Z1-Camera2.txt")
        XCTAssertEqual(listing.split(separator: "\n").count, 1053)
        XCTAssertTrue(listing.contains("res/mipmap-xhdpi-v4/ic_launcher_gallery.png\n"))
        XCTAssertNil(ApkIconExtractor.highestDensityMipmap(inListing: listing))
    }

    // MARK: - Compiled adaptive-icon XML

    func testAdaptiveIconLayersOfRealCompiledXML() throws {
        let camera = try XCTUnwrap(AdaptiveIconManifest(
            data: try LogcatSdkApkFixtures.data("Camera2-res-mipmap-anydpi-v21-logo_camera_color.xml")
        ))
        XCTAssertEqual(camera.references, [
            .init(layer: .background, drawable: .resource(0x7F06_001A)),
            .init(layer: .foreground, drawable: .resource(0x7F0D_0002)),
        ])

        let verifier = try XCTUnwrap(AdaptiveIconManifest(
            data: try LogcatSdkApkFixtures.data("verifier-res-mipmap-anydpi-v26-ic_launcher.xml")
        ))
        XCTAssertEqual(verifier.references, [
            .init(layer: .background, drawable: .resource(0x7F06_0036)),
            .init(layer: .foreground, drawable: .resource(0x7F08_005F)),
        ])

        let egg = try XCTUnwrap(AdaptiveIconManifest(
            data: try LogcatSdkApkFixtures.data("EasterEgg-res-drawable-android16_patch_adaptive.xml")
        ))
        XCTAssertEqual(egg.references, [
            .init(layer: .background, drawable: .resource(0x7F05_000A)),
            .init(layer: .foreground, drawable: .resource(0x7F05_000B)),
            .init(layer: .monochrome, drawable: .resource(0x7F05_000C)),
        ])

        // The ids above are the ones aapt2 prints for the same files.
        let xmltree = try LogcatSdkApkFixtures.text("aapt2-dump-xmltree-Camera2-logo_camera_color.txt")
        XCTAssertTrue(xmltree.contains("android:drawable(0x01010199)=@0x7f06001a"))
        XCTAssertTrue(xmltree.contains("android:drawable(0x01010199)=@0x7f0d0002"))
    }

    // MARK: - resources.arsc

    /// A platform-built table: 16-bit entry offsets and compact entries,
    /// which carry the value's type in the flags' high byte and its data in
    /// place of the key reference. Reading only full entries resolved
    /// nothing in any system APK (Camera2's adaptive foreground included).
    func testCompactEntriesOfARealPlatformTable() throws {
        let arsc = try archiveMember("resources.arsc", of: bookmarkProvider)
        let encoding = try firstTypeChunkEncoding(of: arsc)
        XCTAssertEqual(encoding.chunkFlags, 0x02, "FLAG_OFFSET16")
        XCTAssertEqual(encoding.entryFlags & 0x0008, 0x0008, "FLAG_COMPACT")

        let table = try XCTUnwrap(ApkResourceTable(data: arsc))
        // `aapt2 dump resources`: mipmap/ic_launcher_shortcut_browser_bookmark
        // in (mdpi), (hdpi) and (xhdpi).
        let dump = try LogcatSdkApkFixtures.text("aapt2-dump-resources-BookmarkProvider.txt")
        XCTAssertTrue(dump.contains("resource 0x7f010000 mipmap/ic_launcher_shortcut_browser_bookmark"))
        XCTAssertEqual(table.filePaths(for: bookmarkIconID), [
            .init(path: "res/mipmap-xhdpi-v4/ic_launcher_shortcut_browser_bookmark.png", density: 320),
            .init(path: "res/mipmap-hdpi-v4/ic_launcher_shortcut_browser_bookmark.png", density: 240),
            .init(path: "res/mipmap-mdpi-v4/ic_launcher_shortcut_browser_bookmark.png", density: 160),
        ])
        XCTAssertNil(table.color(for: bookmarkIconID))
    }

    // MARK: - End to end

    /// The whole pipeline on the real APK with aapt2's real badging replayed:
    /// the densest raster is cached under `<package>-<versionCode>.png`,
    /// byte for byte.
    func testIconOfARealApkWithReplayedBadging() async throws {
        let directory = try LogcatSdkApkFixtures.temporaryDirectory(self, prefix: "apk-real")
        let badging = LogcatSdkApkFixtures.url("aapt2-dump-badging-BookmarkProvider.txt")
        let tool = try LogcatSdkApkFixtures.script("""
            #!/bin/sh
            cat "\(badging.path)"
            """, named: "aapt2", in: directory)
        try await assertBookmarkProviderIcon(tool: tool, cache: directory.appendingPathComponent("cache"))

        let metadata = try await ApkIconExtractor.metadata(
            forAPKAt: LogcatSdkApkFixtures.url(bookmarkProvider),
            tool: tool
        )
        XCTAssertEqual(metadata, ApkMetadata(
            package: "com.android.bookmarkprovider",
            versionCode: "37",
            versionName: "17",
            label: "Bookmark Provider"
        ))
    }

    /// The same with the SDK's own aapt2, when one is installed.
    func testIconOfARealApkWithTheInstalledAapt2() async throws {
        guard let tool = ApkToolLocator.locate() else {
            throw XCTSkip("aapt2 not installed")
        }
        let directory = try LogcatSdkApkFixtures.temporaryDirectory(self, prefix: "apk-real-aapt2")
        try await assertBookmarkProviderIcon(tool: tool, cache: directory)
    }

    // MARK: - Helpers

    private func assertBookmarkProviderIcon(tool: URL, cache: URL) async throws {
        let icon = try await ApkIconExtractor.icon(
            forAPKAt: LogcatSdkApkFixtures.url(bookmarkProvider),
            cacheDirectory: cache,
            tool: tool
        )
        let url = try XCTUnwrap(icon)
        XCTAssertEqual(url.lastPathComponent, "com.android.bookmarkprovider-37.png")
        let cached = try Data(contentsOf: url)
        XCTAssertEqual(
            cached,
            try archiveMember("res/mipmap-xhdpi-v4/ic_launcher_shortcut_browser_bookmark.png", of: bookmarkProvider)
        )
        XCTAssertEqual(cached.count, 5600)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(cached as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 96)
        XCTAssertEqual(image.height, 96)
    }

    /// An archive member's bytes, read with the system `unzip`.
    private func archiveMember(_ member: String, of apk: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", LogcatSdkApkFixtures.url(apk).path, member]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "unzip -p \(member)")
        return data
    }

    /// The flags of the table's first `RES_TABLE_TYPE_TYPE` chunk and of its
    /// first entry, walked independently of `ApkResourceTable`: table header,
    /// global string pool, package header, then the package's chunks.
    private func firstTypeChunkEncoding(of arsc: Data) throws -> (chunkFlags: UInt8, entryFlags: UInt16) {
        let bytes = [UInt8](arsc)
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
        XCTAssertEqual(u16(0), 0x0002)
        let pool = u16(2)
        let package = pool + u32(pool + 4)
        XCTAssertEqual(u16(package), 0x0200)
        var chunk = package + u16(package + 2)
        while chunk < package + u32(package + 4) {
            if u16(chunk) == 0x0201 {
                let flags = bytes[chunk + 9]
                let headerSize = u16(chunk + 2)
                let entriesStart = chunk + u32(chunk + 16)
                let firstOffset = u16(chunk + headerSize) * 4 // FLAG_OFFSET16 slots
                return (flags, UInt16(u16(entriesStart + firstOffset + 2)))
            }
            chunk += u32(chunk + 4)
        }
        throw NoTypeChunk()
    }

    private struct NoTypeChunk: Error {}
}
