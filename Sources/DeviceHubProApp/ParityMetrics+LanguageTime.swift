import CoreGraphics

/// Sizes of the Language & time group's own controls. The rows themselves use
/// the audited Controls metrics; these cover what Device Hub's panel has no
/// counterpart for (a searchable value popover, the clock popover), built from
/// the popover row metrics so they share its rhythm.
extension ParityMetrics {
    /// The searchable popover's width: room for a language's native and
    /// English names on one row.
    static let controlsSearchPopoverWidth: CGFloat = 280
    /// Twelve popover rows of list before it scrolls.
    static let controlsSearchPopoverListHeight: CGFloat =
        (controlsPopoverRowHeight + controlsPopoverRowSpacing) * 12
    /// The section headings inside the searchable popover.
    static let controlsSearchPopoverHeadingFontSize: CGFloat = controlsCaptionFontSize
    static let controlsSearchPopoverHeadingHeight: CGFloat = 20
    /// The clock popover's width (date picker plus the quick buttons).
    static let controlsClockPopoverWidth: CGFloat = 280
    /// Space between the clock popover's rows of controls.
    static let controlsClockPopoverSpacing: CGFloat = 8
}
