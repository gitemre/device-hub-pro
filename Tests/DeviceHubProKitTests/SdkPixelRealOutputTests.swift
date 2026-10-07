import XCTest
@testable import DeviceHubProKit

/// `sdkmanager` output parsing and the Pixel image/min-API logic against
/// real bytes: `sdkmanager --list` and `sdkmanager --uninstall <missing>`
/// (cmdline-tools 22.0, stdout and stderr kept apart as `ProcessRunner`
/// reads them) and `devices/nexus.xml` from the cmdline-tools
/// `tools.sdklib.jar` (see `LogcatSdkApkFixtures`).
final class SdkPixelRealOutputTests: XCTestCase {
    private let listStdout = "sdkmanager-list.stdout.txt"
    private let listStderr = "sdkmanager-list.stderr.txt"

    // MARK: - sdkmanager --list

    /// All 327 system images of the `Available Packages:` table, in order;
    /// the `Installed packages:` table above and `Available Updates:` below
    /// contribute nothing. (Counted independently with awk over the table.)
    func testAvailableImagesOfARealListing() throws {
        let images = SdkmanagerParsing.availableImages(
            fromListOutput: try LogcatSdkApkFixtures.text(listStdout)
        )
        XCTAssertEqual(images.count, 327)
        XCTAssertEqual(images.first, SystemImage(
            package: "system-images;android-10;default;armeabi-v7a",
            api: "android-10",
            tag: "default",
            abi: "armeabi-v7a"
        ))
        XCTAssertEqual(images.last, SystemImage(
            package: "system-images;android-canary-20260909;google_apis_ps16k;x86_64",
            api: "android-canary-20260909",
            tag: "google_apis_ps16k",
            abi: "x86_64"
        ))
        let packages = Set(images.map(\.package))
        for package in [
            "system-images;android-37.1;google_apis_playstore_ps16k;arm64-v8a",
            "system-images;android-35-ext15;google_apis_playstore;arm64-v8a",
            "system-images;android-37.2-beta1;google_apis_ps16k;arm64-v8a",
            "system-images;android-CANARY;google_apis_playstore_ps16k;arm64-v8a",
            "system-images;android-36;android-wear-signed;arm64-v8a",
        ] {
            XCTAssertTrue(packages.contains(package), package)
        }
        XCTAssertEqual(images.count, packages.count, "the table lists every package once")
    }

    /// The listing opens with one LF-terminated line of `\r`-joined progress
    /// redraws that ends in `100% Computing updates...` and `\r\n`.
    func testProgressOfTheRealRedrawLine() throws {
        let stdout = try LogcatSdkApkFixtures.text(listStdout)
        let firstLine = try XCTUnwrap(stdout.split(separator: "\n", maxSplits: 1).first.map(String.init))
        XCTAssertTrue(firstLine.hasPrefix("Loading package information..."))
        XCTAssertEqual(SdkmanagerParsing.progress(from: firstLine), 1.0)

        let redraws = firstLine.split(separator: "\r").map(String.init)
        XCTAssertNil(SdkmanagerParsing.progress(from: redraws[0]))
        XCTAssertNil(SdkmanagerParsing.progress(from: redraws[1]))
        XCTAssertEqual(redraws[2].trimmingCharacters(in: .whitespaces),
                       "[=========                              ] 25% Loading local repository...")
        XCTAssertEqual(SdkmanagerParsing.progress(from: redraws[2]), 0.25)
        XCTAssertEqual(SdkmanagerParsing.progress(from: redraws[3]), 0.25)
        XCTAssertTrue(redraws[4].contains("26% Fetch remote repository..."))
        XCTAssertEqual(SdkmanagerParsing.progress(from: redraws[4]), 0.26)
    }

    /// The tool's deprecation banner (stderr) is chatter, not license text.
    func testTheRealDeprecationBannerIsNotLicenseText() throws {
        XCTAssertEqual(
            SdkmanagerParsing.licensePromptLines(from: try LogcatSdkApkFixtures.text(listStderr)),
            []
        )
    }

    /// `listAvailableImages` reads stdout only; the banner on stderr must not
    /// disturb it.
    func testListAvailableImagesThroughAToolReplayingTheRealOutput() async throws {
        let sdkmanager = try replayingSdkmanager(stdout: listStdout, stderr: listStderr, exitCode: 0)
        let client = SdkmanagerClient(sdkmanagerURL: sdkmanager, environment: ["JAVA_HOME": "/unused"])
        let images = try await client.listAvailableImages()
        XCTAssertEqual(images.count, 327)
    }

