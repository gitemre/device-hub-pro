import DeviceHubProKit
import SwiftUI

/// Main-actor because its drivers (`EmulatorHardwareController`, and
/// `AppModel` forwarding to it) are: a `@MainActor` class cannot satisfy a
/// non-isolated protocol requirement in Swift 6 mode.
@MainActor
protocol FoldControlDriving: AnyObject {
    var hingeAngle: Double? { get }
    func setPostureAnimated(_ posture: PostureKind)
    func setHingeAngle(_ degrees: Double)
}

@MainActor
enum FoldStripActions {
    static func presetTapped(_ posture: PostureKind, driver: any FoldControlDriving) {
        driver.setPostureAnimated(posture)
    }

    static func sliderChanged(_ degrees: Double, driver: any FoldControlDriving) {
        // A non-finite drag value (NaN can reach here) must never reach the
        // hinge sender — it would go to gRPC verbatim.
        guard degrees.isFinite else { return }
        driver.setHingeAngle(min(max(degrees, 0), 180))
    }

    /// The slider thumb position: the driver's live hinge angle when it has
    /// one (presets and polls move the thumb), else the local drag value.
    static func thumbAngle(driver: any FoldControlDriving, local: Double) -> Double {
        driver.hingeAngle ?? local
    }
}

/// The stage's fold controls (spec §9): posture presets and the 0–180° hinge
/// slider — the reference simulator strip's counterpart.
struct FoldControlStrip: View {
    let driver: any FoldControlDriving
    let showsSlider: Bool
    @State private var sliderAngle: Double = 180

    /// The strip's laid-out height with or without the live slider
    /// (`FoldControlStripTests` pins it): where the stage starts before the
    /// strip has reported its own (`FoldStripStage`).
    static let estimatedHeight: CGFloat = 32

    /// The strip's gap to the stage's bottom edge.
    static let stageBottomPadding: CGFloat = 8

    /// How much of the strip a narrow stage column keeps. The strip tries
    /// the full one first and takes the next that fits: Log focus's stage
    /// column is as narrow as 280 pt, and the full strip (labels and a
    /// 160 pt slider) needs about 420.
    enum Compaction: CaseIterable {
        /// Labelled presets and the 160 pt slider.
        case full
        /// Icon-only presets and a shorter slider.
        case icons
        /// Icon-only presets.
        case presetsOnly

        var showsLabels: Bool { self == .full }
        var sliderWidth: CGFloat? {
            switch self {
            case .full: return 160
            case .icons: return 84
            case .presetsOnly: return nil
            }
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Compaction.allCases, id: \.self) { compaction in
                strip(compaction)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func strip(_ compaction: Compaction) -> some View {
        HStack(spacing: compaction.showsLabels ? 10 : 6) {
            // Presets stay enabled without gRPC:
            // `EmulatorHardwareController.runPostureAnimation` falls back to
            // the emulator console's `posture` command (pinned there), so they
            // settle even console-only (spec §10).
            ForEach(PostureKind.allCases) { posture in
                Button {
                    FoldStripActions.presetTapped(posture, driver: driver)
                } label: {
                    if compaction.showsLabels {
                        Image(systemName: posture.systemImage)
                        Text(posture.label)
                    } else {
                        Image(systemName: posture.systemImage)
                            .accessibilityLabel(posture.label)
                    }
                }
                .help("\(posture.label): hinge \(posture.angleRange)")
            }
            if let sliderWidth = compaction.sliderWidth {
                if showsSlider {
                    Slider(
                        value: Binding(
                            get: { FoldStripActions.thumbAngle(driver: driver, local: sliderAngle) },
                            set: { value in
                                sliderAngle = value
                                FoldStripActions.sliderChanged(value, driver: driver)
                            }),
                        in: 0...180
                    )
                    .frame(width: sliderWidth)
                }
                // Without a console port (gRPC) the slider cannot move the hinge: not shown.
            }
        }
    }
}
