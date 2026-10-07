import Foundation

/// Whether the packaged app can check for updates, decided from the two
/// Info.plist values `Scripts/package-app.sh` fills in at build time:
/// `SUFeedURL` (from `DHP_APPCAST_URL`) and `SUPublicEDKey` (from
/// `DHP_SPARKLE_PUBLIC_KEY`). The checked-in template holds both empty,
/// so a local build, a development run and `swift test` have no updater: the
/// app never starts Sparkle and hides "Check for Updates…".
///
/// The feed must be an https URL (a feed that can be rewritten in transit
/// defeats the signed update flow), and the key must be non-empty; with only
/// one of them set the updater stays off rather than start half configured.
public struct UpdaterConfiguration: Equatable, Sendable {
    public let feedURL: URL?
    public let publicKey: String?

    public init(infoDictionary: [String: Any]?) {
        let feed = (infoDictionary?["SUFeedURL"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = (infoDictionary?["SUPublicEDKey"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let url = URL(string: feed), url.scheme?.lowercased() == "https", url.host?.isEmpty == false {
            feedURL = url
        } else {
            feedURL = nil
        }
        publicKey = key.isEmpty ? nil : key
    }

    /// The configuration of the running app.
    public static var current: UpdaterConfiguration {
        UpdaterConfiguration(infoDictionary: Bundle.main.infoDictionary)
    }

    public var isEnabled: Bool { feedURL != nil && publicKey != nil }
}
