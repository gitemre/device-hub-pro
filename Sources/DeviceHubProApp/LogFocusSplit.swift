import AppKit
import SwiftUI

/// The detail column: the device stage alone, or, in Log focus mode, the
/// stage at a fixed width on the left (still the same view, so the mirror
/// session carries on) and the wide log pane filling the rest. The divider
/// between them drags; the width is remembered.
struct LogFocusSplit<Stage: View, Log: View>: View {
    let isFocus: Bool
    @ViewBuilder var stage: () -> Stage
    @ViewBuilder var log: () -> Log

    @AppStorage("logFocusStageWidth") private var storedWidth: Double = 380
    @State private var dragStartWidth: Double?

    static var minStage: Double { 280 }
    static var minLog: Double { 420 }

    /// The stage width for a detail column `total` points wide.
    static func clampedStageWidth(_ width: Double, total: Double) -> Double {
        max(minStage, min(width, total - minLog))
    }

    var body: some View {
        GeometryReader { geometry in
            let total = Double(geometry.size.width)
            let width = Self.clampedStageWidth(storedWidth, total: total)
            HStack(spacing: 0) {
                stage()
                    .frame(width: isFocus ? CGFloat(width) : nil)
                if isFocus {
                    Divider()
                        .overlay {
                            Color.clear
                                .frame(width: 9)
                                .contentShape(Rectangle())
                                .onHover { inside in
                                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                                }
                                .gesture(
                                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                        .onChanged { value in
                                            let start = dragStartWidth ?? width
                                            dragStartWidth = start
                                            storedWidth = Self.clampedStageWidth(
                                                start + Double(value.translation.width), total: total
                                            )
                                        }
                                        .onEnded { _ in dragStartWidth = nil }
                                )
                        }
                    log()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}
