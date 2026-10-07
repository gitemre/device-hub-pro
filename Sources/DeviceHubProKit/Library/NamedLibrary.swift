import Foundation

/// An entry a user names and keeps: a saved push, a saved deep link.
public protocol NamedLibraryItem: Codable, Sendable, Equatable, Identifiable where ID == UUID {
    var id: UUID { get set }
    var name: String { get set }
}

/// An ordered list of named entries with unique (case-insensitive) names:
/// the pure part of the saved push and deep link libraries, so the rules are
/// tested without a file or a view.
public struct NamedLibrary<Item: NamedLibraryItem>: Sendable, Equatable {
    public private(set) var items: [Item]

    public init(items: [Item] = []) { self.items = items }

    public func item(id: UUID) -> Item? { items.first { $0.id == id } }

    /// Whether `name` can name an entry other than `id`: not empty, not
    /// another entry's.
    public func isNameAvailable(_ name: String, excluding id: UUID? = nil) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !items.contains { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// `base`, or `base 2`, `base 3` … when taken.
    public func freeName(_ base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = trimmed.isEmpty ? "Untitled" : trimmed
        if isNameAvailable(root) { return root }
        var number = 2
        while !isNameAvailable("\(root) \(number)") { number += 1 }
        return "\(root) \(number)"
    }

    /// Adds `item` under a free name (a taken one gets a number).
    @discardableResult
    public mutating func add(_ item: Item) -> Item {
        var item = item
        item.name = freeName(item.name)
        items.append(item)
        return item
    }

    /// Replaces the entry with the same id, keeping its position; its name
    /// stays unique (a clash keeps the old name).
    @discardableResult
    public mutating func update(_ item: Item) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return false }
        var item = item
        item.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isNameAvailable(item.name, excluding: item.id) { item.name = items[index].name }
        items[index] = item
        return true
    }

    @discardableResult
    public mutating func rename(id: UUID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = items.firstIndex(where: { $0.id == id }), isNameAvailable(trimmed, excluding: id) else {
            return false
        }
        items[index].name = trimmed
        return true
    }

    /// A copy named "<name> copy", "<name> copy 2" …, placed after the original.
    @discardableResult
    public mutating func duplicate(id: UUID) -> Item? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = items[index]
        copy.id = UUID()
        copy.name = freeName("\(items[index].name) copy")
        items.insert(copy, at: index + 1)
        return copy
    }

    @discardableResult
    public mutating func delete(id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items.remove(at: index)
        return true
    }
}

/// One JSON file in Device Hub Pro's Application Support folder (or any folder a
/// test names). A file that cannot be read loads as empty; an entry in it that
/// cannot be decoded is dropped, the others kept.
public struct LibraryFile: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// `~/Library/Application Support/DeviceHubPro`.
    public static var applicationSupportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("DeviceHubPro", isDirectory: true)
    }

    private struct Envelope<T: Codable>: Codable {
        var schema = 1
        var items: [T]
    }

    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: any Decoder) throws {
            value = try? decoder.singleValueContainer().decode(T.self)
        }
    }

    private struct LossyEnvelope<T: Decodable>: Decodable {
        let items: [Lossy<T>]
    }

    public func load<T: Codable>(_ type: T.Type = T.self) -> [T] {
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(LossyEnvelope<T>.self, from: data)
        else { return [] }
        return envelope.items.compactMap(\.value)
    }

    @discardableResult
    public func save<T: Codable>(_ items: [T]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Envelope(items: items)).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
