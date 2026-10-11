import Foundation

/// Checks made before an AVD is launched, for starts that can only fail or
/// go wrong: an AVD that names its Android version 0, a system image that is
/// missing or incomplete, an image built for the other processor. The
/// emulator's own errors still speak for everything else
/// (`EmulatorStartFailure`).
public enum EmulatorPreflight {
    /// The SDK roots a system image of `emulatorURL`'s AVDs may sit under:
    /// the SDK the emulator binary is in (through a symlink too, the root it
    /// resolves `image.sysdir.1` against when it is launched without
    /// `ANDROID_SDK_ROOT`), then the other roots Device Hub Pro knows.
    public static func sdkRoots(
        emulatorURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        let own = emulatorURL.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        var seen = Set<String>()
        return ([own.path] + AvdmanagerLocator.sdkRoots(environment: environment))
            .filter { seen.insert($0).inserted }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The AVD's system image directory (`image.sysdir.1` of its
    /// `config.ini`) under the first of `sdkRoots` that has it, else under
    /// the first root; nil when the AVD names none.
    public static func systemImageDirectory(avdName: String, avdHome: URL? = nil, sdkRoots: [URL]) -> URL? {
        guard let path = AvdConfig.values(avdName: avdName, avdHome: avdHome)["image.sysdir.1"]?
            .trimmingCharacters(in: .whitespaces), !path.isEmpty
        else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true) }
        let candidates = sdkRoots.map { $0.appendingPathComponent(path, isDirectory: true) }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates.first
    }

    /// The API level a system image declares: `AndroidVersion.ApiLevel` of
    /// its `source.properties` ("36", "37.0"); nil when it has none.
    public static func apiLevel(ofImage directory: URL) -> String? {
        let values = AvdConfig.valuesFile(directory.appendingPathComponent("source.properties"))
        guard let level = values["AndroidVersion.ApiLevel"]?.trimmingCharacters(in: .whitespaces),
              !level.isEmpty
        else { return nil }
        return level
    }

    /// Writes back the target of an AVD that names Android version 0.
    ///
    /// `avdmanager` from cmdline-tools 19.0 and older cannot read an API
    /// level with a minor version (Android 17's image says
    /// `AndroidVersion.ApiLevel=37.0`): it writes `target=android-0` in the
    /// AVD's `<name>.ini` and no target in its `config.ini`. The emulator then
    /// takes the AVD for API level 0 and runs it without the hypervisor
    /// ("hvf is not enabled on this aarch64 host"), in software, which macOS
    /// can refuse ("qemu_mprotect__osdep: mprotect failed: Permission
    /// denied"). Measured 2026-10-11 on the Google APIs arm64 image r6 of
    /// API 37.0: cmdline-tools 13.0 and 19.0 wrote `android-0`; 20.0, 21.0
    /// and 23.0 wrote `android-37.0`, in both files. A Mac with an older SDK
    /// keeps its own cmdline-tools, which Device Hub Pro's `avdmanager` is.
    ///
    /// When the target is `android-0` or missing and the image names its
    /// level, `target=android-<level>` goes into both files (every other byte
    /// stays). Returns the target written; nil when nothing was wrong, or the
    /// image cannot say.
    @discardableResult
    public static func repairTarget(avdName: String, avdHome: URL? = nil, sdkRoots: [URL]) throws -> String? {
        let pointer = AvdConfig.homeURL(avdHome: avdHome).appendingPathComponent("\(avdName).ini")
        guard FileManager.default.fileExists(atPath: pointer.path) else { return nil }
        let current = AvdConfig.valuesFile(pointer)["target"]?.trimmingCharacters(in: .whitespaces) ?? ""
        guard current.isEmpty || current == brokenTarget,
              let image = systemImageDirectory(avdName: avdName, avdHome: avdHome, sdkRoots: sdkRoots),
              let level = apiLevel(ofImage: image), level != "0"
        else { return nil }
        let target = "android-\(level)"
        try AvdConfig.setValue(target, forKey: "target", in: pointer)
        try AvdConfig.setValue(target, forKey: "target", avdName: avdName, avdHome: avdHome)
        return target
    }

    /// The target an old `avdmanager` writes for an image it cannot read.
    public static let brokenTarget = "android-0"

    /// The files every system image the emulator boots holds (API 21 on, as
    /// Google ships them): a missing one means a download that did not finish.
    static let requiredImageFiles = ["system.img", "ramdisk.img"]

    /// Why `avdName` cannot start on this Mac, known before the emulator
    /// runs; nil when nothing is. `hostIsAppleSilicon` is this Mac's
    /// processor (`isAppleSilicon`).
    public static func problem(
        avdName: String,
        avdHome: URL? = nil,
        sdkRoots: [URL],
        hostIsAppleSilicon: Bool = isAppleSilicon
    ) -> String? {
        let config = AvdConfig.values(avdName: avdName, avdHome: avdHome)
        // An AVD whose config cannot be read is the emulator's to report.
        guard !config.isEmpty else { return nil }
        if hostIsAppleSilicon, let abi = config["abi.type"]?.trimmingCharacters(in: .whitespaces), abi.hasPrefix("x86") {
            return "This emulator uses an Intel (\(abi)) system image, which can\u{2019}t run on a Mac with Apple silicon. Create one with an ARM 64 system image."
        }
        guard let image = systemImageDirectory(avdName: avdName, avdHome: avdHome, sdkRoots: sdkRoots) else { return nil }
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: image.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return EmulatorStartFailure.missingSystemImage
        }
        let files = (try? manager.contentsOfDirectory(atPath: image.path)) ?? []
        let hasKernel = files.contains { $0.hasPrefix("kernel-") }
        let complete = hasKernel && requiredImageFiles.allSatisfy { name in
            let attributes = try? manager.attributesOfItem(atPath: image.appendingPathComponent(name).path)
            return ((attributes?[.size] as? NSNumber)?.intValue ?? 0) > 0
        }
        return complete ? nil : EmulatorStartFailure.missingSystemImage
    }

    /// Whether this Mac has Apple silicon (also when the app runs translated).
    public static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }
}
