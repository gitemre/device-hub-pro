import DeviceHubProKit
import Foundation
import Observation
import Sparkle

/// In-app updates through Sparkle 2. Nothing starts unless the packaged
/// Info.plist names a feed and a public key (`UpdaterConfiguration`), so a
/// local build, a `.build/debug` run and the tests never touch Sparkle and
/// the menu item is hidden.
///
/// The automatic-check choice lives in Sparkle's own defaults
/// (`SUEnableAutomaticChecks`; the template's value is the default, on), so
/// there is one source of truth and Sparkle's own prompt writes the same key.
@MainActor
@Observable
final class AppUpdater {
    let configuration: UpdaterConfiguration
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    /// Mirrors the updater's state for the menu item.
    private(set) var canCheckForUpdates = false
    /// Stored so the Settings toggle re-renders when it changes.
    private(set) var automaticChecks = false

    var isEnabled: Bool { controller != nil }

    init(configuration: UpdaterConfiguration = .current) {
        self.configuration = configuration
        guard configuration.isEnabled else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
        self.controller = controller
        canCheckForUpdates = controller.updater.canCheckForUpdates
        automaticChecks = controller.updater.automaticallyChecksForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
        automaticChecks = controller?.updater.automaticallyChecksForUpdates ?? false
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
