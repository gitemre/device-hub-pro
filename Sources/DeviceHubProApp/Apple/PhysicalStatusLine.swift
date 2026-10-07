import SwiftUI
import DeviceHubProKit

/// What the physical stage says under Device Hub's bare phone,
/// as pure data: nothing when there is nothing to say. Device Hub
/// keeps no card over the phone; only these lines can appear, each for a
/// reason:
///
/// - fast input starting (a spinner), or failed (the reason and Retry), or
///   Control failed (the reason);
/// - the preview's "View only · refreshes about every N s";
/// - a permission hint with the button that only opens the System Settings
///   pane (Camera for the live view, Microphone for the audio).
///
/// Live View, Auto-refresh and Control are switches of the menus now
/// (`PhysicalLiveViewController`'s `setLiveView(_:)`, `setAutoRefresh(_:)`,
/// `setControl(_:)`).
struct PhysicalStatusLine: Equatable {
    enum Kind: Equatable {
        /// Control is starting: shown with a spinner.
        case progress
        /// Control failed or a soft note ("Tap a text field first").
        case message
        /// Everything else.
        case info
    }

    /// The button a line offers; each only opens a System Settings pane.
    enum Action: Equatable {
        case openCameraSettings
        case openMicrophoneSettings
        /// Try fast input again after it could not start.
        case retryInput

        var title: String {
            switch self {
            case .retryInput: "Retry"
            case .openCameraSettings: "Open Camera Settings"
            case .openMicrophoneSettings: "Open Microphone Settings"
            }
        }
    }

    struct Entry: Equatable, Identifiable {
        let kind: Kind
        let text: String
        var action: Action?

        var id: String { "\(kind)-\(text)" }
    }

    var entries: [Entry]

    var isEmpty: Bool { entries.isEmpty }

    /// The lines for the inputs, in the order they show.
    ///
    /// - Parameters:
    ///   - viewKind: what draws now (`nil` for the static panel, which has
    ///     no session).
    ///   - cadence: the preview's measured cadence ("about every 1.5 s").
    ///   - controlIsReady: Control answers ("Controlling" for "View only").
    static func make(
        viewKind: PhysicalViewKind?,
        cadence: String?,
        controlIsReady: Bool,
        controlProgress: String?,
        controlMessage: String?,
        planNote: String?,
        offersCameraSettings: Bool,
        audioNote: String?,
        inputFailure: String? = nil
    ) -> PhysicalStatusLine {
        var entries: [Entry] = []
        if let inputFailure {
            entries.append(Entry(kind: .message, text: inputFailure, action: .retryInput))
        }
        if let controlProgress {
            entries.append(Entry(kind: .progress, text: controlProgress))
        } else if let controlMessage {
            entries.append(Entry(kind: .message, text: controlMessage))
        }
        if viewKind == .screenshots {
            let mode = controlIsReady ? "Controlling" : "View only"
            entries.append(Entry(kind: .info, text: "\(mode) · " + (cadence.map { "refreshes \($0)" } ?? "refreshing…")))
        }
        if let planNote {
            entries.append(Entry(kind: .info, text: planNote, action: offersCameraSettings ? .openCameraSettings : nil))
        }
        if let audioNote {
            entries.append(Entry(kind: .info, text: audioNote, action: .openMicrophoneSettings))
        }
        return PhysicalStatusLine(entries: entries)
    }
}

/// The small status line: over the live or preview stage (`session` names
/// what draws) and on the static panel (`session` nil). It draws nothing
/// while there is nothing to say.
struct PhysicalStatusLineView: View {
    @Environment(DeviceWorkspace.self) private var workspace
    var session: (any PhysicalViewSession)?

    var body: some View {
        let live = workspace.physicalLive
        let control = workspace.physicalControl
        let line = PhysicalStatusLine.make(
            viewKind: session?.viewKind,
            cadence: live.cadenceText,
            controlIsReady: control.isReady,
            controlProgress: control.progressText,
            controlMessage: control.message,
            planNote: live.plan.noteText,
            offersCameraSettings: live.plan.offersCameraSettings,
            audioNote: live.audioNoteText,
            inputFailure: control.inputFailure
        )
        if !line.isEmpty {
            VStack(spacing: 3) {
                ForEach(line.entries) { entry in
                    HStack(spacing: 6) {
                        if entry.kind == .progress {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Text(entry.text)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                        if let action = entry.action {
                            Button(action.title) { perform(action, live: live) }
                                .buttonStyle(.link)
                                .font(.system(size: 11))
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: 460)
            .liquidGlass()
            .glassHairline(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("iPhone status")
        }
    }

    private func perform(_ action: PhysicalStatusLine.Action, live: PhysicalLiveViewController) {
        switch action {
        case .openCameraSettings: live.openCameraSettings()
        case .openMicrophoneSettings: live.openMicrophoneSettings()
        case .retryInput: live.retryInput()
        }
    }
}
