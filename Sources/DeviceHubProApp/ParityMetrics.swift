import AppKit
import SwiftUI

/// Device Hub parity metrics. Every value is the audited measurement from
/// the parity audit — never hardcode parity sizes in views again.
/// The toolbar's glyph ink.
enum ToolbarInk {
    /// DH's label-coloured glyphs (+, filter, keyboard, collapse, the dots):
    /// 85% black over the near-white glass, #262626 (measured 37-38 in DH's
    /// key window). `NSColor.labelColor` itself renders lighter here (72, as
    /// the glass applies its vibrancy to the semantic colour), so the same
    /// 85% is spelled out per appearance.
    static let label = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]).map {
            $0 == .darkAqua || $0 == .vibrantDark
        } == true
            ? NSColor.white.withAlphaComponent(0.85)
            : NSColor.black.withAlphaComponent(0.85)
    })
}

extension ToolbarInk {
    /// The solid ink DH draws the zoom, sidebar and inspector glyphs in
    /// (measured 0 in its key window): black, white in dark mode. Spelled
    /// out for the shapes drawn by hand next to a symbol (the Zoom to Fit
    /// compass), which a semantic colour renders lighter than the symbol.
    static let solid = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]).map {
            $0 == .darkAqua || $0 == .vibrantDark
        } == true ? NSColor.white : NSColor.black
    })
}

enum ParityMetrics {
    // SB-01 — sidebar search field
    static let sidebarSearchHeight: CGFloat = 28
    /// DH's search field and row selection share one inset (they are flush).
    static let sidebarSearchOuterInset: CGFloat = 10
    static let sidebarHeaderFontSize: CGFloat = 11
    /// DH 27.0 (2026-09-29): "Available" is regular weight and its ink
    /// starts at x=16 (semibold at x=14 before).
    static let sidebarHeaderLeadingInset: CGFloat = 2
    // SB-01/SB-02 rhythm — DH: 41 pt from the search capsule's bottom to the
    // first row's top, i.e. 20.5 pt above the "Available" header text and
    // 12 pt below it. The header area itself adds ≈2.5 pt above and ≈3.5 pt
    // below the text, so the knobs below are the remainders.
    // Since 2026-09-25 the header text sits between two 8.5 pt paddings
    // (the collapsible sections' hover chevron centres on it), so the search
    // spacing gives the added top padding back: 18 − 8.5.
    // 2026-09-29 (2x): DH's list starts at y=128 with a 32 pt header row
    // (text at 136.5) and its first device row at 160; ours started at 127.5
    // with a 31 pt header (first row 158.5). The spacing takes the 0.5 pt, the
    // header's bottom padding the extra 1 pt.
    // The search capsule spans y 91–119 in DH (ours started at 90): 1 pt more
    // above, 1 pt less below, the list still starting at 128. Its placeholder
    // starts at x=38 (ours 40).
    static let sidebarSearchTopSpacing: CGFloat = 9
    static let sidebarSearchIconSpacing: CGFloat = 4
    static let sidebarSearchBottomSpacing: CGFloat = 9
    static let sidebarHeaderBottomSpacing: CGFloat = 8.5
    static let sidebarHeaderExtraBottom: CGFloat = 1
    // SB-02 — sidebar row
    static let sidebarRowHeight: CGFloat = 46
    /// The hairline rim of a booted row's white tile (black at this opacity).
    /// A UDID takes at most this much of its Info row (DH 27.0, 2x: 327 of 430 px).
    static let udidMaxWidthFraction: CGFloat = 0.76
    static let sidebarBootedTileRingOpacity: Double = 0.036
    static let sidebarIconDiameter: CGFloat = 32
    static let sidebarIconGlyphSize: CGFloat = 17
    /// Tile to title (DH 27.0, 2026-09-29: the title's text starts at x=56,
    /// 8 pt after the 32 pt tile; it was 10 pt here, x=58).
    static let sidebarRowContentSpacing: CGFloat = 8
    static let sidebarTitleFontSize: CGFloat = 13
    static let sidebarSubtitleFontSize: CGFloat = 11
    static let sidebarVersionFontSize: CGFloat = 11
    // SB-02 device icon tile (state-aware silhouette, 2026-09-28). DH's
    // sidebar row icon is a two-layer SF Symbol (`.palette` rendering: a
    // frame layer + a "screen" layer) over a state-coloured circle, measured
    // on DH 27.0's sidebar (light appearance, key window, pixel-sampled at
    // 2x): a booted row draws a white circle (#FFFFFF), a near-black frame
    // (#000000 at the glyph's rim) and a blue "lit screen" gradient inside it
    // (#3B93EF top → #47AFDC bottom); a stopped row draws a light gray
    // circle (#E7E7E8), a medium-gray frame (#ABABAC) and a flat lighter-gray
    // screen (#D5D5D6, no gradient). Dark mode was not measured (DH was only
    // captured in light appearance); the Dark constants are a conservative
    // adaptive guess kept the same distance apart, flagged as a residual in
    // the parity audit until DH's dark sidebar can be captured.
    static let sidebarIconTileBooted = Color(red: 1, green: 1, blue: 1)
    static let sidebarIconTileBootedDark = Color(white: 0.93)
    static let sidebarIconTileStoppedDark = Color(white: 0.30)
    static let sidebarIconFrameBooted = Color(red: 0, green: 0, blue: 0)
    static let sidebarIconFrameBootedDark = Color(white: 1.0)
    static let sidebarIconFrameStoppedDark = Color(white: 0.62)
    static let sidebarIconScreenStoppedDark = Color(white: 0.40)
    static let sidebarIconTileStoppedOpacity: Double = 0.046
    // The screen and frame draw over the tile, so their own opacities are
    // what is left of the measured totals (12.2 % and 29.3 % against the
    // background) after the tile's 4.6 %: 1 - 0.878 / 0.954 and
    // 1 - 0.707 / 0.954.
    static let sidebarIconScreenStoppedOpacity: Double = 0.079
    static let sidebarIconFrameStoppedOpacity: Double = 0.259
    static let sidebarIconScreenGradientTopBooted = Color(red: 0.231, green: 0.576, blue: 0.937)
    static let sidebarIconScreenGradientBottomBooted = Color(red: 0.278, green: 0.686, blue: 0.863)

