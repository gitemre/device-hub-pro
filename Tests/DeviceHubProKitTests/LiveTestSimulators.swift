import Foundation
import XCTest
@testable import DeviceHubProKit

/// The only way iOS live tests get a simulator — the counterpart of
/// `LiveTestDevices`, and stricter.
///
/// Without `DHP_IOS_LIVE=1` every iOS live test skips: "a simulator is
/// booted" is not safe to act on, because the default device set is shared
/// with Xcode, Device Hub and other tools. With it, a test gets a private
/// device set under `$TMPDIR/devicehubpro-live-sims/<run>` and creates its own
/// device there; `tearDown()` shuts it down, deletes it, and removes both the
/// set folder and `~/Library/Logs/CoreSimulator/<UDID>` (which simctl's
/// `delete` leaves behind, even for a private set). Candidates only ever come
/// from `simctl list`, which cannot list a physical device, and no selector
/// such as `booted` is ever passed.
///
/// devicectl cannot see private sets, so a devicectl live test uses
/// `pinnedDefaultSetSimulator`, which accepts only a UDID named in
/// `DHP_SIM_UDID` that the default set's `simctl list` shows.
enum LiveTestSimulators {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["DHP_IOS_LIVE"] == "1"
    }

    /// The folder CoreSimulator writes every device's logs into.
    static var logsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CoreSimulator", isDirectory: true)
    }

    /// A usable toolchain, or a skip explaining why there is none.
    static func toolchain() async throws -> AppleToolchain {
        guard isEnabled else {
            throw XCTSkip("iOS live tests run only with DHP_IOS_LIVE=1")
        }
        let toolchain = await AppleToolchain.probe()
        guard toolchain.simctlUsable else {
            throw XCTSkip("simctl is not usable: \(toolchain.setupAdvice ?? "unknown")")
        }
        return toolchain
    }

    /// One private device set holding at most one device this test run created.
    final class Session: @unchecked Sendable {
        let toolchain: AppleToolchain
        let setDirectory: URL
        let simctl: SimctlClient
        private(set) var udid: String?

        init(toolchain: AppleToolchain) throws {
            self.toolchain = toolchain
            setDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("devicehubpro-live-sims", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: setDirectory, withIntermediateDirectories: true)
            guard let simctl = toolchain.makeSimctlClient(deviceSet: setDirectory) else {
                throw XCTSkip("simctl is not usable")
            }
            self.simctl = simctl
        }

        /// Creates an iPhone 17 Pro on the newest available iOS runtime that
        /// supports it (or that runtime's first iPhone).
        func createDevice(name: String) async throws -> SimulatorDevice {
            precondition(udid == nil, "one device per session")
            let runtimes = try await simctl.listRuntimes()
                .filter { $0.platform == "iOS" && $0.isAvailable }
                .sorted { AppleToolchain.compareVersions($0.version, $1.version) == .orderedAscending }
            guard let runtime = runtimes.last else { throw XCTSkip("no iOS simulator runtime installed") }
            let preferred = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
            let deviceType = runtime.supportedDeviceTypeIdentifiers.contains(preferred)
                ? preferred
                : try XCTUnwrap(runtime.supportedDeviceTypeIdentifiers.first { $0.contains("iPhone") })
            let created = try await simctl.create(
                name: name,
                deviceTypeIdentifier: deviceType,
                runtimeIdentifier: runtime.identifier
            )
            udid = created
            let device = try await simctl.listDevices().first { $0.udid == created }
            return try XCTUnwrap(device, "the created device is not in the set's listing")
        }

        /// Shuts the device down (if booted), deletes it, and removes its log
        /// folder and the set folder. Returns what could not be removed.
        @discardableResult
        func tearDown() async -> [String] {
            var leftovers: [String] = []
            let fileManager = FileManager.default
            if let udid {
                // Best effort: a device that never booted fails `shutdown`
                // with SimError 405, which is fine here.
                try? await simctl.shutdown(udid: udid)
                do {
                    try await simctl.delete(udid: udid)
                } catch {
                    leftovers.append("device \(udid): \(error)")
                }
                let logs = LiveTestSimulators.logsDirectory.appendingPathComponent(udid, isDirectory: true)
                // CoreSimulatorService may still be writing the folder right
                // after the delete; retry briefly.
                for _ in 0..<10 where fileManager.fileExists(atPath: logs.path) {
                    // Best effort: a failed removal is retried, then reported.
                    try? fileManager.removeItem(at: logs)
                    if fileManager.fileExists(atPath: logs.path) {
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                }
                if fileManager.fileExists(atPath: logs.path) {
                    leftovers.append(logs.path)
                }
                self.udid = nil
            }
            // Best effort: reported below when it survives.
            try? fileManager.removeItem(at: setDirectory)
            if fileManager.fileExists(atPath: setDirectory.path) {
                leftovers.append(setDirectory.path)
            }
            let parent = setDirectory.deletingLastPathComponent()
            if (try? fileManager.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
                // Best effort: another run may be using the parent folder.
                try? fileManager.removeItem(at: parent)
            }
            return leftovers
        }
    }

    /// The default-set simulator named in `DHP_SIM_UDID`, for devicectl
    /// live tests. Refused unless the default set's `simctl list` shows it,
    /// so a physical device's identifier can never get through.
    static func pinnedDefaultSetSimulator(toolchain: AppleToolchain) async throws -> SimulatorDevice {
        guard let pinned = ProcessInfo.processInfo.environment["DHP_SIM_UDID"], !pinned.isEmpty else {
            throw XCTSkip("devicectl live tests need DHP_SIM_UDID (a default-set simulator)")
        }
        let simctl = try XCTUnwrap(toolchain.makeSimctlClient())
        guard let device = try await simctl.listDevices().first(where: { $0.udid == pinned }) else {
            throw XCTSkip("DHP_SIM_UDID \(pinned) is not a simulator in the default set; refused")
        }
        return device
    }
}
