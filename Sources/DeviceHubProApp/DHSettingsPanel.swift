import SwiftUI

// MARK: - Panel surface

/// Device Hub's settings-panel surface: a scroll of flat cards, 10 pt side
/// insets, first card 8 pt below the toolbar band (`dh-CT-panel.png`).
struct DHSettingsPanel<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ParityMetrics.inspectorCardSpacing) {
                content()
            }
            .padding(.horizontal, ParityMetrics.inspectorCardInset)
            .padding(.top, ParityMetrics.controlsPanelTopSpacing)
            .padding(.bottom, ParityMetrics.inspectorCardInset)
        }
        // A legacy (non-overlay) scroller reserves a right-hand gutter, which
        // would inset the cards' trailing edge past DH's audited 10 pt. DH's
        // panel draws no gutter; wheel/trackpad scrolling is unaffected.
        .scrollIndicators(.never)
    }
}

/// Device Hub's Controls empty state for a device that is off: a centered
/// glyph above a caption, filling the whole panel — no card, no scroll
/// (`dh-CT-empty-2026-09-28.png`, DH's settings panel for a stopped
/// simulator). Until 2026-09-28 both the Android and iOS panels showed a
/// small `DHCard` with a row and a caption near the top instead.
struct DHControlsEmptyState<Glyph: View>: View {
    let caption: String
    /// Lifts the group off the panel's centre (DH's Apps placeholder sits
    /// 12.5 pt lower than its Settings and Reports ones, measured on 27.0).
    var verticalOffset: CGFloat = ParityMetrics.controlsEmptyStateOffset
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        VStack(spacing: ParityMetrics.controlsEmptyStateGap) {
            glyph()
            Text(caption)
                .font(.system(size: ParityMetrics.controlsEmptyStateCaptionFontSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: ParityMetrics.controlsEmptyStateCaptionWidth)
        }
        .offset(y: verticalOffset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

extension DHControlsEmptyState where Glyph == DHEmptyStateSymbol {
    init(glyph: String, caption: String) {
        self.init(caption: caption) { DHEmptyStateSymbol(name: glyph) }
    }
}

/// The panel of a selected device that the lists no longer show: the caption
/// and a Rescan button, so the state is never a dead end.
struct DeviceNoLongerListedState: View {
    @Environment(AppModel.self) private var model
    var glyph = "questionmark.circle"

    var body: some View {
        VStack(spacing: 10) {
            DHControlsEmptyState(glyph: glyph, caption: "This device is no longer listed.")
            Button("Rescan") {
                Task { await model.refresh() }
            }
            .disabled(model.isBusy)
            .padding(.bottom, 16)
        }
    }
}

/// The empty state's SF Symbol, 36 pt (DH's sliders glyph measured 35.5 pt
/// wide).
struct DHEmptyStateSymbol: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .font(.system(size: ParityMetrics.controlsEmptyStateGlyphFontSize))
            .foregroundStyle(.secondary)
    }
}

/// One rounded group of rows. Rows are separated by `DHHairline()`.
struct DHCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            Color.primary.opacity(ParityMetrics.inspectorCardFillOpacity),
            in: RoundedRectangle(cornerRadius: ParityMetrics.inspectorCardRadius, style: .continuous)
        )
    }
}

/// One collapsible domain group: DH's small gray section heading above a
/// `DHCard` ("Paired Simulators" in its Info inspector). The heading shows a
/// disclosure chevron while hovered, like the sidebar's native sections;
/// collapsed, the group is the heading alone. (Until 2026-09-28 the heading
/// was a 42 pt row inside the card and read as one more setting.)
/// The expanded state persists globally per group; `forceExpanded` switches
/// to a harness-only key so `DHP_CONTROLS_EXPAND_ALL=1` never touches
/// the user's saved layout.
struct DHGroup<Content: View>: View {
    let id: String
    let title: String
    let defaultExpanded: Bool
    let forceExpanded: Bool
    @ViewBuilder var content: () -> Content

    private static var hitOutset: CGFloat { 5 }

