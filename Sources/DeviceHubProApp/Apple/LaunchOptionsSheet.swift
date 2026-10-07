import SwiftUI
import DeviceHubProKit

/// Launch with Options… for a simulator app: arguments (one per line),
/// environment variables (`KEY=value` per line, passed as
/// `SIMCTL_CHILD_<KEY>`), wait for the debugger and terminate the running
/// copy first. The last options are remembered per bundle id.
struct LaunchOptionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    let app: SimulatorApp
    let udid: String

    @State private var argumentsText = ""
    @State private var environmentText = ""
    @State private var waitForDebugger = false
    @State private var terminateRunning = false
    @State private var isLoaded = false

    private var environmentProblem: String? {
        do {
            _ = try SimulatorLaunchOptions.parseEnvironment(environmentText)
            return nil
        } catch {
            return "\(error)"
        }
    }

    var body: some View {
        DHSheet(
            title: "Launch \(app.title)",
            width: 500,
            actions: [
                DHSheetAction(title: "Launch", isEnabled: environmentProblem == nil, isDefault: true) { launch() },
            ]
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Arguments (one per line)").font(.caption).foregroundStyle(.secondary)
                PlainCodeEditor(text: $argumentsText, tabMovesFocus: true)
                    .modifier(CodeEditorWell(height: 70))
                    .accessibilityLabel("Launch arguments")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Environment (KEY=value, one per line)").font(.caption).foregroundStyle(.secondary)
                PlainCodeEditor(text: $environmentText, tabMovesFocus: true)
                    .modifier(CodeEditorWell(height: 70))
                    .accessibilityLabel("Launch environment")
                if let environmentProblem {
                    Text(environmentProblem).font(.caption).foregroundStyle(.red)
                }
            }
            DHSheetCard {
                DHSheetRow(title: "Wait for debugger") { Toggle("", isOn: $waitForDebugger).labelsHidden() }
                DHSheetRow(title: "Terminate running instance first") {
                    Toggle("", isOn: $terminateRunning).labelsHidden()
                }
            }
            Text("Variables reach the app when it launches. Options are remembered for \(app.bundleIdentifier).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { load() }
    }

    private func load() {
        guard !isLoaded else { return }
        isLoaded = true
        let options = model.libraries.options(for: app.bundleIdentifier)
        argumentsText = SimulatorLaunchOptions.argumentsText(options.arguments)
        environmentText = SimulatorLaunchOptions.environmentText(options.environment)
        waitForDebugger = options.waitForDebugger
        terminateRunning = options.terminateRunning
    }

    private func launch() {
        guard let environment = try? SimulatorLaunchOptions.parseEnvironment(environmentText) else { return }
        let options = SimulatorLaunchOptions(
            arguments: SimulatorLaunchOptions.parseArguments(argumentsText),
            environment: environment,
            waitForDebugger: waitForDebugger,
            terminateRunning: terminateRunning
        )
        model.libraries.remember(options, for: app.bundleIdentifier)
        dismiss()
        Task { await workspace.simulatorApps.launch(app, udid: udid, options: options) }
    }
}
