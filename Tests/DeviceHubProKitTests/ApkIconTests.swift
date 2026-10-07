import XCTest
@testable import DeviceHubProKit

final class ApkIconTests: XCTestCase {
    /// A real 1x1 RGBA PNG. Extraction must copy the archive bytes verbatim,
    /// so tests compare against this payload, not against a re-encoded image.
    private let pngPayload = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    )!

    /// A minimal WebP header: `RIFF` + a size + `WEBP`.
    private var webpHeader: Data {
        Data("RIFF".utf8) + Data([0x00, 0x00, 0x00, 0x00]) + Data("WEBP".utf8)
    }

    // MARK: - Badging parsing

    func testIconPathPrefersHighestDensity() {
        let badging = """
            package: name='com.example.app' versionCode='42' versionName='1.2.3'
            application-label:'Example'
            application-icon-160:'res/mipmap-mdpi/ic_launcher.png'
            application-icon-240:'res/mipmap-hdpi/ic_launcher.png'
            application-icon-320:'res/mipmap-xhdpi/ic_launcher.png'
            application-icon-480:'res/mipmap-xxhdpi/ic_launcher.png'
            application-icon-640:'res/mipmap-xxxhdpi/ic_launcher.png'
            icon:'res/mipmap-xxxhdpi/ic_launcher.png'
            """
        XCTAssertEqual(
            ApkIconParsing.iconPath(fromBadging: badging),
            "res/mipmap-xxxhdpi/ic_launcher.png"
        )
    }

    func testIconPathIgnoresPseudoDensities() {
        let badging = """
            application-icon-160:'res/mipmap-mdpi/ic_launcher.png'
            application-icon-65534:'res/mipmap-anydpi-v26/ic_launcher.xml'
            application-icon-65535:'res/mipmap-anydpi-v26/ic_launcher.xml'
            """
        XCTAssertEqual(
            ApkIconParsing.iconPath(fromBadging: badging),
            "res/mipmap-mdpi/ic_launcher.png"
        )
    }

    func testIconPathUsesPseudoDensityWithoutRealOnes() {
        let badging = "application-icon-65535:'res/drawable/icon'\n"
        XCTAssertEqual(ApkIconParsing.iconPath(fromBadging: badging), "res/drawable/icon")
    }

    func testIconPathFallsBackToPlainIcon() {
        let badging = """
            package: name='com.legacy.app' versionCode='7' versionName='0.7'
            icon:'res/drawable-hdpi/icon.png'
            """
        XCTAssertEqual(ApkIconParsing.iconPath(fromBadging: badging), "res/drawable-hdpi/icon.png")
    }

    func testIconPathIsNilWithoutIcon() {
        let badging = """
            package: name='com.example.automation.server' versionCode='273' versionName='10.6.1'
            application-label:'Automation Server'
            """
        XCTAssertNil(ApkIconParsing.iconPath(fromBadging: badging))
    }

    func testPackageLabelAndVersions() {
        let badging = """
            package: name='com.example.app' versionCode='42' versionName='1.2.3' platformBuildVersionName='16'
            application-label:'Example'
            application-label-de:'Beispiel'
            """
        XCTAssertEqual(ApkIconParsing.packageName(fromBadging: badging), "com.example.app")
        XCTAssertEqual(ApkIconParsing.label(fromBadging: badging), "Example")
        XCTAssertEqual(ApkIconParsing.versionCode(fromBadging: badging), "42")
        XCTAssertEqual(ApkIconParsing.versionName(fromBadging: badging), "1.2.3")
    }

    func testLabelFallsBackToLocalizedLabel() {
        let badging = """
            package: name='com.example.app' versionCode='42'
            application-label-de:'Beispiel'
            """
        XCTAssertEqual(ApkIconParsing.label(fromBadging: badging), "Beispiel")
    }

    /// aapt2 reports empty attributes for some APKs (observed on an automation
    /// server test APK); an empty string must not become a cache key.
    func testEmptyVersionAttributesAreNil() {
        let badging = """
            package: name='com.example.automation.server.test' versionCode='' versionName=''
            """
        XCTAssertNil(ApkIconParsing.versionCode(fromBadging: badging))
        XCTAssertNil(ApkIconParsing.versionName(fromBadging: badging))
    }

    // MARK: - Metadata

    func testMetadataParsesIdentityFields() {
        let badging = """
            package: name='com.example.app' versionCode='42' versionName='1.2.3' platformBuildVersionName='16'
            application-label:'Example'
            """
        let metadata = ApkIconParsing.metadata(fromBadging: badging)
        XCTAssertEqual(metadata.package, "com.example.app")
        XCTAssertEqual(metadata.versionCode, "42")
        XCTAssertEqual(metadata.versionName, "1.2.3")
        XCTAssertEqual(metadata.label, "Example")
    }

    func testMetadataWithoutIdentityLinesIsEmpty() {
        let metadata = ApkIconParsing.metadata(
            fromBadging: "application-icon-160:'res/mipmap-mdpi/ic_launcher.png'\n"
        )
        XCTAssertNil(metadata.package)
        XCTAssertNil(metadata.versionCode)
        XCTAssertNil(metadata.versionName)
        XCTAssertNil(metadata.label)
    }

    func testExtractorMetadataReadsBadgingOnce() async throws {
        let harness = try makeHarness(badging: Self.multiDensityBadging)

        let metadata = try await ApkIconExtractor.metadata(forAPKAt: harness.apk, tool: harness.tool)

        XCTAssertEqual(metadata.package, "com.example.app")
        XCTAssertEqual(metadata.versionCode, "42")
        XCTAssertEqual(metadata.versionName, "1.2.3")
        XCTAssertEqual(metadata.label, "Example")
        XCTAssertEqual(invocationCount(harness.marker), 1)
    }

    func testMetadataMissingToolThrowsTypedError() async throws {
        let directory = try temporaryDirectory()
        do {
            _ = try await ApkIconExtractor.metadata(
                forAPKAt: directory.appendingPathComponent("app.apk"),
                tool: directory.appendingPathComponent("aapt2")
            )
            XCTFail("expected toolNotFound")
        } catch ApkIconError.toolNotFound {
        }
    }

    func testMetadataBadgingFailureThrowsTypedError() async throws {
        let harness = try makeHarness(
            badging: "",
            exitCode: 1,
            stderr: "bad apk"
        )
        do {
            _ = try await ApkIconExtractor.metadata(forAPKAt: harness.apk, tool: harness.tool)
            XCTFail("expected badgingFailed")
        } catch ApkIconError.badgingFailed(let exitCode, let message) {
            XCTAssertEqual(exitCode, 1)
            XCTAssertEqual(message, "bad apk")
        }
    }

    // MARK: - Locator

    func testLocatorHonorsEnvironmentOverride() throws {
        let directory = try temporaryDirectory()
        let script = try executableScript(in: directory, named: "aapt2", content: "#!/bin/sh\n")
        let found = ApkToolLocator.locate(environment: [
            "DHP_AAPT2": script.path,
            "PATH": "/nonexistent",
        ])
        XCTAssertEqual(found?.path, script.path)
    }

    func testLocatorPicksNewestBuildToolsRevision() throws {
        let root = try temporaryDirectory()
        for revision in ["99.2.0", "99.10.0"] {
            _ = try executableScript(
                in: root.appendingPathComponent("build-tools/\(revision)", isDirectory: true),
                named: "aapt2",
                content: "#!/bin/sh\n"
            )
        }
        // A revision without an aapt2 binary must not shadow an older one.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("build-tools/100.0.0", isDirectory: true),
            withIntermediateDirectories: true
        )

        let found = ApkToolLocator.locate(environment: [
            "ANDROID_HOME": root.path,
            "PATH": "/nonexistent",
        ])
        XCTAssertEqual(
            found?.path,
            root.appendingPathComponent("build-tools/99.10.0/aapt2").path
        )
    }

    // MARK: - Extract and cache

    func testExtractsIconNamedByBadging() async throws {
        let harness = try makeHarness(badging: Self.multiDensityBadging)
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        let extracted = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )

        XCTAssertEqual(extracted?.lastPathComponent, "com.example.app-42.png")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(extracted)), pngPayload)
        // The app's name is kept beside its icon, for the Apps list.
        XCTAssertEqual(ApkIconExtractor.cachedLabel(forPackage: "com.example.app", version: "42", in: cache), "Example")
        XCTAssertNil(ApkIconExtractor.cachedLabel(forPackage: "com.example.other", version: "1", in: cache))
    }

    func testCacheHitKeepsExistingFile() async throws {
        let harness = try makeHarness(badging: Self.multiDensityBadging)
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        let firstResult = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )
        let first = try XCTUnwrap(firstResult)
        // A decodable raster that differs from the extracted payload, so the
        // hit is trusted and the file is left untouched.
        let sentinel = pngPayload + Data("already-cached".utf8)
        try sentinel.write(to: first)

        let second = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )

        XCTAssertEqual(second, first)
        XCTAssertEqual(try Data(contentsOf: first), sentinel, "a cache hit must not rewrite the file")
        // Badging still runs to derive the package/version key; only the
        // archive extraction is skipped.
        XCTAssertEqual(invocationCount(harness.marker), 2)
    }

    func testPoisonedCacheFileIsDeletedAndReextracted() async throws {
        // A pre-fix build cached a non-raster payload (an adaptive XML named
        // as the icon) under the `.png` name. The hit must sniff it, delete
        // it and fall through to extraction instead of returning garbage and
        // driving every later reader into a permanent failure.
        let harness = try makeHarness(badging: Self.multiDensityBadging)
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)
        let cacheFile = ApkIconExtractor.cacheFileURL(
            forPackage: "com.example.app",
            version: "42",
            in: cache
        )
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("<adaptive-icon/>".utf8).write(to: cacheFile)

        let extracted = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )

        XCTAssertEqual(extracted, cacheFile)
        XCTAssertEqual(
            try Data(contentsOf: XCTUnwrap(extracted)),
            pngPayload,
            "the poisoned cache file must be replaced by the freshly extracted raster"
        )
    }

    func testTruncatedCacheFileIsDeletedAndReextracted() async throws {
        // A truncated PNG carries the magic bytes but does not decode. The
        // hit must not trust it: delete and fall through to extraction.
        let harness = try makeHarness(badging: Self.multiDensityBadging)
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)
        let cacheFile = ApkIconExtractor.cacheFileURL(
            forPackage: "com.example.app",
            version: "42",
            in: cache
        )
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: cacheFile)

        let extracted = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )

        XCTAssertEqual(extracted, cacheFile)
        XCTAssertEqual(
            try Data(contentsOf: XCTUnwrap(extracted)),
            pngPayload,
            "the truncated cache file must be replaced by the freshly extracted raster"
        )
    }

    func testCacheKeyUsesVersionCodeThenAPKStem() async throws {
        let badging = """
            package: name='com.example.automation.server.test' versionCode='' versionName=''
            application-icon-160:'res/icon.png'
            """
        let harness = try makeHarness(
            badging: badging,
            name: "automation-server-test.apk",
            entries: ["res/icon.png": pngPayload]
        )
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        let extracted = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )

        XCTAssertEqual(
            extracted?.lastPathComponent,
            "com.example.automation.server.test-automation-server-test.png"
        )
    }

    func testCacheFileURLSanitizesTheVersion() {
        let directory = URL(fileURLWithPath: "/tmp/cache", isDirectory: true)
        XCTAssertEqual(
            ApkIconExtractor.cacheFileURL(
                forPackage: "com.example.app",
                version: "2.2.9",
                in: directory
            ).lastPathComponent,
            "com.example.app-2.2.9.png"
        )
        XCTAssertEqual(
            ApkIconExtractor.cacheFileURL(
                forPackage: "com.example.app",
                version: "23.18.18 (190408)",
                in: directory
            ).lastPathComponent,
            "com.example.app-23.18.18__190408_.png"
        )
    }

    func testAdaptiveIconFallsBackToMipmapRaster() async throws {
        let badging = """
            package: name='com.example.app' versionCode='42' versionName='1.2.3'
            application-icon-640:'res/mipmap-anydpi-v26/ic_launcher.xml'
            """
        let mdpi = Data("mdpi-raster".utf8)
        let harness = try makeHarness(
            badging: badging,
            entries: [
                "res/mipmap-anydpi-v26/ic_launcher.xml": Data("<adaptive-icon/>".utf8),
                "res/mipmap-mdpi/ic_launcher.png": mdpi,
                "res/mipmap-xxxhdpi/ic_launcher.png": pngPayload,
            ]
        )
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        let extracted = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )

        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(extracted)), pngPayload)
    }

    func testAdaptiveIconFindsVersionQualifiedMipmap() async throws {
        // Compiled APKs carry a version qualifier on density buckets
        // (`mipmap-xxxhdpi-v4`), the shape most adaptive-icon apps ship.
        let badging = """
            package: name='com.example.app' versionCode='42' versionName='1.2.3'
            application-icon-640:'res/mipmap-anydpi-v26/ic_launcher.xml'
            """
        let harness = try makeHarness(
            badging: badging,
            entries: [
                "res/mipmap-anydpi-v26/ic_launcher.xml": Data("<adaptive-icon/>".utf8),
                "res/mipmap-mdpi-v4/ic_launcher.png": Data("mdpi-raster".utf8),
                "res/mipmap-xxxhdpi-v4/ic_launcher.png": pngPayload,
            ]
        )
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        let extracted = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )

        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(extracted)), pngPayload)
    }

    func testAdaptiveIconRejectsNonLauncherMipmaps() async throws {
        // camera2-style APK: badging names the adaptive XML, but the only
        // raster is shortcut artwork (`ic_launcher_gallery`), not the app
        // icon. The adaptive fallback accepts only the exact launcher stems,
        // so the extractor must return nil (the caller keeps the SF tile)
        // instead of extracting the gallery glyph.
        let badging = """
            package: name='com.android.camera2' versionCode='20002000' versionName='2.0.0'
            application-icon-640:'res/mipmap-anydpi-v26/ic_launcher.xml'
            """
        let harness = try makeHarness(
            badging: badging,
            entries: [
                "res/mipmap-anydpi-v26/ic_launcher.xml": Data("<adaptive-icon/>".utf8),
                "res/mipmap-xhdpi-v4/ic_launcher_gallery.png": pngPayload,
            ]
        )
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        let extracted = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )

        XCTAssertNil(extracted)
    }

    func testAdaptiveIconIgnoresLayerRasters() async throws {
        // Adaptive layers are not a usable icon on their own: a lone
        // foreground is mostly transparent, so the SF tile is the better
        // answer.
        let badging = """
            package: name='com.example.app' versionCode='42' versionName='1.2.3'
            application-icon-640:'res/mipmap-anydpi-v26/ic_launcher.xml'
            """
        let harness = try makeHarness(
            badging: badging,
            entries: [
                "res/mipmap-anydpi-v26/ic_launcher.xml": Data("<adaptive-icon/>".utf8),
                "res/mipmap-xxxhdpi/ic_launcher_foreground.png": Data("foreground".utf8),
                "res/mipmap-xxxhdpi/ic_launcher_background.png": Data("background".utf8),
            ]
        )
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        let extracted = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )

        XCTAssertNil(extracted)
    }

    func testNoIconLinesReturnNil() async throws {
        let badging = """
            package: name='com.example.app' versionCode='42' versionName='1.2.3'
            application-label:'Example'
            """
        let harness = try makeHarness(badging: badging, entries: ["res/icon.png": pngPayload])
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        let extracted = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )

        XCTAssertNil(extracted)
    }

    func testAdaptiveIconWithoutRasterReturnsNil() async throws {
        let badging = """
            package: name='com.example.app' versionCode='42' versionName='1.2.3'
            application-icon-640:'res/mipmap-anydpi-v26/ic_launcher.xml'
            """
        let harness = try makeHarness(
            badging: badging,
            entries: [
                "res/mipmap-anydpi-v26/ic_launcher.xml": Data("<adaptive-icon/>".utf8),
            ]
        )
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        let extracted = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )

        XCTAssertNil(extracted)
    }

    func testMissingToolThrowsTypedError() async throws {
        let harness = try makeHarness(badging: Self.multiDensityBadging)
        let missing = harness.directory.appendingPathComponent("no-such-aapt2")
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        do {
            _ = try await ApkIconExtractor.icon(
                forAPKAt: harness.apk,
                cacheDirectory: cache,
                tool: missing
            )
            XCTFail("expected toolNotFound")
        } catch ApkIconError.toolNotFound {
            // Expected.
        }
    }

    func testBadgingFailureThrowsTypedError() async throws {
        let harness = try makeHarness(
            badging: Self.multiDensityBadging,
            exitCode: 1,
            stderr: "boom: not a valid APK"
        )
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        do {
            _ = try await ApkIconExtractor.icon(
                forAPKAt: harness.apk,
                cacheDirectory: cache,
                tool: harness.tool
            )
            XCTFail("expected badgingFailed")
        } catch ApkIconError.badgingFailed(let exitCode, let message) {
            XCTAssertEqual(exitCode, 1)
            XCTAssertTrue(message.contains("boom"), message)
        }
    }

    func testMissingArchiveEntryThrowsTypedError() async throws {
        // Badging names a density variant the archive does not contain — as
        // with split APKs; the caller must hear about it, not get a bad file.
        let harness = try makeHarness(
            badging: Self.multiDensityBadging,
            entries: ["res/mipmap-mdpi/ic_launcher.png": pngPayload]
        )
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        do {
            _ = try await ApkIconExtractor.icon(
                forAPKAt: harness.apk,
                cacheDirectory: cache,
                tool: harness.tool
            )
            XCTFail("expected extractionFailed")
        } catch ApkIconError.extractionFailed(let entry, _) {
            XCTAssertEqual(entry, "res/mipmap-xxxhdpi/ic_launcher.png")
        }
    }

    // MARK: - Payload sniffing

    func testRasterPayloadRecognizesPNGJPEGAndWebP() {
        XCTAssertTrue(ApkIconExtractor.isRasterPayload(pngPayload))
        XCTAssertTrue(ApkIconExtractor.isRasterPayload(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x42])))
        XCTAssertTrue(ApkIconExtractor.isRasterPayload(webpHeader))
    }

    func testRasterPayloadRecognizesGIFAndBMP() {
        XCTAssertTrue(ApkIconExtractor.isRasterPayload(Data("GIF87a".utf8) + Data([0x01, 0x02])))
        XCTAssertTrue(ApkIconExtractor.isRasterPayload(Data("GIF89a".utf8) + Data([0x01, 0x02])))
        XCTAssertTrue(ApkIconExtractor.isRasterPayload(Data("BM".utf8) + Data(repeating: 0, count: 10)))
    }

    func testRasterPayloadRejectsNonRasters() {
        XCTAssertFalse(ApkIconExtractor.isRasterPayload(Data("<vector/>".utf8)))
        XCTAssertFalse(ApkIconExtractor.isRasterPayload(Data("RIFF".utf8)))
        XCTAssertFalse(ApkIconExtractor.isRasterPayload(Data()))
        XCTAssertFalse(ApkIconExtractor.isRasterPayload(Data("mdpi-raster".utf8)))
        XCTAssertFalse(ApkIconExtractor.isRasterPayload(Data("GIF".utf8)))
        XCTAssertFalse(ApkIconExtractor.isRasterPayload(Data("B".utf8)))
    }

    func testBogusRasterPayloadIsNotCached() async throws {
        // Badging names a `.png` entry whose bytes are really an XML adaptive
        // icon; caching it would leave a bogus `.png` that every later reader
        // decodes as nil, poisoning the version.
        let badging = """
            package: name='com.example.app' versionCode='42' versionName='1.2.3'
            icon:'res/drawable/ic_png.png'
            """
        let harness = try makeHarness(
            badging: badging,
            entries: ["res/drawable/ic_png.png": Data("<vector/>".utf8)]
        )
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        let extracted = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )

        XCTAssertNil(extracted)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: ApkIconExtractor.cacheFileURL(
                    forPackage: "com.example.app",
                    version: "42",
                    in: cache
                ).path
            ),
            "a non-raster payload must not be written to the cache"
        )
    }

    func testTruncatedRasterPayloadIsNotCached() async throws {
        // The bytes start with the PNG magic but are not a decodable image;
        // writing them would poison the version. The extraction must return
        // nil and leave no cache file.
        let badging = """
            package: name='com.example.app' versionCode='42' versionName='1.2.3'
            icon:'res/drawable/ic_png.png'
            """
        let harness = try makeHarness(
            badging: badging,
            entries: [
                "res/drawable/ic_png.png": Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            ]
        )
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        let extracted = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )

        XCTAssertNil(extracted)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: ApkIconExtractor.cacheFileURL(
                    forPackage: "com.example.app",
                    version: "42",
                    in: cache
                ).path
            ),
            "a truncated raster must not be written to the cache"
        )
    }

    // MARK: - Archive member guarding

    func testExactArchiveMemberRejectsWildcardsAndOptions() {
        XCTAssertTrue(ApkIconExtractor.isExactArchiveMember("res/mipmap-mdpi/ic_launcher.png"))
        XCTAssertFalse(ApkIconExtractor.isExactArchiveMember("res/drawable/*.png"))
        XCTAssertFalse(ApkIconExtractor.isExactArchiveMember("res/drawable/icon?.png"))
        XCTAssertFalse(ApkIconExtractor.isExactArchiveMember("res/drawable/[ab].png"))
        XCTAssertFalse(ApkIconExtractor.isExactArchiveMember("-o"))
        XCTAssertFalse(ApkIconExtractor.isExactArchiveMember(""))
    }

    func testExactArchiveMemberRejectsBackslashEscapes() {
        // Info-ZIP reads `\` as its pattern escape, so `a\*.png` is still a
        // wildcard to `unzip` even though `*` is behind the escape.
        XCTAssertFalse(ApkIconExtractor.isExactArchiveMember("res/drawable/icon\\.png"))
        XCTAssertFalse(ApkIconExtractor.isExactArchiveMember("res\\drawable\\icon.png"))
    }

    func testWildcardBadgingEntryIsNotExtracted() async throws {
        // `unzip` treats `*`, `?` and `[...]` as match patterns: a badging
        // entry with one could pull an unrelated archive member into the icon
        // cache. Only literal members are acceptable.
        let badging = """
            package: name='com.example.app' versionCode='42' versionName='1.2.3'
            icon:'res/drawable/*.png'
            """
        let harness = try makeHarness(
            badging: badging,
            entries: ["res/drawable/icon.png": pngPayload]
        )
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        let extracted = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )

        XCTAssertNil(extracted)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: ApkIconExtractor.cacheFileURL(
                    forPackage: "com.example.app",
                    version: "42",
                    in: cache
                ).path
            )
        )
    }

    // MARK: - Adaptive icon resolution through the resource table

    /// These tests run against hand-built binary fixtures
    /// (`ApkFixture.resourceTable` and `ApkFixture.adaptiveIconXML`, shared
    /// with `ApkResourceParsingTests`) so they stay hermetic on machines with no
    /// device: the shapes mirror rasters pulled from real APKs — a shrunk release build's
    /// `res/BW.xml` whose foreground is a hidden `res/CH.png`, Chrome's sparse
    /// table with an extensionless `res/ima` WebP foreground. The opt-in
    /// `testLiveExtractionFromRunningEmulator` exercises the same code against
    /// a real device when one is attached.

    /// Shrunk-release-shaped: the adaptive XML's foreground is a resource-table entry
    /// whose rasters are hashed `res/*.png` files (no mipmap folder, no
    /// launcher stem) and the background is a plain color. The extractor must
    /// resolve the reference through `resources.arsc`, take the
    /// highest-density raster and composite it over the background color.
    func testAdaptiveIconResolvesResourceTableRasters() async throws {
        let badging = """
            package: name='com.example.app' versionCode='42' versionName='1.2.3'
            application-icon-640:'res/BW.xml'
            """
        let harness = try makeHarness(
            badging: badging,
            entries: [
                "resources.arsc": ApkFixture.resourceTable([
                    ApkFixture.Entry(id: 0x7F060062, density: 0, value: .color(0xFFD6E6F0)),
                    ApkFixture.Entry(id: 0x7F0800E4, density: 160, value: .file("res/bB.png")),
                    ApkFixture.Entry(id: 0x7F0800E4, density: 640, value: .file("res/CH.png")),
                ]),
                "res/BW.xml": ApkFixture.adaptiveIconXML(layers: [
                    (["background"], 0x7F060062),
                    (["foreground"], 0x7F0800E4),
                ]),
                "res/bB.png": Data("mdpi-raster".utf8),
                "res/CH.png": layeredForeground,
            ]
        )
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        let extracted = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )

        try assertAdaptiveIcon(extracted, corner: ApkFixture.Color(0xD6, 0xE6, 0xF0))
    }

    /// Both adaptive layers are rasters: the icon is the foreground drawn
    /// over the background, never the background alone — even when the
    /// background's raster sits at a higher density.
    func testAdaptiveIconCompositesForegroundOverBackgroundRaster() async throws {
        let badging = """
            package: name='com.example.app' versionCode='42' versionName='1.2.3'
            application-icon-640:'res/adaptive.xml'
            """
        let harness = try makeHarness(
            badging: badging,
            entries: [
                "resources.arsc": ApkFixture.resourceTable([
                    ApkFixture.Entry(id: 0x7F080001, density: 640, value: .file("res/background.png")),
                    ApkFixture.Entry(id: 0x7F080002, density: 160, value: .file("res/foreground.png")),
                ]),
                "res/adaptive.xml": ApkFixture.adaptiveIconXML(layers: [
                    (["background"], 0x7F080001),
                    (["foreground"], 0x7F080002),
                ]),
                "res/background.png": ApkFixture.solidPNG(size: 24, Self.blue),
                "res/foreground.png": layeredForeground,
            ]
        )
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        let extracted = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )

        try assertAdaptiveIcon(extracted, corner: Self.blue)
    }

    /// A vector foreground cannot be rasterized here. The background raster
    /// alone (a flat square or pattern) is not the app's icon, so there is
    /// no icon at all — the caller keeps its placeholder instead of caching
    /// a colored square under the package's name.
    func testAdaptiveIconWithAVectorForegroundIsNotReplacedByItsBackground() async throws {
        let badging = """
            package: name='com.example.app' versionCode='42' versionName='1.2.3'
            application-icon-640:'res/adaptive.xml'
            """
        let harness = try makeHarness(
            badging: badging,
            entries: [
                "resources.arsc": ApkFixture.resourceTable([
                    ApkFixture.Entry(id: 0x7F080001, density: 640, value: .file("res/bg.png")),
                    ApkFixture.Entry(id: 0x7F080002, density: 0, value: .file("res/fg.xml")),
                ]),
                "res/adaptive.xml": ApkFixture.adaptiveIconXML(layers: [
                    (["background"], 0x7F080001),
                    (["foreground"], 0x7F080002),
                    (["monochrome"], 0x7F080001),
                ]),
                "res/bg.png": ApkFixture.solidPNG(size: 24, Self.blue),
                "res/fg.xml": Data("<vector/>".utf8),
            ]
        )
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        let extracted = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )

        XCTAssertNil(extracted)
    }

    /// `<background android:drawable="#FF102030"/>`: a literal color layer.
    func testAdaptiveIconCompositesALiteralColorBackground() async throws {
        let badging = """
            package: name='com.example.app' versionCode='42' versionName='1.2.3'
            application-icon-640:'res/adaptive.xml'
            """
        let harness = try makeHarness(
            badging: badging,
            entries: [
                "resources.arsc": ApkFixture.resourceTable([
                    ApkFixture.Entry(id: 0x7F080002, density: 640, value: .file("res/fg.png")),
                ]),
                "res/adaptive.xml": ApkFixture.adaptiveIconXML(drawables: [
                    (["background"], .color(0xFF102030)),
                    (["foreground"], .reference(0x7F080002)),
                ]),
                "res/fg.png": layeredForeground,
            ]
        )
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        let extracted = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )

        try assertAdaptiveIcon(extracted, corner: ApkFixture.Color(0x10, 0x20, 0x30))
    }

    /// An icon XML that is not layered (one drawable in an `<inset>`) shows
    /// that drawable's raster itself, byte for byte.
    func testNonLayeredIconXMLShowsItsDrawable() async throws {
        let badging = """
            package: name='com.example.app' versionCode='42' versionName='1.2.3'
            application-icon-640:'res/inset.xml'
            """
        let harness = try makeHarness(
            badging: badging,
            entries: [
                "resources.arsc": ApkFixture.resourceTable([
                    ApkFixture.Entry(id: 0x7F080002, density: 640, value: .file("res/full.png")),
                ]),
                "res/inset.xml": ApkFixture.adaptiveIconXML(layers: [(["inset"], 0x7F080002)]),
                "res/full.png": pngPayload,
            ]
        )
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        let extracted = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )

        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(extracted)), pngPayload)
    }

    /// A shrunk release build nests the referenced drawable in an `<inset>` inside
    /// `<foreground>`; the nearest enclosing layer element is what counts.
    func testAdaptiveIconResolvesReferenceInsideLayerWrapper() async throws {
        let badging = """
            package: name='com.example.app' versionCode='42' versionName='1.2.3'
            application-icon-640:'res/adaptive.xml'
            """
        let harness = try makeHarness(
            badging: badging,
            entries: [
                "resources.arsc": ApkFixture.resourceTable([
                    ApkFixture.Entry(id: 0x7F0800E4, density: 640, value: .file("res/wrapped.png")),
                ]),
                "res/adaptive.xml": ApkFixture.adaptiveIconXML(layers: [
                    (["foreground", "inset"], 0x7F0800E4),
                ]),
                "res/wrapped.png": layeredForeground,
            ]
        )
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        let extracted = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )

        try assertAdaptiveIcon(extracted, corner: .clear)
    }

    /// A layer may name another resource reference (an alias) instead of a
    /// file; every hop resolves and the file at the end is extracted.
    func testAdaptiveIconResolvesAliasedReference() async throws {
        let badging = """
            package: name='com.example.app' versionCode='42' versionName='1.2.3'
            application-icon-640:'res/adaptive.xml'
            """
        let harness = try makeHarness(
            badging: badging,
            entries: [
                "resources.arsc": ApkFixture.resourceTable([
                    ApkFixture.Entry(id: 0x7F080001, density: 0, value: .reference(0x7F080002)),
                    ApkFixture.Entry(id: 0x7F080002, density: 640, value: .file("res/aliased.png")),
                ]),
                "res/adaptive.xml": ApkFixture.adaptiveIconXML(layers: [
                    (["foreground"], 0x7F080001),
                ]),
                "res/aliased.png": layeredForeground,
            ]
        )
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        let extracted = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )

        try assertAdaptiveIcon(extracted, corner: .clear)
    }

    /// A reference may name a vector XML at the densest bucket and a raster at
    /// a lower one. A vector cannot be shown, so the next candidate must win.
    func testAdaptiveIconFallsToRasterWhenDensestEntryIsNotARaster() async throws {
        let badging = """
            package: name='com.example.app' versionCode='42' versionName='1.2.3'
            application-icon-640:'res/adaptive.xml'
            """
        let harness = try makeHarness(
            badging: badging,
            entries: [
                "resources.arsc": ApkFixture.resourceTable([
                    ApkFixture.Entry(id: 0x7F080002, density: 640, value: .file("res/foreground.xml")),
                    ApkFixture.Entry(id: 0x7F080002, density: 320, value: .file("res/foreground.png")),
                ]),
                "res/adaptive.xml": ApkFixture.adaptiveIconXML(layers: [
                    (["foreground"], 0x7F080002),
                ]),
                "res/foreground.xml": Data("<vector/>".utf8),
                "res/foreground.png": layeredForeground,
            ]
        )
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        let extracted = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )

        try assertAdaptiveIcon(extracted, corner: .clear)
    }

    /// A split APK's resource table can name a file the base archive does not
    /// carry; the next candidate must be tried instead of failing the icon.
    func testAdaptiveIconSkipsMissingResourceFiles() async throws {
        let badging = """
            package: name='com.example.app' versionCode='42' versionName='1.2.3'
            application-icon-640:'res/adaptive.xml'
            """
        let harness = try makeHarness(
            badging: badging,
            entries: [
                "resources.arsc": ApkFixture.resourceTable([
                    ApkFixture.Entry(id: 0x7F080002, density: 640, value: .file("res/absent.png")),
                    ApkFixture.Entry(id: 0x7F080002, density: 320, value: .file("res/present.png")),
                ]),
                "res/adaptive.xml": ApkFixture.adaptiveIconXML(layers: [
                    (["foreground"], 0x7F080002),
                ]),
                "res/present.png": layeredForeground,
            ]
        )
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        let extracted = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )

        try assertAdaptiveIcon(extracted, corner: .clear)
    }

    /// Chrome-shaped: sparse type chunks (`FLAG_SPARSE`) and extensionless
    /// hashed file names; rasterness comes from the payload, not the name.
    func testAdaptiveIconResolvesSparseResourceTable() async throws {
        let badging = """
            package: name='com.example.browser' versionCode='700000000' versionName='140.0'
            application-icon-640:'res/r2e.xml'
            """
        let harness = try makeHarness(
            badging: badging,
            entries: [
                "resources.arsc": ApkFixture.resourceTable([
                    ApkFixture.Entry(id: 0x7F110002, density: 480, value: .file("res/EFE")),
                    ApkFixture.Entry(id: 0x7F110002, density: 640, value: .file("res/ima")),
                ], sparse: true),
                "res/r2e.xml": ApkFixture.adaptiveIconXML(layers: [
                    (["foreground"], 0x7F110002),
                ]),
                "res/EFE": webpHeader,
                "res/ima": layeredForeground,
            ]
        )
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        let extracted = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )

        try assertAdaptiveIcon(extracted, corner: .clear)
    }

    /// The offset16 encoding (`FLAG_OFFSET16`) stores entry offsets in
    /// 4-byte units as 16-bit values.
    func testAdaptiveIconResolvesOffset16ResourceTable() async throws {
        let badging = """
            package: name='com.example.app' versionCode='42' versionName='1.2.3'
            application-icon-640:'res/adaptive.xml'
            """
        let harness = try makeHarness(
            badging: badging,
            entries: [
                "resources.arsc": ApkFixture.resourceTable([
                    ApkFixture.Entry(id: 0x7F080002, density: 640, value: .file("res/offset.png")),
                ], offset16: true),
                "res/adaptive.xml": ApkFixture.adaptiveIconXML(layers: [
                    (["foreground"], 0x7F080002),
                ]),
                "res/offset.png": layeredForeground,
            ]
        )
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        let extracted = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )

        try assertAdaptiveIcon(extracted, corner: .clear)
    }

    /// Older toolchains encode string pools as UTF-16; both the resource
    /// table's global pool and the XML's pool must decode either way.
    func testAdaptiveIconResolvesUTF16StringPools() async throws {
        let badging = """
            package: name='com.example.app' versionCode='42' versionName='1.2.3'
            application-icon-640:'res/adaptive.xml'
            """
        let harness = try makeHarness(
            badging: badging,
            entries: [
                "resources.arsc": ApkFixture.resourceTable([
                    ApkFixture.Entry(id: 0x7F080002, density: 640, value: .file("res/utf16.png")),
                ], utf16: true),
                "res/adaptive.xml": ApkFixture.adaptiveIconXML(layers: [
                    (["foreground"], 0x7F080002),
                ], utf16: true),
                "res/utf16.png": layeredForeground,
            ]
        )
        let cache = harness.directory.appendingPathComponent("cache", isDirectory: true)

        let extracted = try await ApkIconExtractor.icon(
            forAPKAt: harness.apk,
            cacheDirectory: cache,
            tool: harness.tool
        )

        try assertAdaptiveIcon(extracted, corner: .clear)
    }

    // MARK: - Adaptive fixtures

    private static let red = ApkFixture.Color(220, 20, 60)
    private static let blue = ApkFixture.Color(30, 80, 200)

    /// A 12 px adaptive foreground layer: transparent, with an opaque red
    /// block over its centre (pixels 4…7), like real launcher foregrounds
    /// that keep their artwork inside the safe zone.
    private var layeredForeground: Data {
        ApkFixture.png(size: 12) { x, y in
            (4...7).contains(x) && (4...7).contains(y) ? Self.red : .clear
        }
    }

    /// Asserts `url` holds the composited adaptive icon of
    /// `layeredForeground`: the 8 px viewport (72 of the 108 dp canvas), the
    /// red artwork at its centre and `corner` — the background — where the
    /// foreground is transparent.
    private func assertAdaptiveIcon(
        _ url: URL?,
        corner: ApkFixture.Color,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try Data(contentsOf: XCTUnwrap(url, file: file, line: line))
        XCTAssertTrue(ApkIconExtractor.isDecodableRasterPayload(data), file: file, line: line)
        let centre = try XCTUnwrap(ApkFixture.decodePixel(data, x: 4, y: 4), file: file, line: line)
        XCTAssertEqual(centre.width, 8, file: file, line: line)
        XCTAssertEqual(centre.height, 8, file: file, line: line)
        assertColor(centre.color, Self.red, file: file, line: line)
        for (x, y) in [(0, 0), (7, 0), (0, 7), (7, 7)] {
            let pixel = try XCTUnwrap(ApkFixture.decodePixel(data, x: x, y: y), file: file, line: line)
            assertColor(pixel.color, corner, file: file, line: line)
        }
    }

    private func assertColor(
        _ actual: ApkFixture.Color,
        _ expected: ApkFixture.Color,
        file: StaticString,
        line: UInt
    ) {
        XCTAssertEqual(Int(actual.alpha), Int(expected.alpha), accuracy: 2, "\(actual) ≠ \(expected)", file: file, line: line)
        guard expected.alpha > 0 else { return }
        XCTAssertEqual(Int(actual.red), Int(expected.red), accuracy: 2, "\(actual) ≠ \(expected)", file: file, line: line)
        XCTAssertEqual(Int(actual.green), Int(expected.green), accuracy: 2, "\(actual) ≠ \(expected)", file: file, line: line)
        XCTAssertEqual(Int(actual.blue), Int(expected.blue), accuracy: 2, "\(actual) ≠ \(expected)", file: file, line: line)
    }

    // MARK: - Live check

    /// Set `DHP_LIVE_ICON=1` (and optionally `DHP_LIVE_ICON_SERIAL`,
    /// `DHP_LIVE_ICON_PACKAGE`, `DHP_LIVE_ICON_OUT`) to extract an
    /// icon from an APK pulled off a running emulator with the real toolchain.
    func testLiveExtractionFromRunningEmulator() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DHP_LIVE_ICON"] == "1" else {
            throw XCTSkip("set DHP_LIVE_ICON=1 to run the live APK icon check")
        }
        guard let adb = AdbClient.locate() else {
            throw XCTSkip("adb not installed")
        }
        let devices = try await adb.listDevices()
        let serial = environment["DHP_LIVE_ICON_SERIAL"]
            ?? devices.first(where: { $0.isOnline && $0.isEmulator })?.serial
        guard let serial, let device = devices.first(where: { $0.serial == serial }) else {
            throw XCTSkip("no running emulator")
        }
        let package: String?
        if let override = environment["DHP_LIVE_ICON_PACKAGE"], !override.isEmpty {
            package = override
        } else {
            package = try await adb.listPackages(serial: device.serial).first
        }
        guard let package else {
            throw XCTSkip("no third-party package on \(device.serial)")
        }
        guard let apkPath = try await adb.shell(serial: device.serial, ["pm", "path", package])
            .split(separator: "\n")
            .first
            .map({ $0.replacingOccurrences(of: "package:", with: "") })
        else {
            throw XCTSkip("pm path returned nothing for \(package)")
        }

        let directory = try temporaryDirectory()
        let apk = directory.appendingPathComponent("\(package).apk")
        try await adb.pull(serial: device.serial, remotePath: apkPath, to: apk)

        guard let tool = ApkToolLocator.locate(environment: environment) else {
            throw XCTSkip("aapt2 not installed")
        }
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        guard let icon = try await ApkIconExtractor.icon(
            forAPKAt: apk,
            cacheDirectory: cache,
            tool: tool
        ) else {
            XCTFail("no icon extracted from \(package) (\(apkPath))")
            return
        }

        let iconData = try Data(contentsOf: icon)
        let isPNG = iconData.prefix(8).elementsEqual(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        let isWebP = iconData.prefix(4).elementsEqual(Data("RIFF".utf8))
            && iconData.dropFirst(8).prefix(4).elementsEqual(Data("WEBP".utf8))
        XCTAssertTrue(isPNG || isWebP, "\(icon.path) is neither PNG nor WebP")

        if let outPath = environment["DHP_LIVE_ICON_OUT"], !outPath.isEmpty {
            let out = URL(fileURLWithPath: outPath)
            try? FileManager.default.removeItem(at: out)
            try iconData.write(to: out)
            print("live icon: \(icon.path) -> \(out.path)")
        } else {
            print("live icon: \(icon.path) (\(iconData.count) bytes)")
        }
    }

    // MARK: - Harness

    /// Fixture badging output of an APK with four density variants; aapt2
    /// resolves `icon:` to the highest one.
    private static let multiDensityBadging = """
        package: name='com.example.app' versionCode='42' versionName='1.2.3'
        application-label:'Example'
        application-icon-160:'res/mipmap-mdpi/ic_launcher.png'
        application-icon-240:'res/mipmap-hdpi/ic_launcher.png'
        application-icon-320:'res/mipmap-xhdpi/ic_launcher.png'
        application-icon-640:'res/mipmap-xxxhdpi/ic_launcher.png'
        icon:'res/mipmap-xxxhdpi/ic_launcher.png'
        """

    private struct Harness {
        let directory: URL
        let apk: URL
        let tool: URL
        let marker: URL
    }

    /// Builds a synthetic APK (a real zip) plus a fake `aapt2` shell script
    /// that prints `badging` and records every invocation in `marker`.
    private func makeHarness(
        badging: String,
        name: String = "app.apk",
        entries: [String: Data]? = nil,
        exitCode: Int32 = 0,
        stderr: String = ""
    ) throws -> Harness {
        let directory = try temporaryDirectory()
        let archiveEntries = entries ?? [
            "res/mipmap-mdpi/ic_launcher.png": Data("mdpi-raster".utf8),
            "res/mipmap-xxxhdpi/ic_launcher.png": pngPayload,
        ]
        let apk = try makeAPK(at: directory.appendingPathComponent(name), entries: archiveEntries)
        let marker = directory.appendingPathComponent("aapt2-invocations.txt")
        let tool = try executableScript(
            in: directory,
            named: "fake-aapt2",
            content: fakeAapt2Script(
                badging: badging,
                marker: marker,
                exitCode: exitCode,
                stderr: stderr
            )
        )
        return Harness(directory: directory, apk: apk, tool: tool, marker: marker)
    }

    private func fakeAapt2Script(
        badging: String,
        marker: URL,
        exitCode: Int32,
        stderr: String
    ) -> String {
        var script = """
            #!/bin/sh
            echo invoked >> "\(marker.path)"
            cat <<'BADGING'
            \(badging)
            BADGING
            """
        if !stderr.isEmpty {
            script += "\necho \"\(stderr)\" >&2"
        }
        script += "\nexit \(exitCode)\n"
        return script
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApkIconTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeAPK(at url: URL, entries: [String: Data]) throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("apk-staging-\(UUID().uuidString)", isDirectory: true)
        for (path, data) in entries {
            let file = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: file)
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-X", url.path] + entries.keys.sorted()
        process.currentDirectoryURL = staging
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "zip failed to build the fixture APK")
        return url
    }

    private func executableScript(in directory: URL, named name: String, content: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func invocationCount(_ marker: URL) -> Int {
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").count
    }
}
