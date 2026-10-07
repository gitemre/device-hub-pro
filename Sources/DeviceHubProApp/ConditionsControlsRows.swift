import SwiftUI
import DeviceHubProKit

extension ParityMetrics {
    /// The Connection latency editor's millisecond fields (up to 5 digits
    /// at the row's 13 pt label size, plus the field's text insets).
    static let conditionsLatencyFieldWidth: CGFloat = 56
}

/// One row of the Network conditions or App conditions group, in Device
/// Hub's row language. Each value is the device's read-back
/// (`DeviceConditionsController`); captions say what a row really does and,
/// after an action, what Android recorded.
struct ConditionsRowView: View {
    @Environment(DeviceWorkspace.self) private var workspace
    let row: ControlsRow

    private var conditions: DeviceConditionsController { workspace.conditions }
    private var isWriting: Bool { conditions.isWriting }

    var body: some View {
        switch row {
        case .networkSpeed: speedRow
        case .connectionLatency: latencyRow
        case .meteredMobileData: meterRow
        case .resetConditions: resetRow
        case .targetApp: targetRow
        case .lowMemory: lowMemoryRow
        case .killProcess: killRow
        default: EmptyView()
        }
    }

    // MARK: - Network conditions

    private var speedRow: some View {
        let reading = conditions.shaping
        return VStack(spacing: 0) {
          DHPopupRow(
            title: "Speed",
            glyph: "speedometer",
            help: dhHelp(
                ConditionsRowText.speedFootnote,
                "The emulator's classic network speeds (GSM 14.4 kbit/s to EVDO 280 Mbit/s), applied with tc in the device."
            ),
            options: NetworkSpeed.allCases,
            selection: reading?.speed,
            placeholder: ConditionsRowText.speedPlaceholder(reading),
            actionTitle: nil,
            onAction: nil,
            titleFor: { $0.label },
            onSelect: { speed in Task { await conditions.setSpeed(speed) } }
          )
          .disabled(reading == nil || isWriting)
          DHCaptionRow(ConditionsRowText.speedPathCaption(conditions.network?.connectivity.dataPath))
          if conditions.network?.connectivity.dataPath == .mobileData, conditions.savedDataPath != nil {
              DHCaptionRow("Reset conditions, disconnecting or quitting turns Wi-Fi and mobile data back to how they were.")
          }
        }
    }

    private var latencyRow: some View {
        @Bindable var conditions = conditions
        let stored = conditions.shaping.map(\.latency)

        return VStack(spacing: 0) {
            DHPopupRow(
                title: "Connection latency",
                glyph: "timer",
                help: dhHelp(
                    ConditionsRowText.latencyFootnote,
                    "The emulator's classic latency profiles: GPRS and UMTS share 35–200 ms; EDGE and HSCSD 80–400 ms."
                ),
                options: LatencyPreset.allCases,
                selection: stored.flatMap(LatencyPreset.matching),
                placeholder: ConditionsRowText.latencyPlaceholder(stored),
                actionTitle: "Custom…",
                onAction: { conditions.beginCustomLatency() },
                titleFor: { $0.label },
                onSelect: { preset in Task { await conditions.setLatency(preset.latency) } }
            )
            .disabled(stored == nil || isWriting)
            if conditions.isEditingCustomLatency {
                DHControlRow("Custom", help: "Whole milliseconds, 1 ≤ minimum ≤ maximum.") {
                    HStack(spacing: 6) {
                        DHField(
                            text: $conditions.customLatencyMinimum,
                            prompt: "min",
                            accessibilityLabel: "Minimum latency in milliseconds",
                            alignment: .trailing
                        )
                        .frame(width: ParityMetrics.conditionsLatencyFieldWidth)
                        Text("–")
                            .font(.system(size: ParityMetrics.controlsLabelFontSize))
                            .foregroundStyle(.secondary)
                        DHField(
                            text: $conditions.customLatencyMaximum,
                            prompt: "max",
                            accessibilityLabel: "Maximum latency in milliseconds",
                            alignment: .trailing
                        )
                        .frame(width: ParityMetrics.conditionsLatencyFieldWidth)
                        Text("ms")
                            .font(.system(size: ParityMetrics.controlsLabelFontSize))
                            .foregroundStyle(.secondary)
                        Button("Apply") {
                            Task { await conditions.applyCustomLatency() }
                        }
                        .buttonStyle(.dhPanel)
                        .disabled(isWriting)
                        Button("Cancel") {
                            conditions.isEditingCustomLatency = false
                            conditions.customLatencyError = nil
                        }
                        .buttonStyle(.dhPanel)
                    }
                }
                if let error = conditions.customLatencyError {
                    DHCaptionRow(error)
                }
            }
        }
    }

