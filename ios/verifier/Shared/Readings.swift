import Foundation

/// One row's reading: the text the row shows, and a stable token a test can
/// compare (the value Device Hub Pro wrote where there is one, such as simctl's
/// content size name).
struct Reading: Codable, Sendable, Equatable {
    var value: String
    var raw: String

    init(_ value: String, raw: String) {
        self.value = value
        self.raw = raw
    }
}

/// `Documents/readings.json`, rewritten on every change; a test reads it back
/// through `simctl get_app_container <udid> com.devicehubpro.verifier data`.
struct ReadingsDocument: Codable, Sendable, Equatable {
    struct Row: Codable, Sendable, Equatable {
        let title: String
        let observes: Observes
        let value: String
        let raw: String
        /// The last change since launch; nil (absent from the file) while the
        /// row still shows its first reading.
        let changedAt: Date?
        let changes: Int
    }

    static let fileName = "readings.json"
    static let schema = 1

    var schema = ReadingsDocument.schema
    let bundle: String
    let system: String
    let launchedAt: Date
    let writtenAt: Date
    let rows: [String: Row]

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ReadingsDocument.timestamp(date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = ReadingsDocument.date(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: text))
            }
            return date
        }
        return decoder
    }

    /// ISO 8601 in UTC with milliseconds (`2026-09-26T14:02:11.123Z`).
    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    static func date(_ text: String) -> Date? {
        try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)
    }
}

/// The rows' texts, kept free of UIKit so `swift test` checks them on the Mac.
enum Readings {
    static func toggle(_ on: Bool, detail: String? = nil) -> Reading {
        Reading([on ? "On" : "Off", detail].compactMap { $0 }.joined(separator: " · "), raw: on ? "on" : "off")
    }

    static func appearance(dark: Bool) -> Reading {
        dark ? Reading("Dark", raw: "dark") : Reading("Light", raw: "light")
    }

    /// simctl's content size names (`simctl ui <udid> content_size`), in
    /// order; devicectl's `--text-size` takes the same words.
    static let textSizes: [(token: String, name: String)] = [
        ("extra-small", "Extra Small"),
        ("small", "Small"),
        ("medium", "Medium"),
        ("large", "Large (default)"),
        ("extra-large", "Extra Large"),
        ("extra-extra-large", "Extra Extra Large"),
        ("extra-extra-extra-large", "Extra Extra Extra Large"),
        ("accessibility-medium", "Accessibility Medium"),
        ("accessibility-large", "Accessibility Large"),
        ("accessibility-extra-large", "Accessibility Extra Large"),
        ("accessibility-extra-extra-large", "Accessibility Extra Extra Large"),
        ("accessibility-extra-extra-extra-large", "Accessibility Extra Extra Extra Large"),
    ]

    /// A text size by its position among the twelve (SwiftUI's
    /// `DynamicTypeSize` order); nil outside them.
    static func textSize(index: Int) -> Reading? {
        guard textSizes.indices.contains(index) else { return nil }
        let size = textSizes[index]
        return Reading("\(size.name) · \(index + 1) of \(textSizes.count)", raw: size.token)
    }

    static func location(latitude: Double, longitude: Double, accuracy: Double, at date: Date) -> Reading {
        let point = String(format: "%.5f,%.5f", latitude, longitude)
        let shown = String(format: "%.5f, %.5f", latitude, longitude)
        return Reading("\(shown) · ±\(Int(accuracy.rounded())) m · \(clock(date))", raw: point)
    }

    static func locationUnavailable(_ why: String) -> Reading {
        Reading(why, raw: "none")
    }

    /// The first preferred language, the region format's identifier and the
    /// direction that language writes in.
    static func language(preferred: [String], localeIdentifier: String, rightToLeft: Bool) -> Reading {
        let first = preferred.first ?? "none"
        let others = preferred.count > 1 ? " (+\(preferred.count - 1) more)" : ""
        return Reading(
            "\(first)\(others) · region \(localeIdentifier) · \(rightToLeft ? "RTL" : "LTR")",
            raw: first
        )
    }

    static func timeZone(identifier: String, secondsFromGMT: Int) -> Reading {
        let sign = secondsFromGMT < 0 ? "-" : "+"
        let minutes = abs(secondsFromGMT) / 60
        let offset = String(format: "GMT%@%02d:%02d", sign, minutes / 60, minutes % 60)
        return Reading("\(identifier) · \(offset)", raw: identifier)
    }

    /// The hour format a locale's `j` skeleton expands to: `H` and `k` are
    /// 24-hour, `h` and `K` 12-hour.
    static func timeFormat(pattern: String) -> Reading {
        var inQuote = false
        for character in pattern {
            if character == "'" {
                inQuote.toggle()
                continue
            }
            guard !inQuote else { continue }
            switch character {
            case "H", "k": return Reading("24-hour (\(pattern))", raw: "24")
            case "h", "K": return Reading("12-hour (\(pattern))", raw: "12")
            default: continue
            }
        }
        return Reading("Unknown (\(pattern))", raw: "unknown")
    }

