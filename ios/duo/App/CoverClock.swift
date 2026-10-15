import SwiftUI

/// The cover's face: a big white clock, the date and the phase. White
/// whatever the sky, so the cover always has bright pixels: Device Hub Pro
/// counts a panel as lit from its brightness, and a cover that fades in from
/// black for long reads as a screen not responding.
struct CoverClock: View {
    let phase: DayPhase
    /// The time of day the sky shows (`DayCycle.progress`): from sunrise on
    /// the sun rises in the clock's column, and the text needs lifting off it.
    let progress: Double
    /// The window's shorter side, which sizes the clock.
    let shortSide: CGFloat
    /// Landscape (tent) has room for a larger clock.
    let isLandscape: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.colorSchemeContrast) private var contrast

    /// Hours without AM/PM: the clock is a face, the date line says the rest.
    private static let timeStyle = Date.FormatStyle.dateTime
        .hour(.defaultDigits(amPM: .omitted))
        .minute(.twoDigits)

    /// Thin, as a picture; heavier when Bold Text or Increase Contrast asks
    /// for strokes that hold up over a bright sky.
    private var clockWeight: Font.Weight {
        if legibilityWeight == .bold { return .regular }
        return contrast == .increased ? .light : .thin
    }

    var body: some View {
        let scrim = DayCycle.textScrim(progress: progress) * (contrast == .increased ? 1.4 : 1)
        TimelineView(.everyMinute) { context in
            VStack(spacing: 6) {
                // A fixed size, not Dynamic Type: the clock is the cover's
                // picture, sized from the panel, and the first to give way
                // when the lines under it grow.
                Text(context.date, format: Self.timeStyle)
                    .font(.system(size: shortSide * (isLandscape ? 0.36 : 0.27), weight: clockWeight, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    // The horizon (0.64 of the landscape cover) falls in
                    // this gap rather than under the date.
                    .padding(.bottom, 10)
                    .layoutPriority(-1)
                Group {
                    Text(context.date, format: .dateTime.weekday(.wide).month(.wide).day())
                    Label(phase.title, systemImage: phase.symbolName)
                        .contentTransition(.symbolEffect(.replace))
                        .animation(reduceMotion ? nil : .snappy, value: phase)
                }
                .font(.title3)
                .dynamicTypeSize(...DynamicTypeSize.accessibility3)
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .modifier(SkyLegible(edge: scrim > 0.1, softRadius: 12))
            .background { veil(scrim) }
            .accessibilityElement(children: .combine)
        }
    }

    /// The legibility veil the Lock Screen puts behind its clock over a
    /// bright wallpaper: a soft ellipse of the sky's own deepest blue, none
    /// at night and strongest when the low sun sits behind the digits.
    private func veil(_ opacity: Double) -> some View {
        let colour = DayCycle.palette(progress: progress).zenith.mixed(with: RGB(r: 0, g: 0, b: 0), 0.35)
        return EllipticalGradient(
            colors: [colour.sceneColor(opacity), colour.sceneColor(0.7 * opacity), colour.sceneColor(0)],
            startRadiusFraction: 0,
            endRadiusFraction: 0.5
        )
        .padding(.horizontal, -48)
        .padding(.vertical, -36)
        .opacity(opacity > 0.004 ? 1 : 0)
        .accessibilityHidden(true)
    }
}

/// White text over the sky: a soft shadow lifts it off the scene, and over
/// a bright sky a tight dark edge keeps thin strokes readable (at night that
/// edge would only grey them). Increase Contrast makes both stronger and
/// keeps the edge on.
private struct SkyLegible: ViewModifier {
    let edge: Bool
    let softRadius: CGFloat

    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let increased = contrast == .increased
        content
            .shadow(color: .black.opacity(increased ? 0.5 : edge ? 0.3 : 0), radius: 1.5, y: 0.5)
            .shadow(color: .black.opacity(increased ? 0.45 : 0.3), radius: softRadius, y: 2)
    }
}
