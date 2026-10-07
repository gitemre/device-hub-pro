import SwiftUI
import Observation
import DeviceHubProKit

/// Device ▸ Shell…: runs `adb -s <serial> shell <command>` one command at a
/// time (no PTY; nothing typed reaches a running command), shows its output
/// and exit status, keeps a history (up / down in the field) and can cancel a
/// running command. The retained output is capped (`ShellTranscript`).
@MainActor
@Observable
final class DeviceShellModel {
    private let adb: AdbClient?
    let serial: String?

    private(set) var transcript = ShellTranscript()
    private(set) var isRunning = false
    var history = ShellHistory()
    var command = ""

    private var task: Task<Void, Never>?
    /// Lines wait here and are applied in batches, so a chatty command does
    /// not redraw the view per line.
    private let pending = PendingLines()
    private var flusher: Task<Void, Never>?

    init(adb: AdbClient?, serial: String?) {
        self.adb = adb
        self.serial = serial
    }

    func run() {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning, let adb, let serial else { return }
        history.record(text)
        command = ""
        transcript.append("$ \(text)", kind: .command)
        isRunning = true
        let pending = pending
        flusher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                // The model is gone (the sheet closed): so is the loop.
                guard let self else { return }
                self.flush()
            }
        }
        task = Task { [weak self] in
            let outcome: String
            do {
                let status = try await adb.runShell(serial: serial, command: text) { pending.add($0) }
                outcome = "exit \(status)"
            } catch is CancellationError {
                outcome = "cancelled"
            } catch {
                outcome = String(describing: error)
            }
            self?.finish(outcome)
        }
    }

    func cancel() {
        task?.cancel()
        // A model with no command running has no flusher to end; one whose
        // command was cancelled gets its flusher ended by `finish`.
        if !isRunning { flusher?.cancel() }
    }

    func clear() { transcript.clear() }

    func historyUp() { command = history.previous(current: command) }
    func historyDown() { command = history.next(current: command) }

    private func flush() {
        for line in pending.drain() { transcript.append(line, kind: .output) }
    }

    private func finish(_ outcome: String) {
        flusher?.cancel()
        flush()
        transcript.append(outcome, kind: .status)
        isRunning = false
    }
}

private final class PendingLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) {
        lock.lock()
        lines.append(line)
        // A command that floods faster than the view drains it keeps only what
        // the transcript could hold anyway.
        if lines.count > 20_000 { lines.removeFirst(lines.count - 20_000) }
        lock.unlock()
    }

    func drain() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let taken = lines
        lines.removeAll(keepingCapacity: true)
        return taken
    }
}

struct DeviceShellSheet: View {
    @Environment(DeviceWorkspace.self) private var workspace

    var body: some View {
        DeviceShellContent(
            model: DeviceShellModel(adb: workspace.services.adbClient, serial: workspace.context.serial),
            deviceName: workspace.context.device.map { workspace.services.displayName(of: $0) }
        )
    }
}

private struct DeviceShellContent: View {
    @State var model: DeviceShellModel
    /// Which device the commands run on: the sheet had no title at all.
    let deviceName: String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var commandFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Text(deviceName.map { "Shell on \($0)" } ?? "Shell")
                .font(.headline)
                .padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.transcript.lines) { line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(color(line.kind))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: model.transcript.lines.last?.id) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            Divider()
            HStack(spacing: 8) {
                Text("$").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                TextField("", text: $model.command, prompt: Text("adb shell command"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($commandFocused)
                    .onSubmit { model.run() }
                    .onKeyPress(.upArrow) { model.historyUp(); return .handled }
                    .onKeyPress(.downArrow) { model.historyDown(); return .handled }
                    .disabled(model.isRunning)
                    // A disabled field gives up focus while a command runs:
                    // take it back when the command is done.
                    .onChange(of: model.isRunning) { _, running in
                        if !running { Task { @MainActor in commandFocused = true } }
                    }
                    .onAppear { commandFocused = true }
                if model.isRunning {
                    Button("Cancel") { model.cancel() }
                } else {
                    Button("Run") { model.run() }
                        .disabled(model.command.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Clear") { model.clear() }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            if model.transcript.droppedLines > 0 {
                Text("Older output was dropped (\(model.transcript.droppedLines) lines) to keep memory bounded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }
        }
        .frame(width: 640, height: 440)
        // Closing the sheet ends a running command, and its flusher with it.
        .onDisappear { model.cancel() }
    }

    private func color(_ kind: ShellTranscript.Kind) -> Color {
        switch kind {
        case .command: return .accentColor
        case .output: return .primary
        case .status: return .secondary
        }
    }
}
