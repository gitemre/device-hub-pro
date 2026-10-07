import SwiftUI

/// The search fields' placeholders, one wording for the Android and the iOS
/// panels: a lowercase plural noun ("Search languages", "Search time zones").
enum DHSearchPrompt {
    static let languages = "Search languages"
    static let timeZones = "Search time zones"
}

/// An action item at the bottom of a `DHSearchablePopupRow`'s popover (the
/// Language row's "Restore …", the App language row's "System default").
struct DHPopupAction: Identifiable {
    let id: String
    let title: String
    var isEnabled = true
    let action: () -> Void
}

/// `DHPopupRow` for long lists (every language a device offers, every time
/// zone, every installed app): the same row — glyph, label, value and the
/// 20 pt chevron circle as one hit target — whose popover has a search field,
/// a pinned section, the full list in a scrolling lazy stack and optional
/// action items.
struct DHSearchablePopupRow<Option: Identifiable>: View {
    let title: String
    var glyph: String?
    var help: String = ""
    /// What the row shows as its value (the device's reading).
    let valueText: String
    var pinnedTitle: String?
    var pinned: [Option] = []
    var allTitle: String?
    let all: [Option]
    let selectedID: Option.ID?
    let titleFor: (Option) -> String
    var detailFor: ((Option) -> String?)?
    /// Whether an option matches the search text (already trimmed, non-empty).
    let matches: (Option, String) -> Bool
    var actions: [DHPopupAction] = []
    var isLoading = false
    var searchPrompt = "Search"
    /// Called when the popover opens (a row can load its list lazily).
    var onOpen: (() -> Void)?
    let onSelect: (Option) -> Void

