import CoreGraphics

/// Pointer-feedback geometry (parity audit, "Pointer feedback"):
/// Device Hub's hover/press platters, measured 2026-09-25 on DH 27.0 at 2x
/// as the changed-pixel box between a rest and a hover capture of the same
/// control. Every toolbar and pill platter is 28 pt tall — 4 pt inside the
/// 36 pt capsule at the top and bottom — and as wide as DH's control.
extension ParityMetrics {
    /// TB-01 + / filter and TB-03 full screen / ⋯: DH's 30×28 pt items.
    static let toolbarItemPlatterSize = CGSize(width: 30, height: 28)
    /// TB-03 keyboard and device-frame toggles: DH's capture-keyboard and
    /// resize toggles hover 35×28 and 33.5×28 pt.
    static let toolbarTogglePlatterSize = CGSize(width: 34, height: 28)
    /// TB-03 zoom and TB-04 inspector segments: DH's segmented platter,
    /// hovered or selected alike, reads 31×28 pt (a capsule, not the 32 pt
    /// circle the 2026-09-18 audit recorded).
    static let toolbarSegmentPlatterSize = CGSize(width: 31, height: 28)
    /// TB-02 sidebar toggle: DH darkens the whole 36 pt circle.
    static let toolbarSidebarTogglePlatterDiameter: CGFloat = toolbarSidebarToggleDiameter

    /// PL-01 pill buttons: DH's apps / screenshot / record hover 32×28 pt.
    static let pillPlatterSize = CGSize(width: 32, height: 28)
    /// PL-02 rotate circle: DH darkens the whole 36 pt circle.
    static let pillCirclePlatterDiameter: CGFloat = pillCircleDiameter

    /// A disabled toolbar glyph: DH greys its zoom glyphs to #adadad over
    /// the near-white glass (≈31 % of the glyph's ink; measured #adadad at
    /// this value, #9d9d9d at 0.36).
    static let chromeDisabledGlyphOpacity: Double = 0.31

    /// CT-07 popup value on hover (and while its popover is open): DH draws
    /// a 24 pt rounded rectangle from 13 pt before the value text to 3.5 pt
    /// past the 20 pt chevron circle, in the circle's own fill (the circle
    /// merges into it). "Light" in Appearance: 78.5×24 pt, radius ≈6 pt.
    static let controlsPopupPlatterHeight: CGFloat = 24
    static let controlsPopupPlatterLeadingOutset: CGFloat = 13
    static let controlsPopupPlatterRadius: CGFloat = 6
    /// The least room between a popup row's title and its value: the
    /// platter's lead-in plus a 3 pt gap (it was 8 pt, and a long value's
    /// platter painted over the title's end).
    static let controlsPopupTitleGap: CGFloat = controlsPopupPlatterLeadingOutset + 3

    /// ST-02 stage Start button: DH's measures 80×30 pt (AX); with
    /// `.glassProminent` at `.large` these label minimums produce it.
    /// DH's Start button is 80 x 30 pt (the grey one an inactive window draws).
    static let stagePrimaryButtonWidth: CGFloat = 80
    static let stagePrimaryButtonHeight: CGFloat = 30
    static let stagePrimaryButtonLabelMinWidth: CGFloat = 52
    static let stagePrimaryButtonLabelMinHeight: CGFloat = 18

    /// Annotation colour swatches: 16 pt dots 5 pt apart take clicks up to
    /// the middle of the gap (21 pt targets).
    static let annotationSwatchHitOutset: CGFloat = 2.5
    /// Location sheet: a saved location's ✕ takes clicks over 22 pt.
    static let locationDeleteHitOutset: CGFloat = 4

    /// SB-01: the search field's clear button takes clicks over 20×20 pt
    /// (its glyph alone was ≈14 pt).
    static let sidebarSearchClearHitSize: CGFloat = 20
}