    /// `sdkmanager --uninstall <package it does not have>` exits 0 and only
    /// warns, on stderr: `Warning: Unable to find package …`. That must not
    /// read as a removal.
    func testUninstallOfAMissingPackageWithTheRealAnswer() async throws {
        let stderr = try LogcatSdkApkFixtures.text("sdkmanager-uninstall-missing.stderr.txt")
        XCTAssertTrue(stderr.hasSuffix(
            "Warning: Unable to find package system-images;android-999;devicehubpro_missing;arm64-v8a\n"
        ))
        let sdkmanager = try replayingSdkmanager(
            stdout: "sdkmanager-uninstall-missing.stdout.txt",
            stderr: "sdkmanager-uninstall-missing.stderr.txt",
            exitCode: 0
        )
        let client = SdkmanagerClient(sdkmanagerURL: sdkmanager, environment: ["JAVA_HOME": "/unused"])
        do {
            try await client.uninstall(package: "system-images;android-999;devicehubpro_missing;arm64-v8a")
            XCTFail("a package sdkmanager could not find must not count as removed")
        } catch SdkmanagerError.commandFailed(let message) {
            XCTAssertEqual(
                message,
                "sdkmanager did not find system-images;android-999;devicehubpro_missing;arm64-v8a in the SDK it manages; nothing was removed."
            )
        }
    }

    // MARK: - nexus.xml

    /// `unzip -p cmdline-tools/latest/lib/sdklib/tools.sdklib.jar
    /// com/android/sdklib/devices/nexus.xml`: 45 devices, 40 with a
    /// `<d:id>` (the oldest Nexus profiles have none). Values cross-checked
    /// with an XML parser.
    func testMinApiTableFromTheRealNexusXML() throws {
        let table = PixelMinApiTable.parse(nexusXML: try LogcatSdkApkFixtures.text("sdklib-devices-nexus.xml"))
        XCTAssertEqual(table.entries.count, 40)
        let expected: [String: PixelMinApiTable.Entry] = [
            "Nexus 5": .init(minApi: "19", playstoreEnabled: true),
            "pixel_c": .init(minApi: "23", playstoreEnabled: false),
            "pixel": .init(minApi: "25", playstoreEnabled: true),
            "pixel_xl": .init(minApi: "25", playstoreEnabled: false),
            "pixel_4": .init(minApi: "29", playstoreEnabled: true),
            "pixel_4a": .init(minApi: "30", playstoreEnabled: false),
            "pixel_fold": .init(minApi: "34", playstoreEnabled: true),
            "pixel_9_pro": .init(minApi: "35", playstoreEnabled: true),
            "pixel_9_pro_fold": .init(minApi: "35", playstoreEnabled: true),
            "pixel_10_pro_fold": .init(minApi: "36.1", playstoreEnabled: true),
        ]
        for (id, entry) in expected {
            XCTAssertEqual(table.entries[id], entry, id)
        }
    }

    // MARK: - API strings sdkmanager really offers

    /// SDK-extension images are their base API (`android-35-ext15` is API
    /// 35); reading them as API 0 marked every one "below the minimum" and
    /// sorted it last. Codenames still carry no number.
    func testApiComparisonOfRealImageApis() {
        XCTAssertEqual(PixelMinApiTable.compare("android-35-ext15", "35"), .orderedSame)
        XCTAssertEqual(PixelMinApiTable.compare("android-34-ext12", "35"), .orderedAscending)
        XCTAssertEqual(PixelMinApiTable.compare("android-36-ext19", "android-36.1"), .orderedAscending)
        XCTAssertEqual(PixelMinApiTable.compare("android-37.2-beta1", "android-37.1"), .orderedDescending)
        XCTAssertEqual(PixelMinApiTable.compare("android-37.2-beta1", "android-37.2"), .orderedSame)
        XCTAssertEqual(PixelMinApiTable.compare("android-canary-20260909", "35"), .orderedAscending)
        XCTAssertEqual(PixelMinApiTable.compare("android-CANARY", "35"), .orderedAscending)
    }