    private var meterRow: some View {
        let metered = conditions.network?.connectivity.isMobileDataMetered
        return VStack(spacing: 0) {
            DHToggleRow(
                title: "Metered mobile data",
                glyph: "gauge.with.needle",
                help: dhHelp(
                    ConditionsRowText.meterFootnote,
                    "Marks the mobile connection as metered or unmetered."
                ),
                value: metered
            ) { await conditions.setMobileDataMetered($0) }
            .disabled(isWriting)
            if metered == nil {
                DHCaptionRow(ConditionsRowText.meterUnavailable)
            }
        }
    }

    private var resetRow: some View {
        DHControlRow("Reset conditions", glyph: "arrow.counterclockwise", help: ConditionsRowText.resetFootnote) {
            Button("Reset") {
                Task { await conditions.resetNetworkConditions() }
            }
            .buttonStyle(.dhPanel)
            .disabled(isWriting || conditions.network == nil)
        }
    }

    // MARK: - App conditions

    private var targetOptions: [TargetAppOption] {
        conditions.targetPackages.map {
            TargetAppOption(package: $0, isForeground: $0 == conditions.foregroundPackage)
        }
    }

    private var targetRow: some View {
        let options = targetOptions
        let line = ConditionsRowText.processLine(conditions.targetSnapshot, apiLevel: conditions.apiLevel)
        return VStack(spacing: 0) {
            DHPopupRow(
                title: "Target app",
                glyph: "app",
                help: "The app the rows below act on: installed third-party apps, and the app in the foreground.",
                options: options,
                selection: options.first { $0.package == conditions.targetPackage },
                placeholder: conditions.isLoadingTargets ? "Loading…" : "Choose an app",
                actionTitle: "Refresh List",
                onAction: { conditions.loadTargets() },
                titleFor: { $0.title },
                onSelect: { conditions.targetPackage = $0.package }
            )
            if let line {
                DHCaptionRow(line)
            }
        }
    }

    private var lowMemoryRow: some View {
        let gate = conditions.lowMemoryGate
        let caption = conditions.trimOutcome ?? gate?.reason
        return VStack(spacing: 0) {
            DHControlRow(
                "Simulate low memory",
                glyph: "memorychip",
                help: dhHelp(
                    ConditionsRowText.lowMemoryFootnote,
                    "Runs am send-trim-memory --user current <package> RUNNING_CRITICAL (foreground) or COMPLETE (background), then reads the level back from the process record."
                )
            ) {
                Button("Send") {
                    Task { await conditions.simulateLowMemory() }
                }
                .buttonStyle(.dhPanel)
                .disabled(conditions.targetPackage == nil || gate != .allowed || isWriting)
            }
            if let caption {
                DHCaptionRow(caption)
            }
        }
    }

    private var killRow: some View {
        VStack(spacing: 0) {
            DHControlRow(
                "Kill process",
                glyph: "xmark.circle",
                help: dhHelp(
                    ConditionsRowText.killFootnote,
                    "Runs am kill --user current <package>, then checks the pid and Android's exit record."
                )
            ) {
                Button("Kill") {
                    Task { await conditions.killProcess() }
                }
                .buttonStyle(.dhPanel)
                .disabled(conditions.targetPackage == nil || isWriting)
            }
            if let outcome = conditions.killOutcome {
                DHCaptionRow(outcome)
            }
        }
    }

    // MARK: - Pieces

    private func valueText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: ParityMetrics.controlsLabelFontSize))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}
