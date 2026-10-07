import Foundation

/// The parts of `android.net.Uri` (`Uri.StringUri`) the Links rows model:
/// where it finds the authority and the host, how it decodes them
/// (`UriCodec`), what `Uri.toSafeString` — the `dat=` of the `Intent { … }`
/// that `am` prints — shows of a link, and which hosts App Links applies to
/// (`Patterns.DOMAIN_NAME`).
///
/// Everything walks Unicode scalars, not Swift characters: Android compares
/// UTF-16 units, and a `/` followed by a combining mark is one Swift
/// character but still Android's path separator.
enum LinkUri {
    // MARK: - Parts

    /// How a release finds the host (Uri.java android-9.0.0_r1 added `\`
    /// and the last `@`; android-10.0.0_r1 added `findPortSeparator`).
    enum HostRule: CaseIterable {
        /// API 29+: the authority ends at `/`, `\`, `?` or `#`; the host
        /// follows the last `@` and ends before a trailing `:digits` port
        /// (android-16.0.0_r1:737–760, 1121–1175).
        case current
        /// API 28: as `current`, but the host ends at the first `:` after
        /// the last `@`.
        case api28
        /// API 27 and older: the authority ends at `/`, `?` or `#`; the host
        /// follows the first `@` and ends at the first `:` after it.
        case api27
    }

    /// The index of the first `:` (`Uri.findSchemeSeparator`: any first
    /// colon; `LinkRequest` accepts only a valid scheme before it).
    static func schemeSeparator(of uri: String) -> String.Index? {
        uri.unicodeScalars.firstIndex(of: ":")
    }

    /// The encoded authority of a hierarchical `scheme://…` link
    /// (`StringUri.parseAuthority`); nil without `//` after the first `:`.
    static func authorityRange(of uri: String, rule: HostRule = .current) -> Range<String.Index>? {
        let scalars = uri.unicodeScalars
        guard let colon = schemeSeparator(of: uri) else { return nil }
        let afterColon = scalars.index(after: colon)
        guard scalars[afterColon...].starts(with: "//".unicodeScalars) else { return nil }
        let start = scalars.index(afterColon, offsetBy: 2)
        let end = scalars[start...].firstIndex { scalar in
            scalar == "/" || scalar == "?" || scalar == "#" || (scalar == "\\" && rule != .api27)
        } ?? scalars.endIndex
        return start..<end
    }

    /// The encoded host (`StringUri.parseHost` before `decode`); nil for an
    /// opaque link.
    static func encodedHostRange(of uri: String, rule: HostRule = .current) -> Range<String.Index>? {
        guard let authority = authorityRange(of: uri, rule: rule) else { return nil }
        let scalars = uri.unicodeScalars
        let slice = scalars[authority]
        let userInfoEnd: String.Index? = rule == .api27 ? slice.firstIndex(of: "@") : slice.lastIndex(of: "@")
        let start = userInfoEnd.map { scalars.index(after: $0) } ?? authority.lowerBound
        let end: String.Index
        switch rule {
        case .current:
            end = portSeparator(in: slice) ?? authority.upperBound
        case .api28, .api27:
            // `authority.indexOf(':', userInfoSeparator)`.
            end = scalars[(userInfoEnd ?? authority.lowerBound)..<authority.upperBound].firstIndex(of: ":")
                ?? authority.upperBound
        }
        return start..<max(start, end)
    }

    /// `findPortSeparator`: the `:` of a trailing `:digits` (ASCII digits
    /// only), searched from the end of the whole authority.
    private static func portSeparator(in authority: Substring.UnicodeScalarView) -> String.Index? {
        var index = authority.endIndex
        while index > authority.startIndex {
            let previous = authority.index(before: index)
            let scalar = authority[previous]
            if scalar == ":" { return previous }
            guard ("0"..."9").contains(scalar) else { return nil }
            index = previous
        }
        return nil
    }

    /// `Uri.getHost()`: the encoded host, decoded.
    static func host(of uri: String, rule: HostRule = .current) -> String? {
        encodedHostRange(of: uri, rule: rule).map { decode(text(uri, $0)) }
    }

    /// The exact scalars of `uri` in `range` (a `String` subscript would
    /// round the bounds to character boundaries).
    static func text(_ uri: String, _ range: Range<String.Index>) -> String {
        String(Substring(uri.unicodeScalars[range]))
    }

    // MARK: - Decoding

