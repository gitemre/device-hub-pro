import Foundation

/// Keeps the adb server's own mDNS discovery off until the user needs
/// wireless debugging.
///
/// macOS asks "Allow Device Hub Pro to find devices on local networks?" the first
/// time a process the app is responsible for joins the mDNS multicast group.
/// The adb server (started by the app's first adb call, which is the device
/// watcher at launch) does exactly that as soon as it starts, so on a fresh
/// Mac the question appeared before the user had done anything. adb reads
/// `ADB_MDNS=0` to start without mDNS discovery (`adb mdns check` then
/// answers "mdns discovery disabled", established against platform-tools
/// 37.0.1); the app puts it in its own environment, which the adb server and
/// every other adb call inherit, until a wireless need arrives (the Pair
/// Nearby Device sheet, a wireless device already connected, or a Mac that
/// used wireless debugging before), and then removes it.
///
/// A launch environment that sets `ADB_MDNS` itself is left alone, and an
/// adb server that another tool (Android Studio, a terminal) started is
/// not ours to change: only a server this app started with the variable
/// set answers "disabled", and only that one is restarted.
public enum AdbMdnsPolicy {
    public static let environmentKey = "ADB_MDNS"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var weDisabled = false

    /// Whether this process disabled mDNS and has not enabled it since.
    public static var isDisabledByApp: Bool {
        lock.withLock { weDisabled }
    }

    /// At launch: with no wireless need, starts every adb this process runs
    /// with mDNS discovery off. A value the launch environment already
    /// carries wins. Returns whether the app disabled it.
    @discardableResult
    public static func applyLaunchPolicy(
        localNetworkWanted: Bool,
        launchEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        lock.withLock {
            guard !localNetworkWanted, launchEnvironment[environmentKey] == nil, !weDisabled else {
                return weDisabled
            }
            setenv(environmentKey, "0", 1)
            weDisabled = true
            return true
        }
    }

    /// From now on adb is started with mDNS discovery. Returns whether the
    /// app had disabled it (an adb server started meanwhile may need a
    /// restart to pick the change up).
    @discardableResult
    public static func enable() -> Bool {
        lock.withLock {
            guard weDisabled else { return false }
            unsetenv(environmentKey)
            weDisabled = false
            return true
        }
    }

    /// Whether `adb mdns check`'s answer says discovery is disabled.
    public static func reportsDisabled(_ output: String) -> Bool {
        output.localizedCaseInsensitiveContains("mdns discovery disabled")
    }
}

extension AdbClient {
    /// The running adb server was started with mDNS discovery off (what
    /// `AdbMdnsPolicy` does before the first wireless need). A failed call
    /// counts as "not disabled", so a dead server is never restarted for it.
    public func mdnsDiscoveryDisabled() async -> Bool {
        do {
            let output = try await run(["mdns", "check"], timeout: .seconds(5))
            return AdbMdnsPolicy.reportsDisabled(output)
        } catch AdbError.commandFailed(_, _, let message) {
            return AdbMdnsPolicy.reportsDisabled(message)
        } catch {
            return false
        }
    }
}
