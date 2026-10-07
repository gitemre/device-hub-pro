import CoreGraphics

/// The simulator crash report list in Diagnostics (parity audit, CR
/// rows). Device Hub has no counterpart (it says crash reports are
/// unavailable for simulators), so these follow Device Hub Pro's own inspector
/// cards: the Info card's fill, radius, inset and 13 pt rows.
extension ParityMetrics {
    /// The list's height before it scrolls: about five rows, so the log
    /// below keeps most of the column.
    static let crashReportsListMaxHeight: CGFloat = 190
    /// A row's vertical padding (two lines of text: 13 pt and 11 pt).
    static let crashReportsRowVerticalPadding: CGFloat = 5
    /// A row's leading and trailing padding inside the card.
    static let crashReportsRowHorizontalPadding: CGFloat = 10
    /// The process name.
    static let crashReportsTitleFontSize: CGFloat = 13
    /// The exception, time and loop line.
    static let crashReportsDetailFontSize: CGFloat = 11
}
