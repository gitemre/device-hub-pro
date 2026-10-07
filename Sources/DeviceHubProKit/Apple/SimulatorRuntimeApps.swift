import Foundation
import os

/// The apps Device Hub lists that `simctl listapps` leaves out.
///
/// `simctl listapps` prints the apps SpringBoard could launch. Device Hub's
/// Apps tab also lists the ones the system itself never launches (the
/// iMessage app hosts: ActivityMessagesApp, Memoji, Memoji Stickers, Stickers,
/// HashtagImages, BusinessExtensionsWrapper on iOS 26.5): each is a runtime
/// app bundle whose `Info.plist` says `LSApplicationLaunchProhibited`, and
/// `simctl appinfo <udid> <bundle id>` knows it. Measured on an iOS 26.5
/// simulator, the runtime's `Applications` folder holds 245 bundles and exactly
/// those six carry the key, so the list Device Hub shows is `listapps` plus
/// them (42 apps against 36).
public enum SimulatorRuntimeApps {
    /// The runtime's `Applications` folder, read from the path of a listed
    /// system app (`…/RuntimeRoot/Applications/Web.app`); nil when the
    /// listing names none.
    public static func applicationsFolder(from apps: [SimulatorApp]) -> URL? {
        for app in apps where app.applicationType == "System" {
            guard let path = app.path else { continue }
            let folder = URL(fileURLWithPath: path, isDirectory: true).deletingLastPathComponent()
            if folder.lastPathComponent == "Applications", folder.deletingLastPathComponent().lastPathComponent == "RuntimeRoot" {
                return folder
            }
        }
        return nil
    }

    private static let cache = OSAllocatedUnfairLock(initialState: [String: [String]]())

    /// The bundle identifiers of the launch-prohibited apps in `folder`, in
    /// name order. A runtime never changes after it is installed, so the
    /// answer is kept per folder.
    public static func launchProhibitedIdentifiers(in folder: URL) -> [String] {
        if let known = cache.withLock({ $0[folder.path] }) { return known }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        var identifiers: [String] = []
        for name in names where name.hasSuffix(".app") {
            guard let bundle = SimulatorAppBundle.read(app: folder.appendingPathComponent(name, isDirectory: true)),
                  bundle.launchProhibited, let identifier = bundle.bundleIdentifier
            else { continue }
            identifiers.append(identifier)
        }
        let found = identifiers
        cache.withLock { $0[folder.path] = found }
        return found
    }

    /// The launch-prohibited apps `listed` does not hold: the bundle
    /// identifiers to ask `simctl appinfo` about.
    public static func missingIdentifiers(from listed: [SimulatorApp]) -> [String] {
        guard let folder = applicationsFolder(from: listed) else { return [] }
        let known = Set(listed.map(\.bundleIdentifier))
        return launchProhibitedIdentifiers(in: folder).filter { !known.contains($0) }
    }
}
