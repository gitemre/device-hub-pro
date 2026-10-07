import AppKit
import Foundation
import Observation
import DeviceHubProKit

/// Each running simulator's and emulator's memory for the sidebar, refreshed
/// about every 10 s, only while one of the app's windows is on screen (not
/// occluded or minimised, app not hidden), and only when something runs.
/// One process-table scan per refresh serves every device
/// (`DeviceProcessMemory.measure`), off the main actor.
@MainActor
@Observable
final class DeviceMemoryMonitor {
    private(set) var report = DeviceMemoryReport()

    @ObservationIgnored private let table: ProcessTable
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The simulators the next refresh measures (the booted ones).
    @ObservationIgnored private var simulatorUDIDs: Set<String> = []
    /// Whether any Android emulator runs (qemu is looked for only then).
    @ObservationIgnored private var wantsEmulators = false

    init(table: ProcessTable = LiveProcessTable(), interval: Duration = .seconds(10)) {
        self.table = table
        self.interval = interval
    }

    /// What is running now, from the inventories; the loop starts on the
    /// first non-empty call and idles when nothing runs.
    func update(bootedSimulators: Set<String>, androidRunning: Bool) {
        let changed = bootedSimulators != simulatorUDIDs || androidRunning != wantsEmulators
        simulatorUDIDs = bootedSimulators
        wantsEmulators = androidRunning
        if bootedSimulators.isEmpty, !androidRunning {
            if !report.simulators.isEmpty || !report.emulators.isEmpty { report = DeviceMemoryReport() }
            return
        }
        if task == nil { start() } else if changed { Task { await refresh() } }
    }

    func bytes(simulator udid: String) -> UInt64? { report.simulators[udid] }

    private func start() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let interval = self?.interval else { return }
                try? await Task.sleep(for: interval)
                if self?.simulatorUDIDs.isEmpty == true, self?.wantsEmulators == false {
                    self?.task = nil
                    return
                }
            }
        }
    }

    private static var appIsVisible: Bool {
        guard !NSApp.isHidden else { return false }
        return NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
    }

    private func refresh() async {
        guard Self.appIsVisible else { return }
        let table = self.table
        let udids = simulatorUDIDs
        let wantsEmulators = self.wantsEmulators
        let measured = await Task.detached(priority: .utility) {
            DeviceProcessMemory.measure(table: table, simulatorUDIDs: udids)
        }.value
        var next = measured
        if !wantsEmulators { next.emulators = [] }
        if next != report { report = next }
    }

    /// The label for a row: "1.8 GB" and whether it is over the warning threshold.
    static func label(_ bytes: UInt64?) -> (text: String, warning: Bool)? {
        guard let bytes else { return nil }
        return (DeviceProcessMemory.format(bytes), bytes >= DeviceProcessMemory.warningThreshold)
    }
}

/// The words a sidebar device row speaks and shows on hover.
@MainActor
enum DeviceRowAccessibility {
    /// "AQA Verify, Simulator, 3.0 GB in use, iOS 27.0": the parts that exist,
    /// joined by commas.
    static func label(title: String, subtitle: String, memoryBytes: UInt64?, osLabel: String) -> String {
        var parts = [title, subtitle]
        if let memory = DeviceMemoryMonitor.label(memoryBytes) { parts.append("\(memory.text) in use") }
        parts.append(osLabel)
        return parts
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// One tooltip: "Memory in use: 3.0 GB", "(high)" over the threshold; an
    /// emulator's figure is the process footprint, which can exceed its RAM.
    static func tooltip(memoryBytes: UInt64?, isAndroidEmulator: Bool) -> String {
        guard let memory = DeviceMemoryMonitor.label(memoryBytes) else { return "" }
        var text = "Memory in use: \(memory.text)" + (memory.warning ? " (high)" : "")
        if isAndroidEmulator {
            text += "\nThe emulator process's physical footprint, as Activity Monitor shows it; a hypervisor guest's memory can count beyond its RAM setting."
        }
        return text
    }
}
