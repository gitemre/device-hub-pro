import Foundation

/// Who the report must not name: the user's home folder, account and full
/// name, and the Mac's names. `ProblemReportInputs.live` reads them; a test
/// supplies its own.
public struct ScrubIdentity: Sendable, Equatable {
    public var homePath: String
    public var userName: String
    public var fullName: String
    public var hostNames: [String]

    public init(homePath: String, userName: String, fullName: String, hostNames: [String]) {
        self.homePath = homePath
        self.userName = userName
        self.fullName = fullName
        self.hostNames = hostNames
    }
}

/// Takes what must not leave the Mac out of the strings of a report.
///
/// Every string value of the report's JSON goes through `scrub(_:)` (keys are
/// fixed by the schema, and no dictionary in it is keyed by user data except
/// `collection.removed`, which the scrubber writes itself), so a field added
/// later is covered without a change here. The passes run in this order, each
/// counted under its category in `removed`:
///
/// 1. secrets, given literally (`secret`);
/// 2. mDNS service names, the identifier table and the serials found where adb
///    puts one (`-s <serial>`, `device '<serial>' not found`), whether or not
///    the phone is connected now (`phoneSerial`, `udid`): phone serials become
///    `phone-N`, simulator UDIDs `sim-N`;
/// 3. the home folder, in its forms, and the per-user temporary folder
///    (`homePath`);
/// 4. the user name, where it is anchored (`/Users/<name>`, `android-<name>`,
///    `<name>@` with the host after it), and as a bare word only from four
///    characters (`userName`);
/// 5. the Mac's names (`hostName`), then the full name and its parts, ignoring
///    case and diacritics, with the Turkish dotted and dotless i folded
///    together (`fullName`);
/// 7. patterns: credentials in URLs (`secret`), emails, JWTs, base64 runs
///    (`token`, and the `user@host` comment after the adb key), hardware UDIDs
///    (`udid`), MAC addresses, IPv6, private IPv4 addresses and any IPv4
///    address with a port (`ipAddress`), and other UUIDs.
///
/// A string equal to a raw value of one of the report's enums
/// (`ProblemReport.enumRawValues`) is left alone, so a name or host that
/// equals one cannot make the report unreadable. The serials are learned from
/// every string first (in a fixed order), then replaced everywhere, so a
/// serial an error names in one place is also removed where it stands alone.
///
/// An alias is stable within one scrubber: the same raw value always gets the
/// same alias, so a report still shows which values were one.
public struct ProblemReportScrubber {
    /// What the scrubber replaced, by category.
    public private(set) var removed: [String: Int] = [:]

    private let identity: ScrubIdentity
    private let secrets: [String]
    /// Raw identifiers longest first, with their aliases.
    private let identifiers: [(raw: String, alias: String)]
    private let tables: Tables
    private let patterns = Patterns()

    /// The alias numbering that must survive from one string to the next.
    private final class Tables {
        var phoneAliases: [String: String] = [:]
        var nextPhone: Int
        var lanAddresses: [String: Int] = [:]
        var publicAddresses: [String: Int] = [:]
        var uuids: [String: Int] = [:]
        /// Serials found in the text (not in the identifier table), longest
        /// first, each with the expression that finds it as a whole token.
        var learned: [(raw: String, alias: String, regex: NSRegularExpression)] = []

        init(identifiers: [String: String]) {
            for (raw, alias) in identifiers where alias.hasPrefix("phone-") {
                phoneAliases[raw.lowercased()] = alias
            }
            let numbers = identifiers.values.compactMap { alias -> Int? in
                alias.hasPrefix("phone-") ? Int(alias.dropFirst("phone-".count)) : nil
            }
            nextPhone = (numbers.max() ?? 0) + 1
        }
    }

    public init(identity: ScrubIdentity, secrets: [String], identifiers: [String: String]) {
        self.identity = identity
        // A short value would replace too much of ordinary text.
        self.secrets = secrets.filter { $0.count >= 4 }.sorted { $0.count > $1.count }
        self.identifiers = identifiers.filter { $0.key.count >= 4 }
            .sorted { $0.key.count > $1.key.count }
            .map { (raw: $0.key, alias: $0.value) }
        self.tables = Tables(identifiers: identifiers)
    }

    // MARK: The report

