import SwiftUI
import DeviceHubProKit

/// The license sdkmanager is waiting on: the tool's own text when it sent
/// one, a generic question when it only asked for the review gate. Shared by
/// the AVD create sheet and the Pixel provisioning screen. Accepting an
/// agreement takes an explicit click: Return does not accept.
struct SDKLicenseSheet: View {
    let prompt: SDKLicensePrompt
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Android SDK License")
                .font(.headline)
            if prompt.text.isEmpty {
                Text("Accept the Android SDK license to continue?")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    Text(prompt.text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 260)
                .background(
                    Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
            HStack {
                Spacer()
                Button("Decline") { onDecline() }
                    .keyboardShortcut(.cancelAction)
                Button("Accept") { onAccept() }
                    .glassProminentButton()
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }
}
