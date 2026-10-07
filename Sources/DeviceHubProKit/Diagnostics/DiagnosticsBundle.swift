import Foundation

public enum DiagnosticsBundleError: Error, Equatable, CustomStringConvertible {
    case noFilesToArchive
    case archiveFailed(exitCode: Int32, message: String)
    /// Every device section failed (device gone, adb wedged); `reason` is the
    /// first failure. Nothing was written.
    case deviceUnreachable(reason: String)

    public var description: String {
        switch self {
        case .noFilesToArchive:
            return "There was nothing to put in the diagnostics bundle."
        case .archiveFailed(let exitCode, let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "The zip tool failed (\(exitCode))."
                : "The zip tool failed (\(exitCode)): \(detail)"
        case .deviceUnreachable(let reason):
            return "The device did not answer any diagnostics command: \(reason)"
        }
    }
}

/// The outcome of `DiagnosticsBundle.collect`: the archive and whether the
/// logcat window came from the device's own clock (false) or from the host
/// clock because the device could not answer (true). A caller that surfaces
/// "saved" should say the window is approximate when the fallback fired, and
/// name `failedSections` when there are any.
public struct DiagnosticsBundleResult: Sendable {
    public let url: URL
    public let usedHostClockFallback: Bool
    /// The sections that could not be collected (`logcat`,
    /// `dumpsys-battery`, `dumpsys-meminfo`, `getprop`), in collection order.
    /// Each one's archive entry is `<name>.error.txt` with the failure instead
    /// of `<name>.txt`.
    public let failedSections: [String]
    /// `logcat.txt` holds the last `DiagnosticsBundle.logcatFallbackLineCount`
    /// lines instead of the five-minute window: the device rejected logcat's
    /// epoch time form (Android 6 and older).
    public let usedLogcatLineFallback: Bool

    public init(
        url: URL,
        usedHostClockFallback: Bool,
        failedSections: [String] = [],
        usedLogcatLineFallback: Bool = false
    ) {
        self.url = url
        self.usedHostClockFallback = usedHostClockFallback
        self.failedSections = failedSections
        self.usedLogcatLineFallback = usedLogcatLineFallback
    }
}

/// Collects a device's diagnostics — the last five minutes of logcat, the
/// battery and memory dumps, every system property and the device info — and
/// writes them as a single zip.
///
/// Designed after Device Hub's diagnostic-file download (its docs mention one,
/// no captured reference exists), with Android's own dump commands as the
/// content. The archive is produced by `/usr/bin/zip`, run with `-j` so the
/// entries sit at the archive root.
///
/// Every section is a bounded adb call collected on its own: a section that
/// fails or times out becomes `<name>.error.txt` and the rest of the bundle
/// is still written. Command output is archived as the raw bytes the device
/// sent — logcat routinely carries invalid UTF-8 (messages cut mid-character,
/// native code logging bytes), which a strict text decode would turn into an
/// empty file.
public enum DiagnosticsBundle {
    /// Seconds of logcat kept in `logcat.txt` (the last five minutes).
    public static let logcatWindowSeconds = 300

    /// The per-command bound `collect` uses unless told otherwise.
    public static let defaultSectionTimeout: Duration = .seconds(30)

    /// Lines `logcat.txt` falls back to when the device rejects the epoch
    /// time window (`-t <epoch>.000` is Android 7+).
    public static let logcatFallbackLineCount = 10_000

