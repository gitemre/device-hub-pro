import Foundation

/// A deep link kept under a name, optionally grouped (by app: a scheme or a
/// bundle id).
public struct SavedLink: NamedLibraryItem {
    public var id: UUID
    public var name: String
    public var url: String
    /// A free label, typically the app's scheme or bundle id; nil is ungrouped.
    public var group: String?

    public init(id: UUID = UUID(), name: String, url: String, group: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.group = group
    }

    /// The scheme of a non-web link ("myapp" for `myapp://x`), the natural
    /// per-app group; nil for http(s) links and text with no scheme.
    public static func suggestedGroup(for url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":"), colon != trimmed.startIndex else { return nil }
        let scheme = String(trimmed[..<colon]).lowercased()
        guard scheme != "http", scheme != "https",
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) else { return nil }
        return scheme
    }

    /// The links in sections: named groups sorted, the ungrouped last.
    public static func sections(_ links: [SavedLink]) -> [(group: String?, links: [SavedLink])] {
        var named: [String: [SavedLink]] = [:]
        var loose: [SavedLink] = []
        for link in links {
            if let group = link.group, !group.isEmpty { named[group, default: []].append(link) } else { loose.append(link) }
        }
        var sections: [(group: String?, links: [SavedLink])] = named.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { (group: Optional($0), links: named[$0] ?? []) }
        if !loose.isEmpty { sections.append((group: nil, links: loose)) }
        return sections
    }
}
