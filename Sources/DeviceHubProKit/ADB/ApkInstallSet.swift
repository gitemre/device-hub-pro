import Foundation
import SwiftProtobuf

/// The APK files one install puts on a device: a single APK, a split set from
/// a directory, or the contents of a bundletool `.apks` archive.
///
/// - A **directory** installs every `*.apk` directly inside it, together, with
///   `adb install-multiple` (a base APK plus its config splits).
/// - A **`.apks`** archive (bundletool `build-apks` output) is extracted to a
///   temporary directory. Its `universal.apk` is installed when it has one
///   (`--mode universal`). Otherwise one **variant** is chosen from its
///   `toc.pb`: bundletool writes a separate split set per SDK threshold (for
///   example uncompressed native libraries from API 23), named apart with a
///   `_2`, `_3`… suffix (`splits/base-master.apk`, `splits/base-master_2.apk`),
///   and installing two variants together hands the package manager two base
///   APKs, which it refuses. The variant is the one with the highest minimum
///   SDK the device meets — bundletool's own rule — and all of its split
///   APKs go in: the package manager keeps the ABI, density and language
///   splits the device can use, and every feature module is installed (like
///   `bundletool install-apks --modules=_ALL_`). An archive without a
///   `toc.pb` is not bundletool's; its `splits/*.apk` go in as they are.
/// - Anything else is installed as one APK.
struct ApkInstallSet {
    let apks: [URL]
    /// The extraction directory of a `.apks` archive, removed by `cleanUp()`.
    let temporaryDirectory: URL?

    /// `deviceSdk` reads the target's API level (`ro.build.version.sdk`); it
    /// is asked only when a `.apks` archive holds more than one variant.
    static func resolve(
        _ url: URL,
        deviceSdk: () async throws -> Int? = { nil }
    ) async throws -> ApkInstallSet {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists, isDirectory.boolValue {
            let apks = apkFiles(in: url)
            guard !apks.isEmpty else {
                throw AdbError.invalidInstallPackage("\(url.lastPathComponent) contains no .apk files")
            }
            return ApkInstallSet(apks: apks, temporaryDirectory: nil)
        }
        guard url.pathExtension.lowercased() == "apks" else {
            return ApkInstallSet(apks: [url], temporaryDirectory: nil)
        }
        return try await extract(url, deviceSdk: deviceSdk)
    }