    /// Collects diagnostics for `serial` and writes
    /// `<serial>-diagnostics-<yyyyMMdd-HHmmss>.zip` into `directory`; returns
    /// the archive and how it was collected. `fallbackNow` is the clock
    /// substituted when the device cannot answer `date +%s` (injectable so the
    /// fallback path is testable). Each adb call is terminated after
    /// `sectionTimeout`. Throws `.deviceUnreachable` when no device section
    /// could be collected, and `CancellationError` when the task is cancelled.
    public static func collect(
        serial: String,
        adb: AdbClient,
        into directory: URL,
        fallbackNow: @Sendable () -> Date = { Date() },
        sectionTimeout: Duration = DiagnosticsBundle.defaultSectionTimeout
    ) async throws -> DiagnosticsBundleResult {
        let adbURL = adb.adbURL
        // logcat's time argument only takes `MM-DD hh:mm:ss.mmm`, an absolute
        // date or epoch seconds — never a relative `5m` — so ask the device
        // for its clock and hand logcat the cutoff in its own epoch seconds.
        let clock = try await logcatCutoff(
            serial: serial,
            adbURL: adbURL,
            timeout: min(sectionTimeout, .seconds(10)),
            fallbackNow: fallbackNow
        )

        var logcat = try await capture(
            ["-s", serial, "logcat", "-d", "-v", "threadtime", "-t", "\(clock.epoch).000"],
            adbURL: adbURL,
            timeout: sectionTimeout
        )
        var usedLogcatLineFallback = false
        if case .failure(let failure) = logcat, failure.isNonZeroExit {
            // Android 6 rejects the epoch form; a bounded line count is the
            // closest window it understands.
            let fallback = try await capture(
                ["-s", serial, "logcat", "-d", "-v", "threadtime", "-t", "\(logcatFallbackLineCount)"],
                adbURL: adbURL,
                timeout: sectionTimeout
            )
            if case .success = fallback {
                logcat = fallback
                usedLogcatLineFallback = true
            }
        }
        let battery = try await capture(
            ["-s", serial, "shell", "dumpsys", "battery"],
            adbURL: adbURL,
            timeout: sectionTimeout
        )
        let meminfo = try await capture(
            ["-s", serial, "shell", "dumpsys", "meminfo"],
            adbURL: adbURL,
            timeout: sectionTimeout
        )
        let getprop = try await capture(
            ["-s", serial, "shell", "getprop"],
            adbURL: adbURL,
            timeout: sectionTimeout
        )
        let properties: [String: String] = switch getprop {
        case .success(let data): Self.properties(fromGetprop: String(decoding: data, as: UTF8.self))
        case .failure: [:]
        }

        let sections: [(name: String, output: Result<Data, SectionFailure>)] = [
            ("logcat", logcat),
            ("dumpsys-battery", battery),
            ("dumpsys-meminfo", meminfo),
            ("getprop", getprop.map { _ in Data(format(properties).utf8) }),
        ]
        let failures = sections.compactMap { section -> (String, SectionFailure)? in
            guard case .failure(let failure) = section.output else { return nil }
            return (section.name, failure)
        }
        if failures.count == sections.count, let first = failures.first {
            throw DiagnosticsBundleError.deviceUnreachable(reason: first.1.description)
        }

        let staging = try makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }

        for section in sections {
            switch section.output {
            case .success(let data):
                try write(data, named: "\(section.name).txt", to: staging)
            case .failure(let failure):
                try write(Data(failure.report.utf8), named: "\(section.name).error.txt", to: staging)
            }
        }
        try write(try deviceJSON(serial: serial, properties: properties), named: "device.json", to: staging)

        let url = try await archive(
            directory: staging,
            named: suggestedFileName(serial: serial),
            into: directory
        )
        return DiagnosticsBundleResult(
            url: url,
            usedHostClockFallback: clock.usedHostClockFallback,
            failedSections: failures.map(\.0),
            usedLogcatLineFallback: usedLogcatLineFallback
        )
    }

    /// Why one section's adb call produced no output.
    struct SectionFailure: Error, CustomStringConvertible {
        let arguments: [String]
        let reason: String
        let standardError: String
        let isNonZeroExit: Bool

        var description: String {
            "adb \(arguments.joined(separator: " ")): \(reason)"
        }

        /// The `<name>.error.txt` body: the command, the failure and whatever
        /// the command printed on stderr.
        var report: String {
            let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            return description + "\n" + (detail.isEmpty ? "" : detail + "\n")
        }
    }

    /// Runs one bounded adb call and returns its raw stdout, or why it
    /// failed. Only cancellation propagates: a failed section must not take
    /// the rest of the bundle with it.
    private static func capture(
        _ arguments: [String],
        adbURL: URL,
        timeout: Duration
    ) async throws -> Result<Data, SectionFailure> {
        do {
            let result = try await ProcessRunner.run(
                executable: adbURL,
                arguments: arguments,
                timeout: timeout
            )
            guard result.exitCode == 0 else {
                return .failure(SectionFailure(
                    arguments: arguments,
                    reason: "exited with status \(result.exitCode)",
                    standardError: String(decoding: result.standardError, as: UTF8.self),
                    isNonZeroExit: true
                ))
            }
            return .success(result.standardOutput)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return .failure(SectionFailure(
                arguments: arguments,
                reason: "\(error)",
                standardError: "",
                isNonZeroExit: false
            ))
        }
    }

