import Foundation

/// Parsing helpers for adb output. Pure functions so they are unit-testable
/// without a device.
public enum AdbParsing {
    /// Parses `adb devices -l` output.
    public static func devices(from output: String) -> [AndroidDevice] {
        var result: [AndroidDevice] = []

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard !line.hasPrefix("List of devices") else { continue }
            guard !line.hasPrefix("*") else { continue }

            let parts = line
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            guard parts.count >= 2 else { continue }

            let serial = parts[0]
            let state = parts[1]

            var metadata: [String: String] = [:]
            for token in parts.dropFirst(2) {
                guard let separator = token.firstIndex(of: ":") else { continue }
                let key = String(token[..<separator])
                let value = String(token[token.index(after: separator)...])
                metadata[key] = value
            }

            result.append(AndroidDevice(
                serial: serial,
                state: state,
                model: metadata["model"],
                product: metadata["product"],
                device: metadata["device"],
                transportID: metadata["transport_id"]
            ))
        }

        return result
    }

    /// Strips anything the device prints before the PNG payload. Some emulator
    /// images (e.g. foldables) emit `[Warning] Multiple displays…` before the
    /// actual `screencap` output.
    public static func pngData(from data: Data) -> Data? {
        let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        guard let range = data.range(of: signature) else { return nil }
        return data.subdata(in: range.lowerBound..<data.endIndex)
    }

    /// Parses the preset list in the console's answer to `resize-display`
    /// without an index. The console answers with its usage line, `KO usage:
    /// "resize-display <index>" 0: phone\t1: unfolded\t2: tablet` (emulator
    /// 36.6.11 and 37.2.8), so a KO answer is expected here: every `<index>:
    /// <name>` pair after `usage:` is a preset. An answer without a usage (a
    /// bare `KO`, another console error) has none. The console lists the
    /// same presets for every AVD, resizable or not.
    public static func resizePresets(fromUsage output: String) -> [ResizePreset] {
        guard let usage = output.range(of: "usage:", options: .caseInsensitive) else { return [] }

        var presets: [ResizePreset] = []
        var pendingIndex: Int?

        let tokens = output[usage.upperBound...].split(whereSeparator: \.isWhitespace)
        for token in tokens {
            if token.hasSuffix(":"), let index = Int(token.dropLast()) {
                pendingIndex = index
                continue
            }
            if let index = pendingIndex {
                presets.append(ResizePreset(index: index, name: String(token)))
                pendingIndex = nil
            }
        }
        return presets
    }

    /// Parses `settings list <namespace>` output (`key=value` per line).
    /// Lines may end in `\r\n` (see `packages(from:)`).
    public static func globalSettings(from output: String) -> [String: String] {
        var settings: [String: String] = [:]
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            settings[key] = value
        }
        return settings
    }

    /// Classifies `cmd uimode night` output. `Night mode: yes|no|auto` maps to
    /// the three selectable modes; AOSP's other answers (`custom_schedule`,
    /// `custom_bedtime`, `unknown`, older images' `custom`) are `unmapped` —
    /// the command works, the value just has no Light/Dark/System
    /// counterpart. Only output that never carries a `Night mode:` line is
    /// `unreadable`.
    public static func appearanceReading(from output: String) -> AppearanceReading {
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let range = line.range(of: "Night mode:") else { continue }
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
            switch value {
            case "yes": return .mode(.dark)
            case "no": return .mode(.light)
            case "auto": return .mode(.system)
            case "": return .unreadable
            default: return .unmapped(value)
            }
        }
        return .unreadable
    }

    /// Parses the `adb emu avd name` response (`<name>\r\nOK`).
    public static func avdName(from output: String) -> String? {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0 != "OK" }
    }

    /// Parses the `adb emu avd discoverypath` response (`<path>\nOK`).
    public static func discoveryPath(from output: String) -> String? {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("/") }
    }

    /// Parses the emulator discovery file: the active gRPC port and the JWT
    /// token Android Studio-launched emulators require for every call.
    public static func emulatorDiscovery(from output: String) -> (port: Int?, token: String?) {
        var values: [String: String] = [:]
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            values[key] = value
        }
        return (values["grpc.port"].flatMap(Int.init), values["grpc.token"])
    }

    /// Parses an `adb emu sensor get <name>` response such as
    /// `acceleration = 0:9.77631:0.812349`. Handles the console's CRLF endings
    /// (`\r\n` is a single grapheme in Swift, so `split(separator:)"\n"` misses it).
    public static func sensorTriple(from output: String) -> (x: Double, y: Double, z: Double)? {
        for rawLine in output.components(separatedBy: .newlines) {
            guard let separator = rawLine.firstIndex(of: "=") else { continue }
            let parts = rawLine[rawLine.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
                .split(separator: ":")
            guard parts.count == 3,
                  let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  let y = Double(parts[1].trimmingCharacters(in: .whitespaces)),
                  let z = Double(parts[2].trimmingCharacters(in: .whitespaces)) else {
                continue
            }
            return (x, y, z)
        }
        return nil
    }

    /// Maps the emulator's gravity vector to its physical rotation index
    /// (0 = portrait, 1 = 90° clockwise, 2 = upside-down portrait,
    /// 3 = 270° clockwise).
    public static func poseIndex(x: Double, y: Double, z: Double) -> Int {
        if abs(x) > abs(y) {
            return x < 0 ? 1 : 3
        }
        return y > 0 ? 0 : 2
    }

    /// Reads `mCurrentOrientation=N` from `dumpsys display`: the framework's
    /// display rotation, which can differ from the stream's rotation metadata
    /// when the emulator's physical rotation was forced.
    public static func displayRotation(from output: String) -> Int? {
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("mCurrentOrientation=") else { continue }
            return Int(line.dropFirst("mCurrentOrientation=".count))
        }
        return nil
    }

    /// Parses `pm list packages` output lines (`package:com.example`).
    ///
    /// Devices without adb's shell protocol (Android 6 and older) run `adb
    /// shell <command>` under a PTY, whose output translation ends every
    /// line in `\r\n` — one grapheme in Swift, which `split(separator:
    /// "\n")` never splits — so lines are split on any newline.
    public static func packages(from output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("package:") else { return nil }
            return String(trimmed.dropFirst("package:".count))
        }
        .sorted()
    }

    /// Parses `pm list packages --show-versioncode` lines like
    /// `package:com.example.app versionCode:1234`, split like
    /// `packages(from:)`.
    public static func packagesWithVersions(
        from output: String
    ) -> [AdbClient.InstalledPackage] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("package:") else { return nil }
            var id = String(trimmed.dropFirst("package:".count))
            var version: String?
            if let range = id.range(of: " versionCode:") {
                version = String(id[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                id = String(id[..<range.lowerBound])
            }
            return AdbClient.InstalledPackage(id: id, versionCode: version)
        }
        .sorted { $0.id < $1.id }
    }

    /// The `feature:` names of `pm list features` output (`feature:name` or
    /// `feature:name=version`, one per line).
    public static func features(from output: String) -> Set<String> {
        var names = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("feature:") else { continue }
            let name = text.dropFirst("feature:".count).split(separator: "=", maxSplits: 1).first
            if let name, !name.isEmpty { names.insert(String(name)) }
        }
        return names
    }

    /// Parses `getprop` output: one `[key]: [value]` record per property
    /// (toolbox `getprop` prints `[%s]: [%s]\n`). A value may hold newlines —
    /// bootstat's `persist.sys.boot.reason.history` is one `reason,time`
    /// entry per line on every device — so a record whose line does not end
    /// with `]` continues on the following lines, up to the one that does.
    /// Lines may end in `\r\n` (see `packages(from:)`).
    public static func getprop(from output: String) -> [String: String] {
        var result: [String: String] = [:]
        // The record whose value is still open (no closing `]` yet).
        var openKey: String?
        // Blank lines count inside a multi-line value; the empty piece after
        // the final newline does not.
        var lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }

        for rawLine in lines {
            let line = String(rawLine)
            if let key = openKey {
                let closes = line.hasSuffix("]")
                result[key, default: ""] += "\n" + (closes ? String(line.dropLast()) : line)
                if closes {
                    openKey = nil
                }
                continue
            }
            guard line.hasPrefix("["), let separator = line.range(of: "]: [") else { continue }

            let key = String(line[line.index(after: line.startIndex)..<separator.lowerBound])
            let value = line[separator.upperBound...]
            if value.hasSuffix("]") {
                result[key] = String(value.dropLast())
            } else {
                result[key] = String(value)
                openKey = key
            }
        }

        return result
    }

    /// Parses the payload of one `adb track-devices` frame (see
    /// `AdbHostFrameDecoder`): the complete device list, one device per line,
    /// with no header and no terminator line. The plain variant sends
    /// `serial\tstate`; the `-l` variant sends the `devices -l` row
    /// (`serial   state product:… model:… device:… transport_id:N`), so its
    /// devices carry the same details a `devices -l` read would. An empty
    /// payload is an empty list.
    public static func trackDevicesSnapshot(from payload: String) -> [AndroidDevice] {
        var devices: [AndroidDevice] = []
        for rawLine in payload.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            if columns.count == 2 {
                // Plain rows are tab-separated, which keeps a serial with
                // spaces (adb's "(no serial number)") in one piece.
                let serial = String(columns[0]).trimmingCharacters(in: .whitespaces)
                let state = String(columns[1]).trimmingCharacters(in: .whitespaces)
                guard !serial.isEmpty, !state.isEmpty else { continue }
                devices.append(AndroidDevice(serial: serial, state: state))
            } else {
                devices.append(contentsOf: Self.devices(from: line))
            }
        }
        return devices
    }
}