    @State private var isPresented = false
    @State private var isHovered = false
    @State private var query = ""
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            if let glyph {
                Image(systemName: glyph)
                    .accessibilityHidden(true)
                    .font(.system(size: ParityMetrics.controlsGlyphFontSize))
                    .foregroundStyle(.secondary)
                    .frame(width: ParityMetrics.controlsGlyphFrame)
                    .padding(.leading, ParityMetrics.controlsGlyphLeading)
                Text(title)
                    .font(.system(size: ParityMetrics.controlsLabelFontSize))
                    .padding(.leading, ParityMetrics.controlsLabelGap)
            } else {
                Text(title)
                    .font(.system(size: ParityMetrics.controlsLabelFontSize))
                    .padding(.leading, ParityMetrics.controlsGlyphLeading)
            }
            // Room for the value's hover platter, which starts 13 pt
            // before the text, so it never paints over a long title.
            Spacer(minLength: ParityMetrics.controlsPopupTitleGap)
            DHPopupValueLabel(text: valueText, isHighlighted: isHovered || isPresented)
        }
        .frame(height: ParityMetrics.controlsRowHeight)
        .padding(.trailing, ParityMetrics.controlsTrailingInset)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { open() }
        .focusable(interactions: .activate)
        .onKeyActivation([.space, .return, .downArrow]) {
            guard isEnabled else { return .ignored }
            open()
            return .handled
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popover
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(valueText))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .dhTooltip(help)
    }

    private func open() {
        guard isEnabled else { return }
        query = ""
        onOpen?()
        isPresented = true
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: ParityMetrics.controlsPopoverRowSpacing) {
            DHField(text: $query, prompt: searchPrompt, accessibilityLabel: searchPrompt == "Search" ? "Search \(title)" : searchPrompt)
                .padding(.bottom, ParityMetrics.controlsPopoverDividerInset)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: ParityMetrics.controlsPopoverRowSpacing) {
                    listContent
                }
            }
            .frame(height: ParityMetrics.controlsSearchPopoverListHeight)
            if !actions.isEmpty {
                Divider()
                    .padding(.vertical, ParityMetrics.controlsPopoverDividerInset)
                ForEach(actions) { item in
                    DHSearchPopoverRow(title: item.title, isEnabled: item.isEnabled) {
                        item.action()
                        isPresented = false
                    }
                }
            }
        }
        .padding(ParityMetrics.controlsPopoverInset)
        .frame(width: ParityMetrics.controlsSearchPopoverWidth)
    }

    @ViewBuilder
    private var listContent: some View {
        if trimmedQuery.isEmpty {
            if !pinned.isEmpty {
                if let pinnedTitle { heading(pinnedTitle) }
                optionRows(pinned)
            }
            if let allTitle { heading(allTitle) }
            if all.isEmpty && isLoading {
                heading("Loading…")
            } else {
                optionRows(all)
            }
        } else {
            let unique = searchResults(trimmedQuery)
            if unique.isEmpty {
                heading(isLoading ? "Loading…" : "No matches")
            } else {
                optionRows(unique)
            }
        }
    }

    /// The pinned and full lists' matches, each option once.
    private func searchResults(_ text: String) -> [Option] {
        var seen = Set<Option.ID>()
        return (pinned + all).filter { matches($0, text) && seen.insert($0.id).inserted }
    }

    private func optionRows(_ options: [Option]) -> some View {
        ForEach(options) { option in
            DHSearchPopoverRow(
                title: titleFor(option),
                detail: detailFor?(option),
                isSelected: option.id == selectedID
            ) {
                onSelect(option)
                isPresented = false
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: ParityMetrics.controlsSearchPopoverHeadingFontSize, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(height: ParityMetrics.controlsSearchPopoverHeadingHeight, alignment: .bottomLeading)
            .padding(.leading, ParityMetrics.controlsPopoverRowInset)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The value and the 20 pt chevron circle of a DH value popup, drawn by hand
/// (so `.disabled` dims it through `isEnabled`), for `DHPopupRow` and
/// `DHSearchablePopupRow` alike.
///
/// Highlighted (the row hovered, or its popover open) it shows DH's popup
/// platter (CT-07 hover, "Pointer feedback" in the parity map): a 24 pt
/// rounded rectangle from 13 pt before the value to the circle's trailing
/// padding, in the circle's own fill — the circle merges into it, as DH's
/// does, instead of doubling its tint.
struct DHPopupValueLabel: View {
    let text: String
    var isHighlighted = false
    var truncationMode: Text.TruncationMode = .middle
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: ParityMetrics.controlsValueTrailingGap) {
            Text(text)
                .font(.system(size: ParityMetrics.controlsLabelFontSize))
                .lineLimit(1)
                .truncationMode(truncationMode)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: ParityMetrics.controlsPopupChevronFontSize, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: ParityMetrics.controlsPopupDiameter, height: ParityMetrics.controlsPopupDiameter)
                .background(
                    Color.primary.opacity(showsPlatter ? 0 : ParityMetrics.controlsPopupFillOpacity),
                    in: Circle()
                )
                .padding(.trailing, ParityMetrics.controlsPopupTrailingInset - ParityMetrics.controlsTrailingInset)
        }
        .background {
            if showsPlatter {
                RoundedRectangle(cornerRadius: ParityMetrics.controlsPopupPlatterRadius, style: .continuous)
                    .fill(Color.primary.opacity(ParityMetrics.controlsPopupFillOpacity))
                    .padding(.leading, -ParityMetrics.controlsPopupPlatterLeadingOutset)
                    .frame(height: ParityMetrics.controlsPopupPlatterHeight)
            }
        }
        .opacity(isEnabled ? 1 : ParityMetrics.controlsDisabledOpacity)
    }

    private var showsPlatter: Bool {
        isHighlighted && isEnabled
    }
}

/// One item of a searchable popover: the popover row of `DHPopupRow` (a
/// checkmark column, the title and a hover fill) with an optional secondary
/// detail after the title.
struct DHSearchPopoverRow: View {
    let title: String
    var detail: String?
    var isSelected = false
    var isEnabled = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: ParityMetrics.controlsPopoverCheckmarkSpacing) {
                Image(systemName: "checkmark")
                    .font(.system(size: ParityMetrics.controlsPopoverCheckmarkFontSize, weight: .semibold))
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: ParityMetrics.controlsPopoverCheckmarkWidth, alignment: .leading)
                Text(title)
                    .font(.system(size: ParityMetrics.controlsLabelFontSize))
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: ParityMetrics.controlsCaptionFontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ParityMetrics.controlsPopoverRowInset)
            .frame(height: ParityMetrics.controlsPopoverRowHeight)
            .background(
                RoundedRectangle(cornerRadius: ParityMetrics.controlsPopoverRowRadius, style: .continuous)
                    .fill(Color.primary.opacity(
                        isHovered && isEnabled ? ParityMetrics.controlsPopoverRowHoverOpacity : 0
                    ))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