    /// The default archive name, `<serial>-diagnostics-<yyyyMMdd-HHmmss>.zip`.
    public static func suggestedFileName(serial: String, date: Date = Date()) -> String {
        "\(sanitized(serial))-diagnostics-\(timestamp(date)).zip"
    }

    /// Zips every file in `stagingDirectory` into `name` inside
    /// `destinationDirectory`; entries sit at the archive root. The archive is
    /// deterministic: files are added in name order.
    static func archive(
        directory stagingDirectory: URL,
        named name: String,
        into destinationDirectory: URL
    ) async throws -> URL {
        let fileManager = FileManager.default
        let names = try fileManager.contentsOfDirectory(atPath: stagingDirectory.path).sorted()
        guard !names.isEmpty else { throw DiagnosticsBundleError.noFilesToArchive }

        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let zipURL = destinationDirectory.appendingPathComponent(name)
        try? fileManager.removeItem(at: zipURL)

        let arguments = ["-X", "-j", zipURL.path]
            + names.map { stagingDirectory.appendingPathComponent($0).path }
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: arguments
        )
        guard result.exitCode == 0, fileManager.fileExists(atPath: zipURL.path) else {
            throw DiagnosticsBundleError.archiveFailed(
                exitCode: result.exitCode,
                message: result.standardErrorText
            )
        }
        return zipURL
    }

    /// The logcat cutoff (device epoch − `logcatWindowSeconds`) from the
    /// device's own clock, so the window matches the timestamps in its log;
    /// `fallbackNow` substitutes for a device that cannot answer, and the
    /// returned flag keeps that substitution visible to the caller.
    private static func logcatCutoff(
        serial: String,
        adbURL: URL,
        timeout: Duration,
        fallbackNow: @Sendable () -> Date
    ) async throws -> (epoch: Int, usedHostClockFallback: Bool) {
        let answer = try await capture(
            ["-s", serial, "shell", "date", "+%s"],
            adbURL: adbURL,
            timeout: timeout
        )
        if case .success(let data) = answer,
           let seconds = Int(
               String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
           ) {
            return (seconds - logcatWindowSeconds, false)
        }
        return (Int(fallbackNow().timeIntervalSince1970) - logcatWindowSeconds, true)
    }

    private static func makeStagingDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func write(_ data: Data, named name: String, to directory: URL) throws {
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    /// Every property `getprop` printed, value complete.
    ///
    /// toolbox `getprop` prints `[key]: [value]` with the value verbatim, so
    /// a value holding newlines spans several output lines — on every
    /// device, `persist.sys.boot.reason.history` lists one reboot per line:
    ///
    ///     [persist.sys.boot.reason.history]: [reboot,1790279800
    ///     reboot,1790279318]
    ///
    /// A value stays open until a line ends with its closing `]`; the lines
    /// in between are part of it. A line-by-line read kept only the first
    /// line of such a value and dropped the rest. CRLF (the pty older adbd
    /// runs `shell` commands on) ends a line like LF.
    static func properties(fromGetprop output: String) -> [String: String] {
        var properties: [String: String] = [:]
        var key: String?
        var value = ""
        func finish() {
            guard let key else { return }
            properties[key] = value.hasSuffix("]") ? String(value.dropLast()) : value
        }
        for line in output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let isOpen = key != nil && !value.hasSuffix("]")
            if isOpen {
                value += "\n" + line
                continue
            }
            guard line.hasPrefix("["), let separator = line.range(of: "]: [") else { continue }
            finish()
            key = String(line[line.index(after: line.startIndex)..<separator.lowerBound])
            value = String(line[separator.upperBound...])
        }
        finish()
        return properties
    }

    /// `getprop` as stable `key=value` lines, sorted by key.
    private static func format(_ properties: [String: String]) -> String {
        properties.keys.sorted()
            .map { "\($0)=\(properties[$0] ?? "")" }
            .joined(separator: "\n") + "\n"
    }

    private static func deviceJSON(serial: String, properties: [String: String]) throws -> Data {
        let info = DeviceInfo.from(
            serial: serial,
            properties: properties,
            isEmulator: serial.hasPrefix("emulator-")
        )
        let object: [String: Any] = [
            "serial": info.serial,
            "model": info.model,
            "manufacturer": info.manufacturer,
            "androidVersion": info.androidVersion,
            "apiLevel": info.apiLevel,
            "abi": info.abi,
            "isEmulator": info.isEmulator,
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func sanitized(_ serial: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String(serial.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.isEmpty ? "device" : cleaned
    }
}