    /// `Uri.decode`: `UriCodec.decode(s, convertPlus: false, UTF_8,
    /// throwOnFailure: false)` (android-16.0.0_r1:77–176; libcore
    /// android-7.0.0_r1:271–378 is the same code), quirks included:
    ///
    /// - a `%` cut short by the end of the text becomes U+FFFD and ends the
    ///   decoding;
    /// - a `%` followed by a non-hex character becomes U+FFFD and then the
    ///   byte of the digits read so far (`%AZ` is U+FFFD and a line feed,
    ///   `%Z1` U+FFFD, NUL and `1`), the bad character consumed;
    /// - bytes that are not UTF-8 become U+FFFD (Swift's replacement may
    ///   count them differently from Java's; the ASCII bytes, line breaks
    ///   among them, come out the same).
    static func decode(_ text: String) -> String {
        let units = Array(text.utf16)
        var output: [UInt16] = []
        output.reserveCapacity(units.count)
        var bytes: [UInt8] = []
        func flush() {
            guard !bytes.isEmpty else { return }
            output.append(contentsOf: String(decoding: bytes, as: UTF8.self).utf16)
            bytes.removeAll(keepingCapacity: true)
        }
        var index = 0
        decoding: while index < units.count {
            let unit = units[index]
            index += 1
            guard unit == 0x25 else {
                flush()
                output.append(unit)
                continue
            }
            var value: UInt8 = 0
            for _ in 0..<2 {
                guard index < units.count else {
                    flush()
                    output.append(0xFFFD)
                    break decoding
                }
                let digit = hexValue(units[index])
                index += 1
                guard let digit else {
                    flush()
                    output.append(0xFFFD)
                    break
                }
                value = value &* 0x10 &+ digit
            }
            bytes.append(value)
        }
        flush()
        return String(decoding: output, as: UTF16.self)
    }

    private static func hexValue(_ unit: UInt16) -> UInt8? {
        switch unit {
        case 0x30...0x39: return UInt8(unit - 0x30)
        case 0x61...0x66: return UInt8(unit - 0x61 + 10)
        case 0x41...0x46: return UInt8(unit - 0x41 + 10)
        default: return nil
        }
    }

    // MARK: - What am prints

    /// Schemes `toSafeString` masks with `x` (API 21+).
    private static let maskedSchemes: Set<String> = ["tel", "sip", "sms", "smsto", "mailto", "nfc"]
    /// Schemes whose host alone `toSafeString` prints on every release.
    private static let hostOnlySchemes: Set<String> = ["http", "https", "ftp", "rtsp"]

    /// The `dat=` texts `am` can print for `uri` that hold a line break
    /// (a Unicode newline, `CharacterSet.newlines`), longest first; empty
    /// for almost every link.
    ///
    /// `Intent.toString()` shows the data as `Uri.toSafeString`: API 33+
    /// prints `scheme://` and the decoded host (android-16.0.0_r1:400–436);
    /// API 32 and older print it for http, https, ftp and rtsp, and the
    /// whole decoded scheme-specific part (the path and query included)
    /// for any other scheme (android-12.0.0_r1:399–440). A `%0A` there
    /// reaches `am`'s output as a real line break, so a link could print
    /// `Warning:` or `Status:` lines of its own (`LinkLaunchResult.parse`
    /// removes these texts first). Each host rule gives a candidate;
    /// before API 24 the PTY also turns each line feed into CR LF.
    static func safeStringEchoes(of uri: String) -> [String] {
        guard let colon = schemeSeparator(of: uri) else { return [] }
        let scalars = uri.unicodeScalars
        let scheme = text(uri, scalars.startIndex..<colon)
        let lowered = scheme.lowercased()
        guard !maskedSchemes.contains(lowered) else { return [] }
        var echoes: [String] = []
        if !hostOnlySchemes.contains(lowered) {
            let afterColon = scalars.index(after: colon)
            let sspEnd = scalars[afterColon...].firstIndex(of: "#") ?? scalars.endIndex
            echoes.append("dat=" + scheme + ":" + decode(text(uri, afterColon..<sspEnd)))
        }
        for rule in HostRule.allCases {
            if let host = host(of: uri, rule: rule) {
                echoes.append("dat=" + scheme + "://" + host)
            }
        }
        var seen = Set<[UInt8]>()
        var result: [String] = []
        for echo in echoes where echo.unicodeScalars.contains(where: CharacterSet.newlines.contains) {
            for form in [echo, echo.replacingOccurrences(of: "\n", with: "\r\n", options: .literal)]
            where seen.insert(Array(form.utf8)).inserted {
                result.append(form)
            }
        }
        return result.sorted { $0.utf16.count > $1.utf16.count }
    }

