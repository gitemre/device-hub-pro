import Darwin
import Foundation

/// One row of the Mac's process table.
public struct ProcessEntry: Equatable, Sendable {
    public let pid: Int32
    public let parentPid: Int32
    /// The kernel's short command name (at most 16 bytes: `pbi_comm`).
    public let name: String

    public init(pid: Int32, parentPid: Int32, name: String) {
        self.pid = pid
        self.parentPid = parentPid
        self.name = name
    }
}

/// What the measurement needs from the Mac: one scan of the process table,
/// a process's arguments (asked only for the few launchd_sim and qemu
/// processes) and its memory footprint (asked only for a device's own
/// processes). The live one uses public APIs; tests use a fake table.
public protocol ProcessTable: Sendable {
    func entries() -> [ProcessEntry]
    /// The process's argv (argv[0] first), empty when unreadable.
    func arguments(of pid: Int32) -> [String]
    /// `phys_footprint` in bytes, nil when the kernel does not answer
    /// (a process of another user, or one that just exited).
    func footprint(of pid: Int32) -> UInt64?
}

/// A running Android emulator's qemu process and what it holds.
public struct EmulatorMemory: Equatable, Sendable {
    public let pid: Int32
    /// The AVD name (`-avd <name>` or `@<name>`), nil when the arguments name none.
    public let avdName: String?
    /// The console port (`-port N` or `-ports N,M`; the serial is
    /// `emulator-N`), nil when the arguments name none.
    public let consolePort: Int?
    public let footprintBytes: UInt64

    public var serial: String? { consolePort.map { "emulator-\($0)" } }
}

/// The memory of the simulators and emulators running on this Mac.
public struct DeviceMemoryReport: Equatable, Sendable {
    /// Simulator UDID -> bytes: `phys_footprint` summed over the device's
    /// launchd_sim and every process below it (not RSS: that counts shared
    /// pages once per process and leaves compressed ones out).
    public var simulators: [String: UInt64] = [:]
    public var emulators: [EmulatorMemory] = []

    public init(simulators: [String: UInt64] = [:], emulators: [EmulatorMemory] = []) {
        self.simulators = simulators
        self.emulators = emulators
    }

    public func emulatorBytes(avdName: String) -> UInt64? {
        emulators.first { $0.avdName == avdName }?.footprintBytes
    }

    public func emulatorBytes(serial: String) -> UInt64? {
        emulators.first { $0.serial == serial }?.footprintBytes
    }
}

public enum DeviceProcessMemory {
    /// Descendants counted per device at most (a runaway tree stays bounded).
    static let maxProcessesPerDevice = 2_000

    /// Measures `simulatorUDIDs` and every qemu emulator with ONE scan of
    /// the process table. A simulator's launchd_sim is the process named
    /// `launchd_sim` whose arguments contain the device's UDID; its tree is
    /// found by parent pid. Nothing is measured for a UDID with no
    /// launchd_sim (a shut down device).
    public static func measure(table: ProcessTable, simulatorUDIDs: Set<String>) -> DeviceMemoryReport {
        let entries = table.entries()
        var report = DeviceMemoryReport()

        var children: [Int32: [Int32]] = [:]
        for entry in entries { children[entry.parentPid, default: []].append(entry.pid) }

        if !simulatorUDIDs.isEmpty {
            for entry in entries where entry.name == "launchd_sim" {
                let joined = table.arguments(of: entry.pid).joined(separator: "\u{0}")
                guard let udid = simulatorUDIDs.first(where: { joined.contains($0) }) else { continue }
                var total: UInt64 = 0
                var seen: Set<Int32> = [entry.pid]
                var queue = [entry.pid]
                var index = 0
                while index < queue.count, seen.count <= maxProcessesPerDevice {
                    let pid = queue[index]
                    index += 1
                    total += table.footprint(of: pid) ?? 0
                    for child in children[pid] ?? [] where seen.insert(child).inserted {
                        queue.append(child)
                    }
                }
                report.simulators[udid, default: 0] += total
            }
        }

        for entry in entries where entry.name.hasPrefix("qemu-system") {
            guard let bytes = table.footprint(of: entry.pid) else { continue }
            let arguments = table.arguments(of: entry.pid)
            report.emulators.append(EmulatorMemory(
                pid: entry.pid,
                avdName: avdName(in: arguments),
                consolePort: consolePort(in: arguments),
                footprintBytes: bytes
            ))
        }
        return report
    }

    static func avdName(in arguments: [String]) -> String? {
        if let index = arguments.firstIndex(of: "-avd"), arguments.indices.contains(index + 1) {
            return arguments[index + 1]
        }
        return arguments.first { $0.hasPrefix("@") && $0.count > 1 }.map { String($0.dropFirst()) }
    }

    static func consolePort(in arguments: [String]) -> Int? {
        for flag in ["-port", "-ports"] {
            if let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) {
                let first = arguments[index + 1].split(separator: ",").first.map(String.init) ?? ""
                if let port = Int(first) { return port }
            }
        }
        return nil
    }

    /// "1.8 GB" / "640 MB": decimal-free below a gigabyte.
    public static func format(_ bytes: UInt64) -> String {
        let gigabyte = Double(1 << 30)
        if Double(bytes) >= gigabyte { return String(format: "%.1f GB", Double(bytes) / gigabyte) }
        return String(format: "%.0f MB", Double(bytes) / Double(1 << 20))
    }

    /// Above this a device's row is tinted as a warning.
    public static let warningThreshold: UInt64 = 4 << 30
}

/// The live process table: `proc_listpids` + `proc_pidinfo` (PROC_PIDTBSDINFO),
/// `sysctl` KERN_PROCARGS2 and `proc_pid_rusage` (RUSAGE_INFO_V4).
public struct LiveProcessTable: ProcessTable {
    public init() {}

    public func entries() -> [ProcessEntry] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 16)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard written > 0 else { return [] }
        var result: [ProcessEntry] = []
        result.reserveCapacity(Int(written) / MemoryLayout<pid_t>.size)
        for pid in pids.prefix(Int(written) / MemoryLayout<pid_t>.size) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            let name = withUnsafePointer(to: &info.pbi_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
            }
            result.append(ProcessEntry(pid: pid, parentPid: Int32(info.pbi_ppid), name: name))
        }
        return result
    }

    public func arguments(of pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        func nextString() -> String? {
            guard index < size else { return nil }
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            let text = String(decoding: buffer[start..<index], as: UTF8.self)
            while index < size, buffer[index] == 0 { index += 1 }
            return text
        }
        _ = nextString() // the executable path
        var arguments: [String] = []
        while arguments.count < Int(argc), let argument = nextString() { arguments.append(argument) }
        return arguments
    }

    public func footprint(of pid: Int32) -> UInt64? {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? usage.ri_phys_footprint : nil
    }
}
