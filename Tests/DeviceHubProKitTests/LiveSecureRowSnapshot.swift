import Foundation
@testable import DeviceHubProKit

/// One secure settings row as `content query` prints it, and the shell line
/// that puts it back exactly, for live tests that change accessibility
/// settings. A plain `settings put` on an existing row sets
/// `is_preserved_in_restore=true`, so "put the old value back" alone does not
/// restore a row. `_id` changes on every mutation and is ignored.
///
/// Restores, each verified on the API 37 emulator (`ColorFilterIntegrationTests`
/// and the spec review's `content-query-secure.notes.txt`):
/// - `No result found.` → `settings delete`
/// - a value, not preserved → delete, then one `settings put` (a fresh row is
///   not preserved)
/// - a value, preserved → delete, then two puts (a second put on an existing
///   row marks it preserved, even with the same value)
/// - `value=NULL`, not preserved → delete, then `content call … PUT_secure`
///   with no value and `_overrideable_by_restore:b:true`
/// - `value=NULL`, preserved → not seen; no restore is guessed
struct LiveSecureRowSnapshot: Equatable, CustomStringConvertible {
    enum State: Equatable {
        case absent
        /// `value` is nil for `value=NULL`.
        case row(value: String?, preservedInRestore: Bool)

        /// The row's value; nil when absent or NULL.
        var value: String? {
            if case .row(let value, _) = self { return value }
            return nil
        }
    }

    let key: String
    let state: State

    var description: String {
        switch state {
        case .absent:
            return "\(key): absent"
        case .row(let value, let preserved):
            return "\(key): value=\(value ?? "NULL"), is_preserved_in_restore=\(preserved)"
        }
    }

    /// One key's answer (`content query --uri content://settings/secure/<key>`):
    /// `No result found.`, or its one row. nil for anything else.
    static func parse(_ output: String, key: String) -> LiveSecureRowSnapshot? {
        if output.trimmingCharacters(in: .whitespacesAndNewlines) == "No result found." {
            return LiveSecureRowSnapshot(key: key, state: .absent)
        }
        guard let rows = rows(output), rows.count == 1, let state = rows[key] else { return nil }
        return LiveSecureRowSnapshot(key: key, state: state)
    }

    /// Every row of a `content query` answer by name:
    /// `Row: 0 _id=246, name=K, value=0, is_preserved_in_restore=false`. The
    /// value is the text between `value=` and the last
    /// `, is_preserved_in_restore=` (a value may hold commas, or run over
    /// several lines). Before Android 11 SettingsProvider has no such column
    /// (`ALL_COLUMNS = {_ID, NAME, VALUE}`, SettingsProvider.java
    /// android-9.0.0_r1 and android-10.0.0_r1; the column arrives in
    /// android-11.0.0_r1), so a row ends at its value and reads as not
    /// preserved: a delete and one put recreate it exactly there. nil when a
    /// row does not read either way.
    static func rows(_ output: String) -> [String: State]? {
        var records: [String] = []
        for line in output.components(separatedBy: "\n") {
            if isRowStart(line) {
                records.append(line)
            } else if !records.isEmpty {
                records[records.count - 1] += "\n" + line
            }
        }
        guard !records.isEmpty else { return nil }
        var rows: [String: State] = [:]
        for record in records {
            let text = record.trimmingCharacters(in: .newlines)
            guard let nameStart = text.range(of: ", name="),
                  let valueStart = text.range(of: ", value=", range: nameStart.upperBound..<text.endIndex)
            else { return nil }
            let name = String(text[nameStart.upperBound..<valueStart.lowerBound])
            let value: String
            let preserved: Bool
            if let flag = text.range(of: ", is_preserved_in_restore=", options: .backwards),
               valueStart.upperBound <= flag.lowerBound {
                value = String(text[valueStart.upperBound..<flag.lowerBound])
                switch text[flag.upperBound...] {
                case "true": preserved = true
                case "false": preserved = false
                default: return nil
                }
            } else {
                value = String(text[valueStart.upperBound...])
                preserved = false
            }
            rows[name] = .row(value: value == "NULL" ? nil : value, preservedInRestore: preserved)
        }
        return rows
    }

    private static func isRowStart(_ line: String) -> Bool {
        guard line.hasPrefix("Row: ") else { return false }
        let rest = line.dropFirst("Row: ".count)
        let digits = rest.prefix { $0.isNumber }
        return !digits.isEmpty && rest.dropFirst(digits.count).hasPrefix(" _id=")
    }

    /// `keys`' rows from one `content query --uri content://settings/secure`
    /// (every `content` run starts app_process, about a second each); a key
    /// the table does not list is absent.
    static func read(_ adb: AdbClient, serial: String, keys: [String]) async throws -> [LiveSecureRowSnapshot] {
        let output = try await adb.shell(serial: serial, ["content", "query", "--uri", "content://settings/secure"])
        guard let rows = rows(output) else {
            throw AdbError.commandFailed(
                arguments: ["-s", serial, "shell", "content", "query", "--uri", "content://settings/secure"],
                exitCode: 0,
                message: "unreadable rows"
            )
        }
        return keys.map { LiveSecureRowSnapshot(key: $0, state: rows[$0] ?? .absent) }
    }

    /// The shell line that recreates the row; nil for a NULL row that is
    /// preserved in restore (never seen, so not guessed).
    var restoreScript: String? {
        let delete = "settings delete secure \(key)"
        switch state {
        case .absent:
            return delete
        case .row(let value?, false):
            return "\(delete); settings put secure \(key) \(AdbClient.shellQuoted(value))"
        case .row(let value?, true):
            let put = "settings put secure \(key) \(AdbClient.shellQuoted(value))"
            return "\(delete); \(put); \(put)"
        case .row(nil, false):
            return "\(delete); content call --uri content://settings --method PUT_secure --arg \(key) --extra _overrideable_by_restore:b:true"
        case .row(nil, true):
            return nil
        }
    }
}
