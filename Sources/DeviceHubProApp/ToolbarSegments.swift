import SwiftUI

/// One segment of a Device Hub segmented toolbar capsule (TB-03 zoom, TB-04
/// inspector): a 36×36 pt button whose selected state is DH's platter.
struct ToolbarSegment: Identifiable {
    let id: String
    var isActive = false
    var isDisabled = false
    var shortcut: KeyEquivalent?
    let help: String
    /// What assistive tech hears, when it differs from the tooltip (Device
    /// Hub's segments name their symbols: "Edit", "Text Document").
    let accessibilityName: String
    let action: () -> Void
    let label: AnyView

    /// A disabled segment shows no selection, like DH's zoom capsule while
    /// the device is stopped (all three separators, no platter).
    var showsSelection: Bool {
        isActive && !isDisabled
    }

    init<Label: View>(
        id: String,
        isActive: Bool = false,
        isDisabled: Bool = false,
        shortcut: KeyEquivalent? = nil,
        help: String,
        label accessibilityName: String? = nil,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.id = id
        self.isActive = isActive
        self.isDisabled = isDisabled
        self.shortcut = shortcut
        self.help = help
        self.accessibilityName = accessibilityName ?? help
        self.action = action
        self.label = AnyView(label())
    }
}

/// Device Hub's segmented toolbar capsule. Like `NSSegmentedControl`, the
/// 1 pt separator between two segments shows only while neither of them is
/// selected or hovered (DH hides it on hover even over disabled segments),
/// and a segment's hover and press platter matches its selected platter.
///
/// The capsule keeps its audited width (TB-03 151 pt, TB-04 112 pt): the
/// boundary after `layoutSeparatorAfter` reserves the separator's 1 pt in
/// the layout, as the static separator always did; the other boundaries draw
/// theirs over the two segments' shared edge.
struct ToolbarSegmentedCapsule: View {
    let segments: [ToolbarSegment]
    let padding: CGFloat
    var layoutSeparatorAfter: Int? = 0
    /// The capsule's own accessibility name (Device Hub's segmented controls
    /// are "Zoom" and "Inspector Category"), so each segment keeps its own
    /// label instead of taking the toolbar item's (the first segment's).
    var groupLabel: String?

    @State private var hoveredID: String?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                if index > 0 {
                    separator(before: index)
                }
                button(segment)
            }
        }
        .frame(height: ParityMetrics.toolbarButtonHeight)
        .padding(.horizontal, padding)
        .toolbarControlSurface()
        .padding(.horizontal, -ParityMetrics.toolbarClusterInset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(groupLabel ?? "")
    }

    /// Whether the separator between `segments[index - 1]` and
    /// `segments[index]` shows.
    static func separatorVisible(before index: Int, in segments: [ToolbarSegment], hoveredID: String?) -> Bool {
        func highlighted(_ segment: ToolbarSegment) -> Bool {
            segment.showsSelection || segment.id == hoveredID
        }
        return !highlighted(segments[index - 1]) && !highlighted(segments[index])
    }

    @ViewBuilder
    private func separator(before index: Int) -> some View {
        let line = ToolbarSeparator()
            .opacity(Self.separatorVisible(before: index, in: segments, hoveredID: hoveredID) ? 1 : 0)
        if layoutSeparatorAfter == index - 1 {
            line
        } else {
            Color.clear
                .frame(width: 0, height: ParityMetrics.toolbarSeparatorHeight)
                .overlay { line }
        }
    }

    private func button(_ segment: ToolbarSegment) -> some View {
        Button(action: segment.action) {
            segment.label
                .font(.system(size: ParityMetrics.toolbarIconSize, weight: ParityMetrics.toolbarIconWeight))
                .frame(
                    width: ParityMetrics.toolbarButtonWidth,
                    height: ParityMetrics.toolbarButtonHeight
                )
                .background {
                    if segment.showsSelection {
                        ToolbarActivePlatter()
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(ChromeButtonStyle(platter: .capsule(ParityMetrics.toolbarSegmentPlatterSize)))
        .disabled(segment.isDisabled)
        .keyboardShortcut(segment.shortcut.map { KeyboardShortcut($0, modifiers: .command) })
        .onHover { hovering in
            if hovering {
                hoveredID = segment.id
            } else if hoveredID == segment.id {
                hoveredID = nil
            }
        }
        .accessibilityLabel(segment.accessibilityName)
        .toolbarButtonAccessibilityState(active: segment.isActive, toggleState: nil)
        .help(segment.help)
    }
}

/// DH's 1 pt, 20 pt-tall separator inside the zoom and inspector capsules.
struct ToolbarSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(ParityMetrics.toolbarSeparatorOpacity))
            .frame(
                width: ParityMetrics.toolbarSeparatorWidth,
                height: ParityMetrics.toolbarSeparatorHeight
            )
    }
}

/// DH's selected-segment platter: the 31×28 pt capsule a hover shows, in
/// `secondarySystemFill` while the window is key and darker in the
/// background. Changes with the selection at once, like DH's segmented
/// control.
struct ToolbarActivePlatter: View {
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        Capsule()
            .fill(
                controlActiveState == .key
                    ? AnyShapeStyle(Color(nsColor: .secondarySystemFill))
                    : AnyShapeStyle(.primary.opacity(ParityMetrics.toolbarActiveCircleFillOpacityInactive))
            )
            .frame(
                width: ParityMetrics.toolbarSegmentPlatterSize.width,
                height: ParityMetrics.toolbarSegmentPlatterSize.height
            )
    }
}