    @AppStorage private var isExpanded: Bool
    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        id: String,
        title: String,
        defaultExpanded: Bool,
        forceExpanded: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.id = id
        self.title = title
        self.defaultExpanded = defaultExpanded
        self.forceExpanded = forceExpanded
        self.content = content
        let key = forceExpanded
            ? "controlsGroup.\(id).expanded.harness"
            : "controlsGroup.\(id).expanded"
        _isExpanded = AppStorage(
            wrappedValue: forceExpanded || defaultExpanded,
            key
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ParityMetrics.controlsGroupHeadingCardGap) {
            heading
            if isExpanded {
                DHCard {
                    content()
                }
            }
        }
    }

    /// A collapsed group always shows its chevron, so a header with rows
    /// folded under it does not read as an empty one; an open group shows
    /// it on hover or focus only.
    static func showsChevron(isExpanded: Bool, isHovered: Bool, isFocused: Bool) -> Bool {
        !isExpanded || isHovered || isFocused
    }

    private var heading: some View {
        Button {
            MotionMetrics.run(MotionMetrics.standard, reduceMotion: reduceMotion) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 0) {
                Text(title)
                    .font(.system(size: ParityMetrics.controlsGroupHeadingFontSize, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, ParityMetrics.controlsGroupHeadingLeading)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(
                        size: ParityMetrics.controlsDisclosureChevronFontSize,
                        weight: .semibold
                    ))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .padding(.trailing, ParityMetrics.controlsTrailingInset)
                    .opacity(Self.showsChevron(isExpanded: isExpanded, isHovered: isHovered, isFocused: isFocused) ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .frame(height: ParityMetrics.controlsGroupHeadingHeight)
            // A taller hit area than the 13 pt text line, without moving
            // the heading off DH's rhythm.
            .padding(.vertical, Self.hitOutset)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -Self.hitOutset)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(isExpanded ? "expanded" : "collapsed"))
        .accessibilityHint(Text(isExpanded ? "Hide settings" : "Show settings"))
        .accessibilityIdentifier("controlsGroup.\(id)")
    }
}

/// DH's 1 pt row divider, inset 10 pt per side inside the card.
struct DHHairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(ParityMetrics.inspectorDividerOpacity))
            .frame(height: ParityMetrics.inspectorDividerHeight)
            .padding(.horizontal, ParityMetrics.inspectorDividerInset)
    }
}

// MARK: - Rows

/// A 42 pt settings row: optional leading glyph, 13 pt label, trailing
/// control ending 10 pt before the card's edge.
struct DHRow<Trailing: View>: View {
    private let title: String
    private let glyph: String?
    private let help: String
    private let trailing: Trailing

    init(
        _ title: String,
        glyph: String? = nil,
        help: String = "",
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.glyph = glyph
        self.help = help
        self.trailing = trailing()
    }

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
                    .lineLimit(1)
                    .padding(.leading, ParityMetrics.controlsLabelGap)
            } else {
                Text(title)
                    .font(.system(size: ParityMetrics.controlsLabelFontSize))
                    .lineLimit(1)
                    .padding(.leading, ParityMetrics.controlsGlyphLeading)
            }
            Spacer(minLength: 8)
            trailing
        }
        .frame(height: ParityMetrics.controlsRowHeight)
        .padding(.trailing, ParityMetrics.controlsTrailingInset)
        .dhTooltip(help)
    }
}

/// A row whose control is DH's switch. A nil value (the device has not
/// answered) disables the switch and draws it as unknown, never as Off.
struct DHToggleRow: View {
    let title: String
    var glyph: String?
    var help: String = ""
    let value: Bool?
    /// Spoken after the switch's value (e.g. a pending restart).
    var accessibilityStatus: String?
    let action: (Bool) async -> Void

    var body: some View {
        DHRow(title, glyph: glyph, help: help) {
            DHSwitch(isOn: value, accessibilityStatus: accessibilityStatus) { newValue in
                Task { await action(newValue) }
            }
            .disabled(value == nil)
            .accessibilityLabel(Text(title))
        }
    }
}