    /// The Pixel 9 Pro picker from the real listing and the images installed
    /// on the capture host (the listing's `Installed packages:` table).
    func testPixelPickerFromTheRealListing() throws {
        let table = PixelMinApiTable.parse(nexusXML: try LogcatSdkApkFixtures.text("sdklib-devices-nexus.xml"))
        let skins = SkinResolver.catalog(skinsDirectory: LogcatSdkApkFixtures.url("skins"))
        let device = try XCTUnwrap(
            PixelCatalog.devices(
                skins: skins,
                installedAvdNames: [],
                avdDevices: [],
                minApiTable: table
            ).first { $0.skinName == "pixel_9_pro" }
        )
        XCTAssertEqual(device.minApi, "35")
        XCTAssertTrue(device.playstoreEnabled)

        let installed = [
            "system-images;android-34;google_atd;arm64-v8a",
            "system-images;android-35;google_apis;arm64-v8a",
            "system-images;android-36.1;google_apis_playstore_ps16k;arm64-v8a",
            "system-images;android-37.1;google_apis_playstore_ps16k;arm64-v8a",
        ].map(Self.image)
        let available = SdkmanagerParsing.availableImages(
            fromListOutput: try LogcatSdkApkFixtures.text(listStdout)
        )
        let candidates = PixelImageSuggestion.candidates(
            device: device,
            installed: installed,
            available: available,
            hostAbi: "arm64-v8a"
        )
        let packages = candidates.map(\.image.package)

        // Canary images are offered under both spellings the listing uses.
        XCTAssertFalse(packages.contains { $0.lowercased().contains("canary") }, "\(packages)")
        XCTAssertFalse(packages.contains { $0.contains("beta") })
        XCTAssertFalse(packages.contains { $0.contains("atd") || $0.contains("wear") || $0.contains("tv") })
        XCTAssertTrue(candidates.allSatisfy { $0.image.abi == "arm64-v8a" })

        XCTAssertEqual(Array(packages.prefix(4)), [
            "system-images;android-37.1;google_apis_playstore_ps16k;arm64-v8a",
            "system-images;android-36.1;google_apis_playstore_ps16k;arm64-v8a",
            "system-images;android-35;google_apis;arm64-v8a",
            "system-images;android-37.2;google_apis_playstore_ps16k;arm64-v8a",
        ])
        XCTAssertEqual(candidates.prefix(3).map(\.isInstalled), [true, true, true])
        XCTAssertEqual(
            PixelImageSuggestion.preferred(in: candidates)?.image.package,
            "system-images;android-37.1;google_apis_playstore_ps16k;arm64-v8a"
        )

        func candidate(_ package: String) -> PixelImageCandidate? {
            candidates.first { $0.image.package == package }
        }
        XCTAssertEqual(
            candidate("system-images;android-35-ext15;google_apis_playstore;arm64-v8a")?.meetsMinimum,
            true
        )
        XCTAssertEqual(
            candidate("system-images;android-34-ext12;google_apis_playstore;arm64-v8a")?.meetsMinimum,
            false
        )
        // Extension images sit with their API, newest extension first.
        let api36Playstore = packages.filter {
            $0.hasPrefix("system-images;android-36") && !$0.hasPrefix("system-images;android-36.1")
                && $0.contains(";google_apis_playstore")
        }
        XCTAssertEqual(api36Playstore, [
            "system-images;android-36-ext19;google_apis_playstore;arm64-v8a",
            "system-images;android-36-ext18;google_apis_playstore;arm64-v8a",
            "system-images;android-36;google_apis_playstore_ps16k;arm64-v8a",
        ])
    }

    // MARK: - Helpers

    private static func image(_ package: String) -> SystemImage {
        let parts = package.split(separator: ";").map(String.init)
        return SystemImage(package: package, api: parts[1], tag: parts[2], abi: parts[3])
    }

    /// A stand-in `sdkmanager` that replays captured stdout and stderr.
    private func replayingSdkmanager(stdout: String, stderr: String, exitCode: Int32) throws -> URL {
        let directory = try LogcatSdkApkFixtures.temporaryDirectory(self, prefix: "sdkmanager-real")
        return try LogcatSdkApkFixtures.script("""
            #!/bin/sh
            cat "\(LogcatSdkApkFixtures.url(stderr).path)" >&2
            cat "\(LogcatSdkApkFixtures.url(stdout).path)"
            exit \(exitCode)
            """, named: "sdkmanager", in: directory)
    }
}
