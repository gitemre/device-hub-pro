import Foundation

/// One adb port-forwarding rule, in either direction.
///
/// `listen` is the socket spec the rule opens and `target` the one it
/// connects to: for `adb forward <local> <remote>` the host listens and the
/// device is the target; for `adb reverse <remote> <local>` the device
/// listens and the host is the target. Removal names the listening spec in
/// both directions (`forward --remove <local>`, `reverse --remove <remote>`).
public struct PortForwardRule: Sendable, Hashable, Identifiable {
    public enum Direction: String, Sendable, Hashable, CaseIterable {
        /// `adb forward`: a host socket reaches the device.
        case forward
        /// `adb reverse`: a device socket reaches the host.
        case reverse
    }

    public let direction: Direction
    public let listen: String
    public let target: String

    public var id: String { "\(direction.rawValue) \(listen) \(target)" }

    public init(direction: Direction, listen: String, target: String) {
        self.direction = direction
        self.listen = listen
        self.target = target
    }
}

/// Parsing and validation of adb's port-forwarding text.
public enum PortForwarding {
    /// Parses the output of `adb -s <serial> forward --list` or
    /// `reverse --list`, keeping the rules of `serial`.
    ///
    /// SOURCE-DERIVED from Android platform/packages/modules/adb (main,
    /// 1cf2f017): `format_listeners` (adb_listeners.cpp) writes one line per
    /// listener, `<serial> <listen spec> <target spec>` and a newline, and
    /// `(reverse)` in place of the serial for a listener with no serial. For
    /// `forward --list` client/commandline.cpp sends `host:list-forward`,
    /// which `handle_forward_request` (adb.cpp) answers with every listener of
    /// the server, whatever `-s` named: the rows of other devices are dropped
    /// here by their first column. For `reverse --list` it sends
    /// `reverse:list-forward` to the device, whose adbd answers the same way
    /// for its own listeners, so every row belongs to this device. A device
    /// with no rules prints nothing; any line without exactly three columns
    /// is skipped rather than guessed at. The two shapes were then captured
    /// on a live emulator (2026-10-04, API 35, adb 37.0.0, see the fixtures in
    /// `Fixtures/adb-portforward/`): the forward row starts with the serial,
    /// and the reverse listing from this emulator's adbd starts with a
    /// transport name (`host-16`), not `(reverse)`; the parser keeps both.
    public static func rules(
        from output: String,
        direction: PortForwardRule.Direction,
        serial: String? = nil
    ) -> [PortForwardRule] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> PortForwardRule? in
                let columns = line.split(separator: " ", omittingEmptySubsequences: true)
                guard columns.count == 3 else { return nil }
                if direction == .forward, let serial, columns[0] != serial { return nil }
                return PortForwardRule(direction: direction, listen: String(columns[1]), target: String(columns[2]))
            }
    }

    /// Why a socket spec cannot be used, or nil when adb would take it.
    /// Accepts the specs adb documents for forwarding: `tcp:<port>`,
    /// `localabstract:<name>`, `localreserved:<name>`, `localfilesystem:<path>`
    /// and, for a forward target only, `jdwp:<pid>`.
    public static func validate(spec: String, allowsJdwp: Bool = false) -> String? {
        guard !spec.isEmpty else { return "Enter a socket such as tcp:8080." }
        guard let colon = spec.firstIndex(of: ":") else { return "A socket reads like tcp:8080." }
        let kind = String(spec[..<colon])
        let value = String(spec[spec.index(after: colon)...])
        guard !value.isEmpty else { return "The socket \(kind): needs a value." }
        guard !value.contains(where: { $0.isWhitespace }) else {
            return "A socket cannot contain spaces."
        }
        switch kind {
        case "tcp":
            guard let port = Int(value), (1...65535).contains(port), String(port) == value else {
                return "A TCP port is a number from 1 to 65535."
            }
            return nil
        case "localabstract", "localreserved", "localfilesystem", "local":
            return nil
        case "jdwp":
            guard allowsJdwp else { return "jdwp: can only be the device side of a forward." }
            guard Int(value) != nil else { return "A jdwp: target is a process id." }
            return nil
        default:
            return "Unknown socket type \(kind): use tcp:, localabstract:, localreserved: or localfilesystem:."
        }
    }

    /// A spec as typed, with a bare port number read as `tcp:<port>` (what a
    /// tester types first) and surrounding spaces dropped.
    public static func normalized(_ spec: String) -> String {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else { return trimmed }
        return "tcp:" + trimmed
    }

    /// The first problem with a new rule's two specs (as typed, see
    /// `normalized`), or nil.
    public static func validate(direction: PortForwardRule.Direction, listen: String, target: String) -> String? {
        if let problem = validate(spec: normalized(listen)) { return "Listen: \(problem)" }
        if let problem = validate(spec: normalized(target), allowsJdwp: direction == .forward) { return "Target: \(problem)" }
        return nil
    }
}