    // SB-03 — selection
    static let sidebarSelectionRadius: CGFloat = 8
    static let sidebarSelectionInset: CGFloat = 10
    /// DH's audited fill #d7d7d7 in light mode; dark mode gets a
    /// lighter-than-background gray so the white icon circles stay readable.
    static let sidebarSelectionWhite: CGFloat = 0.843
    static let sidebarSelectionWhiteDark: CGFloat = 0.32
    /// The selection in a window that is not key (DH 27.0, 2026-09-29).
    static let sidebarSelectionInactive = Color(red: 231 / 255, green: 231 / 255, blue: 232 / 255)

    // The selection while the list is focused (2026-09-29, DH 27.0): the fill
    // is the app's accent colour (`controlAccentColor`, #0070f5 under the
    // modern design; `selectedContentBackgroundColor` reads darker, #0064e1), the
    // title white, the subtitle and version translucent white, the icon tile
    // white at 20 % (#338df7 over the fill) and its glyph white at ~36 %
    // (#5ca4f9).
    static let sidebarSelectedTileOpacity: Double = 0.20
    /// A booted row on the accent pill keeps its coloured glyph on a light
    /// tile (DH 27.0, 2026-09-29: the tile reads #c3d5fd over #0270f5, the
    /// glyph's frame and screen gradient are the unselected ones); only a
    /// stopped row's tile and glyph turn translucent white.
    static let sidebarSelectedBootedTileOpacity: Double = 0.71
    /// DH's emphasised pill is `#0070f5`; the system's default accent draws
    /// `#007aff` and `selectedContentBackgroundColor` `#0064e1` here. With a
    /// non-default accent, or in dark appearance (not measured), the pill
    /// takes the system's accent.
    static func sidebarSelectionAccent(isDark: Bool) -> Color {
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)
        let isDefaultBlue = accent.map { $0.redComponent < 0.05 && (0.40...0.50).contains($0.greenComponent) && $0.blueComponent > 0.9 } ?? false
        if isDefaultBlue, !isDark { return Color(red: 0, green: 112 / 255, blue: 245 / 255) }
        return Color(nsColor: .controlAccentColor)
    }
    static let sidebarSelectedGlyphOpacity: Double = 0.40
    static let sidebarSelectedScreenOpacity: Double = 0.23
    static let sidebarSelectedSecondaryTextOpacity: Double = 0.72
    /// A press that travels farther than this is a drag, not a click (the
    /// table view's own drag threshold).
    static let sidebarRowDragThreshold: CGFloat = 4
    /// The search field's focus ring (2026-09-29): the accent at half
    /// strength, 4 pt wide, centred on the capsule's edge.
    static let sidebarSearchFocusRingOpacity: Double = 0.5
    static let sidebarSearchFocusRingWidth: CGFloat = 4
    /// The inline name editor (2026-09-29): 2 pt left of the title's text,
    /// 16 pt tall (the title line), ending at x = 237 of the 300 pt sidebar
    /// (23 pt before a four-digit version's left edge): the version column
    /// is fixed at 36 pt while renaming.
    static let sidebarRenameFieldLeadingInset: CGFloat = 2
    static let sidebarRenameFieldHeight: CGFloat = 16
    static let sidebarRenameVersionColumnWidth: CGFloat = 36

    // TB-01/TB-02 — toolbar leading cluster. The capsule's audited 73×36 pt
    // size is composed from the knobs below (28 pt menu label + 5 pt gap +
    // 6 pt padding).
    static let toolbarButtonHeight: CGFloat = 36
    /// Every toolbar glyph is `.regular` at this size (TB-06 stroke pass,
    /// 2026-09-28): against DH's 2x captures the ink boxes match (32×32 px
    /// for the zoom four, 33×28 for Settings, 16×32 for Info), the ink areas
    /// match within 3% (a `.medium` 16.5 glyph was 12% heavy) and the ring
    /// stroke measures 3.08 px in DH against 2.92 regular and 3.47 medium.
    static let toolbarIconSize: CGFloat = 16.85
    static let toolbarIconWeight: Font.Weight = .regular
    /// The leading +/≡ menu glyphs (drawn as overlays — the borderless menu
    /// flattens its label and ignores font sizes): DH's `plus` ink measures
    /// 13.5×13.5 pt and its filter glyph 16.5×10 pt (2026-09-18).
    static let toolbarPlusGlyphSize: CGFloat = 16.85
    /// DH's `+` is lighter than its other glyphs: 2.45 px strokes against
    /// 2.94 regular and 2.23 light at this size.
    static let toolbarPlusGlyphWeight: Font.Weight = .light
    /// Horizontal nudges landing the overlaid glyphs' ink where DH's is
    /// (2x boxes: `+` 373-399 px, filter 440-472 px; the overlays sat +1.5
    /// and -1 px off).
    static let toolbarPlusGlyphNudge: CGFloat = -1.25
    static let toolbarFilterGlyphNudge: CGFloat = 0.5
    static let toolbarFilterGlyphSize: CGFloat = 16.5
    /// DH's gap between toolbar capsules (TB-01/TB-03).
    static let toolbarClusterSpacing: CGFloat = 7
    /// The leading cluster's capsule-to-toggle gap: DH's measures 7.5 pt
    /// (248 → 255.5 pt, 2026-09-28); 7 pt rendered 6.5 beside the glass.
    static let toolbarLeadingClusterSpacing: CGFloat = 8
    static let toolbarLeadingButtonWidth: CGFloat = 28
    static let toolbarLeadingButtonSpacing: CGFloat = 5
    /// 6.5 pt: DH's capsule measures 74.5 pt at 173.5–248 pt (re-measured
    /// on DH 27.0, 2026-09-28; the 6 pt padding drew it 1 pt narrower).
    static let toolbarLeadingCapsulePadding: CGFloat = 6.5
    static let toolbarSidebarToggleDiameter: CGFloat = 36
    /// Inset from the sidebar view's trailing edge to the leading cluster's
    /// right edge (the toggle). DH's toggle ink ends at 292.5 pt beside its
    /// 300 pt sidebar (re-measured 2026-09-28; the 2026-09-18 audit's 289
    /// read the AppKit sidebar wrapper at 296 pt); 7 pt left ours at 293.5.
    static let toolbarLeadingAccessoryTrailingInset: CGFloat = 8
    /// The leading cluster's width (the 73 pt +/filter capsule, the 7 pt
    /// gap, the 36 pt sidebar toggle).
    static let toolbarLeadingClusterWidth: CGFloat =
        2 * toolbarLeadingButtonWidth + toolbarLeadingButtonSpacing + 2 * toolbarLeadingCapsulePadding
        + toolbarLeadingClusterSpacing + toolbarSidebarToggleDiameter
    /// With the sidebar collapsed only the sidebar toggle remains (DH drops
    /// the + and filter capsule): its width is the toggle's glass circle.
    static let toolbarLeadingCollapsedClusterWidth: CGFloat = toolbarSidebarToggleDiameter
    /// With the sidebar collapsed the toggle sits this far after the traffic
    /// lights. DH 27.0's toggle (AX frame 92–136 pt, glass centred at 114 pt)
    /// follows a zoom button ending at 80 pt (chrome audit, 2026-09-29); at a
    /// 17 pt gap ours reads centre 114 pt.
    static let toolbarLeadingCollapsedGap: CGFloat = 17
    /// The stage title then starts where the accessory ends: its ink lands at
    /// x = 152 pt, DH's (pixels of DH's capture, 19 pt after the toggle).
    /// The traffic lights' trailing edge when AppKit reports no window
    /// buttons (a titled window's zoom button ends at x≈72).
    static let toolbarWindowButtonsFallbackMaxX: CGFloat = 72
    // TB-03/TB-04 — toolbar trailing clusters
    static let toolbarButtonWidth: CGFloat = 36
    static let toolbarKeyboardButtonSpacing: CGFloat = 4
    static let toolbarKeyboardCapsulePadding: CGFloat = 3.5
    static let toolbarZoomCapsulePadding: CGFloat = 3
    static let toolbarRotateCapsulePadding: CGFloat = 1
    static let toolbarInspectorCapsulePadding: CGFloat = 1.5
    /// DH's selected-segment fill while the window is inactive (**#d1**),
    /// state-aware like the capsule surface. While the window is key it is
    /// `secondarySystemFill` (`ToolbarActivePlatter`): #e8 over the zoom
    /// capsule's #fcfcfc (the 2026-09-18 audit's "#e5–#e8") and #df over
    /// the inspector capsule's #f2f2f1 (re-measured 2026-09-25; the old
    /// 7 % `.primary` rendered #f0f0ef there, 2 levels below the capsule —
    /// all but invisible). Its shape is `toolbarSegmentPlatterSize` (a
    /// 31×28 pt capsule; it was drawn as a 32 pt circle).
    static let toolbarActiveCircleFillOpacityInactive: Double = 0.15
    static let toolbarSeparatorWidth: CGFloat = 1
    static let toolbarSeparatorHeight: CGFloat = 20
    /// DH's separators stay light in the key window (≈#e0 over the near-white
    /// fill) and ≈#c2 when inactive.
    static let toolbarSeparatorOpacity: Double = 0.12
    /// DH's overflow glyph: three 3 pt dots at a 3 pt gap (15 pt total).
    static let toolbarMoreDotDiameter: CGFloat = 3
    static let toolbarMoreDotSpacing: CGFloat = 3
    /// The "Zoom to Fit" glyph: ``FourTriangleCompassShape``, sized and
    /// nudged onto the magnifier lens's centre (TB-06), tuned against a 2x
    /// crop of DH's own icon.
    static let toolbarFitLensGlyphSize: CGFloat = 7.9
    static let toolbarFitLensGlyphOffset = CGSize(width: -1.4, height: -1.6)
    /// SwiftUI spaces adjacent toolbar items by ≈8 pt (measured); pulling the
    /// rendered glass in by the remainder lands DH's 7 pt gaps (TB-01/TB-03).
    static let toolbarClusterInset: CGFloat = (8 - toolbarClusterSpacing) / 2
    /// TB-04 wants ≈8–10 pt from the far capsule to the window edge; the
    /// system's own trailing inset leaves ≈11.5 pt, so the capsule is pulled
    /// out by the remainder (measured result ≈7 pt).
    static let toolbarTrailingInset: CGFloat = 4.5

    // PL-01/PL-02 — floating stage pill: DH's capsule [apps │ screenshot │
    // record] plus a separate rotate circle (no `…`). DH's capsule measures
    // 108.5×36 pt and its three icon centres sit at 41 / 109 / 176.5 px from
    // the capsule's left edge at 2x — i.e. 34 pt button pitch with 3.25 pt
    // padding per side. Icons ink ≈14.5–15 pt.
    static let pillHeight: CGFloat = 36
    /// DH's pill glass is plain, near-white glass (#fbfbfb over the white
    /// stage, DH 27.0 2026-09-29), taking a little of the picture's colour
    /// over a zoomed device: no gray tint (the round-2 gray was inverted).
    static let pillTint: Color? = nil
    /// White laid over the glass (any glass tint darkens it): the plain
    /// glass reads #f0f0f0 over the white stage, DH's #fafafa. Light
    /// appearance only: over the dark stage the same white turned the pill
    /// light gray under white symbols (about 2:1), so dark keeps the plain
    /// dark glass with a faint lift.
    static let pillLift = Color(nsColor: NSColor(name: "DeviceHubProPillLift") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.06)
            : NSColor.white.withAlphaComponent(0.65)
    })
    static let pillButtonWidth: CGFloat = 34
    /// DH's pill buttons take the pointer on 32 x 28 pt (AX, DH 27.0).
    static let pillButtonHitSize = CGSize(width: 32, height: 28)
    /// 108.5 pt audited capsule = 3 × 34 pt buttons + 3.25 pt per side.
    static let pillCapsulePadding: CGFloat = (108.5 - pillButtonWidth * 3) / 2
    /// DH's gap between the capsule and the rotate circle (PL-02). The
    /// reference reads 7 pt between the rendered glass edges; interactive
    /// glass bleeds ≈0.5 pt per side, so the layout spacing is 8 pt.
    static let pillSpacing: CGFloat = 8
    static let pillCircleDiameter: CGFloat = 36
    /// The audit's "≈16–17 pt" was an eyeball estimate; the reference icons
    /// ink 29–30 px at 2x, which 15 pt symbols reproduce (camera/record
    /// exact; the apps glyph is SF's nearest to DH's Material `grid_view`).
    static let pillIconSize: CGFloat = 15
    /// DH's Home glyph (its own `app.grid.3x3`): a 3 x 3 grid of small
    /// squares, 12.75 pt across (3.25 pt squares, 1.5 pt apart), where ours
    /// used SF's 15 pt `square.grid.3x3.fill`.
    static let pillGridDot: CGFloat = 3.25
    static let pillGridGap: CGFloat = 1.5
    static let pillGridCorner: CGFloat = 0.6
    /// DH floats the pill **8 pt above the window's bottom edge**, centered
    /// in the canvas — not attached to the device (PL-02).
    static let pillBottomInset: CGFloat = 8
    /// What the compact window keeps under the phone for the pill: DH's phone
    /// ends 9 pt above the pill's top (36 pt pill + 8 pt inset + 1 pt).
    static let compactStagePillBand: CGFloat = 45
    /// DH's compact stage begins 6.5 pt above the toolbar band's bottom edge
    /// (its phone is 480 pt tall and starts 1.5 pt under the band).
    static let compactStageTopOverlap: CGFloat = 6.5
    /// The band the main stage keeps under the device for the pill (the
    /// compact window keeps `compactStagePillBand`): DH centres the running
    /// device 9.5 pt lower than that band gave (audit 2026-09-29: DH's art
    /// y 285-709 in a 983 pt window, ours 275-700), which is a stage that
    /// ends 41 pt above the window's bottom edge, 3 pt below the pill's top.
    /// The stage's own 10 pt padding keeps the device off the pill.
    static let mainStagePillBand: CGFloat = 41

    // STAGE-BANNER — DH's "Screenshot Saved" and "Zoom Controls" cards
    // (measured live on DH 27.0, 1x: 285 x 50 and 270 x 50 pt, the card's
    // bottom 7 pt above the pill's top, so 8 + 36 + 7 above the window's).
    static let stageBannerHeight: CGFloat = 50
    static let stageBannerCorner: CGFloat = 16
    static let stageBannerPadding: CGFloat = 12
    static let stageBannerSpacing: CGFloat = 10
    static let stageBannerThumbnail: CGFloat = 26
    static let stageBannerDisc: CGFloat = 17
    static let screenshotBannerWidth: CGFloat = 285
    static let stageBannerBottomInset: CGFloat = pillBottomInset + pillHeight + 7

    // ST-01 — stage title: the window's own title and subtitle (13 pt
    // semibold / 11 pt, drawn by the system like DH's), so it has no metrics
    // of its own; it starts where the leading titlebar accessory ends.

    // IN-01 — inspector segmented control. Until 2026-09-28 this was drawn
    // by hand instead of the system picker: the macOS 26.0-era system
    // control rendered a floating white glass capsule whose fill, labels and
    // width matched neither Device Hub's then-flat track nor its gray
    // labels. Re-measured on Device Hub 27.0, DH's own control is now that
    // same floating glass capsule (`dh-IN-01-live-2026-09-28.png`), so the
    // system `Picker(.segmented)` replaces the hand-drawn one; only its
    // layout padding remains audited here (the control's own fill, pill and
    // label colours are AppKit's).
    static let inspectorSegmentedSideInset: CGFloat = 9
    /// DH's header rhythm: the track sits 8 pt below our panel's content top
    /// (3 pt more than DH's 5 pt, compensating our 3 pt shallower toolbar
    /// band) and the first card follows 10 pt under it.
    static let inspectorSegmentedTopSpacing: CGFloat = 8
    static let inspectorSegmentedBottomSpacing: CGFloat = 10
    /// Edit Visibility (DH 27.0, 2026-09-29): the capsule sits 30 pt under
    /// the last card (20 here plus the stack's 10), the checklist's tick box
    /// 10 pt in from its card's edge.
    static let infoEditVisibilityTopGap: CGFloat = 20
    static let infoEditCheckboxInset: CGFloat = 10

    // IN-02 — inspector cards. DH: fill #e6e6e6 — a 4 % primary overlay
    // reads #e6e6e6 over our ≈#eeeeee inspector background in light mode and
    // stays subtle in dark mode. The reference's top corners fit r≈24 px =
    // 12 pt (the audit's "≈8 pt" was an eyeball estimate); rows 36 pt, card
    // gap 10 pt, cards inset 10 pt like the segmented control.
    static let inspectorCardFillOpacity: CGFloat = 0.04
    static let inspectorCardRadius: CGFloat = 12
    static let inspectorCardInset: CGFloat = 10
    static let inspectorRowHeight: CGFloat = 36
    /// Info-card rows: 13 pt label and value, 12 pt text inset.
    static let inspectorRowFontSize: CGFloat = 13
    static let inspectorRowTextInset: CGFloat = 10
    static let inspectorCardSpacing: CGFloat = 10
    /// 1 pt divider ≈#dcdcdc over the card fill. DH insets the info-card
    /// dividers **10 pt per side** (x=70–549 with the card at x=50–569);
    /// the Apps rows use the 52 pt text column / 10 pt trailing pair, and
    /// the Apps footer's divider is full-bleed.
    static let inspectorDividerOpacity: CGFloat = 0.05
    static let inspectorDividerHeight: CGFloat = 1
    static let inspectorDividerInset: CGFloat = 10

    // IN-03 — apps list. DH: 48 pt row pitch (47 pt row + 1 pt divider),
    // 26 pt icon tile 14 pt in from the card's edge, text column at 52 pt
    // (where the row dividers start); the list scrolls under a 22 pt +/-
    // footer whose 1 pt divider spans the card; the filter capsule is 30 pt
    // tall inside the same 10 pt insets, 10 pt below a panel-wide divider.
    /// A physical device's Reports panel (Device Hub 27.0, measured on the
    /// test iPhone 2026-09-29): the empty card is 128 pt tall; a report row is
    /// 48 pt with a 32 pt document icon 10 pt in and the text column 50 pt in.
    /// Its bottom bar (Filter field and kind pop-up): 13 pt text, the capsule 10.5 pt
    /// above the window's foot.
    static let inspectorReportsFilterFontSize: CGFloat = 13
    static let inspectorReportsFilterBottomSpacing: CGFloat = 10.5
    static let physicalReportsEmptyCardHeight: CGFloat = 128
    /// Row height without its 1 pt divider (DH's rows are 48 pt apart).
    static let physicalReportsRowHeight: CGFloat = 47
    /// Name and detail text, fitted to Device Hub's measured text widths
    /// ("Today at 18:22:32 • 215 KB" is 129.5 pt there).
    static let physicalReportsNameFontSize: CGFloat = 12.3
    static let physicalReportsDetailFontSize: CGFloat = 10.1
    static let physicalReportsIconSize: CGFloat = 32
    static let physicalReportsIconInset: CGFloat = 10
    static let physicalReportsIconSpacing: CGFloat = 8
    static let physicalReportsTextInset: CGFloat = 50
    static let inspectorAppsRowHeight: CGFloat = 47
    static let inspectorAppsTileSize: CGFloat = 26
    static let inspectorAppsTileRadius: CGFloat = 7
    static let inspectorAppsTileInset: CGFloat = 14
    static let inspectorAppsTextInset: CGFloat = 52
    /// Tile-to-text gap (the text column minus the tile's edge, 52−14−26).
    static let inspectorAppsTileTextSpacing: CGFloat = 12
    /// The row dividers stop 10 pt short of the card's right edge.
    static let inspectorAppsDividerTrailingInset: CGFloat = 10
    static let inspectorAppsFooterHeight: CGFloat = 22
    static let inspectorAppsFooterButtonWidth: CGFloat = 24
    /// DH's 1 pt separators inside the +/− footer and the filter capsule are
    /// both 16 pt tall.
    static let inspectorAppsSeparatorHeight: CGFloat = 16
    static let inspectorAppsFilterHeight: CGFloat = 30
    /// DH's "Filter" placeholder and scope label ink measure ≈11.5–12 pt.
    static let inspectorAppsFilterFontSize: CGFloat = 12
    /// The +/− glyphs ink ≈8 pt wide at 2x (a ≈12 pt symbol).
    static let inspectorAppsFooterIconSize: CGFloat = 12
    /// DH's app-row typography: the name ink measures ≈130 pt for a 21-char
    /// title (CoreText: 12.3–12.5 pt semibold — rendered at the 13 pt card
    /// scale), the package ≈156 pt (10.5 pt — rendered 11), the version's
    /// digit height 17 px (≈12 pt).
    static let inspectorAppsNameFontSize: CGFloat = 13
    static let inspectorAppsPackageFontSize: CGFloat = 11
    static let inspectorAppsVersionFontSize: CGFloat = 12
    /// The capsule reads ≈#e0e0e0 over our ≈#eeeeee panel (a 6 % primary
    /// overlay); its inner divider ≈#cdcdcd (8 %).
    static let inspectorAppsFilterFillOpacity: CGFloat = 0.06
    static let inspectorAppsScopeDividerOpacity: CGFloat = 0.08
    /// Selected-row tint over the card fill (list interaction, not audited).
    static let inspectorAppsSelectionOpacity: CGFloat = 0.05
    /// DH's "All Apps" scope cell: the capsule's 1 pt divider sits 87 pt
    /// from its right edge, with the label 14 pt after the divider and
    /// ≈8 pt of trailing room before the capsule's edge.
    static let inspectorAppsScopeWidth: CGFloat = 87
    static let inspectorAppsScopeLeading: CGFloat = 14
    static let inspectorAppsScopeTrailing: CGFloat = 8
    /// The label + chevron budget inside the audited cell (87 − 14 − 8).
    /// "System Apps" measures 74.2 pt at 12 pt and only 53 pt of text room
    /// is left after the 9 pt chevron and its 3 pt gap, so the label renders
    /// at ≈0.71 (0.6 floor) — full string, no cell widening, no truncation.
    static let inspectorAppsScopeLabelWidth: CGFloat = 65
    static let inspectorAppsFilterTopSpacing: CGFloat = 10
    static let inspectorAppsFilterBottomSpacing: CGFloat = 8.5

    // IN-03 addendum — the Apps footer's busy state (`+` opens the file
    // panel directly, as Device Hub's does).
    static let inspectorAppsInstallSpinnerLeading: CGFloat = 8
    static let inspectorAppsInstallLabelFontSize: CGFloat = 11
    static let inspectorAppsInstallLabelLeading: CGFloat = 4

    // CT — Controls inspector, rebuilt as Device Hub's device-settings panel
    // (measured from a 2x capture of Device Hub 27.0's panel). DH draws a flat
    // card list: 42 pt rows + 1 pt inset hairlines, 10 pt card insets, a 16 pt
    // leading glyph frame 12 pt into the card, a 13 pt label at 39.5 pt, and
    // the control ending 10 pt before the card edge (the value popup ends
    // 13.5 pt before it). Fills are opacities over our audited panel (#ededed)
    // and card (#e6e6e6) so the key/inactive calibration of the reference
    // still holds.
    static let controlsPanelTopSpacing: CGFloat = 8
    static let controlsRowHeight: CGFloat = 42
    static let controlsPopupRowLift: CGFloat = 1.5
    static let controlsGlyphFrame: CGFloat = 16
    static let controlsGlyphLeading: CGFloat = 12
    static let controlsGlyphFontSize: CGFloat = 13
    static let controlsLabelFontSize: CGFloat = 13
    /// The label's ink starts at card+39.5 in the reference; SF's text box
    /// carries a ≈2 pt side bearing, so the box itself starts at 37.5.
    static let controlsLabelLeading: CGFloat = 37.5
    /// The label's gap after the glyph: the label box starts at 37.5 pt and
    /// the glyph frame ends at 12 + 16 pt, so this is the remainder.
    static let controlsLabelGap: CGFloat = max(
        controlsLabelLeading - controlsGlyphLeading - controlsGlyphFrame,
        0
    )
    static let controlsTrailingInset: CGFloat = 10
    static let controlsValueTrailingGap: CGFloat = 14
    static let controlsPopupDiameter: CGFloat = 20
    static let controlsPopupTrailingInset: CGFloat = 13.5
    static let controlsPopupChevronFontSize: CGFloat = 9
    /// The collapsible group heading's hover chevron (the sidebar sections'
    /// native disclosure, drawn by hand for the panel's headings).
    static let controlsDisclosureChevronFontSize: CGFloat = 11
    static let controlsPopupFillOpacity: Double = 0.085
    /// DH's control gray (switch track + slider rail) over the card.
    static let controlsControlFillOpacity: Double = 0.115
    static let controlsSwitchWidth: CGFloat = 36
    static let controlsSwitchHeight: CGFloat = 16
    static let controlsSwitchKnobWidth: CGFloat = 20
    static let controlsSwitchKnobHeight: CGFloat = 14
    static let controlsSliderWidth: CGFloat = 120
    /// DH's Sound slider carries nine evenly spaced decoration dots (its knob
    /// moves freely between them), measured 12.5 pt apart across the travel.
    static let controlsSoundTickCount = 9
    static let controlsSliderKnobHeight: CGFloat = 16
    /// "100%" at the 11 pt caption size needs ~27 pt; a fixed box keeps the
    /// battery slider right-aligned exactly like DH's control column. (At
    /// 13 pt in a 36 pt box the 280 pt inspector left "Battery" 43 pt and
    /// the label broke over two lines.)
    static let controlsBatteryValueWidth: CGFloat = 28
    static let controlsBatteryValueSpacing: CGFloat = 6
    static let controlsFieldHeight: CGFloat = 20
    static let controlsFieldRadius: CGFloat = 5
    static let controlsFieldFillOpacity: Double = 0.07
    static let controlsFieldTextInset: CGFloat = 6
    static let controlsCaptionFontSize: CGFloat = 11
    /// The hand-drawn switch, slider and popup value dim to this while
    /// disabled (AppKit's disabled controls read at about half strength);
    /// `.disabled` does not dim custom shapes by itself. Not audited: DH's
    /// reference shows no disabled row.
    static let controlsDisabledOpacity: Double = 0.45
    /// The value popup's own rows (`DHPopupRow`'s popover). DH's popup is a
    /// system menu; these are our values for the SwiftUI popover that
    /// replaces it (a menu label could not be sized reliably).
    static let controlsPopoverInset: CGFloat = 6
    static let controlsPopoverMinWidth: CGFloat = 190
    static let controlsPopoverRowSpacing: CGFloat = 2
    static let controlsPopoverDividerInset: CGFloat = 3
    static let controlsPopoverRowHeight: CGFloat = 24
    static let controlsPopoverRowInset: CGFloat = 8
    static let controlsPopoverRowRadius: CGFloat = 5
    static let controlsPopoverRowHoverOpacity: Double = 0.08
    static let controlsPopoverCheckmarkFontSize: CGFloat = 11
    static let controlsPopoverCheckmarkWidth: CGFloat = 14
    static let controlsPopoverCheckmarkSpacing: CGFloat = 6
    /// The Foldable group's posture buttons (our own control: DH's panel has
    /// no posture row).
    static let controlsPostureButtonWidth: CGFloat = 26
    static let controlsPostureButtonHeight: CGFloat = 20
    static let controlsPostureGlyphFontSize: CGFloat = 11
    /// DH's in-panel push button ("Edit Visibility" in its Info inspector,
    /// measured 2026-09-28 at 2x): a flat 84×21 pt capsule, fill #e2e2e1 over
    /// the #ededec panel (a 4.6 % primary overlay), 10 pt semibold ink #636362
    /// (56 % primary over the fill), text 64 pt wide centred with ≈10 pt each
    /// side. DH draws no blue or bordered buttons in its panels.
    static let controlsButtonHeight: CGFloat = 21
    static let controlsButtonHorizontalPadding: CGFloat = 9
    static let controlsButtonFontSize: CGFloat = 10
    static let controlsButtonFillOpacity: Double = 0.046
    static let controlsButtonPressedFillOpacity: Double = 0.092
    static let controlsButtonInkOpacity: Double = 0.56
    /// DH's inspector section heading ("Paired Simulators", same capture):
    /// 11 pt semibold secondary ink, 10 pt in from the card edge, cap top
    /// 12.5 pt below the card above and the baseline 8.5 pt above the card it
    /// heads (30 pt between the two cards instead of the usual 10).
    static let controlsGroupHeadingFontSize: CGFloat = 11
    /// The heading's line, fixed so the card below lands on whole points
    /// (11 pt SF's natural line is 13.1 pt).
    static let controlsGroupHeadingHeight: CGFloat = 13
    static let controlsGroupHeadingLeading: CGFloat = 10
    static let controlsGroupHeadingCardGap: CGFloat = 7
    /// The Controls panel's empty state for a device that is off (CT-10,
    /// measured on Device Hub 27.0's settings panel for a stopped simulator,
    /// 2x, 2026-09-28): a centered glyph and caption filling the whole panel
    /// below the toolbar band — no card, no scroll. Glyph 28 pt secondary,
    /// 25 pt gap to a 13 pt secondary caption ("Start the simulator to
    /// customize behavior and appearance."), wrapping at ~220 pt, both
    /// horizontally and vertically centered.
    static let controlsEmptyStateGlyphFontSize: CGFloat = 36
    static let noSelectionFontSize: CGFloat = 17
    static let appsEmptyStateGlyphWidth: CGFloat = 39
    static let appsEmptyStateOffset: CGFloat = -5
    static let controlsEmptyStateGap: CGFloat = 17.5
    /// DH's placeholder group sits 4 pt below the panel's centre (Settings and
    /// Reports, measured on 27.0).
    static let controlsEmptyStateOffset: CGFloat = 4
    static let controlsEmptyStateCaptionFontSize: CGFloat = 13
    static let controlsEmptyStateCaptionWidth: CGFloat = 220

    // STATUS — the transient status banner over the stage. Device Hub has
    // no counterpart; our own values, kept here rather than in the view.
    static let statusBannerTopInset: CGFloat = 10
    static let statusBannerSpacing: CGFloat = 8
    static let statusBannerHorizontalPadding: CGFloat = 14
    static let statusBannerVerticalPadding: CGFloat = 8

    // VID — recording indicator. Device Hub's record button flips to a stop
    // glyph but shows no elapsed readout, so these are our own values (spec
    // §8.3) — a red dot + REC + elapsed time in a glass capsule on the stage.
    static let recordingIndicatorTopInset: CGFloat = 14
    static let recordingIndicatorDotDiameter: CGFloat = 8
    static let recordingIndicatorSpacing: CGFloat = 6
    static let recordingIndicatorHorizontalPadding: CGFloat = 12
    static let recordingIndicatorVerticalPadding: CGFloat = 6
    static let recordingIndicatorFontSize: CGFloat = 11

    // ANN — annotation editor. Device Hub has no annotation surface, so these
    // are our own design values (spec §8.1), kept here rather than hardcoded in
    // the view. The sheet is fixed-size: the fit scale stays stable while
    // annotations are placed, so display points always map back to the same
    // image pixels when `AnnotationRenderer` composites.
    static let annotationSheetWidth: CGFloat = 960
    static let annotationSheetHeight: CGFloat = 700
    static let annotationCanvasInset: CGFloat = 20
    static let annotationCapsulePadding: CGFloat = 6
    static let annotationToolButtonSize: CGFloat = 30
    static let annotationToolIconSize: CGFloat = 15
    static let annotationSwatchSize: CGFloat = 16
    static let annotationWidthSliderWidth: CGFloat = 100

    // LOG — logcat placeholder states (spec §9.3c). Our own values in the
    // inspector's language: secondary text plus a small SF symbol for the
    // no-device / no-output / disconnected states, and a thin paused banner
    // above the list while a stream is paused.
    static let logcatStateIconSize: CGFloat = 22
    static let logcatStateSpacing: CGFloat = 6
    static let logcatStatePadding: CGFloat = 24
    static let logcatPausedBannerHeight: CGFloat = 22
    static let logcatPausedBannerFontSize: CGFloat = 11
    static let logcatPausedBannerHorizontalInset: CGFloat = 10
    /// The banner's Retry button takes clicks over the banner's height and
    /// this much either side of the word (it took the 11 pt word alone).
    static let logcatRetryHorizontalPadding: CGFloat = 6

    // STOP — stopped-device stage (AvdDetailView, SimulatorDetailView,
    // PixelDeviceDetailView; items 4/8, 2026-09-28, re-measured live). DH
    // draws its stopped device small, vertically centred in the window, and
    // its screen as a plain gradient (the earlier 400 pt device and app-icon
    // grid looked out of proportion). Live-measured on our
    // own `AQA probe Stage` simulator, unbooted (DH's own accessibility
    // tree, exact points, no pixel↔point guessing): the device image is
    // exactly 183.5×200 pt, the name's line box 20.5 pt tall starting
    // 23.7 pt below the device (line-height 20.5 pt ⇒ a 17 pt font, not our
    // 26 pt `.title`), the subtitle's 16 pt tall starting 4.1 pt below the
    // name (13 pt `.callout`, already ours), and the Start capsule 20.2 pt
    // below the subtitle. Gaps are on top of the panel's existing 14 pt
    // `VStack` rhythm, so the extra top padding below is the remainder
    // (23.7 − 14 and 20.2 − 14). The whole group sits centred in the
    // stage's own height (not pinned near the top): DH's group-centre
    // matches its *window's* vertical centre almost exactly (off by
    // 0.25 pt of 969 pt), which is DH's content extending under its 52 pt
    // toolbar; our SwiftUI toolbar reserves its own space instead, so we
    // centre in the stage's own visible height, landing ≈26 pt lower than
    // DH's — the toolbar-underlap nuance is not reproduced.
    /// The window's toolbar band (52 pt): DH's stopped-stage group is
    /// centred on the window, so ours drops this much from the bottom.
    static let stoppedStageToolbarBand: CGFloat = 52
    static let stoppedHeroHeight: CGFloat = 200
    /// The system icon's box: 250 x 200 pt (an Apple TV, the wide one, measures
    /// 250.5 pt across on DH 27.0; phones and tablets are height-limited).
    static let stoppedHeroIconWidth: CGFloat = 250
    /// Boot spinner and its "Connecting display…" caption (DH 27.0, 1x): the
    /// spinner's box ends 11 pt above the caption's line, which is 12 pt text.
    static let bootSpinnerToCaptionGap: CGFloat = 11
    static let bootCaptionFontSize: CGFloat = 12
    /// The device inside DH's 200 pt hero image: 194 pt tall.
    static let stoppedHeroDeviceHeight: CGFloat = 194
    /// DH's contact shadow under the stopped device (measured, 1x): a thin
    /// ellipse, about 9 pt tall, 8 pt wider than the device on each side.
    static let contactShadowHeight: CGFloat = 8
    static let contactShadowOverhang: CGFloat = 8
    static let contactShadowBlur: CGFloat = 2
    static let contactShadowOpacity: Double = 0.42
    static let stoppedHeroToNameGap: CGFloat = 10
    static let stoppedSubtitleToButtonGap: CGFloat = 6
    /// DH's name ink (line-height 20.5 pt ⇒ ≈17 pt), semibold — much smaller
    /// and lighter than `.title.bold()` (26 pt bold). Medium, not semibold: DH's
    /// stroke is visibly lighter than ours was (audit 2026-09-29, 2x captures).
    static let stoppedNameFontSize: CGFloat = 17
    static let stoppedNameFontWeight: Font.Weight = .medium

    // PAIR — wireless pairing sheet (spec §11.3). Device Hub has no wireless
    // adb pairing surface (its iOS devices pair over its own transport), so
    // these are our own values in the sheets' language: a fixed-width grouped
    // form, a hint line, and the inline error/busy status above the buttons.
    static let pairingSheetWidth: CGFloat = 460
    static let pairingFormMaxFieldWidth: CGFloat = 240
    static let pairingHintFontSize: CGFloat = 11
    static let pairingStatusSpacing: CGFloat = 8
    static let pairingStatusHorizontalInset: CGFloat = 20
    static let pairingStatusBottomSpacing: CGFloat = 8
    static let pairingButtonsBottomSpacing: CGFloat = 16
}
