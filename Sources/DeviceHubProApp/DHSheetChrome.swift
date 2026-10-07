import SwiftUI

/// Device Hub's sheet language (measured on its New Simulator sheet, DH
/// 27.0, 2026-09-29): 20 pt around a rounded card of 39.8 pt rows, labels on
/// the left and the value or its popup right-aligned, a rule, then a footer
/// with a gray Cancel and a blue default button. Shared by the sheets the
/// Device menu opens (Push Notification, Permissions, Time Zone, Open URL,
/// Sensors, Incoming Call / SMS, Phone Number) and the New Simulator sheet.
enum DHSheetMetrics {
    static let cardInset: CGFloat = 20
    static let rowHeight: CGFloat = 39.2
    static let rowInset: CGFloat = 10
    static let cardRadius: CGFloat = 10
    static let fieldWidth: CGFloat = 225.5
    static let footerTop: CGFloat = 17
    static let footerBottom: CGFloat = 16
    static let footerSide: CGFloat = 16
}

/// A button of the sheet's footer, after Cancel.
struct DHSheetAction {
    let title: String
    var isEnabled = true
    var isDefault = false
    let action: () -> Void
}

/// The sheet: an optional centered bold title, the content in a 20 pt inset,
/// a rule and the footer.
struct DHSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    var title: String?
    var width: CGFloat = 470
    var cancelTitle = "Cancel"
    /// Extra footer buttons, the last `isDefault` one being the blue default.
    var actions: [DHSheetAction] = []
    /// A note at the footer's leading edge (a spinner line, a caption).
    var footerNote: String?
    /// Replaces closing the sheet when Cancel is pressed or Esc is typed
    /// (a sheet with an inline edit cancels just the edit); nil dismisses.
    var onCancel: (() -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                if let title {
                    Text(title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }
                content()
            }
            .padding(DHSheetMetrics.cardInset)
            Divider()
            HStack(spacing: 8) {
                if let footerNote {
                    Text(footerNote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button(cancelTitle) { if let onCancel { onCancel() } else { dismiss() } }
                    .keyboardShortcut(.cancelAction)
                ForEach(actions.indices, id: \.self) { index in
                    let action = actions[index]
                    if action.isDefault {
                        Button(action.title, action: action.action)
                            .glassProminentButton()
                            .keyboardShortcut(.defaultAction)
                            .disabled(!action.isEnabled)
                    } else {
                        Button(action.title, action: action.action)
                            .disabled(!action.isEnabled)
                    }
                }
            }
            .padding(.horizontal, DHSheetMetrics.footerSide)
            .padding(.top, DHSheetMetrics.footerTop)
            .padding(.bottom, DHSheetMetrics.footerBottom)
        }
        .frame(width: width)
    }
}

/// The rounded card holding the rows, with a hairline between them.
struct DHSheetCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content()) { rows in
                ForEach(rows.indices, id: \.self) { index in
                    if index > 0 {
                        Divider().padding(.horizontal, DHSheetMetrics.rowInset)
                    }
                    rows[index]
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: DHSheetMetrics.cardRadius, style: .continuous)
                .fill(Color(nsColor: .quaternarySystemFill))
        )
    }
}

/// One row: the label, then the trailing control.
struct DHSheetRow<Trailing: View>: View {
    let title: String
    var height: CGFloat = DHSheetMetrics.rowHeight
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, DHSheetMetrics.rowInset)
        .frame(minHeight: height)
    }
}

/// A right-aligned text field, as the sheet's Name row draws it.
struct DHSheetTextField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat = DHSheetMetrics.fieldWidth

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .labelsHidden()
            .frame(width: width)
    }
}

/// A popup's trailing capsule glyph as the sheet draws it: a light disc
/// holding one chevron (single for a menu button, up and down for a popup),
/// after the current value.
struct DHSheetPopupChrome: ViewModifier {
    var symbol = "chevron.up.chevron.down"

    func body(content: Content) -> some View {
        HStack(spacing: 6) {
            content
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 19, height: 19)
                .background(Circle().fill(Color(nsColor: .quaternarySystemFill)))
                .allowsHitTesting(false)
        }
    }
}

/// A plain-text popup: the selected title and a disc chevron.
struct DHSheetPopup<Selection: Hashable>: View {
    struct Option: Identifiable {
        let value: Selection
        let title: String
        var id: Int { title.hashValue ^ "\(value)".hashValue }
    }

    let options: [Option]
    @Binding var selection: Selection
    var placeholder = ""
    var symbol = "chevron.up.chevron.down"

    var body: some View {
        Menu {
            ForEach(options) { option in
                Toggle(option.title, isOn: Binding(
                    get: { selection == option.value },
                    set: { if $0 { selection = option.value } }
                ))
            }
        } label: {
            Text(options.first { $0.value == selection }?.title ?? placeholder)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .modifier(DHSheetPopupChrome(symbol: symbol))
    }
}
