import Foundation

/// Padding from a window's edges, in points; leading and trailing as SwiftUI
/// lays them out.
struct EdgePadding: Equatable, Sendable {
    var top, leading, bottom, trailing: Double
}

/// Where controls may sit in the full window, as padding from its edges:
/// inside the safe area (the vertical bar, the status bar, the top and
/// bottom bars) plus a margin, and the deck also clear of the fold's band,
/// on the trailing page in a book and on the base in a laptop.
struct ControlAreas: Equatable, Sendable {
    /// The safe area plus the margin.
    var safe: EdgePadding
    var deck: EdgePadding

    init(safeArea: EdgePadding, layout: SceneLayout, margin: Double = 16) {
        safe = EdgePadding(
            top: safeArea.top + margin,
            leading: safeArea.leading + margin,
            bottom: safeArea.bottom + margin,
            trailing: safeArea.trailing + margin
        )
        deck = safe
        switch layout {
        case .single:
            break
        case let .book(spineX, halfWidth, _):
            deck.leading = max(deck.leading, spineX + halfWidth + margin)
        case let .lidAndBase(creaseY, halfHeight):
            deck.top = max(deck.top, creaseY + halfHeight + margin)
        }
    }
}
