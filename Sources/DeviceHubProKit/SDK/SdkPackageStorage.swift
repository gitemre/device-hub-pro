import Foundation

/// Where installed SDK packages live on disk and how much space they take.
///
/// An sdkmanager package path maps onto the SDK tree segment by segment
/// (`system-images;android-35;google_apis;arm64-v8a` →
/// `<sdk>/system-images/android-35/google_apis/arm64-v8a`), and an installed
/// package carries the tool's `package.xml` manifest there — a directory left
/// behind by a cancelled download does not.
public enum SdkPackageStorage {
    /// The package's install directory under `sdkRoot`, or nil for a string
    /// that is not a package path (see `SdkmanagerClient.isPackagePath`; no
    /// `..` segment can climb out of the SDK).
    public static func directory(forPackage package: String, sdkRoot: URL) -> URL? {
        guard SdkmanagerClient.isPackagePath(package) else { return nil }
        let segments = package.split(separator: ";").map(String.init)
        guard !segments.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return segments.reduce(sdkRoot) { url, segment in
            url.appendingPathComponent(segment, isDirectory: true)
        }
    }

    /// Whether the package is installed under `sdkRoot`: its directory holds
    /// sdkmanager's `package.xml` manifest.
    public static func isInstalled(package: String, sdkRoot: URL) -> Bool {
        guard let directory = directory(forPackage: package, sdkRoot: sdkRoot) else { return false }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("package.xml").path)
    }

    /// The bytes the installed package occupies on disk — what uninstalling
    /// it frees. Allocated sizes are summed, so sparse images count only the
    /// blocks they use; symbolic links are not followed. Nil when the package
    /// is not installed. Walks the whole tree: call it off the main actor
    /// (``installedSizes(ofPackages:sdkRoot:)`` does).
    public static func installedSize(ofPackage package: String, sdkRoot: URL) -> Int64? {
        guard isInstalled(package: package, sdkRoot: sdkRoot),
              let directory = directory(forPackage: package, sdkRoot: sdkRoot)
        else {
            return nil
        }
        return allocatedSize(of: directory)
    }

    /// ``installedSize(ofPackage:sdkRoot:)`` for each package, computed on a
    /// background task; packages that are not installed are left out.
    public static func installedSizes(ofPackages packages: [String], sdkRoot: URL) async -> [String: Int64] {
        await Task.detached(priority: .utility) {
            var sizes: [String: Int64] = [:]
            for package in packages {
                if let size = installedSize(ofPackage: package, sdkRoot: sdkRoot) {
                    sizes[package] = size
                }
            }
            return sizes
        }.value
    }

    /// Sum of the regular files' allocated sizes under `directory`.
    static func allocatedSize(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else {
                continue
            }
            let size = values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? values.fileSize
                ?? 0
            total += Int64(size)
        }
        return total
    }
}
