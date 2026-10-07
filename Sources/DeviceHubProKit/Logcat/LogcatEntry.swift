import Foundation

public enum LogcatLevel: String, Sendable, CaseIterable, Codable {
    case verbose = "V"
    case debug = "D"
    case info = "I"
    case warning = "W"
    case error = "E"
    case fatal = "F"

    public var severity: Int {
        switch self {
        case .verbose: return 0
        case .debug: return 1
        case .info: return 2
        case .warning: return 3
        case .error: return 4
        case .fatal: return 5
        }
    }

    public var label: String {
        switch self {
        case .verbose: return "Verbose"
        case .debug: return "Debug"
        case .info: return "Info"
        case .warning: return "Warn"
        case .error: return "Error"
        case .fatal: return "Fatal"
        }
    }
}

public struct LogcatEntry: Sendable, Identifiable, Hashable {
    /// Monotonic id assigned by the stream. Zero for entries that were not
    /// produced by a stream (e.g. in tests).
    public var id: UInt64
    public let timestamp: String
    public let pid: Int
    public let tid: Int
    public let level: LogcatLevel
    public let tag: String
    public var message: String
    /// The unified-log subsystem of a simulator's event
    /// (`com.apple.UIKit`); empty for logcat, which has none.
    public let subsystem: String

    public init(
        id: UInt64 = 0,
        timestamp: String,
        pid: Int,
        tid: Int,
        level: LogcatLevel,
        tag: String,
        message: String,
        subsystem: String = ""
    ) {
        self.id = id
        self.timestamp = timestamp
        self.pid = pid
        self.tid = tid
        self.level = level
        self.tag = tag
        self.message = message
        self.subsystem = subsystem
    }

    /// True when this line looks like the start of a crash report. The
    /// `--------- beginning of crash` buffer marker is not one: it belongs to
    /// no entry (the stream drops it), and matching it would flag whatever
    /// unrelated line it was attached to.
    public var isCrash: Bool {
        message.contains("FATAL EXCEPTION")
            || tag == "AndroidRuntime" && message.contains("Process:")
    }
}
