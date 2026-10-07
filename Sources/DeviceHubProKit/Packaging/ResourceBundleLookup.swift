import Foundation

/// Finds a SwiftPM resource bundle (`<Package>_<Target>.bundle`) in a
/// packaged `Device Hub Pro.app` as well as in a `swift build` / `swift test` run.
///
/// `Scripts/package-app.sh` copies the resource bundles into
/// `Device Hub Pro.app/Contents/Resources`. SwiftPM's generated `Bundle.module`
/// alone does not reliably reach them there: the accessor of the native
/// build system looks beside the main bundle URL (the `.app` root, which
/// cannot hold unsealed content) and then at the absolute `.build` path of
/// the machine that built it, and traps with `fatalError` when neither
/// exists. Such an app runs on the build machine and crashes on a tester's
/// Mac. The Swift Build accessor happens to check `Bundle.main.resourceURL`
/// first, but that is a toolchain detail, so the lookup checks the running
/// app's resource directory itself and asks `Bundle.module` only when no
/// packaged bundle is there (a `swift test` run, whose main bundle is the
/// test runner).
public enum ResourceBundleLookup {
    /// The Kit target's resource bundle (`<Package>_<Target>`).
    public static let kitBundleName = "DeviceHubPro_DeviceHubProKit"
    /// The app target's resource bundle (`<Package>_<Target>`).
    public static let appBundleName = "DeviceHubPro_DeviceHubProApp"

    /// `<bundleName>.bundle` inside `resourceDirectory`, when that directory
    /// holds it.
    public static func packagedBundle(named bundleName: String, in resourceDirectory: URL?) -> Bundle? {
        guard let resourceDirectory else { return nil }
        let url = resourceDirectory.appendingPathComponent("\(bundleName).bundle", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return Bundle(url: url)
    }

    /// The URL of a bundled resource. A packaged bundle in
    /// `resourceDirectory` (the running app's `Contents/Resources` by
    /// default) wins and is authoritative: a resource missing from it is
    /// reported as missing instead of falling through to `module`, whose
    /// accessor may trap on a machine without the build directory. Without
    /// a packaged bundle, `module` (the target's `Bundle.module`) is asked.
    public static func url(
        forResource name: String,
        withExtension fileExtension: String?,
        bundleName: String,
        resourceDirectory: URL? = Bundle.main.resourceURL,
        module: () -> Bundle
    ) -> URL? {
        if let packaged = packagedBundle(named: bundleName, in: resourceDirectory) {
            return packaged.url(forResource: name, withExtension: fileExtension)
        }
        return module().url(forResource: name, withExtension: fileExtension)
    }
}
