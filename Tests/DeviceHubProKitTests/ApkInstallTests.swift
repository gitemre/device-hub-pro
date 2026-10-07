import XCTest
@testable import DeviceHubProKit

/// `AdbClient.install`: its flags and the split sets it accepts, traced
/// through a fake adb that logs its argv.
final class ApkInstallTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApkInstallTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Best effort: a leftover fixture directory must not fail the test.
        try? FileManager.default.removeItem(at: directory)
    }

    /// A fake adb that logs its argv (one line per call), answers the API
    /// level query with `sdk`, and prints `Success` for anything else, like a
    /// real install.
    private func makeStubAdb(sdk: String = "34") throws -> (client: AdbClient, calls: () -> [[String]]) {
        let log = directory.appendingPathComponent("calls.log")
        let adbURL = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        for argument in "$@"; do printf '%s\\037' "$argument" >> "\(log.path)"; done
        printf '\\n' >> "\(log.path)"
        if [ "$3 $4 $5" = "shell getprop ro.build.version.sdk" ]; then
          printf '%s\\n' "\(sdk)"
          exit 0
        fi
        printf 'Performing Streamed Install\\nSuccess\\n'
        """
        try Data(script.utf8).write(to: adbURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adbURL.path)
        let calls = {
            // Best effort: no log means no calls.
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
                .split(separator: "\n")
                .map { $0.split(separator: "\u{1F}").map(String.init) }
        }
        return (AdbClient(adbURL: adbURL), calls)
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("apk".utf8).write(to: url)
    }

    // MARK: Flags

    /// `-t` is on by default: Android Studio's Run output is test-only and
    /// the device refuses it without the flag. `-d` is opt-in.
    func testInstallArgumentsAllowTestPackagesByDefaultAndDowngradeOnRequest() {
        let apk = URL(fileURLWithPath: "/tmp/app-debug.apk")
        XCTAssertEqual(
            AdbClient.installArguments(serial: "R58M", apks: [apk], options: .init()),
            ["-s", "R58M", "install", "-r", "-t", "/tmp/app-debug.apk"]
        )
        XCTAssertEqual(
            AdbClient.installArguments(
                serial: "R58M",
                apks: [apk],
                options: .init(allowTestPackages: false, allowDowngrade: true)
            ),
            ["-s", "R58M", "install", "-r", "-d", "/tmp/app-debug.apk"]
        )
        XCTAssertEqual(
            AdbClient.installArguments(
                serial: "R58M",
                apks: [URL(fileURLWithPath: "/s/base.apk"), URL(fileURLWithPath: "/s/split.apk")],
                options: .init()
            ),
            ["-s", "R58M", "install-multiple", "-r", "-t", "/s/base.apk", "/s/split.apk"]
        )
    }

    func testSingleApkInstallsWithTheTestOnlyFlag() async throws {
        let stub = try makeStubAdb()
        let apk = directory.appendingPathComponent("app-debug.apk")
        try touch(apk)

        try await stub.client.install(serial: "emulator-5554", apkURL: apk)

        XCTAssertEqual(stub.calls(), [["-s", "emulator-5554", "install", "-r", "-t", apk.path]])
    }

    // MARK: Split sets

    /// A directory of split APKs goes in together with `install-multiple`;
    /// non-APK files are ignored.
    func testDirectoryOfSplitsInstallsWithInstallMultiple() async throws {
        let stub = try makeStubAdb()
        let splits = directory.appendingPathComponent("splits", isDirectory: true)
        try touch(splits.appendingPathComponent("split_config.arm64_v8a.apk"))
        try touch(splits.appendingPathComponent("base.apk"))
        try touch(splits.appendingPathComponent("notes.txt"))

        try await stub.client.install(serial: "R58M", apkURL: splits)

        XCTAssertEqual(stub.calls(), [[
            "-s", "R58M", "install-multiple", "-r", "-t",
            splits.appendingPathComponent("base.apk").path,
            splits.appendingPathComponent("split_config.arm64_v8a.apk").path,
        ]])
    }

    func testDirectoryWithoutApksIsRefusedBeforeAdbRuns() async throws {
        let stub = try makeStubAdb()
        let empty = directory.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        do {
            try await stub.client.install(serial: "R58M", apkURL: empty)
            XCTFail("expected an empty directory to be refused")
        } catch AdbError.invalidInstallPackage(let reason) {
            XCTAssertTrue(reason.contains("no .apk"), reason)
        }
        XCTAssertTrue(stub.calls().isEmpty)
    }

    /// A bundletool `.apks` set with one variant installs that variant's
    /// splits together, from a temporary extraction that is removed
    /// afterwards. One variant needs no device query.
    func testApksArchiveInstallsItsSplits() async throws {
        let stub = try makeStubAdb()
        let splits = ["splits/base-master.apk", "splits/base-arm64_v8a.apk", "splits/base-xxhdpi.apk"]
        let archive = try makeApksArchive(
            entries: splits,
            toc: Self.toc([(number: 0, minSdk: 21, paths: splits)])
        )

        try await stub.client.install(serial: "R58M", apkURL: archive)

        XCTAssertEqual(stub.calls().count, 1, "the install alone: no API level query")
        let call = try XCTUnwrap(stub.calls().first)
        XCTAssertEqual(Array(call.prefix(5)), ["-s", "R58M", "install-multiple", "-r", "-t"])
        let paths = Array(call.dropFirst(5))
        XCTAssertEqual(
            paths.map { URL(fileURLWithPath: $0).lastPathComponent },
            ["base-arm64_v8a.apk", "base-master.apk", "base-xxhdpi.apk"]
        )
        XCTAssertTrue(paths.allSatisfy { $0.contains("/splits/") })
        let extraction = URL(fileURLWithPath: paths[0]).deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: extraction.path),
            "the extraction directory is removed after the install"
        )
    }

    /// A universal `.apks` set (`--mode universal`) installs its one APK.
    func testUniversalApksArchiveInstallsTheUniversalApk() async throws {
        let stub = try makeStubAdb()
        let archive = try makeApksArchive(entries: ["toc.pb", "universal.apk"])

        try await stub.client.install(serial: "R58M", apkURL: archive)

        let call = try XCTUnwrap(stub.calls().first)
        XCTAssertEqual(Array(call.prefix(5)), ["-s", "R58M", "install", "-r", "-t"])
        XCTAssertEqual(call.last.map { URL(fileURLWithPath: $0).lastPathComponent }, "universal.apk")
    }

    func testApksArchiveWithoutApksIsRefused() async throws {
        let stub = try makeStubAdb()
        let archive = try makeApksArchive(entries: [], toc: Self.toc([]))

        do {
            try await stub.client.install(serial: "R58M", apkURL: archive)
            XCTFail("expected an archive without APKs to be refused")
        } catch AdbError.invalidInstallPackage(let reason) {
            XCTAssertTrue(reason.contains("no split APKs"), reason)
            XCTAssertTrue(reason.contains("--mode=universal"), reason)
        }
        XCTAssertTrue(stub.calls().isEmpty)

        let noToc = try makeApksArchive(entries: ["notes.txt"])
        do {
            try await stub.client.install(serial: "R58M", apkURL: noToc)
            XCTFail("expected an archive without APKs to be refused")
        } catch AdbError.invalidInstallPackage(let reason) {
            XCTAssertTrue(reason.contains("universal.apk"), reason)
        }
        XCTAssertTrue(stub.calls().isEmpty)
    }

    // MARK: Multi-variant sets

    /// A `toc.pb` encoded with protoc from bundletool 1.18.1's own
    /// `commands.proto` (not this app's subset of it), shaped like
    /// `build-apks` output for an app with native code, minSdk 19 and an
    /// on-demand `camera` module. Variant 0 is the pre-Lollipop standalone
    /// APK (`standalones/standalone-arm64_v8a.apk`); variant 1 (API 21+) and
    /// variant 2 (API 23+, uncompressed native libraries) each hold
    /// `base-master`, `base-arm64_v8a`, `base-x86_64`, `base-xxhdpi` and
    /// `camera-master` under `splits/`, variant 2's with a `_2` suffix. It
    /// also carries fields the subset leaves out (APK targeting, delivery
    /// types, the bundletool version, the package name).
    private static let bundletoolToc = Data(base64Encoded: """
    CngKHgoSCgQKAggTEgQKAggVEgQKAggXEggKAggDEgIIBRJWCggKBGJhc2UwARJKChoKBAoCCAMqEgoECgIIExIECgIIFRIECgII\
    FxIkc3RhbmRhbG9uZXMvc3RhbmRhbG9uZS1hcm02NF92OGEuYXBrIgYKBGJhc2UKjgMKFAoSCgQKAggVEgQKAggTEgQKAggXEqEC\
    CggKBGJhc2UwARIyChQqEgoECgIIFRIECgIIExIECgIIFxIWc3BsaXRzL2Jhc2UtbWFzdGVyLmFwaxoCEAESTwoeCggKAggDEgII\
    BSoSCgQKAggVEgQKAggTEgQKAggXEhlzcGxpdHMvYmFzZS1hcm02NF92OGEuYXBrGhIKEGNvbmZpZy5hcm02NF92OGESSQoeCggK\
    AggFEgIIAyoSCgQKAggVEgQKAggTEgQKAggXEhZzcGxpdHMvYmFzZS14ODZfNjQuYXBrGg8KDWNvbmZpZy54ODZfNjQSRQoaIgQK\
    AggHKhIKBAoCCBUSBAoCCBMSBAoCCBcSFnNwbGl0cy9iYXNlLXh4aGRwaS5hcGsaDwoNY29uZmlnLnh4aGRwaRJQChAKBmNhbWVy\
    YSIEYmFzZTACEjwKFCoSCgQKAggVEgQKAggTEgQKAggXEhhzcGxpdHMvY2FtZXJhLW1hc3Rlci5hcGsaCgoGY2FtZXJhEAEYAQqY\
    AwoUChIKBAoCCBcSBAoCCBMSBAoCCBUSqQIKCAoEYmFzZTABEjQKFCoSCgQKAggXEgQKAggTEgQKAggVEhhzcGxpdHMvYmFzZS1t\
    YXN0ZXJfMi5hcGsaAhABElEKHgoICgIIAxICCAUqEgoECgIIFxIECgIIExIECgIIFRIbc3BsaXRzL2Jhc2UtYXJtNjRfdjhhXzIu\
    YXBrGhIKEGNvbmZpZy5hcm02NF92OGESSwoeCggKAggFEgIIAyoSCgQKAggXEgQKAggTEgQKAggVEhhzcGxpdHMvYmFzZS14ODZf\
    NjRfMi5hcGsaDwoNY29uZmlnLng4Nl82NBJHChoiBAoCCAcqEgoECgIIFxIECgIIExIECgIIFRIYc3BsaXRzL2Jhc2UteHhoZHBp\
    XzIuYXBrGg8KDWNvbmZpZy54eGhkcGkSUgoQCgZjYW1lcmEiBGJhc2UwAhI+ChQqEgoECgIIFxIECgIIExIECgIIFRIac3BsaXRz\
    L2NhbWVyYS1tYXN0ZXJfMi5hcGsaCgoGY2FtZXJhEAEYAhIIEgYxLjE4LjEiD2NvbS5leGFtcGxlLmFwcA==
    """)!

    private static let variantOneSplits = [
        "splits/base-arm64_v8a.apk", "splits/base-master.apk", "splits/base-x86_64.apk",
        "splits/base-xxhdpi.apk", "splits/camera-master.apk",
    ]
    private static let variantTwoSplits = [
        "splits/base-arm64_v8a_2.apk", "splits/base-master_2.apk", "splits/base-x86_64_2.apk",
        "splits/base-xxhdpi_2.apk", "splits/camera-master_2.apk",
    ]

    /// bundletool's real `toc.pb` parses into its two split variants; the
    /// standalone variant is not a split set and is left out.
    func testSplitVariantsReadBundletoolsToc() throws {
        let variants = try ApkInstallSet.splitVariants(toc: Self.bundletoolToc)
        XCTAssertEqual(variants, [
            .init(number: 1, minSdk: 21, requiresSdkRuntime: false, paths: Self.variantOneSplits),
            .init(number: 2, minSdk: 23, requiresSdkRuntime: false, paths: Self.variantTwoSplits),
        ])
    }

    /// bundletool's rule: the variant with the highest minimum SDK the
    /// device meets; an SDK-runtime variant only when nothing else fits.
    func testChooseVariantPicksTheHighestMinSdkTheDeviceMeets() {
        let lollipop = ApkInstallSet.SplitVariant(number: 1, minSdk: 21, requiresSdkRuntime: false, paths: ["a"])
        let marshmallow = ApkInstallSet.SplitVariant(number: 2, minSdk: 23, requiresSdkRuntime: false, paths: ["b"])
        let runtime = ApkInstallSet.SplitVariant(number: 3, minSdk: 34, requiresSdkRuntime: true, paths: ["c"])
        let variants = [marshmallow, runtime, lollipop]

        XCTAssertEqual(ApkInstallSet.chooseVariant(variants, deviceSdk: 22), lollipop)
        XCTAssertEqual(ApkInstallSet.chooseVariant(variants, deviceSdk: 23), marshmallow)
        XCTAssertEqual(ApkInstallSet.chooseVariant(variants, deviceSdk: 35), marshmallow)
        XCTAssertNil(ApkInstallSet.chooseVariant(variants, deviceSdk: 20))
        XCTAssertEqual(ApkInstallSet.chooseVariant([runtime], deviceSdk: 35), runtime)
    }

    /// Installing every `splits/*.apk` of a multi-variant set hands the
    /// package manager two base APKs (`base-master.apk` and
    /// `base-master_2.apk`), which it refuses. Only the variant for the
    /// device's API level goes in.
    func testMultiVariantApksArchiveInstallsOnlyTheDevicesVariant() async throws {
        let entries = Self.variantOneSplits + Self.variantTwoSplits + ["standalones/standalone-arm64_v8a.apk"]
        for (sdk, expected) in [("34", Self.variantTwoSplits), ("22", Self.variantOneSplits)] {
            try FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stub = try makeStubAdb(sdk: sdk)
            let archive = try makeApksArchive(entries: entries, toc: Self.bundletoolToc)

            try await stub.client.install(serial: "R58M", apkURL: archive)

            let calls = stub.calls()
            XCTAssertEqual(calls.first, ["-s", "R58M", "shell", "getprop", "ro.build.version.sdk"])
            let install = try XCTUnwrap(calls.last)
            XCTAssertEqual(Array(install.prefix(5)), ["-s", "R58M", "install-multiple", "-r", "-t"])
            XCTAssertEqual(
                install.dropFirst(5).map { "splits/" + URL(fileURLWithPath: $0).lastPathComponent },
                expected,
                "API \(sdk)"
            )
        }
    }

    /// A device below every split variant (pre-Lollipop, which needs the
    /// standalone APK) or one whose API level cannot be read is refused
    /// before anything is installed.
    func testMultiVariantApksArchiveIsRefusedWithoutAMatchingVariant() async throws {
        let entries = Self.variantOneSplits + Self.variantTwoSplits
        for (sdk, expected) in [("19", "no split set for API 19"), ("unknown", "could not be read")] {
            try FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stub = try makeStubAdb(sdk: sdk)
            let archive = try makeApksArchive(entries: entries, toc: Self.bundletoolToc)

            do {
                try await stub.client.install(serial: "R58M", apkURL: archive)
                XCTFail("expected API \(sdk) to be refused")
            } catch AdbError.invalidInstallPackage(let reason) {
                XCTAssertTrue(reason.contains(expected), reason)
            }
            XCTAssertFalse(stub.calls().contains { $0.contains("install-multiple") }, "nothing is installed")
        }
    }

    /// A `toc.pb` that names a file the archive lacks, or that is not a
    /// `BuildApksResult`, is refused rather than half-installed.
    func testApksArchiveWithABrokenTocIsRefused() async throws {
        let stub = try makeStubAdb()
        let missing = try makeApksArchive(
            entries: ["splits/base-master.apk"],
            toc: Self.toc([(number: 0, minSdk: 21, paths: ["splits/base-master.apk", "splits/base-xxhdpi.apk"])])
        )
        do {
            try await stub.client.install(serial: "R58M", apkURL: missing)
            XCTFail("expected a missing split to be refused")
        } catch AdbError.invalidInstallPackage(let reason) {
            XCTAssertTrue(reason.contains("base-xxhdpi.apk"), reason)
        }

        let garbage = try makeApksArchive(entries: ["splits/base-master.apk"], toc: Data("apk".utf8))
        do {
            try await stub.client.install(serial: "R58M", apkURL: garbage)
            XCTFail("expected an unreadable toc.pb to be refused")
        } catch AdbError.invalidInstallPackage(let reason) {
            XCTAssertTrue(reason.contains("toc.pb"), reason)
        }
        XCTAssertTrue(stub.calls().isEmpty)
    }

    /// A `BuildApksResult` with one split variant per entry, every APK in
    /// the `base` module.
    private static func toc(_ variants: [(number: Int, minSdk: Int, paths: [String])]) throws -> Data {
        var result = Android_Bundle_BuildApksResult()
        result.variant = variants.map { spec in
            var variant = Android_Bundle_Variant()
            variant.variantNumber = UInt32(spec.number)
            var version = Android_Bundle_SdkVersion()
            version.min.value = Int32(spec.minSdk)
            variant.targeting.sdkVersionTargeting.value = [version]
            var apkSet = Android_Bundle_ApkSet()
            apkSet.moduleMetadata.name = "base"
            apkSet.apkDescription = spec.paths.map { path in
                var description = Android_Bundle_ApkDescription()
                description.path = path
                description.splitApkMetadata = Android_Bundle_SplitApkMetadata()
                return description
            }
            variant.apkSet = [apkSet]
            return variant
        }
        return try result.serializedBytes()
    }

    /// Zips `entries` (relative paths) into an `.apks` archive, with `toc`
    /// as its `toc.pb` when given.
    private func makeApksArchive(entries: [String], toc: Data? = nil) throws -> URL {
        let source = directory.appendingPathComponent("apks-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for entry in entries {
            try touch(source.appendingPathComponent(entry))
        }
        if let toc {
            try toc.write(to: source.appendingPathComponent("toc.pb"))
        }
        let archive = directory.appendingPathComponent("app-\(UUID().uuidString).apks")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", source.path, archive.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return archive
    }
}