    /// The report with every string scrubbed, and `collection.removed` set.
    /// A report that cannot be scrubbed (it always can) comes back empty
    /// rather than unscrubbed.
    public mutating func scrub(_ report: ProblemReport) -> ProblemReport {
        guard let data = try? ProblemReport.encoder().encode(report),
              let tree = try? JSONDecoder().decode(ReportJSON.self, from: data)
        else { return Self.emptyReport(like: report) }
        learnSerials(inTree: tree)
        let scrubbed = scrubTree(tree)
        guard let scrubbedData = try? JSONEncoder().encode(scrubbed),
              var result = try? ProblemReport.decoder().decode(ProblemReport.self, from: scrubbedData)
        else { return Self.emptyReport(like: report) }
        result.collection.removed = removed
        return result
    }

    /// Keys are visited in order, so the aliases of serials found in the text
    /// are numbered the same way every time.
    private mutating func scrubTree(_ value: ReportJSON) -> ReportJSON {
        switch value {
        case .string(let text):
            if ProblemReport.enumRawValues.contains(text) { return value }
            return .string(scrubLearned(text))
        case .array(let items):
            var scrubbed: [ReportJSON] = []
            for item in items { scrubbed.append(scrubTree(item)) }
            return .array(scrubbed)
        case .object(let fields):
            var scrubbed: [String: ReportJSON] = [:]
            for key in fields.keys.sorted() {
                if let field = fields[key] { scrubbed[key] = scrubTree(field) }
            }
            return .object(scrubbed)
        default:
            return value
        }
    }

    private mutating func learnSerials(inTree value: ReportJSON) {
        switch value {
        case .string(let text):
            if !ProblemReport.enumRawValues.contains(text) { learnSerials(in: text) }
        case .array(let items):
            for item in items { learnSerials(inTree: item) }
        case .object(let fields):
            for key in fields.keys.sorted() {
                if let field = fields[key] { learnSerials(inTree: field) }
            }
        default:
            break
        }
    }

    private static func emptyReport(like report: ProblemReport) -> ProblemReport {
        var empty = ProblemReport(
            id: report.id,
            createdAt: report.createdAt,
            producer: report.producer,
            app: ProblemReport.AppInfo(kind: report.app.kind),
            mac: ProblemReport.MacInfo(macOS: "unknown", appleSilicon: false),
            android: ProblemReport.AndroidInfo(
                consoleTokenFile: ProblemReport.TokenFileInfo(path: "", state: .missing),
                avdHome: ProblemReport.AvdHomeInfo(path: "", exists: false)
            ),
            apple: ProblemReport.AppleInfo()
        )
        empty.collection.notes = ["The report could not be scrubbed, so it holds nothing else."]
        return empty
    }

    // MARK: A string

    /// `text` without anything the passes name.
    public mutating func scrub(_ text: String) -> String {
        learnSerials(in: text)
        return scrubLearned(text)
    }

    /// `scrub(_:)` for a text its serials were already learned from.
    private mutating func scrubLearned(_ text: String) -> String {
        var text = text
        guard !text.isEmpty else { return text }

        for secret in secrets {
            text = replaceLiteral(secret, with: "\u{2039}redacted\u{203A}", in: text, category: "secret")
        }
        text = scrubIdentifiers(text)
        text = scrubHome(text)
        text = scrubUserName(text)
        text = scrubNames(text)
        text = scrubPatterns(text)
        return text
    }

    private mutating func add(_ category: String, _ count: Int) {
        if count > 0 { removed[category, default: 0] += count }
    }

    /// Every occurrence of `needle`, ignoring case.
    private mutating func replaceLiteral(_ needle: String, with replacement: String, in text: String, category: String) -> String {
        guard !needle.isEmpty else { return text }
        let mutable = NSMutableString(string: text)
        let count = mutable.replaceOccurrences(
            of: needle,
            with: replacement,
            options: [.caseInsensitive],
            range: NSRange(location: 0, length: mutable.length)
        )
        add(category, count)
        return mutable as String
    }