/// A row whose control is DH's slider, right-aligned at the card's inset.
///
/// Both handlers are labelled and required: with a defaulted live handler a
/// bare trailing closure silently became the release-only `onCommit`, and
/// the hinge row (built for throttled live writes) moved only on release.
/// Rows that write on release pass `onLiveChange: nil` explicitly.
struct DHSliderRow: View {
    let title: String
    let glyph: String?
    let help: String
    let values: [Double]
    let value: Double
    let showsDots: Bool
    let tickCount: Int
    let accessibilityValue: String
    let onLiveChange: ((Double) -> Void)?
    let onCommit: (Double) -> Void

    init(
        title: String,
        glyph: String? = nil,
        help: String = "",
        values: [Double],
        value: Double,
        showsDots: Bool = false,
        tickCount: Int = 0,
        accessibilityValue: String,
        onLiveChange: ((Double) -> Void)?,
        onCommit: @escaping (Double) -> Void
    ) {
        self.title = title
        self.glyph = glyph
        self.help = help
        self.values = values
        self.value = value
        self.showsDots = showsDots
        self.tickCount = tickCount
        self.accessibilityValue = accessibilityValue
        self.onLiveChange = onLiveChange
        self.onCommit = onCommit
    }

    var body: some View {
        DHRow(title, glyph: glyph, help: help) {
            DHSlider(
                values: values,
                value: value,
                showsDots: showsDots,
                tickCount: tickCount,
                accessibilityLabel: title,
                accessibilityValue: accessibilityValue,
                onLiveChange: onLiveChange,
                onCommit: onCommit
            )
        }
    }
}

/// A settings row whose **whole surface** opens a value popup — glyph, label,
/// value and chevron are one hit target. The popup is a SwiftUI popover with
/// plain buttons (a borderless `Menu` needed a precisely sized clear label and
/// was unreliable to click); the drawn value + circle keep Device Hub's
/// geometry underneath.
struct DHPopupRow<Option: Identifiable>: View {
    let title: String
    var glyph: String?
    var help: String = ""
    let options: [Option]
    let selection: Option?
    let placeholder: String?
    /// Optional action item below the options (the Location row's
    /// "Custom Location…").
    var actionTitle: String?
    var onAction: (() -> Void)?
    let titleFor: (Option) -> String
    /// The selection's title in the row's value, when it is shorter than the
    /// popover's (Device Hub's color filters: "Protanopia" for "Red/Green
    /// (Protanopia)"). The popover and the accessibility picker keep `titleFor`.
    var valueTitleFor: ((Option) -> String)? = nil
    let onSelect: (Option) -> Void

    @State private var isPresented = false
    @State private var isHovered = false
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
            DHPopupValueLabel(
                text: valueText,
                isHighlighted: isHovered || isPresented,
                truncationMode: .tail
            )
        }
        .frame(height: ParityMetrics.controlsRowHeight)
        .padding(.trailing, ParityMetrics.controlsTrailingInset)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { isPresented = true }
        // Keyboard: with keyboard navigation on, Tab reaches the row and
        // Space, Return or ↓ opens the value popup, like a pop-up button.
        .focusable(interactions: .activate)
        .onKeyActivation([.space, .return, .downArrow]) {
            guard isEnabled else { return .ignored }
            isPresented = true
            return .handled
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: ParityMetrics.controlsPopoverRowSpacing) {
                popoverItems
            }
            .padding(ParityMetrics.controlsPopoverInset)
            .frame(minWidth: ParityMetrics.controlsPopoverMinWidth)
        }
        .accessibilityRepresentation {
            VStack {
                Picker(title, selection: selectionBinding) {
                    if selection == nil, let placeholder {
                        Text(placeholder).tag(nil as Option.ID?)
                    }
                    ForEach(options) { option in
                        Text(titleFor(option)).tag(Optional(option.id))
                    }
                }
                .pickerStyle(.menu)
                // The menu picker exposes only its value otherwise.
                .accessibilityLabel(title)
                if let actionTitle, let onAction {
                    Button(actionTitle) { onAction() }
                }
            }
        }
        .dhTooltip(help)
    }

    @ViewBuilder
    private var popoverItems: some View {
        if let placeholder, selection == nil {
            DHPopoverRow(title: placeholder, isEnabled: false) {}
        }
        ForEach(options) { option in
            DHPopoverRow(
                title: titleFor(option),
                isSelected: option.id == selection?.id
            ) {
                onSelect(option)
                isPresented = false
            }
        }
        if let actionTitle, let onAction {
            Divider()
                .padding(.vertical, ParityMetrics.controlsPopoverDividerInset)
            DHPopoverRow(title: actionTitle) {
                onAction()
                isPresented = false
            }
        }
    }

    private var valueText: String {
        if let selection { return (valueTitleFor ?? titleFor)(selection) }
        return placeholder ?? ""
    }

    private var selectionBinding: Binding<Option.ID?> {
        Binding(
            get: { selection?.id },
            set: { newValue in
                guard let newValue,
                      let option = options.first(where: { $0.id == newValue }) else { return }
                onSelect(option)
            }
        )
    }
}

