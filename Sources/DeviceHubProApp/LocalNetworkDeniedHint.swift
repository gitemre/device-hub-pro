import AppKit
import SwiftUI
import DeviceHubProKit

/// Shown beside wireless debugging when the user denied Device Hub Pro the Local
/// Network permission: nothing on the Wi-Fi network can be found or reached
/// until it is allowed. The button only opens the System Settings pane; the
/// app never changes the setting.
struct LocalNetworkDeniedHint: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.adbRecovery.isLocalNetworkDenied {
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalNetworkPolicy.deniedHint)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Local Network Settings") {
                    NSWorkspace.shared.open(LocalNetworkPolicy.settingsURL)
                }
                .glassButton()
            }
            .accessibilityElement(children: .combine)
        }
    }
}