    /// Replaces each match of `regex` with what `transform` returns (nil keeps
    /// the match); returns the text and how many were replaced.
    private func replacing(
        _ regex: NSRegularExpression,
        in text: String,
        _ transform: (_ match: NSTextCheckingResult, _ source: NSString) -> String?
    ) -> (text: String, count: Int) {
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return (text, 0) }
        // Decided from the first match to the last (an alias is numbered in
        // reading order), applied from the last to the first (so the ranges hold).
        let replacements = matches.map { transform($0, source) }
        let result = NSMutableString(string: text)
        var count = 0
        for (match, replacement) in zip(matches, replacements).reversed() {
            guard let replacement else { continue }
            result.replaceCharacters(in: match.range, with: replacement)
            count += 1
        }
        return (result as String, count)
    }

    private mutating func replacing(
        _ regex: NSRegularExpression,
        in text: String,
        category: String,
        with replacement: String
    ) -> String {
        let outcome = replacing(regex, in: text) { _, _ in replacement }
        add(category, outcome.count)
        return outcome.text
    }

    // MARK: 2. Identifiers

    /// Remembers the serials a text names where adb puts one, so a phone that
    /// is not connected now is aliased too: `adb -s <serial> …`, adb's
    /// `device '<serial>' not found` and a phone's mDNS service name
    /// (`adb-<serial>-<6>` of `_adb-tls-connect._tcp`, `_adb-tls-pairing._tcp`
    /// or a listed `_adb._tcp`). A serial the table already knows keeps its
    /// alias; any other gets the next `phone-N`. An emulator's serial and an
    /// alias are not phones.
    private mutating func learnSerials(in text: String) {
        guard text.contains("-s") || text.contains("device '") || text.contains("_adb") else { return }
        let source = text as NSString
        let whole = NSRange(location: 0, length: source.length)
        for match in patterns.mdnsName.matches(in: text, range: whole) {
            learn(source.substring(with: match.range(at: 1)), minimumLength: 1)
        }
        for expression in [patterns.adbSerialArgument, patterns.adbDeviceNotFound] {
            for match in expression.matches(in: text, range: whole) {
                learn(source.substring(with: match.range(at: 1)), minimumLength: 4)
            }
        }
    }

    /// The alias of `serial`, new when it is not known; nil for something that
    /// is not a phone's serial.
    @discardableResult
    private func learn(_ serial: String, minimumLength: Int) -> String? {
        guard serial.count >= minimumLength, Self.isPhoneSerial(serial) else { return nil }
        let key = serial.lowercased()
        if let alias = tables.phoneAliases[key] { return alias }
        let alias = "phone-\(tables.nextPhone)"
        tables.nextPhone += 1
        tables.phoneAliases[key] = alias
        let escaped = NSRegularExpression.escapedPattern(for: serial)
        if let expression = try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])", options: [.caseInsensitive]
        ) {
            tables.learned.append((raw: serial, alias: alias, regex: expression))
            tables.learned.sort { $0.raw.count > $1.raw.count }
        }
        return alias
    }

    /// Not an emulator's serial (`emulator-5554`), not already one of this
    /// scrubber's aliases (`phone-1`, `adb-phone-1`, `sim-2`) and not a value
    /// a pass replaced (`<user>`, `‹redacted›`).
    private static func isPhoneSerial(_ serial: String) -> Bool {
        guard let first = serial.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) else { return false }
        let lowered = serial.lowercased()
        if lowered.range(of: "^emulator-[0-9]+$", options: .regularExpression) != nil { return false }
        if lowered.range(of: "^(adb-)?(phone|sim)(-[0-9]+|$)", options: .regularExpression) != nil { return false }
        return true
    }

    private mutating func scrubIdentifiers(_ input: String) -> String {
        var text = input
        let outcome = replacing(patterns.mdnsName, in: text) { match, source in
            let serial = source.substring(with: match.range(at: 1))
            // `adb-phone-1` is already an alias.
            guard let alias = learn(serial, minimumLength: 1) else { return nil }
            return "adb-\(alias)"
        }
        text = outcome.text
        add("phoneSerial", outcome.count)

        for identifier in identifiers {
            let category = identifier.alias.hasPrefix("phone-") ? "phoneSerial"
                : identifier.alias.hasPrefix("sim-") ? "udid" : "secret"
            text = replaceLiteral(identifier.raw, with: identifier.alias, in: text, category: category)
        }
        for found in tables.learned {
            text = replacing(found.regex, in: text, category: "phoneSerial", with: found.alias)
        }
        return text
    }

    // MARK: 3. Home folder

    private mutating func scrubHome(_ input: String) -> String {
        var text = input
        let home = identity.homePath
        if !home.isEmpty, home != "/" {
            let encoded = home.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? home
            // Longest first, so `/private/Users/u` is one match.
            let forms = [
                "/System/Volumes/Data" + home,
                "/private" + home,
                "file://" + encoded,
                home,
                home.replacingOccurrences(of: "/", with: "\\/"),
            ]
            for form in forms {
                let pattern = NSRegularExpression.escapedPattern(for: form) + "(?![A-Za-z0-9_-])"
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    text = replacing(regex, in: text, category: "homePath", with: "~")
                }
            }
        }
        let outcome = replacing(patterns.temporaryFolder, in: text) { _, _ in "$TMPDIR/" }
        add("homePath", outcome.count)
        return outcome.text
    }

    // MARK: 4. User name

    private mutating func scrubUserName(_ input: String) -> String {
        let user = identity.userName
        guard !user.isEmpty else { return input }
        var text = input
        let escaped = NSRegularExpression.escapedPattern(for: user)
        let anchored: [(pattern: String, replacement: String)] = [
            ("/Users/\(escaped)(?![A-Za-z0-9_-])", "~"),
            ("(?<![A-Za-z0-9_])android-\(escaped)(?![A-Za-z0-9_])", "android-<user>"),
        ]
        for entry in anchored {
            if let regex = try? NSRegularExpression(pattern: entry.pattern, options: [.caseInsensitive]) {
                text = replacing(regex, in: text, category: "userName", with: entry.replacement)
            }
        }
        // `<user>@<host>` (the comment adb writes into its key, a git author,
        // an address): the host is the Mac's name, whatever it is.
        if let regex = try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9_<])\(escaped)@(\(Patterns.hostToken))?", options: [.caseInsensitive]
        ) {
            var hosts = 0
            let outcome = replacing(regex, in: text) { match, source in
                let range = match.range(at: 1)
                guard range.location != NSNotFound else { return "<user>@" }
                let host = source.substring(with: range)
                if Self.keepsHost(host) { return "<user>@\(host)" }
                hosts += 1
                return "<user>@<host>"
            }
            text = outcome.text
            add("userName", outcome.count)
            add("hostName", hosts)
        }
        // The bare word, only when it is long enough not to hit ordinary text.
        if user.count >= 4, let regex = try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9_<])\(escaped)(?![A-Za-z0-9_>])", options: [.caseInsensitive]
        ) {
            text = replacing(regex, in: text, category: "userName", with: "<user>")
        }
        return text
    }

    /// Hosts that say nothing about the Mac: what `gethostname` gives when
    /// there is no name, and an alias this scrubber wrote.
    private static func keepsHost(_ host: String) -> Bool {
        host.hasPrefix("<") || ["localhost", "unknown"].contains(host.lowercased())
    }

    // MARK: 5. Names

    /// The Mac's names first, so a computer named after its owner ("Emre's
    /// Mac mini") is one `<host>`, then the user's full name and its parts.
    private mutating func scrubNames(_ input: String) -> String {
        var text = input
        let hosts = identity.hostNames.flatMap { host -> [String] in
            let plain = host.replacingOccurrences(of: "\u{2019}", with: "'")
            return plain == host ? [host] : [host, plain]
        }.filter { $0.count >= 3 }
        if !hosts.isEmpty {
            text = replaceNames(hosts, in: text, replacement: "<host>", category: "hostName")
        }
        let full = identity.fullName.trimmingCharacters(in: .whitespaces)
        if !full.isEmpty {
            var names = [full]
            names += full.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0.count >= 3 }
            text = replaceNames(names, in: text, replacement: "<name>", category: "fullName")
        }
        return text
    }

    /// Replaces each of `names` where it stands as a whole word, ignoring case
    /// and diacritics (Barış matches BARIŞ, barış, Baris and a decomposed
    /// form). The Turkish dotted and dotless i are folded first, in a way that
    /// keeps every UTF-16 offset, so the ranges found in the folded text cut
    /// the original.
    private mutating func replaceNames(_ names: [String], in text: String, replacement: String, category: String) -> String {
        let folded = Self.fold(text) as NSString
        var ranges: [NSRange] = []
        var seen = Set<String>()
        for name in names.sorted(by: { $0.count > $1.count }) {
            let needle = Self.fold(name)
            guard seen.insert(needle.lowercased()).inserted else { continue }
            var search = NSRange(location: 0, length: folded.length)
            while search.length > 0 {
                let found = folded.range(
                    of: needle,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: search
                )
                if found.location == NSNotFound { break }
                if Self.isWholeWord(found, in: folded) { ranges.append(found) }
                let next = found.location + max(found.length, 1)
                search = NSRange(location: next, length: folded.length - next)
            }
        }
        guard !ranges.isEmpty else { return text }

        // Longest first found the widest span; overlapping ones merge away.
        ranges.sort { $0.location < $1.location || ($0.location == $1.location && $0.length > $1.length) }
        var kept: [NSRange] = []
        for range in ranges {
            if let last = kept.last, range.location < last.location + last.length { continue }
            kept.append(range)
        }
        let result = NSMutableString(string: text)
        for range in kept.reversed() { result.replaceCharacters(in: range, with: replacement) }
        add(category, kept.count)
        return result as String
    }

    /// The dotless i and the dotted capital I of Turkish, folded to the plain
    /// ones. One UTF-16 unit each way, so offsets do not move.
    static func fold(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{0131}", with: "i").replacingOccurrences(of: "\u{0130}", with: "I")
    }

    private static func isWholeWord(_ range: NSRange, in text: NSString) -> Bool {
        func isWordCharacter(_ unit: unichar) -> Bool {
            guard let scalar = Unicode.Scalar(unit) else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
        }
        if range.location > 0, isWordCharacter(text.character(at: range.location - 1)) { return false }
        let end = range.location + range.length
        if end < text.length, isWordCharacter(text.character(at: end)) { return false }
        return true
    }

    // MARK: 7. Patterns

    private mutating func scrubPatterns(_ input: String) -> String {
        var text = input

        // Credentials first: `user:pass@host` would otherwise be read as an email.
        text = replacing(patterns.credentials, in: text, category: "secret", with: "<credentials>@")
        text = replacing(patterns.email, in: text, category: "email", with: "<email>")
        text = replacing(patterns.jwt, in: text, category: "token", with: "<token>")
        // The UDIDs before the base64 runs, which would take a 40-digit hash.
        text = replacing(patterns.hardwareUDID, in: text, category: "udid", with: "<udid>")
        text = replacing(patterns.sha1, in: text, category: "udid", with: "<udid>")

        // A base64 run is the adb public key and tokens: it has a `+`, ends in
        // `=`, or has digits and no `/`, or is longer than any path or word.
        // A long path (slashes, letters) is not.
        let base64 = replacing(patterns.base64, in: text) { match, source in
            let run = source.substring(with: match.range)
            let digits = run.filter(\.isNumber).count
            let looksEncoded = run.contains("+") || run.hasSuffix("=") || run.count >= 120
                || (!run.contains("/") && digits >= 3)
            return looksEncoded ? "<base64>" : nil
        }
        text = base64.text
        add("token", base64.count)

        // The comment after a key (`user@host`) names whoever made the key,
        // maybe on another Mac than this one.
        var commentHosts = 0
        let comments = replacing(patterns.keyComment, in: text) { match, source in
            let host = source.substring(with: match.range(at: 2))
            let keepHost = Self.keepsHost(host)
            let user = source.substring(with: match.range(at: 1))
            if user == "<user>", keepHost { return nil }
            if !keepHost { commentHosts += 1 }
            return "<user>@" + (keepHost ? host : "<host>")
        }
        text = comments.text
        add("userName", comments.count)
        add("hostName", commentHosts)

        text = replacing(patterns.mac, in: text, category: "macAddress", with: "<mac>")

        let ipv6 = replacing(patterns.ipv6, in: text) { match, source in
            let address = source.substring(with: match.range)
            if address == "::1" { return nil }
            let first = address.split(separator: ":", omittingEmptySubsequences: false).first.map { $0.lowercased() } ?? ""
            return first.count == 4 && first.hasPrefix("fd") ? "<tunnel>" : "<ipv6>"
        }
        text = ipv6.text
        add("ipv6", ipv6.count)

        let tables = self.tables
        var publicAddresses = 0
        let ipv4 = replacing(patterns.ipv4, in: text) { match, source in
            let octets = (1...4).compactMap { Int(source.substring(with: match.range(at: $0))) }
            guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return nil }
            let address = octets.map(String.init).joined(separator: ".")
            if Self.isPrivate(octets) {
                let number = tables.lanAddresses[address] ?? tables.lanAddresses.count + 1
                tables.lanAddresses[address] = number
                return "<lan-ip-\(number)>"
            }
            // Another address is kept (a four-part version number cannot be
            // told from one), unless it has a port: that is a wireless
            // debugging endpoint, a phone's address.
            guard !Self.isLocalToTheHost(octets), Self.hasPort(after: match, in: source) else { return nil }
            let number = tables.publicAddresses[address] ?? tables.publicAddresses.count + 1
            tables.publicAddresses[address] = number
            publicAddresses += 1
            return "<ip-\(number)>"
        }
        text = ipv4.text
        add("lanAddress", ipv4.count - publicAddresses)
        add("ipAddress", publicAddresses)

        let uuids = replacing(patterns.uuid, in: text) { match, source in
            let key = source.substring(with: match.range).lowercased()
            let number = tables.uuids[key] ?? tables.uuids.count + 1
            tables.uuids[key] = number
            return "<uuid-\(number)>"
        }
        text = uuids.text
        add("uuid", uuids.count)
        return text
    }

    /// An address on the local network: RFC 1918, link-local and carrier
    /// grade NAT. The emulator's own network (10.0.2.x), loopback and 0.0.0.0
    /// are not private to the user and stay; so do other addresses, which a
    /// four-part version number ("37.2.8.0") cannot be told from.
    private static func isPrivate(_ octets: [Int]) -> Bool {
        switch (octets[0], octets[1], octets[2]) {
        case (10, 0, 2): return false
        case (10, _, _): return true
        case (172, 16...31, _): return true
        case (192, 168, _): return true
        case (169, 254, _): return true
        case (100, 64...127, _): return true
        default: return false
        }
    }

    /// Loopback, 0.0.0.0 and the emulator's own network: the same on every Mac.
    private static func isLocalToTheHost(_ octets: [Int]) -> Bool {
        octets[0] == 127 || octets == [0, 0, 0, 0] || (octets[0] == 10 && octets[1] == 0 && octets[2] == 2)
    }

    /// Whether `:<port>` follows the match.
    private static func hasPort(after match: NSTextCheckingResult, in source: NSString) -> Bool {
        let end = match.range.location + match.range.length
        guard end < source.length else { return false }
        let tail = source.substring(with: NSRange(location: end, length: min(6, source.length - end)))
        return tail.range(of: "^:[0-9]{2,5}(?![0-9])", options: .regularExpression) != nil
    }

    /// The expressions, compiled once per scrubber.
    private struct Patterns {
        /// A host name after `user@`: ends on a letter or digit.
        static let hostToken = "[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?"

        let temporaryFolder = regex("(?:/private)?/var/folders/[A-Za-z0-9_]{2}/[A-Za-z0-9_]+/T/")
        let mdnsName = regex(
            "adb-([A-Za-z0-9]+)(?:-[A-Za-z0-9]{6})?(?=\\._adb-tls-(?:connect|pairing)\\._tcp|[ \\t]+_adb\\._tcp)"
        )
        /// `-s <serial>`, adb's device selector.
        let adbSerialArgument = regex("(?<![\\w-])-s[ \\t]+([A-Za-z0-9._:%\\[\\]-]*[A-Za-z0-9\\]])")
        /// adb's `device '<serial>' not found`.
        let adbDeviceNotFound = regex("\\bdevice '([^'\\s]+)' not found")
        /// The comment after an adb key: `<base64> user@host`.
        let keyComment = regex("(?<=<base64> )([^\\s\\]@]+)@([^\\s\\]]+)")
        let credentials = regex("(?<=://)[^\\s/@:]+:[^\\s/@]+@")
        let email = regex("[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}")
        let jwt = regex("eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]*")
        let hardwareUDID = regex("(?<![0-9A-Za-z])[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}(?![0-9A-Za-z])")
        let sha1 = regex("(?<![0-9A-Za-z])[0-9A-Fa-f]{40}(?![0-9A-Za-z])")
        let base64 = regex("[A-Za-z0-9+/]{40,}={0,2}")
        let mac = regex("(?<![0-9A-Fa-f:-])(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:-])")
        let ipv6 = regex(
            "(?<![0-9A-Za-z:.%])(?:"
                + "(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}"
                + "|(?:[0-9A-Fa-f]{1,4}:){1,7}:(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,6})?"
                + "|::[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,6}"
                + ")(?![0-9A-Za-z:.])"
        )
        let ipv4 = regex("(?<![0-9.])([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})(?![0-9]|\\.[0-9])")
        let uuid = regex(
            "(?<![0-9A-Za-z])[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}(?![0-9A-Za-z])"
        )

    }
}

/// Compiles one of the scrubber's expressions. They are literals in this
/// file; a bad one is a bug the tests find.
private func regex(_ pattern: String) -> NSRegularExpression {
    do {
        return try NSRegularExpression(pattern: pattern)
    } catch {
        preconditionFailure("Invalid scrub pattern \(pattern): \(error)")
    }
}

// MARK: - A JSON tree

/// A decoded JSON document, for the scrubber to walk without knowing the
/// report's shape.
indirect enum ReportJSON: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([ReportJSON])
    case object([String: ReportJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ReportJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: ReportJSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