    /// Removes the extraction directory, best effort.
    func cleanUp() {
        guard let temporaryDirectory else { return }
        // Best effort: a leftover temp directory is harmless.
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    /// The `*.apk` files directly inside `directory`, by name.
    static func apkFiles(in directory: URL) -> [URL] {
        // Best effort: an unreadable directory holds no APKs.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.lowercased().hasSuffix(".apk") && !$0.hasPrefix(".") }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    private static func extract(
        _ archive: URL,
        deviceSdk: () async throws -> Int?
    ) async throws -> ApkInstallSet {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-apks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let set: ApkInstallSet
        do {
            let result = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-x", "-k", archive.path, directory.path],
                timeout: .seconds(120)
            )
            guard result.exitCode == 0 else {
                throw AdbError.invalidInstallPackage(
                    "\(archive.lastPathComponent) could not be extracted: "
                        + result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            let apks = try await archiveApks(
                in: directory,
                archiveName: archive.lastPathComponent,
                deviceSdk: deviceSdk
            )
            set = ApkInstallSet(apks: apks, temporaryDirectory: directory)
        } catch {
            // Best effort: the failed extraction's directory is scratch.
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return set
    }

    /// The APKs to install from an extracted `.apks` archive (see the type's
    /// documentation for the rules).
    private static func archiveApks(
        in directory: URL,
        archiveName: String,
        deviceSdk: () async throws -> Int?
    ) async throws -> [URL] {
        let universal = directory.appendingPathComponent("universal.apk")
        if FileManager.default.fileExists(atPath: universal.path) {
            return [universal]
        }
        let toc = directory.appendingPathComponent("toc.pb")
        guard FileManager.default.fileExists(atPath: toc.path) else {
            let apks = apkFiles(in: directory.appendingPathComponent("splits", isDirectory: true))
            guard !apks.isEmpty else {
                throw AdbError.invalidInstallPackage("\(archiveName) holds neither universal.apk nor splits/*.apk")
            }
            return apks
        }
        let variants: [SplitVariant]
        do {
            variants = try splitVariants(toc: Data(contentsOf: toc))
        } catch {
            throw AdbError.invalidInstallPackage("\(archiveName) has a toc.pb that could not be read (\(error))")
        }
        guard !variants.isEmpty else {
            throw AdbError.invalidInstallPackage(
                "\(archiveName) holds no split APKs; build it with `bundletool build-apks --mode=universal`"
            )
        }
        let variant: SplitVariant
        if variants.count == 1 {
            variant = variants[0]
        } else {
            guard let sdk = try await deviceSdk() else {
                throw AdbError.invalidInstallPackage(
                    "\(archiveName) holds split sets for several Android versions and the device's API level "
                        + "could not be read; build it with `--connected-device` or `--mode=universal`"
                )
            }
            guard let chosen = chooseVariant(variants, deviceSdk: sdk) else {
                let lowest = variants.map(\.minSdk).min() ?? 1
                throw AdbError.invalidInstallPackage(
                    "\(archiveName) has no split set for API \(sdk) (its lowest is for API \(lowest)); "
                        + "build it with `--mode=universal`"
                )
            }
            variant = chosen
        }
        let apks = variant.paths.map { directory.appendingPathComponent($0) }
        if let missing = apks.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
            throw AdbError.invalidInstallPackage(
                "\(archiveName) lists \(missing.lastPathComponent) in its toc.pb but does not contain it"
            )
        }
        return apks
    }

    /// One variant of a `.apks` set that installs as split APKs.
    struct SplitVariant: Equatable, Sendable {
        /// bundletool's `variant_number`.
        let number: Int
        /// The lowest API level the variant is for (1 when untargeted).
        let minSdk: Int
        /// Needs the privacy sandbox's SDK runtime on the device.
        let requiresSdkRuntime: Bool
        /// The variant's split APKs relative to the archive root, by path.
        let paths: [String]
    }

    /// The split variants listed in a `toc.pb` (a serialized bundletool
    /// `BuildApksResult`). Variants without split APKs — standalone APKs for
    /// pre-Lollipop devices, universal, instant or system APKs — are left out.
    static func splitVariants(toc: Data) throws -> [SplitVariant] {
        let result = try Android_Bundle_BuildApksResult(serializedBytes: toc)
        return result.variant.compactMap { variant in
            let paths = variant.apkSet
                .flatMap(\.apkDescription)
                .filter {
                    if case .splitApkMetadata = $0.apkMetadataOneofValue { return true }
                    return false
                }
                .map(\.path)
            guard !paths.isEmpty else { return nil }
            let targeting = variant.targeting
            return SplitVariant(
                number: Int(variant.variantNumber),
                minSdk: targeting.sdkVersionTargeting.value.map { Int($0.min.value) }.min() ?? 1,
                requiresSdkRuntime: targeting.sdkRuntimeTargeting.requiresSdkRuntime,
                paths: Array(Set(paths)).sorted()
            )
        }
    }

    /// bundletool's variant rule for a device at API `deviceSdk`: among the
    /// variants it meets, the one with the highest minimum SDK. A variant
    /// that needs the SDK runtime is used only when no other one fits, since
    /// whether the device has that runtime is unknown here.
    static func chooseVariant(_ variants: [SplitVariant], deviceSdk: Int) -> SplitVariant? {
        let eligible = variants.filter { $0.minSdk <= deviceSdk }
        let withoutRuntime = eligible.filter { !$0.requiresSdkRuntime }
        return (withoutRuntime.isEmpty ? eligible : withoutRuntime)
            .max { ($0.minSdk, $0.number) < ($1.minSdk, $1.number) }
    }
}
