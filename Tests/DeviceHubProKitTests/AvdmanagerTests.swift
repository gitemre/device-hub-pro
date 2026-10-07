import XCTest
@testable import DeviceHubProKit

final class AvdmanagerTests: XCTestCase {
    // MARK: - Parsing

    func testDevicesParsing() {
        let output = """
            id: 0 or "resizable"
                Name: Resizable (Experimental)
                OEM : Generic
            ---------
            id: 1 or "pixel_9_pro"
                Name: Pixel 9 Pro
                OEM : Google
            ---------
            id: 2 or "Nexus 5"
                Name: Nexus 5
                OEM : Google
            ---------
            """;

        let devices = AvdmanagerParsing.devices(from: output)
        XCTAssertEqual(devices.count, 3)
        XCTAssertEqual(devices[0], AvdDevice(id: "resizable", name: "Resizable (Experimental)"))
        XCTAssertEqual(devices[1], AvdDevice(id: "pixel_9_pro", name: "Pixel 9 Pro"))
        XCTAssertEqual(devices[2], AvdDevice(id: "Nexus 5", name: "Nexus 5"))
    }

    func testDevicesParsingIgnoresGarbage() {
        XCTAssertTrue(AvdmanagerParsing.devices(from: "").isEmpty)
        XCTAssertTrue(AvdmanagerParsing.devices(from: "Loading...\n---------\n").isEmpty)

        // A missing Name falls back to the id.
        let devices = AvdmanagerParsing.devices(from: "id: 0 or \"pixel_8\"\n---------\n")
        XCTAssertEqual(devices, [AvdDevice(id: "pixel_8", name: "pixel_8")])
    }

    // MARK: - Skin mapping

    func testDeviceForSkin() {
        let devices = [
            AvdDevice(id: "pixel", name: "Pixel"),
            AvdDevice(id: "pixel_9_pro", name: "Pixel 9 Pro"),
            AvdDevice(id: "Galaxy Nexus", name: "Galaxy Nexus"),
            AvdDevice(id: "Nexus 5X", name: "Nexus 5X"),
            AvdDevice(id: "Nexus 7 2013", name: "Nexus 7"),
            AvdDevice(id: "automotive_ultrawide", name: "Automotive Ultrawide"),
            AvdDevice(id: "automotive_1080p_landscape", name: "Automotive (1080p landscape)"),
        ]

        XCTAssertEqual(
            AvdmanagerClient.device(forSkinName: "pixel_9_pro", devices: devices)?.id,
            "pixel_9_pro"
        )
        XCTAssertEqual(
            AvdmanagerClient.device(forSkinName: "galaxy_nexus", devices: devices)?.id,
            "Galaxy Nexus"
        )
        XCTAssertEqual(
            AvdmanagerClient.device(forSkinName: "nexus_5x", devices: devices)?.id,
            "Nexus 5X"
        )
        XCTAssertEqual(
            AvdmanagerClient.device(forSkinName: "nexus_7_2013", devices: devices)?.id,
            "Nexus 7 2013"
        )
        XCTAssertEqual(
            AvdmanagerClient.device(forSkinName: "pixel_silver", devices: devices)?.id,
            "pixel"
        )
        XCTAssertEqual(
            AvdmanagerClient.device(
                forSkinName: "automotive_ultrawide_cutout",
                devices: devices
            )?.id,
            "automotive_ultrawide"
        )
        XCTAssertEqual(
            AvdmanagerClient.device(forSkinName: "automotive_landscape", devices: devices)?.id,
            "automotive_1080p_landscape"
        )
        XCTAssertNil(AvdmanagerClient.device(forSkinName: "no_such_skin", devices: devices))
    }

    // MARK: - System images