/// One row inside `DHPopupRow`'s popover: a checkmark column, the title and a
/// hover fill. A plain button — reliable to click, unlike menu items.
private struct DHPopoverRow: View {
    let title: String
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
    }
}

/// Where a control row's content sits: after the label (`leading`, for rows
/// that fill the row with fields) or at the trailing edge (DH's rhythm).
enum DHControlRowAlignment {
    case leading
    case trailing
}

/// A row hosting arbitrary controls (buttons, fields) at DH's rhythm.
struct DHControlRow<Content: View>: View {
    private let title: String?
    private let glyph: String?
    private let help: String
    private let alignment: DHControlRowAlignment
    private let content: Content

    init(
        _ title: String? = nil,
        glyph: String? = nil,
        help: String = "",
        alignment: DHControlRowAlignment = .trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.glyph = glyph
        self.help = help
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        // No stack spacing: the label sits on `DHRow`'s 37.5 pt column (an
        // 8 pt spacing here put these labels 8 pt right of every other row's
        // until 2026-09-28).
        HStack(spacing: 0) {
            if let glyph {
                Image(systemName: glyph)
                    .accessibilityHidden(true)
                    .font(.system(size: ParityMetrics.controlsGlyphFontSize))
                    .foregroundStyle(.secondary)
                    .frame(width: ParityMetrics.controlsGlyphFrame)
                    .padding(.leading, ParityMetrics.controlsGlyphLeading)
            } else if title != nil {
                Color.clear
                    .frame(width: ParityMetrics.controlsGlyphFrame)
                    .padding(.leading, ParityMetrics.controlsGlyphLeading)
            }
            if let title {
                Text(title)
                    .font(.system(size: ParityMetrics.controlsLabelFontSize))
                    .lineLimit(1)
                    .padding(.leading, ParityMetrics.controlsLabelGap)
            }
            if alignment == .trailing {
                Spacer(minLength: 8)
                content
            } else {
                content
                    .padding(.leading, title == nil ? 0 : 8)
                Spacer(minLength: 0)
            }
        }
        .frame(minHeight: ParityMetrics.controlsRowHeight)
        // An untitled leading row (the SMS message field) continues the row
        // above it, so it starts at the label column, not the card's edge.
        .padding(.leading, title == nil && glyph == nil && alignment == .leading
            ? ParityMetrics.controlsLabelLeading : 0)
        .padding(.trailing, ParityMetrics.controlsTrailingInset)
        .dhTooltip(help)
    }
}

/// What a settings row's tooltip may say. Device Hub's rows have none, and
/// no user-visible text quotes a command line (`adb`, `simctl`, `devicectl`,
/// `svc`, `cmd`, `settings put`, a `--flag`, a raw setting name), so a
/// tooltip that does is dropped, and so is one too long to read as a hint.
/// The Apple simulator panel switches its rows' tooltips off altogether
/// (`dhRowTooltips`).
enum DHHelp {
    static let maxLength = 140

    nonisolated(unsafe) private static let technical = try! Regex(
        #"\b(adb|simctl|devicectl|svc|cmd|dumpsys|app_process|logcat|gRPC|SurfaceFlinger|SystemUI)\b|settings put|persist\.|(^|\s)(--[a-z][a-z-]*|-[a-z](\s|$))|[a-z]+_[a-z_]+|[a-z]\|[a-z]|\bam [a-z]|\bon[A-Z][A-Za-z]+\b|\b[a-z]{2,}\.[a-z]{2,}\b"#
    )