    /// `echo` with every Unicode newline replaced by a space, for
    /// `LinkLaunchResult.parse`.
    static func flattened(_ echo: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in echo.unicodeScalars {
            scalars.append(CharacterSet.newlines.contains(scalar) ? " " : scalar)
        }
        return String(scalars)
    }

    // MARK: - App Links hosts

    /// Whether App Links applies to `host`: it matches `Patterns.DOMAIN_NAME`
    /// (DomainVerificationUtils.isDomainVerificationIntent android-16.0.0_r1:
    /// 54–91; Patterns android-16.0.0_r1:293–356) — labels joined by dots
    /// ending in a top-level domain of 2+ letters (or `xn--…`), or an IPv4
    /// address. `localhost` and other single labels do not, so Android
    /// resolves such a link by intent filters alone, like a custom scheme.
    static func isDomainName(_ host: String) -> Bool {
        let scalars = Array(host.unicodeScalars)
        if isIPv4(scalars) { return true }
        let parts = scalars.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let tld = parts.last else { return false }
        return parts.dropLast().allSatisfy(isLabel) && isTopLevelDomain(tld)
    }

    /// `IRI_LABEL`: 1 to 63 label characters, `_` and `-` allowed inside.
    private static func isLabel(_ label: ArraySlice<Unicode.Scalar>) -> Bool {
        guard let first = label.first, let last = label.last, label.count <= 63,
              isLabelCharacter(first), isLabelCharacter(last)
        else { return false }
        return label.dropFirst().dropLast().allSatisfy { isLabelCharacter($0) || $0 == "_" || $0 == "-" }
    }

    /// `TLD`: `xn--` then 1 to 59 of `[\w-]` ending in `\w`, or 2 to 63
    /// letters (ASCII or UCS).
    private static func isTopLevelDomain(_ tld: ArraySlice<Unicode.Scalar>) -> Bool {
        let punycodePrefix = Array("xn--".unicodeScalars)
        if tld.starts(with: punycodePrefix) {
            let rest = tld.dropFirst(punycodePrefix.count)
            if let last = rest.last, rest.count <= 59, isWordCharacter(last),
               rest.dropLast().allSatisfy({ isWordCharacter($0) || $0 == "-" }) {
                return true
            }
        }
        return (2...63).contains(tld.count) && tld.allSatisfy { isASCIILetter($0) || isUCS($0) }
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }

    private static func isLabelCharacter(_ scalar: Unicode.Scalar) -> Bool {
        isASCIILetter(scalar) || isASCIIDigit(scalar) || isUCS(scalar)
    }

    /// Java's `\w` without UNICODE_CHARACTER_CLASS.
    private static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        isASCIILetter(scalar) || isASCIIDigit(scalar) || scalar == "_"
    }

    /// `UCS_CHAR`: RFC 3987's ranges without the space characters.
    private static func isUCS(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        switch value {
        case 0xA0, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x3000:
            return false
        case 0xA0...0xD7FF, 0xF900...0xFDCF, 0xFDF0...0xFFEF, 0xE1000...0xEFFFD:
            return true
        case 0x10000...0xDFFFF:
            return value & 0xFFFF <= 0xFFFD
        default:
            return false
        }
    }

    /// `IP_ADDRESS_STRING`: four dotted decimal octets; the first is never
    /// `0`, the others may be.
    private static func isIPv4(_ scalars: [Unicode.Scalar]) -> Bool {
        let octets = scalars.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        for (index, octet) in octets.enumerated() {
            guard octet.allSatisfy(isASCIIDigit) else { return false }
            let digits = octet.map { UInt8($0.value - 0x30) }
            switch digits.count {
            case 1:
                if index == 0, digits[0] == 0 { return false }
            case 2:
                if digits[0] == 0 { return false }
            case 3:
                let valid = digits[0] <= 1
                    || (digits[0] == 2 && digits[1] <= 4)
                    || (digits[0] == 2 && digits[1] == 5 && digits[2] <= 5)
                if !valid { return false }
            default:
                return false
            }
        }
        return true
    }
}
