import Foundation

/// Simulator.app's two Debug items that Device Hub (Xcode 27) dropped: Slow
/// Animations and Simulate Memory Warning. Both are mechanisms of the
/// simulated OS, reached from the Mac without a private framework.
///
/// **Slow Animations.** UIKit inside the simulator watches the Darwin
/// notification `com.apple.UIKit.SimulatorSlowMotionAnimationState`: its
/// state (0 or 1) says whether animations are slowed, and a post makes
/// running apps re-read it. `notifyutil -s <name> <0|1> -p <name>` run in the
/// simulator (`simctl spawn`) sets the state and posts in one call. The state
/// lives for the boot, a newly launched app reads it at launch, and
/// `notifyutil -g` reads it back. Established against Xcode 27.0 (iOS 27.0
/// simulator runtime 24A434, UIKit): a 0.1 s `UIView` animation in the
/// verifier took more than three times as long after the state was set to 1 and
/// posted, ran at normal speed again after 0 and a post, and did not change
/// when only the state was set (no post).
///
/// **Simulate Memory Warning.** CoreSimulator gives each booted device the
/// file `<device>/data/var/run/memory_warning_simulation` (an empty file,
/// there from boot) and the simulated OS delivers one memory warning to every
/// running app each time the file's modification time is bumped (`touch`).
/// Appending to the file does nothing, and `devicectl device process
/// sendMemoryWarning` answers success but delivers none. Established against
/// Xcode 27.0 (CoreSimulator 1171.7, iOS 27.0 runtime 24A434): the verifier's
/// `UIApplication.didReceiveMemoryWarningNotification` count rose by one per
/// touch.
public enum SimulatorDebugActions {
    /// The Darwin notification (and its state) UIKit's slow animations follow.
    public static let slowAnimationsNotification = "com.apple.UIKit.SimulatorSlowMotionAnimationState"

    /// The file inside a device's data folder whose modification time asks
    /// for a memory warning.
    public static let memoryWarningFileComponents = ["var", "run", "memory_warning_simulation"]

    public enum MemoryWarningError: Error, Equatable, CustomStringConvertible {
        /// The device is not booted (the file is made at boot) or its folder is unknown.
        case notBooted(String)

        public var description: String {
            switch self {
            case .notBooted(let path):
                "The simulator is not running (no \(path))."
            }
        }
    }

    /// The memory warning file of a device whose data folder is `dataDirectory`.
    public static func memoryWarningFile(dataDirectory: URL) -> URL {
        memoryWarningFileComponents.reduce(dataDirectory) { $0.appendingPathComponent($1) }
    }

    /// Asks the simulated OS for one memory warning: bumps the file's
    /// modification time. The file must exist (it is made at boot): making it
    /// would not be seen.
    public static func simulateMemoryWarning(dataDirectory: URL, now: Date = Date()) throws {
        let file = memoryWarningFile(dataDirectory: dataDirectory)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw MemoryWarningError.notBooted(file.lastPathComponent)
        }
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    }
}

extension SimctlClient {
    /// Turns Simulator.app's Slow Animations on or off inside a booted
    /// simulator (`spawn <udid> notifyutil -s <name> <0|1> -p <name>`).
    public func setSlowAnimations(udid: String, enabled: Bool) async throws {
        try Self.validateUDID(udid)
        let name = SimulatorDebugActions.slowAnimationsNotification
        try await checked(["spawn", udid, "notifyutil", "-s", name, enabled ? "1" : "0", "-p", name])
    }

    /// Whether Slow Animations is on in this boot (the notification's state).
    public func slowAnimationsEnabled(udid: String) async throws -> Bool {
        try await notifyState(udid: udid, name: SimulatorDebugActions.slowAnimationsNotification) != 0
    }
}
