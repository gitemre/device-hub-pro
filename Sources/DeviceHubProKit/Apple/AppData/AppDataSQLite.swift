import Foundation

/// A table or view of a SQLite database.
public struct SQLiteTable: Sendable, Equatable, Identifiable {
    public let name: String
    public let isView: Bool
    public var id: String { name }
}

/// A page of a table's rows, every value as text.
public struct SQLiteRows: Sendable, Equatable {
    public let columns: [String]
    public let rows: [[String]]
    /// The table's row count, which may exceed `rows.count`.
    public let totalRows: Int
    public var isTruncated: Bool { totalRows > rows.count }
}

/// A read-only browser over a **copy** of a SQLite database, run through the
/// system `sqlite3`. The database, and its `-wal` and `-shm` files, are
/// copied into a private temporary folder first and opened with `-readonly`,
/// so an app that is running keeps its own file and its own locks, and the
/// browser never writes to it. The copy shows the state at the moment it was
/// made; `reload()` takes a new one. `close()` removes the copy.
public final class SQLiteBrowser: @unchecked Sendable {
    public enum SQLiteError: Error, Equatable, CustomStringConvertible {
        case failed(String)
        case noSuchTable(String)
        case unreadable(String)

        public var description: String {
            switch self {
            case .failed(let message): "sqlite3: \(message)"
            case .noSuchTable(let name): "There is no table “\(name)”."
            case .unreadable(let detail): "sqlite3 printed something unreadable: \(detail)"
            }
        }
    }

    public static let defaultExecutable = URL(fileURLWithPath: "/usr/bin/sqlite3")
    public static let rowLimit = 500
    static let timeout: Duration = .seconds(20)

    public let source: URL
    private let executable: URL
    private let temporaryRoot: URL
    private let lock = NSLock()
    private var copyFolder: URL?

    public init(
        source: URL,
        executable: URL = SQLiteBrowser.defaultExecutable,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.source = source
        self.executable = executable
        self.temporaryRoot = temporaryDirectory
    }

    deinit { close() }

    /// Takes a fresh copy of the database (and its write-ahead files).
    public func reload() throws {
        close()
        let manager = FileManager.default
        let folder = temporaryRoot.appendingPathComponent("DeviceHubPro-sqlite-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            for suffix in ["", "-wal", "-shm"] {
                let from = URL(fileURLWithPath: source.path + suffix)
                guard manager.fileExists(atPath: from.path) else { continue }
                try manager.copyItem(at: from, to: folder.appendingPathComponent("db.sqlite" + suffix))
            }
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
        lock.lock()
        copyFolder = folder
        lock.unlock()
    }

    /// Removes the copy.
    public func close() {
        lock.lock()
        let folder = copyFolder
        copyFolder = nil
        lock.unlock()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func database() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard let copyFolder else { throw SQLiteError.failed("the database is not open") }
        return copyFolder.appendingPathComponent("db.sqlite")
    }

    /// `"name"` with its quotes doubled: the only way a name reaches a query.
    public static func quoteIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func query(_ sql: String) async throws -> [[String: Any]] {
        let database = try database()
        let result = try await ProcessRunner.run(
            executable: executable,
            arguments: ["-readonly", "-json", database.path, sql],
            timeout: Self.timeout
        )
        guard result.exitCode == 0 else {
            throw SQLiteError.failed(result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let text = result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return [] }
        guard let rows = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]] else {
            throw SQLiteError.unreadable(String(text.prefix(200)))
        }
        return rows
    }

    public func tables() async throws -> [SQLiteTable] {
        let rows = try await query(
            "SELECT name, type FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        return rows.compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            return SQLiteTable(name: name, isView: (row["type"] as? String) == "view")
        }
    }

    /// The first `limit` rows of `table` (a name `tables()` listed). A BLOB
    /// shows as `<blob n bytes>`.
    public func rows(of table: String, limit: Int = SQLiteBrowser.rowLimit) async throws -> SQLiteRows {
        guard try await tables().contains(where: { $0.name == table }) else { throw SQLiteError.noSuchTable(table) }
        let quoted = Self.quoteIdentifier(table)
        let columns = try await query("PRAGMA table_info(\(quoted))").compactMap { $0["name"] as? String }
        let total = try await query("SELECT COUNT(*) AS n FROM \(quoted)").first?["n"] as? Int ?? 0
        guard !columns.isEmpty else { return SQLiteRows(columns: [], rows: [], totalRows: total) }
        // Aliases c0, c1 … keep the result's keys apart from any column name.
        let select = columns.enumerated().map { index, column in
            let name = Self.quoteIdentifier(column)
            return "CASE WHEN typeof(\(name)) = 'blob' THEN '<blob ' || length(\(name)) || ' bytes>' ELSE \(name) END AS c\(index)"
        }.joined(separator: ", ")
        let records = try await query("SELECT \(select) FROM \(quoted) LIMIT \(max(0, limit))")
        let rows = records.map { record in
            columns.indices.map { Self.text(record["c\($0)"]) }
        }
        return SQLiteRows(columns: columns, rows: rows, totalRows: total)
    }

    static func text(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: "NULL"
        case let string as String: string
        case let number as NSNumber: number.stringValue
        case let other?: "\(other)"
        }
    }
}
