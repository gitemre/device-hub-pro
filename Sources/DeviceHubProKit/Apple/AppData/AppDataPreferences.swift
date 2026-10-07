import Foundation

/// How a UserDefaults value is shown and edited.
public enum PreferenceKind: String, CaseIterable, Sendable, Identifiable {
    case string, bool, integer, real, date, data, array, dictionary

    public var id: String { rawValue }

    /// The kinds the inspector writes: text, a switch and numbers. A date,
    /// data, array or dictionary is shown and can be deleted, not edited.
    public var isEditable: Bool {
        switch self {
        case .string, .bool, .integer, .real: true
        case .date, .data, .array, .dictionary: false
        }
    }
}

/// One key of a preferences plist.
public struct PreferenceEntry: Sendable, Equatable, Identifiable {
    public let key: String
    public let kind: PreferenceKind
    /// The value as the editor shows it: the text, `true`/`false`, the
    /// number, an ISO 8601 date, "n bytes", "n items".
    public let text: String

    public var id: String { key }
}

/// An app's `Library/Preferences/<bundle>.plist` (its UserDefaults), read as a
/// flat list of keys and written back in the format it had (binary, XML).
///
/// Edits are made on this value and reach the file only through `write(to:)`;
/// the caller makes sure the app is not running first (a running app and the
/// simulator's cfprefsd cache the values and would write their own over it).
public struct PreferencesDocument {
    public enum PreferencesError: Error, Equatable, CustomStringConvertible {
        case notADictionary
        case invalidValue(kind: PreferenceKind, text: String)
        case notEditable(String)
        case noSuchKey(String)

        public var description: String {
            switch self {
            case .notADictionary: "The file is not a property list with a dictionary at its root."
            case .invalidValue(let kind, let text): "“\(text)” is not a valid \(kind.rawValue)."
            case .notEditable(let key): "“\(key)” holds a value the inspector cannot edit; delete it or edit the file."
            case .noSuchKey(let key): "There is no key “\(key)”."
            }
        }
    }

    private var values: [String: Any]
    private var format: PropertyListSerialization.PropertyListFormat

    /// An empty document, written as a binary plist (a missing file's start).
    public init() {
        values = [:]
        format = .binary
    }

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.binary
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        guard let dictionary = object as? [String: Any] else { throw PreferencesError.notADictionary }
        values = dictionary
        self.format = format
    }

    public var entries: [PreferenceEntry] {
        values.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key in
            let (kind, text) = Self.describe(values[key] as Any)
            return PreferenceEntry(key: key, kind: kind, text: text)
        }
    }

    static func describe(_ value: Any) -> (PreferenceKind, String) {
        switch value {
        case let string as String:
            return (.string, string)
        case let date as Date:
            return (.date, ISO8601DateFormatter().string(from: date))
        case let data as Data:
            return (.data, "\(data.count) bytes")
        case let array as [Any]:
            return (.array, array.count == 1 ? "1 item" : "\(array.count) items")
        case let dictionary as [String: Any]:
            return (.dictionary, dictionary.count == 1 ? "1 item" : "\(dictionary.count) items")
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return (.bool, number.boolValue ? "true" : "false") }
            if CFNumberIsFloatType(number) { return (.real, "\(number.doubleValue)") }
            return (.integer, "\(number.int64Value)")
        default:
            return (.string, "\(value)")
        }
    }

    /// Sets `key` to the value `text` reads as for `kind` (an existing key may
    /// change between the editable kinds; a new key is added). A key that holds
    /// a date, data, array or dictionary is not overwritten.
    public mutating func set(key: String, kind: PreferenceKind, text: String) throws {
        if let existing = values[key], !Self.describe(existing).0.isEditable {
            throw PreferencesError.notEditable(key)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .string:
            values[key] = text
        case .bool:
            switch trimmed.lowercased() {
            case "true", "yes", "1": values[key] = true
            case "false", "no", "0": values[key] = false
            default: throw PreferencesError.invalidValue(kind: kind, text: text)
            }
        case .integer:
            guard let number = Int64(trimmed) else { throw PreferencesError.invalidValue(kind: kind, text: text) }
            values[key] = number
        case .real:
            guard let number = Double(trimmed), number.isFinite else {
                throw PreferencesError.invalidValue(kind: kind, text: text)
            }
            values[key] = number
        case .date, .data, .array, .dictionary:
            throw PreferencesError.notEditable(key)
        }
    }

    public mutating func remove(key: String) throws {
        guard values.removeValue(forKey: key) != nil else { throw PreferencesError.noSuchKey(key) }
    }

    /// Writes the plist atomically, in the format it was read in.
    public func write(to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: format, options: 0)
        try data.write(to: url, options: .atomic)
    }
}