    static func isTechnical(_ text: String) -> Bool {
        text.firstMatch(of: technical) != nil
    }

    /// The tooltip to show for a row's `help`: empty for a technical or long
    /// one, or when the panel shows none.
    static func tooltip(_ help: String, enabled: Bool = true) -> String {
        guard enabled, !help.isEmpty, help.count <= maxLength, !isTechnical(help) else { return "" }
        return help
    }
}

private struct DHRowTooltipsKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether settings rows show their tooltip (off in the Apple simulator's
    /// panel, as in Device Hub's).
    var dhRowTooltips: Bool {
        get { self[DHRowTooltipsKey.self] }
        set { self[DHRowTooltipsKey.self] = newValue }
    }
}

private struct DHTooltipModifier: ViewModifier {
    let help: String
    @Environment(\.dhRowTooltips) private var enabled

    func body(content: Content) -> some View {
        content.help(DHHelp.tooltip(help, enabled: enabled))
    }
}

extension View {
    /// A settings row's tooltip, through `DHHelp`.
    func dhTooltip(_ help: String) -> some View {
        modifier(DHTooltipModifier(help: help))
    }
}

/// A row's tooltip from its parts: what the row does for the tester first,
/// then the mechanism. The Controls panel keeps only state under a row
/// (`DHCaptionRow`: an outcome, a warning, what the device reports); fixed
/// explanations live here, as DH's rows carry no prose (2026-09-28).
func dhHelp(_ parts: String?...) -> String {
    parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
}

/// State under a row: 11 pt secondary prose (an outcome, a warning, what
/// the device reports). Fixed explanations go to the row's help (`dhHelp`).
struct DHCaptionRow: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: ParityMetrics.controlsCaptionFontSize))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, ParityMetrics.controlsGlyphLeading)
            .padding(.trailing, ParityMetrics.controlsTrailingInset)
            .padding(.vertical, 6)
    }
}

/// Device Hub's in-panel push button: a flat gray 21 pt capsule with 10 pt
/// semibold gray text ("Edit Visibility"). Every button in the Controls panel
/// uses it — DH has no blue or bordered buttons there — and a pressed button
/// darkens like the toolbar's platters. `.dhPanel` at the call site.
struct DHPanelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DHPanelButtonBody(configuration: configuration)
    }
}

private struct DHPanelButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: ParityMetrics.controlsButtonFontSize, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(
                ParityMetrics.controlsButtonInkOpacity
                    * (isEnabled ? 1 : ParityMetrics.controlsDisabledOpacity)
            ))
            .lineLimit(1)
            .padding(.horizontal, ParityMetrics.controlsButtonHorizontalPadding)
            .frame(height: ParityMetrics.controlsButtonHeight)
            .background(
                Capsule().fill(Color.primary.opacity(
                    configuration.isPressed
                        ? ParityMetrics.controlsButtonPressedFillOpacity
                        : ParityMetrics.controlsButtonFillOpacity
                ))
            )
            .contentShape(Capsule())
            .fixedSize()
    }
}

extension ButtonStyle where Self == DHPanelButtonStyle {
    static var dhPanel: DHPanelButtonStyle { DHPanelButtonStyle() }
}

// MARK: - Controls

/// How `DHSwitch` draws an unknown reading. Custom shapes are not dimmed by
/// `.disabled`, so the unknown switch reads `isEnabled` itself; an unknown
/// reading parks the knob in the middle of an unfilled track instead of
/// passing for Off. (A known reading is drawn by the system switch, which
/// dims itself.)
struct DHSwitchAppearance: Equatable {
    enum KnobPosition: Equatable {
        case leading
        case center
        case trailing
    }

    let knob: KnobPosition
    /// The accent-filled track (on).
    let isFilled: Bool
    let opacity: Double
    let accessibilityValue: String

    init(isOn: Bool?, isEnabled: Bool) {
        switch isOn {
        case true?:
            knob = .trailing
            isFilled = true
            accessibilityValue = "on"
        case false?:
            knob = .leading
            isFilled = false
            accessibilityValue = "off"
        case nil:
            knob = .center
            isFilled = false
            accessibilityValue = "unknown"
        }
        opacity = isEnabled ? 1 : ParityMetrics.controlsDisabledOpacity
    }
}

