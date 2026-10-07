import AppKit
import SwiftUI
import DeviceHubProKit

/// Device Hub's way of saying iOS needs something: a short line and one
/// button ("Get Xcode…" opens Xcode's Mac App Store page; "Open Xcode…" opens
/// the installed one, where Settings > Locations selects it and the first
/// launch installs its components). Shown where iOS would be: under the
/// sidebar's devices, in the Pair Nearby Device sheet's iPhone tile and in the
/// `+` menu. Android never shows it.
struct XcodeHintView: View {
    let guidance: AppleToolchain.XcodeGuidance
    /// Where the button sends the URL (the workspace in the app, a recorder in
    /// tests).
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// "Check Again": reads Xcode's setup again now (nil: no such button).
    var checkAgain: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Text(guidance.message)
                .font(.system(size: ParityMetrics.sidebarSubtitleFontSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let url = guidance.actionURL {
                Button(guidance.actionTitle) { open(url) }
                    .controlSize(.small)
            }
            if let checkAgain {
                Button("Check Again", action: checkAgain)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }
}
