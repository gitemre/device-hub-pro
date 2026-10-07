import SwiftUI

/// The empty stage of a Mac whose Android tools are installed but that has
/// no emulator and no connected phone yet: the "ready" card with Create an
/// Emulator and a hint for connecting a phone. The setup run's own finished
/// screen shows the same card once; this one stays across relaunches until
/// there is a device or the user closes it.
struct AndroidReadyCard: View {
    var onCreateEmulator: () -> Void = {}
    var onPairNearby: () -> Void = {}
    var onDismiss: () -> Void = {}

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.green)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            Text("Android tools are ready")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("The next step is an emulator to run apps on. Device Hub Pro can download an Android system image and create one for you.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                onCreateEmulator()
            } label: {
                Text("Create an Emulator\u{2026}").frame(maxWidth: .infinity)
            }
            .glassProminentButton()
            .controlSize(.large)
            VStack(spacing: 4) {
                Text("Have a phone? Turn on USB debugging in its Developer options and plug it in, or pair it over Wi-Fi.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Pair Nearby Device\u{2026}") { onPairNearby() }
                    .buttonStyle(.link)
                    .font(.callout)
            }
            Button("Don\u{2019}t show again") { onDismiss() }
                .buttonStyle(.link)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: AndroidSetupView.width)
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .accessibilityElement(children: .contain)
    }
}

/// `AndroidReadyCard` on the stage, wired to the window.
struct AndroidReadyStage: View {
    /// Whether the empty stage shows the ready card: the tools are there, the
    /// AVD list was read and is empty, no Android device is connected, the
    /// card was not closed, and no setup run is on screen.
    static func isShown(
        adbAvailable: Bool,
        avdsLoaded: Bool,
        avdCount: Int,
        deviceCount: Int,
        dismissed: Bool,
        phase: AndroidSetupModel.Phase
    ) -> Bool {
        adbAvailable && avdsLoaded && avdCount == 0 && deviceCount == 0 && !dismissed && phase == .idle
    }

    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace

    var body: some View {
        AndroidReadyCard(
            onCreateEmulator: { workspace.window.createFormFactor = .phone },
            onPairNearby: { workspace.window.isPairSheetPresented = true },
            onDismiss: { model.preferences.setAndroidReadyCardDismissed(true) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
