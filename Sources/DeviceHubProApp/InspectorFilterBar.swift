import SwiftUI

/// Device Hub's bottom bar of a list inspector (its Apps and Reports tabs):
/// a full-width hairline, then a filter capsule with a magnifier, a text
/// field and, behind a thin divider, a pop-up showing its current choice.
/// The pop-up is as wide as its label (measured on Device Hub 27.0, Reports:
/// "Crashes" 70 pt, "Diagnostics" 91 pt, "Logs" 50 pt, its right edge fixed
/// 8 pt inside the capsule). The Apps tabs keep their own copy of this
/// capsule with a fixed-width scope pop-up; this one is the Reports panel's.
struct InspectorFilterBar<Popup: View>: View {
    @Binding var text: String
    /// The pop-up's current choice, as shown.
    let popupLabel: String
    /// A `Picker`: it is drawn as an invisible pop-up over the label, so its
    /// menu opens with the current choice on the label, as Device Hub's does.
    @ViewBuilder var popup: () -> Popup
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            InspectorDivider(leadingInset: 0, trailingInset: 0)
            capsule
                .padding(.horizontal, ParityMetrics.inspectorCardInset)
                .padding(.top, ParityMetrics.inspectorAppsFilterTopSpacing)
                .padding(.bottom, ParityMetrics.inspectorReportsFilterBottomSpacing)
        }
    }

    private var capsule: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: ParityMetrics.inspectorReportsFilterFontSize, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 8)
                TextField("Filter", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: ParityMetrics.inspectorReportsFilterFontSize))
                    .focused($isFocused)
                    .padding(.leading, 6)
            }
            .frame(maxHeight: .infinity)
            .textFieldHitArea(Rectangle(), focus: $isFocused)
            .layoutPriority(1)
            Spacer(minLength: 6)

            Rectangle()
                .fill(Color.primary.opacity(ParityMetrics.inspectorAppsScopeDividerOpacity))
                .frame(
                    width: ParityMetrics.inspectorDividerHeight,
                    height: ParityMetrics.inspectorAppsSeparatorHeight
                )
            HStack(spacing: 3) {
                Text(popupLabel)
                    .font(.system(size: ParityMetrics.inspectorReportsFilterFontSize))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(Color.primary.opacity(0.75))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.75))
            }
            .fixedSize()
            .padding(.leading, 11.5)
            .padding(.trailing, 13.5)
            .frame(maxHeight: .infinity)
            .overlay {
                popup()
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(0.011)
                    .accessibilityLabel(popupLabel)
            }
        }
        .frame(height: ParityMetrics.inspectorAppsFilterHeight)
        .background(Color.primary.opacity(ParityMetrics.inspectorAppsFilterFillOpacity), in: Capsule())
    }
}