    /// `UIDevice.batteryLevel` (-1 when unknown).
    static func batteryLevel(_ level: Float) -> Reading {
        guard level >= 0 else {
            return Reading("-1 (unknown) · apps do not see the override", raw: "-1")
        }
        let percent = Int((level * 100).rounded())
        return Reading("\(percent) %", raw: String(percent))
    }

    /// `UIDevice.BatteryState`'s raw value: 0 unknown, 1 unplugged, 2 charging, 3 full.
    static func batteryState(_ rawState: Int) -> Reading {
        switch rawState {
        case 1: return Reading("Unplugged", raw: "unplugged")
        case 2: return Reading("Charging", raw: "charging")
        case 3: return Reading("Full", raw: "full")
        default: return Reading("Unknown · apps do not see the override", raw: "unknown")
        }
    }

    /// `LABiometryType` by name: "faceID", "touchID", "opticID" or "none".
    static func biometrics(type: String, enrolled: Bool, lastMatch: (result: String, at: Date)?) -> Reading {
        let name: String
        switch type {
        case "faceID": name = "Face ID"
        case "touchID": name = "Touch ID"
        case "opticID": name = "Optic ID"
        default: name = "No biometry"
        }
        var parts = [name]
        if type != "none" {
            parts.append(enrolled ? "enrolled" : "not enrolled")
        }
        if let lastMatch {
            parts.append("last match \(lastMatch.result) at \(clock(lastMatch.at))")
        }
        let raw = type == "none" ? "none" : "\(type):\(enrolled ? "enrolled" : "notEnrolled")"
        return Reading(parts.joined(separator: " · "), raw: raw)
    }

    /// `UIDeviceOrientation`'s raw value, as devicectl's orientation names:
    /// 1 portrait, 2 portraitUpsideDown, 3 landscapeLeft, 4 landscapeRight,
    /// 5 faceUp, 6 faceDown, else unknown.
    static func orientation(_ rawValue: Int) -> Reading {
        let names: [Int: (String, String)] = [
            1: ("Portrait", "portrait"),
            2: ("Portrait upside down", "portraitUpsideDown"),
            3: ("Landscape left", "landscapeLeft"),
            4: ("Landscape right", "landscapeRight"),
            5: ("Face up", "faceUp"),
            6: ("Face down", "faceDown"),
        ]
        guard let (name, token) = names[rawValue] else { return Reading("Unknown", raw: "unknown") }
        return Reading(name, raw: token)
    }

    /// The Liquid Glass row's standing note: apps cannot read the opacity.
    static let liquidGlass = Reading("Not readable by apps · watch the glass header", raw: "unreadable")

    static func volume(_ level: Float) -> Reading {
        let percent = Int((level * 100).rounded())
        return Reading("\(percent) %", raw: String(percent))
    }

    static func grayscale(_ on: Bool) -> Reading {
        on ? Reading("Grayscale", raw: "grayscale") : Reading("No grayscale filter", raw: "none")
    }

    static func memoryWarnings(count: Int, last: Date?) -> Reading {
        guard let last, count > 0 else { return Reading("None since launch", raw: "0") }
        return Reading("\(count) since launch · last at \(clock(last))", raw: String(count))
    }

    /// Authorization per service, in a fixed order; each status is the
    /// framework's case name ("authorizedWhenInUse", "denied", …).
    static let permissionServices = [
        "location", "photos", "contacts", "calendar", "reminders", "microphone", "camera", "motion", "mediaLibrary",
    ]

    static func permissions(_ statuses: [String: String]) -> Reading {
        let pairs = permissionServices.map { ($0, statuses[$0] ?? "unknown") }
        return Reading(
            pairs.map { "\($0.0): \($0.1)" }.joined(separator: "\n"),
            raw: pairs.map { "\($0.0)=\($0.1)" }.joined(separator: ",")
        )
    }

    static func link(_ url: String, at date: Date) -> Reading {
        Reading("\(url) · \(clock(date))", raw: url)
    }

    static let noLink = Reading("None since launch", raw: "none")

    /// The last push notification's title and body.
    static func push(title: String, body: String, at date: Date) -> Reading {
        let text = [title, body].filter { !$0.isEmpty }.joined(separator: " — ")
        return Reading("\(text.isEmpty ? "(no text)" : text) · \(clock(date))", raw: text)
    }

    static let noPush = Reading("None since launch", raw: "none")

    /// What the general pasteboard holds, by type only (reading the contents
    /// would show iOS's paste prompt).
    static func pasteboard(changeCount: Int, hasStrings: Bool, hasURLs: Bool, hasImages: Bool) -> Reading {
        let kinds = [(hasStrings, "text"), (hasURLs, "URL"), (hasImages, "image")].filter(\.0).map(\.1)
        return Reading(
            "Change \(changeCount) · \(kinds.isEmpty ? "empty" : kinds.joined(separator: ", "))",
            raw: String(changeCount)
        )
    }

    /// A time of day in 24-hour form, whatever the locale, so readings
    /// compare across the 24-hour row's changes.
    static func clock(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }
}