/// Splits the adb host protocol's length-prefixed stream into payloads.
///
/// `adb track-devices` (and the `host:track-devices` service behind it) sends
/// one frame per device-list change: four ASCII hex digits giving the payload
/// length, then exactly that many bytes. There is no header line and no blank
/// terminator; an empty device list is the bare frame `0000` (verified against
/// platform-tools 37.0.0). Frames arrive split and coalesced arbitrarily
/// across reads, so bytes are buffered until a whole frame is present.
public struct AdbHostFrameDecoder: Sendable {
    public enum DecodingError: Error, Equatable, CustomStringConvertible {
        /// The four bytes where a length was expected are not hex digits: the
        /// stream is not adb's framing (or lost sync) and cannot be resumed.
        case invalidLengthPrefix(String)

        public var description: String {
            switch self {
            case .invalidLengthPrefix(let prefix):
                return "adb sent \(prefix.debugDescription) where a 4-hex-digit frame length was expected"
            }
        }
    }

    private var buffer: [UInt8] = []

    public init() {}

    /// Appends newly read bytes and returns every payload completed by them,
    /// oldest first. Throws on a malformed length prefix; the decoder is then
    /// unusable and the stream should be restarted.
    public mutating func append(_ bytes: Data) throws -> [String] {
        buffer.append(contentsOf: bytes)
        var payloads: [String] = []
        var offset = 0
        while buffer.count - offset >= 4 {
            let prefix = buffer[offset..<(offset + 4)]
            guard prefix.allSatisfy(Self.isHexDigit),
                  let length = Int(String(decoding: prefix, as: UTF8.self), radix: 16)
            else {
                throw DecodingError.invalidLengthPrefix(String(decoding: prefix, as: UTF8.self))
            }
            guard buffer.count - offset - 4 >= length else { break }
            let start = offset + 4
            payloads.append(String(decoding: buffer[start..<(start + length)], as: UTF8.self))
            offset = start + length
        }
        buffer.removeFirst(offset)
        return payloads
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }
}