/// Device Hub's switch: the system mini switch (`Toggle` with `.switch` and
/// `.mini`), 36×16 pt exactly like DH's, drawing its own knob, its Liquid
/// Glass pressed lens and its flip animation, and reached from the keyboard
/// like any system control. A nil reading (the device has not answered) is
/// not a state the system switch has: it is drawn as a dimmed, unfilled
/// track with the knob parked in the middle, and cannot be flipped.
struct DHSwitch: View {
    @Environment(\.isEnabled) private var isEnabled
    /// nil while the device has not answered.
    let isOn: Bool?
    var accessibilityStatus: String?
    let action: (Bool) -> Void

    var body: some View {
        let appearance = DHSwitchAppearance(isOn: isOn, isEnabled: isEnabled)
        Group {
            if let isOn {
                Toggle(
                    isOn: Binding(get: { isOn }, set: { action($0) }),
                    label: { EmptyView() }
                )
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            } else {
                unknownSwitch(appearance)
            }
        }
        .fixedSize()
        .accessibilityValue(Text(
            [appearance.accessibilityValue, accessibilityStatus].compactMap { $0 }.joined(separator: ", ")
        ))
    }

    /// The unknown reading: the resting track and knob of the old drawing,
    /// dimmed and not interactive.
    private func unknownSwitch(_ appearance: DHSwitchAppearance) -> some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(ParityMetrics.controlsControlFillOpacity))
                .frame(width: ParityMetrics.controlsSwitchWidth, height: ParityMetrics.controlsSwitchHeight)
            Capsule(style: .continuous)
                .fill(.white)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(.black.opacity(0.06), lineWidth: 0.5)
                )
                .frame(
                    width: ParityMetrics.controlsSwitchKnobWidth,
                    height: ParityMetrics.controlsSwitchKnobHeight
                )
        }
        .frame(width: ParityMetrics.controlsSwitchWidth, height: ParityMetrics.controlsSwitchHeight)
        .opacity(appearance.opacity)
        .accessibilityElement()
        .accessibilityAddTraits(.isToggle)
    }
}

/// The index of the position nearest to a value; ties go to the smaller
/// position, matching `FontScaleStep.nearest`, so a device value is never
/// rounded up. Nil for no positions.
func nearestSliderIndex(positions: [Double], to value: Double) -> Int? {
    var best: Int?
    var bestDistance = Double.infinity
    for (index, position) in positions.enumerated() {
        let distance = abs(position - value)
        if distance < bestDistance - 1e-9 {
            best = index
            bestDistance = distance
        }
    }
    return best
}

/// Device Hub's slider: the system slider (`Slider` in the index space of
/// `values`, one step per allowed value), 120×16 pt with the system knob,
/// rail, key-window accent fill and Liquid Glass held lens, exactly the
/// controls DH draws. Stepped rows can show the system tick dots. Dragging
/// previews locally; `onCommit` fires once on release. Keyboard: with
/// keyboard navigation on, Tab reaches it and the arrow keys step it (one
/// commit per step, like the accessibility increment).
struct DHSlider: View {
    /// The positions the knob can take, ascending. More than one value =
    /// snapped steps; a single value = no meaningful travel.
    let values: [Double]
    /// The device's current value; the knob follows it whenever it changes.
    let value: Double
    var showsDots = false
    /// Evenly spaced decoration dots that mark no value (DH's Sound row has
    /// nine while its knob moves freely); 0 = none. Ignored with `showsDots`.
    var tickCount = 0
    let accessibilityLabel: String
    let accessibilityValue: String
    /// Fired on every snapped change while dragging (before the release), so
    /// rows whose device follows continuously — the media volume — can apply
    /// the value live.
    var onLiveChange: ((Double) -> Void)?
    let onCommit: (Double) -> Void

    /// The index being dragged to, nil unless the slider is held.
    @State private var dragIndex: Double?
    @State private var isEditing = false

    private var positions: [Double] { values.isEmpty ? [value] : values }
    private var currentIndex: Double {
        Double(nearestSliderIndex(positions: positions, to: value) ?? 0)
    }
    /// The slider works in index space, so unevenly spaced values (the
    /// Android text sizes) still step and tick evenly.
    private var range: ClosedRange<Double> { 0...Double(max(positions.count - 1, 1)) }

