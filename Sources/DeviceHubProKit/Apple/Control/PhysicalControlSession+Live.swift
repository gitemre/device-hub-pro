import Foundation

extension PhysicalControlSession {
    /// Apple's own apps, whose bundle identifiers `devicectl device info
    /// apps` does not list (it lists developer-installed and removable apps
    /// only). They are candidates for "which app owns the keyboard"; an
    /// identifier the phone does not have is simply never in the foreground.
    public static let commonAppleBundleIdentifiers: [String] = [
        "com.apple.Preferences", "com.apple.mobilesafari", "com.apple.MobileSMS", "com.apple.mobilenotes",
        "com.apple.MobileAddressBook", "com.apple.mobilecal", "com.apple.reminders", "com.apple.mobilemail",
        "com.apple.Maps", "com.apple.Music", "com.apple.Health", "com.apple.Passbook", "com.apple.camera",
        "com.apple.Photos", "com.apple.news", "com.apple.stocks", "com.apple.Fitness", "com.apple.shortcuts",
        "com.apple.facetime", "com.apple.mobilephone", "com.apple.AppStore", "com.apple.iBooks",
        "com.apple.Home", "com.apple.weather", "com.apple.calculator", "com.apple.compass",
        "com.apple.podcasts", "com.apple.VoiceMemos", "com.apple.Translate", "com.apple.findmy",
        "com.apple.mobiletimer", "com.apple.Passwords", "com.apple.journal", "com.apple.MobileStore",
    ]

    /// The phone's apps first, then Apple's common ones not already listed.
    static func mergedCandidates(installed: [String]) -> [String] {
        let present = Set(installed)
        return installed + commonAppleBundleIdentifiers.filter { !present.contains($0) }
    }

    /// The real session for `client`'s phone: the signed runner is built from
    /// `ios/agent` into the cache, started with the toolchain's Xcode, and
    /// reached through the phone's CoreDevice tunnel address (read from
    /// `device info details` at each start).
    ///
    /// Throws `.runnerSourcesMissing` when `ios/agent` is not part of this
    /// build and `.launchFailed` when there is no Xcode. `makeTransport` is
    /// for the live test, which watches the runner's own answers.
    public static func live(
        client: DevicectlPhysicalClient,
        toolchain: AppleToolchain,
        team: @escaping @Sendable () -> String?,
        makeTransport: (@Sendable (PhysicalControlEndpoint) -> any PhysicalControlTransport)? = nil,
        onChange: (@Sendable (PhysicalControlSnapshot) -> Void)? = nil
    ) throws -> PhysicalControlSession {
        guard let sources = PhysicalControlRunnerBuilder.locateSources() else {
            throw PhysicalControlError.runnerSourcesMissing
        }
        guard let developerDirectory = toolchain.developerDirectory else {
            throw PhysicalControlError.launchFailed("Xcode was not found")
        }
        let xcodebuild = developerDirectory.appendingPathComponent("usr/bin/xcodebuild")
        guard FileManager.default.isExecutableFile(atPath: xcodebuild.path) else {
            throw PhysicalControlError.launchFailed("Xcode was not found")
        }
        return PhysicalControlSession(
            target: PhysicalControlTarget(
                hardwareUDID: client.device.hardwareUDID,
                productType: client.device.productType
            ),
            team: team,
            tunnelAddress: { try await client.details().value.tunnelIPAddress },
            candidates: {
                // Best effort: the phone's whole list, else its developer/removable
                // apps; either way Apple's common apps follow.
                let all = try? await client.apps(includeAll: true).value.apps.map(\.bundleIdentifier)
                let installed: [String]
                if let all { installed = all } else {
                    installed = (try? await client.apps().value.apps.map(\.bundleIdentifier)) ?? []
                }
                return mergedCandidates(installed: installed)
            },
            provisioner: PhysicalControlRunnerBuilder(
                sourcesDirectory: sources,
                developerDirectory: developerDirectory,
                xcodeBuild: toolchain.xcodeBuild
            ),
            launcher: XcodebuildRunnerLauncher(xcodebuildURL: xcodebuild),
            developerDirectory: developerDirectory,
            makeTransport: makeTransport ?? { PhysicalControlURLSessionTransport(endpoint: $0) },
            onChange: onChange
        )
    }
}
