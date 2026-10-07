import SwiftUI
import DeviceHubProKit

/// A small card in the device list where a platform's devices would appear
/// when that platform cannot be used yet (no Android tools, no Xcode): an
/// icon, the message, the button that fixes it and, optionally, "Don't show
/// again". It sits in its own section ("Android", "iOS") of the list, high in
/// the sidebar, instead of a grey footnote at the bottom that the Dock
/// hides. The message takes as many lines as it needs and the buttons share
/// one row when they fit, else stack, so no text is ever cut to an ellipsis
/// at any sidebar width.
struct SidebarHintCard: View {
    let symbol: String
    let message: String
    let actionTitle: String
    var action: () -> Void
    /// Closes the card for good; nil offers no such link.
    var dismiss: (() -> Void)?
    /// A second button beside the action ("Check Again"); nil offers none.
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?
    /// The raw tool output behind the message, in a collapsed "Show Details".
    var details: String?
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.accentColor.opacity(0.14)))
                    .accessibilityHidden(true)
                Text(message)
                    .font(.system(size: ParityMetrics.sidebarSubtitleFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let details, !details.isEmpty {
                DisclosureGroup("Show Details", isExpanded: $showsDetails) {
                    ScrollView {
                        Text(details)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 90)
                }
                .font(.system(size: ParityMetrics.sidebarSubtitleFontSize))
                .padding(.leading, 40)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { buttons }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
            .padding(.leading, 40)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var buttons: some View {
        // The action's title wraps when even a row of its own is too narrow.
        Button(action: action) {
            Text(actionTitle)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .controlSize(.small)
        if let secondaryTitle, let secondaryAction {
            Button(secondaryTitle, action: secondaryAction)
                .controlSize(.small)
        }
        if let dismiss {
            Button("Don\u{2019}t show again", action: dismiss)
                .buttonStyle(.link)
                .controlSize(.small)
                .font(.system(size: ParityMetrics.sidebarSubtitleFontSize))
                .lineLimit(1)
                .fixedSize()
        }
    }
}