    private var index: Binding<Double> {
        Binding(
            get: { dragIndex ?? currentIndex },
            set: { proposed in
                let shown = dragIndex ?? currentIndex
                let pointerDown = Self.isPointerDrivenEvent(NSApp.currentEvent?.type)
                var snapped = proposed.rounded()
                if !pointerDown, proposed != shown {
                    // Not the pointer: an arrow key or an accessibility
                    // increment (the system reports it as an edit, with a
                    // step of its own). It moves exactly one position.
                    snapped = shown + (proposed > shown ? 1 : -1)
                }
                snapped = min(max(snapped, range.lowerBound), Double(positions.count - 1))
                guard snapped != shown else { return }
                let position = positions[Int(snapped)]
                if pointerDown && isEditing {
                    dragIndex = snapped
                    onLiveChange?(position)
                } else {
                    // One commit, and the knob follows the device's answer.
                    onCommit(position)
                }
            }
        )
    }

    /// Whether the system slider is reacting to the mouse, as opposed to an
    /// arrow key or an accessibility action (which report no mouse event).
    private static func isPointerDrivenEvent(_ type: NSEvent.EventType?) -> Bool {
        type == .leftMouseDown || type == .leftMouseDragged || type == .leftMouseUp
    }

    private func editingChanged(_ editing: Bool) {
        isEditing = editing
        guard !editing else { return }
        if let dragIndex {
            onCommit(positions[Int(dragIndex)])
        }
        dragIndex = nil
    }

    var body: some View {
        slider
            .frame(width: ParityMetrics.controlsSliderWidth, height: ParityMetrics.controlsSliderKnobHeight)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityValue(Text(accessibilityValue))
    }

    /// Rows with dots step and tick natively; the Sound row's dots mark
    /// nothing (`tickCount`) and its knob moves freely; the others are plain
    /// continuous sliders, snapped in `index` (a stepped system slider with no
    /// ticks draws a tick line under its rail).
    @ViewBuilder
    private var slider: some View {
        #if swift(>=6.2)
        if showsDots {
            Slider(
                value: index,
                in: range,
                step: 1,
                label: { EmptyView() },
                tick: { SliderTick($0) },
                onEditingChanged: editingChanged
            )
            .labelsHidden()
        } else if tickCount > 1 {
            let marks = (0..<tickCount).map { range.upperBound * Double($0) / Double(tickCount - 1) }
            Slider(
                value: index,
                in: range,
                label: { EmptyView() },
                ticks: { SliderTickContentForEach(marks, id: \.self) { SliderTick($0) } },
                onEditingChanged: editingChanged
            )
            .labelsHidden()
        } else {
            Slider(value: index, in: range, onEditingChanged: editingChanged)
                .labelsHidden()
        }
        #else
        if showsDots {
            Slider(value: index, in: range, step: 1, onEditingChanged: editingChanged)
                .labelsHidden()
        } else {
            Slider(value: index, in: range, onEditingChanged: editingChanged)
                .labelsHidden()
        }
        #endif
    }
}

/// DH's filled, 20 pt-tall text field (our Android rows; DH's panel has no
/// fields of its own).
struct DHField: View {
    @Binding var text: String
    var prompt: String
    var accessibilityLabel: String
    var alignment: TextAlignment = .leading

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: ParityMetrics.controlsLabelFontSize))
            .multilineTextAlignment(alignment)
            .focused($isFocused)
            .padding(.horizontal, ParityMetrics.controlsFieldTextInset)
            .frame(height: ParityMetrics.controlsFieldHeight)
            .textFieldHitArea(
                RoundedRectangle(cornerRadius: ParityMetrics.controlsFieldRadius, style: .continuous),
                focus: $isFocused
            )
            .background(
                Color.primary.opacity(ParityMetrics.controlsFieldFillOpacity),
                in: RoundedRectangle(cornerRadius: ParityMetrics.controlsFieldRadius, style: .continuous)
            )
            .accessibilityLabel(Text(accessibilityLabel))
    }
}
