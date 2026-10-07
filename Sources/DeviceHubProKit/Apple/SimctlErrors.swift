import Foundation

/// One `(domain=…, code=…)` pair from simctl's error output.
public struct SimctlErrorReference: Sendable, Equatable {
    public let domain: String
    public let code: Int

    public init(domain: String, code: Int) {
        self.domain = domain
        self.code = code
    }
}

/// A simctl call that failed, decoded from its exit status and standard error.
///
/// simctl reports a failure as a header line, `An error was encountered
/// processing the command (domain=…, code=…):`, then a message, then often an
/// `Underlying error (domain=…, code=…):` block. The header is not always the
/// first line (`location start` prints its own complaint first). The exit
/// status is the error code truncated to 8 bits (405 → 149, 2003 → 211,
/// −50 → 206), so the code is read from standard error, never derived from
/// the exit status. Some failures print no header at all (`Invalid device:
/// <udid>` with exit 148, a usage text with exit 117, `Unknown apperance:
/// purple` with exit 1); those keep only the exit status and the message.
public struct SimctlFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        /// The device is in the wrong state for the command (SimError 405:
        /// erase or clone while booted, shutdown while shut down).
        case invalidState
        /// No device with that UDID in the addressed device set (exit 148).
        case invalidDevice
        /// No such app or process (`NSPOSIXErrorDomain` 3: an unknown bundle
        /// identifier, `terminate` of an app that is not running).
        case notFound
        /// A value simctl rejected (`NSPOSIXErrorDomain` 22, or the `ui`
        /// command's bare `Invalid argument`).
        case invalidArgument
        /// simctl printed its usage text (exit 117).
        case usage
        /// The `--set` folder does not exist.
        case missingDeviceSet
        case other
    }

    public let arguments: [String]
    public let exitCode: Int32
    /// The top-level error, when simctl printed a header.
    public let error: SimctlErrorReference?
    /// The `Underlying error` chain, outermost first.
    public let underlying: [SimctlErrorReference]
    /// The first line that explains the failure (the line after the header,
    /// or the first line of standard error when there is no header).
    public let message: String
    public let kind: Kind
    /// The non-empty lines simctl printed before its header, trimmed: what
    /// failed per item when the header only says "see stderr" (`addmedia`'s
    /// `Failed to import '<file>', …`). Empty without a header.
    public let leadingLines: [String]

    public init(
        arguments: [String],
        exitCode: Int32,
        error: SimctlErrorReference?,
        underlying: [SimctlErrorReference],
        message: String,
        kind: Kind,
        leadingLines: [String] = []
    ) {
        self.arguments = arguments
        self.exitCode = exitCode
        self.error = error
        self.underlying = underlying
        self.message = message
        self.kind = kind
        self.leadingLines = leadingLines
    }

    public var description: String {
        let command = (["simctl"] + arguments).joined(separator: " ")
        if let error {
            return "\(command) failed (\(error.domain) \(error.code)): \(message)"
        }
        return "\(command) failed (exit \(exitCode)): \(message)"
    }
}

/// Decodes simctl's failure output.
public enum SimctlErrors {
    /// The exit status simctl uses for an error code: the code truncated to
    /// 8 bits, as `exit(3)` does. Measured: 405 → 149, 2003 → 211, −50 → 206.
    public static func exitStatus(forErrorCode code: Int) -> Int32 {
        Int32(UInt8(truncatingIfNeeded: code))
    }

    /// The exit status simctl uses when it prints its usage text.
    public static let usageExitStatus: Int32 = 117

    /// The exit status for a UDID the addressed device set does not hold.
    public static let invalidDeviceExitStatus: Int32 = 148

    /// Decodes a failed call. Callers invoke this only for a failure (a
    /// non-zero exit, or a `ui` exit 0 that `uiFailure` flagged).
    public static func failure(
        arguments: [String],
        exitCode: Int32,
        standardError: String
    ) -> SimctlFailure {
        let lines = standardError
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)

        var header: SimctlErrorReference?
        var headerIndex: Int?
        var underlying: [SimctlErrorReference] = []
        for (index, line) in lines.enumerated() {
            guard let reference = errorReference(in: line) else { continue }
            if line.hasPrefix("Underlying error") {
                underlying.append(reference)
            } else if header == nil {
                header = reference
                headerIndex = index
            }
        }

        let message: String
        if let headerIndex {
            message = lines[(headerIndex + 1)...]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
        } else {
            message = lines
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
        }

        let leadingLines = headerIndex.map { index in
            lines[..<index]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } ?? []

        return SimctlFailure(
            arguments: arguments,
            exitCode: exitCode,
            error: header,
            underlying: underlying,
            message: message,
            kind: kind(exitCode: exitCode, error: header, message: message),
            leadingLines: leadingLines
        )
    }

    /// The failure a `ui` call reports, or nil when it succeeded.
    ///
    /// `ui … content_size` and `ui … increase_contrast` answer an invalid
    /// value with `Invalid argument` on standard error but exit 0 (measured on
    /// Xcode 27.0), so an exit 0 alone does not mean the value was applied.
    public static func uiFailure(
        arguments: [String],
        exitCode: Int32,
        standardError: String
    ) -> SimctlFailure? {
        let trimmed = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if exitCode != 0 {
            return failure(arguments: arguments, exitCode: exitCode, standardError: standardError)
        }
        guard trimmed.split(whereSeparator: \.isNewline).contains(where: { $0 == "Invalid argument" }) else {
            return nil
        }
        return SimctlFailure(
            arguments: arguments,
            exitCode: exitCode,
            error: nil,
            underlying: [],
            message: "Invalid argument",
            kind: .invalidArgument
        )
    }

    /// The `(domain=…, code=…)` pair on one line, if it holds one.
    public static func errorReference(in line: String) -> SimctlErrorReference? {
        guard let open = line.range(of: "(domain="),
              let comma = line.range(of: ", code=", range: open.upperBound..<line.endIndex),
              let close = line.range(of: ")", range: comma.upperBound..<line.endIndex)
        else { return nil }
        let domain = String(line[open.upperBound..<comma.lowerBound])
        guard !domain.isEmpty, let code = Int(line[comma.upperBound..<close.lowerBound]) else {
            return nil
        }
        return SimctlErrorReference(domain: domain, code: code)
    }

    private static func kind(
        exitCode: Int32,
        error: SimctlErrorReference?,
        message: String
    ) -> SimctlFailure.Kind {
        if let error {
            switch (error.domain, error.code) {
            case ("com.apple.CoreSimulator.SimError", 405):
                return .invalidState
            case ("NSPOSIXErrorDomain", 3):
                return .notFound
            case ("NSPOSIXErrorDomain", 22):
                return .invalidArgument
            default:
                return .other
            }
        }
        if message.hasPrefix("Invalid device:") || exitCode == invalidDeviceExitStatus {
            return .invalidDevice
        }
        if message.hasPrefix("Provided set path does not exist") {
            return .missingDeviceSet
        }
        if exitCode == usageExitStatus {
            return .usage
        }
        if message == "Invalid argument" {
            return .invalidArgument
        }
        return .other
    }
}
