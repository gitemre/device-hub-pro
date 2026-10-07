import XCTest
@testable import DeviceHubProKit

/// The stage navigation bar's emulator path against a real emulator: each
/// key reaches the guest over gRPC `sendKey` (evdev `KEY_BACK`,
/// `KEY_HOMEPAGE`, `KEY_APPSELECT`) and changes the resumed activity.
///
/// Runs only with `DHP_NAV_LIVE_SERIAL=emulator-NNNN` (an emulator the
/// run owns; never a phone) and `DHP_NAV_LIVE_GRPC_PORT=<its gRPC
/// port>`; skips otherwise. Leaves the emulator on its home screen.
final class NavigationKeyLiveTests: XCTestCase {
    private var serial = ""
    private var port = 0

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let serial = environment["DHP_NAV_LIVE_SERIAL"], serial.hasPrefix("emulator-"),
              let port = environment["DHP_NAV_LIVE_GRPC_PORT"].flatMap(Int.init)
        else { throw XCTSkip("set DHP_NAV_LIVE_SERIAL and DHP_NAV_LIVE_GRPC_PORT") }
        self.serial = serial
        self.port = port
    }

    func testBackHomeAndRecentsReachTheGuest() async throws {
        let settings = "com.android.settings/.Settings"

        try adb(["shell", "am", "start", "-n", settings])
        try await waitForResumed(contains: "settings")
        try await EmulatorNavigationKeys.press(.home, port: port)
        try await waitForResumed(notContaining: "settings")
        print("NAVLIVE home ok: \(try resumed())")

        try adb(["shell", "am", "start", "-n", settings])
        try await waitForResumed(contains: "settings")
        try await EmulatorNavigationKeys.press(.back, port: port)
        try await waitForResumed(notContaining: "settings")
        print("NAVLIVE back ok: \(try resumed())")

        try adb(["shell", "am", "start", "-n", settings])
        try await waitForResumed(contains: "settings")
        try await EmulatorNavigationKeys.press(.recents, port: port)
        // Recents is a state of the launcher, not an activity of its own:
        // its overview panel is on screen.
        try await waitForOverview()
        print("NAVLIVE recents ok: overview panel on screen")

        try await EmulatorNavigationKeys.press(.home, port: port)
        try await waitForResumed(notContaining: "settings")
    }

    private func waitForOverview() async throws {
        for _ in 0..<30 {
            let dump = try adb(["exec-out", "uiautomator", "dump", "/dev/tty"])
            if dump.contains("overview_panel") { return }
            try await Task.sleep(for: .milliseconds(300))
        }
        XCTFail("the overview panel never showed")
    }

    @discardableResult
    private func adb(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb")
        process.arguments = ["-s", serial] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func resumed() throws -> String {
        try adb(["shell", "dumpsys", "activity", "activities"])
            .split(separator: "\n")
            .filter { $0.lowercased().contains("resumed") && $0.contains("ActivityRecord") }
            .first.map(String.init) ?? ""
    }

    private func waitForResumed(contains word: String? = nil, notContaining other: String? = nil) async throws {
        for _ in 0..<30 {
            let line = try resumed().lowercased()
            if let word, line.contains(word) { return }
            if let other, !line.isEmpty, !line.contains(other) { return }
            try await Task.sleep(for: .milliseconds(300))
        }
        XCTFail("resumed activity never matched \(word ?? "!\(other ?? "")"): \(try resumed())")
    }
}
