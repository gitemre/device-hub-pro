import SwiftUI
import DeviceHubProKit

/// "Connect an Android Phone\u{2026}" from the `+` menu: what an Android phone
/// needs before it shows up here. Nothing is run; it only explains the steps
/// and hands over to Pair Nearby Device for the wireless way.
struct ConnectAndroidPhoneSheet: View {
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    /// The numbered steps for a cable.
    static let usbSteps = [
        "On the phone, open Settings \u{25B8} About phone and tap Build number 7 times to turn on Developer options.",
        "Open Settings \u{25B8} System \u{25B8} Developer options and turn on USB debugging.",
        "Plug the phone into this Mac and unlock it.",
        "When the phone asks \u{201C}Allow USB debugging?\u{201D}, tick Always allow from this computer and tap Allow.",
    ]

    /// MIUI / HyperOS refuse injected input until a second switch is on:
    /// the mirror then shows but taps and keys do nothing.
    static let xiaomiNote =
        "On a Xiaomi, Redmi or POCO phone, also turn on USB debugging (Security settings) in Developer options, or taps and typing will not reach the phone."

    static let wirelessNote =
        "No cable? Use Pair Nearby Device\u{2026} to pair over Wi\u{2011}Fi with a QR code (Android 11 or newer)."

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "smartphone")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Connect an Android Phone")
                    .font(.title3.bold())
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Self.usbSteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .trailing)
                        Text(step)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text(Self.xiaomiNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.wirelessNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Pair Nearby Device\u{2026}") {
                    dismiss()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        workspace.window.isPairSheetPresented = true
                    }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .glassProminentButton()
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