    func testInstalledSystemImages() throws {
        let sdk = try temporaryDirectory()
        let images = sdk.appendingPathComponent("system-images", isDirectory: true)
        for package in [
            "android-35/google_apis/arm64-v8a",
            "android-35/google_apis/x86_64",
            "android-34/google_atd/arm64-v8a",
        ] {
            try FileManager.default.createDirectory(
                at: images.appendingPathComponent(package, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        // Noise: a file and an incomplete level are not images.
        try Data("x".utf8).write(to: images.appendingPathComponent("README"))
        try FileManager.default.createDirectory(
            at: images.appendingPathComponent("android-36/google_apis", isDirectory: true),
            withIntermediateDirectories: true
        )

        let found = AvdmanagerClient.installedSystemImages(sdkRoot: sdk)
        XCTAssertEqual(
            found.map(\.package),
            [
                "system-images;android-35;google_apis;arm64-v8a",
                "system-images;android-35;google_apis;x86_64",
                "system-images;android-34;google_atd;arm64-v8a",
            ]
        )
        XCTAssertEqual(found[0].label, "API 35 · Google APIs · arm64-v8a")
        XCTAssertEqual(found[2].label, "API 34 · Google APIs ATD · arm64-v8a")
    }

    func testSystemImageLabels() {
        let play = SystemImage(
            package: "system-images;android-37.1;google_apis_playstore_ps16k;arm64-v8a",
            api: "android-37.1",
            tag: "google_apis_playstore_ps16k",
            abi: "arm64-v8a"
        )
        XCTAssertEqual(play.label, "API 37.1 · Play Store · 16 KB · arm64-v8a")

        let playPlain = SystemImage(
            package: "system-images;android-36;google_apis_playstore;arm64-v8a",
            api: "android-36",
            tag: "google_apis_playstore",
            abi: "arm64-v8a"
        )
        XCTAssertEqual(playPlain.label, "API 36 · Play Store · arm64-v8a")

        let aosp = SystemImage(
            package: "system-images;android-36;aosp;arm64-v8a",
            api: "android-36",
            tag: "aosp",
            abi: "arm64-v8a"
        )
        XCTAssertEqual(aosp.label, "API 36 · AOSP · arm64-v8a")

        // The Settings window's plain-language names carry no package id.
        XCTAssertEqual(play.friendlyLabel, "Android 17 · Google Play (16 KB pages) · arm64")
        XCTAssertEqual(playPlain.friendlyLabel, "Android 16 · Google Play · arm64")
        XCTAssertEqual(aosp.friendlyLabel, "Android 16 · AOSP · arm64")
        let atd = SystemImage(
            package: "system-images;android-34;google_atd;x86_64",
            api: "android-34",
            tag: "google_atd",
            abi: "x86_64"
        )
        XCTAssertEqual(atd.friendlyLabel, "Android 14 · Automated test device · x86_64")
        let future = SystemImage(
            package: "system-images;android-99;google_apis;arm64-v8a",
            api: "android-99",
            tag: "google_apis",
            abi: "arm64-v8a"
        )
        XCTAssertEqual(future.friendlyLabel, "API 99 · Google APIs · arm64")
    }

    /// A form factor's image reads in plain words in the create sheet.
    func testFormFactorImagesReadInPlainWords() {
        let wear = SystemImage(
            package: "system-images;android-37.0;android-wear-signed;arm64-v8a",
            api: "android-37.0", tag: "android-wear-signed", abi: "arm64-v8a"
        )
        XCTAssertEqual(wear.label, "API 37.0 · Wear OS · arm64-v8a")
        let tv = SystemImage(
            package: "system-images;android-36;google-tv;arm64-v8a",
            api: "android-36", tag: "google-tv", abi: "arm64-v8a"
        )
        XCTAssertEqual(tv.label, "API 36 · Google TV · arm64-v8a")
        XCTAssertEqual(wear.friendlyLabel, "Android 17 · Wear OS · arm64")
    }

    // MARK: - Locator and Java probing

    func testLocatorHonorsOverride() throws {
        let script = try executableScript(content: "#!/bin/sh\necho fake-avdmanager\n")
        let found = AvdmanagerLocator.locate(environment: [
            "DHP_AVDMANAGER": script.path,
            "PATH": "/nonexistent",
        ])
        XCTAssertEqual(found?.path, script.path)
    }

    func testAnOldJavaIsNotAWorkingJava() async throws {
        let old = try executableScript(content: "#!/bin/sh\necho 'java version \"1.8.0_392\"' >&2\n")
        let found = await AvdmanagerLocator.workingJava(
            environment: ["PATH": "/nonexistent", "JAVA_HOME": "/nonexistent"],
            preferred: old
        )
        XCTAssertNotEqual(found?.path, old.path)
    }

    func testWorkingJava() async throws {
        let good = try executableScript(content: "#!/bin/sh\necho 'openjdk version \"21\"' >&2\n")
        let goodClient = AvdmanagerClient(
            avdmanagerURL: URL(fileURLWithPath: "/bin/echo"),
            javaURL: good
        )
        let found = await goodClient.workingJava(environment: ["PATH": "/nonexistent"])
        XCTAssertEqual(found?.path, good.path)

        let bad = try executableScript(content: "#!/bin/sh\nexit 1\n")
        let badClient = AvdmanagerClient(
            avdmanagerURL: URL(fileURLWithPath: "/bin/echo"),
            javaURL: bad
        )
        let missing = await badClient.workingJava(environment: [
            "PATH": "/nonexistent",
            "JAVA_HOME": "/nonexistent",
        ])
        // /usr/bin/java is a fixed candidate, but without a runtime it fails;
        // on machines with Java installed this finds the real one.
        if missing != nil {
            XCTAssertNotEqual(missing?.path, bad.path)
        }
    }

    // MARK: - create avd

    func testCreateAvdInvokesAvdmanager() async throws {
        let record = FileManager.default.temporaryDirectory
            .appendingPathComponent("avdmanager-args-\(UUID().uuidString).txt")
        let fake = try executableScript(content: """
            #!/bin/sh
            echo "args:$@" > "\(record.path)"
            echo "stdin:$(cat)" >> "\(record.path)"
            echo "avdhome:$ANDROID_AVD_HOME" >> "\(record.path)"
            """)
        let java = try executableScript(content: "#!/bin/sh\necho 'openjdk version \"21\"' >&2\n")
        let client = AvdmanagerClient(avdmanagerURL: fake, javaURL: java)
        let home = try temporaryDirectory()

        try await client.createAvd(
            name: "Pixel_9_Pro_API35",
            deviceId: "pixel_9_pro",
            systemImage: "system-images;android-35;google_apis;arm64-v8a",
            avdHome: home
        )

        let text = try String(contentsOf: record, encoding: .utf8)
        XCTAssertTrue(text.contains("create avd"), text)
        XCTAssertTrue(text.contains("-n Pixel_9_Pro_API35"), text)
        XCTAssertTrue(text.contains("-d pixel_9_pro"), text)
        XCTAssertTrue(
            text.contains("-k system-images;android-35;google_apis;arm64-v8a"),
            text
        )
        XCTAssertTrue(text.contains("stdin:no"), text)
        XCTAssertTrue(text.contains("avdhome:\(home.path)"), text)
        let arguments = text.split(separator: "\n").first.map(String.init) ?? ""
        XCTAssertFalse(
            arguments.split(separator: " ").contains { $0 == "-f" || $0 == "--force" },
            "-f makes avdmanager wipe an existing AVD of the same name: \(arguments)"
        )
    }

    /// A name that is already taken — in any letter case, since the volume is
    /// case-insensitive — is refused before avdmanager runs, so an existing
    /// AVD's data can never be replaced by a create.
    func testCreateAvdRefusesAnExistingNameWithoutRunningAvdmanager() async throws {
        let record = FileManager.default.temporaryDirectory
            .appendingPathComponent("avdmanager-ran-\(UUID().uuidString).txt")
        let fake = try executableScript(content: """
            #!/bin/sh
            echo ran > "\(record.path)"
            """)
        let java = try executableScript(content: "#!/bin/sh\necho 'openjdk version \"21\"' >&2\n")
        let client = AvdmanagerClient(avdmanagerURL: fake, javaURL: java)
        let home = try temporaryDirectory()
        try "path=\(home.path)/Pixel_9_Pro_API35.avd\n".write(
            to: home.appendingPathComponent("Pixel_9_Pro_API35.ini"),
            atomically: true,
            encoding: .utf8
        )

        for name in ["Pixel_9_Pro_API35", "pixel_9_pro_api35"] {
            do {
                try await client.createAvd(
                    name: name,
                    deviceId: "pixel_9_pro",
                    systemImage: "system-images;android-35;google_apis;arm64-v8a",
                    avdHome: home
                )
                XCTFail("expected \(name) to be refused")
            } catch AvdmanagerError.avdAlreadyExists(let refused) {
                XCTAssertEqual(refused, name)
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: record.path),
            "avdmanager must not run for a taken name"
        )
        XCTAssertTrue(
            AvdmanagerError.avdAlreadyExists("Pixel_9").description.contains("already exists")
        )
    }

    /// avdmanager's own refusal (a name created between the check and the
    /// run) suggests `--force`; it surfaces as the name clash instead.
    func testCreateAvdReportsAvdmanagersAlreadyExistsRefusal() async throws {
        let fake = try executableScript(content: """
            #!/bin/sh
            echo "Error: Android Virtual Device 'Pixel_9' already exists." >&2
            echo "Use --force if you want to replace it." >&2
            exit 1
            """)
        let java = try executableScript(content: "#!/bin/sh\necho 'openjdk version \"21\"' >&2\n")
        let client = AvdmanagerClient(avdmanagerURL: fake, javaURL: java)

        do {
            try await client.createAvd(
                name: "Pixel_9",
                deviceId: "pixel_9",
                systemImage: "system-images;android-35;google_apis;arm64-v8a",
                avdHome: try temporaryDirectory()
            )
            XCTFail("expected the refusal to throw")
        } catch AvdmanagerError.avdAlreadyExists(let name) {
            XCTAssertEqual(name, "Pixel_9")
        }
    }

    // MARK: - SDK root (F16)

    /// A symlinked avdmanager (Homebrew's `/opt/homebrew/bin/avdmanager`)
    /// resolves to the SDK it really lives in; stripped unresolved, its path
    /// gave `/`, where no system images are ever found.
    func testSdkRootResolvesASymlinkedAvdmanager() throws {
        let base = try temporaryDirectory().resolvingSymlinksInPath()
        let sdk = base.appendingPathComponent("share/android-commandlinetools", isDirectory: true)
        let tool = sdk.appendingPathComponent("cmdline-tools/latest/bin/avdmanager")
        try FileManager.default.createDirectory(
            at: tool.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        try FileManager.default.createDirectory(
            at: sdk.appendingPathComponent("system-images/android-35"),
            withIntermediateDirectories: true
        )
        let bin = base.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("avdmanager")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)

        let root = AvdmanagerClient.sdkRoot(environment: [
            "DHP_AVDMANAGER": link.path,
            "DHP_ADB": "/nonexistent/adb",
            "PATH": "/nonexistent",
        ])

        XCTAssertEqual(root?.standardizedFileURL.path, sdk.standardizedFileURL.path)
    }

    /// A platform-tools-only directory (Homebrew's adb cask) is not an SDK
    /// root and must not hide the real SDK.
    func testSdkRootSkipsAPlatformToolsOnlyAdbDirectory() throws {
        let base = try temporaryDirectory().resolvingSymlinksInPath()
        let cask = base.appendingPathComponent("Caskroom/android-platform-tools/37.0.0", isDirectory: true)
        let adb = cask.appendingPathComponent("platform-tools/adb")
        try FileManager.default.createDirectory(
            at: adb.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\n".write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        let link = base.appendingPathComponent("adb")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: adb)

        let root = AvdmanagerClient.sdkRoot(environment: [
            "DHP_AVDMANAGER": "/nonexistent/avdmanager",
            "DHP_ADB": link.path,
            "PATH": "/nonexistent",
        ])

        XCTAssertNotEqual(root?.standardizedFileURL.path, cask.standardizedFileURL.path)
        XCTAssertFalse(AvdmanagerClient.looksLikeSdkRoot(cask))
        XCTAssertNotEqual(root?.path, "/opt")
    }

    // MARK: - AVD home and names

    func testAvdHomeResolutionOrder() throws {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let existing = try temporaryDirectory()

        XCTAssertEqual(
            AvdHome.url(environment: [:], homeDirectory: home).path,
            "/Users/tester/.android/avd"
        )
        XCTAssertEqual(
            AvdHome.url(environment: ["ANDROID_AVD_HOME": existing.path], homeDirectory: home).path,
            existing.path
        )
        // The emulator ignores an ANDROID_AVD_HOME that is not a directory.
        XCTAssertEqual(
            AvdHome.url(
                environment: ["ANDROID_AVD_HOME": "/nonexistent/avd", "ANDROID_USER_HOME": "/prefs"],
                homeDirectory: home
            ).path,
            "/prefs/avd"
        )
        XCTAssertEqual(
            AvdHome.url(
                environment: ["ANDROID_EMULATOR_HOME": "/emu", "ANDROID_USER_HOME": "/prefs"],
                homeDirectory: home
            ).path,
            "/emu/avd"
        )
        XCTAssertEqual(
            AvdHome.url(environment: ["ANDROID_SDK_HOME": "/legacy"], homeDirectory: home).path,
            "/legacy/.android/avd"
        )
        XCTAssertEqual(
            AvdHome.url(
                environment: ["ANDROID_PREFS_ROOT": "/prefsroot", "ANDROID_SDK_HOME": "/legacy"],
                homeDirectory: home
            ).path,
            "/prefsroot/.android/avd"
        )
    }

    func testAvdNamesCoverIniEntriesAndOrphanFolders() throws {
        let home = try temporaryDirectory()
        let manager = FileManager.default
        try "".write(to: home.appendingPathComponent("Pixel_9.ini"), atomically: true, encoding: .utf8)
        try manager.createDirectory(
            at: home.appendingPathComponent("Pixel_9.avd"),
            withIntermediateDirectories: true
        )
        try manager.createDirectory(
            at: home.appendingPathComponent("Orphan.avd"),
            withIntermediateDirectories: true
        )
        try "".write(to: home.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        XCTAssertEqual(AvdHome.avdNames(in: home), ["Orphan", "Pixel_9"])
        XCTAssertTrue(AvdHome.containsAvd(named: "PIXEL_9", in: home))
        XCTAssertTrue(AvdmanagerClient.avdExists(named: "orphan", avdHome: home))
        XCTAssertFalse(AvdmanagerClient.avdExists(named: "Pixel_9_Pro", avdHome: home))
        XCTAssertTrue(AvdHome.avdNames(in: home.appendingPathComponent("missing")).isEmpty)
    }

    func testUniqueAvdNameIgnoresCaseAndSuffixesTheLastCandidate() throws {
        XCTAssertEqual(AvdmanagerClient.uniqueAvdName("Pixel_9", existing: []), "Pixel_9")
        XCTAssertEqual(AvdmanagerClient.uniqueAvdName("Pixel_9", existing: ["pixel_9"]), "Pixel_9_2")
        XCTAssertEqual(
            AvdmanagerClient.uniqueAvdName("Pixel_9", existing: ["Pixel_9", "PIXEL_9_2"]),
            "Pixel_9_3"
        )
        // The PixelCatalog ladder: base, then the API name, then a suffix.
        XCTAssertEqual(
            AvdmanagerClient.uniqueAvdName(
                candidates: ["Pixel_9_Pro", "Pixel_9_Pro_API35"],
                existing: ["pixel_9_pro"]
            ),
            "Pixel_9_Pro_API35"
        )
        XCTAssertEqual(
            AvdmanagerClient.uniqueAvdName(
                candidates: ["Pixel_9_Pro", "Pixel_9_Pro_API35"],
                existing: ["Pixel_9_Pro", "pixel_9_pro_api35"]
            ),
            "Pixel_9_Pro_API35_2"
        )

        let home = try temporaryDirectory()
        try "".write(to: home.appendingPathComponent("Pixel_9.ini"), atomically: true, encoding: .utf8)
        XCTAssertEqual(AvdmanagerClient.uniqueAvdName("pixel_9", avdHome: home), "pixel_9_2")
    }

    func testCreateAvdRequiresJava() async throws {
        let badJava = try executableScript(content: "#!/bin/sh\nexit 1\n")
        // Point PATH and HOME-based candidates away is not possible for the
        // fixed /usr/bin/java, so this test only runs where Java is broken.
        let probe = AvdmanagerClient(
            avdmanagerURL: URL(fileURLWithPath: "/bin/echo"),
            javaURL: badJava
        )
        guard await probe.workingJava(environment: [
            "PATH": "/nonexistent",
            "JAVA_HOME": "/nonexistent",
        ]) == nil else {
            throw XCTSkip("a working Java exists; nothing to fail")
        }

        let client = AvdmanagerClient(
            avdmanagerURL: URL(fileURLWithPath: "/bin/echo"),
            javaURL: badJava
        )
        do {
            try await client.createAvd(name: "x", deviceId: "y", systemImage: "z")
            XCTFail("expected javaNotFound")
        } catch AvdmanagerError.javaNotFound {
            // Expected.
        }
    }

    func testSanitizedAvdName() {
        XCTAssertEqual(
            AvdmanagerClient.sanitizedAvdName("Pixel 9 Pro (API 35)"),
            "Pixel_9_Pro_API_35"
        )
        XCTAssertEqual(AvdmanagerClient.sanitizedAvdName("pixel_9_pro"), "pixel_9_pro")
        XCTAssertEqual(AvdmanagerClient.sanitizedAvdName("..."), "device")
    }

    // MARK: - ProcessRunner stdin

    func testStandardInputRoundTrip() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            standardInput: Data("hello\n".utf8)
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutputText, "hello\n")
    }

    // MARK: - Real SDK

    func testRealSdkSystemImages() throws {
        guard let root = AvdmanagerClient.sdkRoot() else {
            throw XCTSkip("no Android SDK")
        }
        let images = AvdmanagerClient.installedSystemImages(sdkRoot: root)
        guard !images.isEmpty else {
            throw XCTSkip("this SDK has no system images installed")
        }
        for image in images {
            XCTAssertTrue(image.package.hasPrefix("system-images;"), image.package)
        }
        XCTAssertEqual(images, images.sorted {
            if $0.api != $1.api { return $0.api > $1.api }
            if $0.tag != $1.tag { return $0.tag < $1.tag }
            return $0.abi < $1.abi
        })
    }

    /// Opt-in real check, like the sdkmanager one:
    /// `DHP_REAL_SDKMANAGER=1 swift test --filter
    /// AvdmanagerTests/testRealAvdmanagerDevices` runs `avdmanager list
    /// device` against the installed cmdline-tools when Java exists (it
    /// reads device definitions only); elsewhere it only asserts that the
    /// client reports Java as missing. Off by default, so the non-live suite
    /// starts no real SDK tool or JVM.
    func testRealAvdmanagerDevices() async throws {
        guard ProcessInfo.processInfo.environment["DHP_REAL_SDKMANAGER"] == "1" else {
            throw XCTSkip("set DHP_REAL_SDKMANAGER=1 to run the real avdmanager check")
        }
        guard let client = AvdmanagerClient.locate() else {
            throw XCTSkip("avdmanager not installed")
        }
        guard await client.workingJava() != nil else {
            do {
                _ = try await client.listDevices()
                XCTFail("expected javaNotFound")
            } catch AvdmanagerError.javaNotFound {
                // Expected on machines without Java.
            }
            return
        }
        let devices = try await client.listDevices()
        XCTAssertFalse(devices.isEmpty)
        // Device definitions ship with cmdline-tools; an older release (such
        // as a CI runner's) predates the Pixel 9 Pro.
        guard devices.contains(where: { $0.id == "pixel_9_pro" }) else {
            throw XCTSkip("this cmdline-tools release has no pixel_9_pro definition")
        }
    }

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AvdmanagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func executableScript(content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-\(UUID().uuidString).sh")
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url
    }
}

final class DeviceMarketNameTests: XCTestCase {
    /// A phone is named as it sells ("Redmi Note 12 Pro"), not by adb's model
    /// code ("2209116AG"); a build without the property keeps the model.
    func testAPhoneIsNamedByItsMarketName() {
        let info = DeviceInfo.from(
            serial: "R0000000000", isEmulatorProperties: [
                "ro.product.model": "2209116AG",
                "ro.product.vendor.marketname": "Redmi Note 12 Pro",
            ]
        )
        XCTAssertEqual(info.marketName, "Redmi Note 12 Pro")
        XCTAssertNil(DeviceInfo.from(serial: "e", isEmulatorProperties: ["ro.product.marketname": "  "]).marketName)

        var phone = AndroidDevice(serial: "R0000000000", state: "device", model: "2209116AG")
        XCTAssertEqual(phone.displayName, "2209116AG")
        phone.marketName = info.marketName
        XCTAssertEqual(phone.displayName, "Redmi Note 12 Pro")
    }
}

private extension DeviceInfo {
    static func from(serial: String, isEmulatorProperties properties: [String: String]) -> DeviceInfo {
        DeviceInfo.from(serial: serial, properties: properties, isEmulator: false)
    }
}
