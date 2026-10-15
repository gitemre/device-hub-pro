import SwiftUI

/// The Liquid Glass deck on the inner panel. Its row is the Time-Lapse
/// control, showing the phase and the angle the sky shows behind a play or
/// pause glyph: interactive glass belongs on a control, and so the main
/// control sits on the base in a laptop and on the trailing page in a book,
/// where the hands are. On an iPhone without a hinge it adds a slider that
/// scrubs the day (and, on the compact window, the slider alone: the clock
/// names the phase and the toolbar has the Time-Lapse).
struct Deck: View {
    let angle: Double
    let phase: DayPhase
    /// Plays or pauses the Time-Lapse; nil leaves the row out.
    var timeLapse: (() -> Void)?
    var isTimeLapsing = false
    /// The slider's value on an iPhone without a hinge; nil hides the slider.
    var scrubbing: Binding<Double>?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var degrees: Int { Int(angle.rounded()) }

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 12) {
                if let timeLapse {
                    timeLapseRow(timeLapse)
                }
                if let scrubbing {
                    slider(scrubbing)
                }
            }
        }
    }

    private func timeLapseRow(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // One line while it fits; at the largest text sizes the phase
            // and the angle stack under the glyphs instead of shrinking.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    glyphs
                    Text(phase.title)
                    degreesText
                }
                VStack(spacing: 4) {
                    glyphs
                    Text(phase.title)
                    degreesText
                }
            }
            .font(.headline)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .contentShape(.rect(cornerRadius: 26))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
        // Only the row animates: the slider's thumb must follow the finger,
        // not ease after it.
        .animation(reduceMotion ? nil : .snappy, value: phase)
        .animation(reduceMotion ? nil : .snappy, value: degrees)
        .animation(reduceMotion ? nil : .snappy, value: isTimeLapsing)
        .accessibilityLabel(isTimeLapsing ? "Pause Time-Lapse" : "Play Time-Lapse")
        .accessibilityValue("\(phase.title), \(degrees) degrees")
        .accessibilityHint("Plays a day from night to noon and back. Moving the hinge stops it.")
    }

    private var glyphs: some View {
        HStack(spacing: 10) {
            Image(systemName: isTimeLapsing ? "pause.fill" : "play.fill")
                .contentTransition(.symbolEffect(.replace))
            Image(systemName: phase.symbolName)
                .symbolRenderingMode(.multicolor)
                .contentTransition(.symbolEffect(.replace))
        }
    }

    private var degreesText: some View {
        Text("\(degrees)°")
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.85))
            .contentTransition(.numericText(value: Double(degrees)))
    }

    private func slider(_ value: Binding<Double>) -> some View {
        Slider(value: value, in: 0...180) {
            Text("Time of day")
        } minimumValueLabel: {
            Image(systemName: DayPhase.night.symbolName)
        } maximumValueLabel: {
            Image(systemName: DayPhase.noon.symbolName)
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityValue("\(degrees) degrees, \(phase.title)")
    }
}
