import AppKit
import SwiftUI

/// Device Hub's pointer feedback on chrome buttons (parity audit,
/// "Pointer feedback", HV rows; measured 2026-09-25 on DH 27.0, light
/// appearance, key window).
///
/// Hovering a toolbar capsule item, a stage-pill button or a settings popup
/// value shows a platter behind it at once — DH's change lands within one
/// 60 fps frame, so there is no fade — and holding the button down darkens
/// it. The fills are the system's semantic fills, which carry the dark and
/// increased-contrast variants: DH's hover reads ≈4.5 % black over its glass
/// (#f2f2f1 → #e7e7e6) = `tertiarySystemFill` (4.7 %), the pressed state
/// ≈8 % (#f8f8f7 → #e4e4e3) = `secondarySystemFill` (7.8 %). Disabled
/// controls show neither. DH shows no hover on rows, switches, sliders,
/// inspector tabs or text fields, and neither do we.
enum PointerFeedback {
    static let hoverFill = Color(nsColor: .tertiarySystemFill)
    static let pressedFill = Color(nsColor: .secondarySystemFill)
    /// TB-01's filter-active fill (2026-09-28): DH's filter toolbar item
    /// fills solid with the system accent while a filter narrows the list —
    /// pixel-sampled at #007AFF, the accent's default blue, so this follows
    /// the accent rather than hardcoding that blue (DH's own controls are
    /// almost certainly doing the same, and a custom accent then matches).
    static let filterActiveFill = Color(nsColor: .controlAccentColor)

    /// The platter fill for a control's state; nil draws nothing.
    static func fill(isHovered: Bool, isPressed: Bool, isEnabled: Bool = true) -> Color? {
        guard isEnabled else { return nil }
        if isPressed { return pressedFill }
        return isHovered ? hoverFill : nil
    }
}

/// A platter's shape, centred in its control's frame.
enum PlatterShape: Equatable {
    /// DH's toolbar and pill items: a capsule of this size.
    case capsule(CGSize)
    /// DH's standalone circle buttons (sidebar toggle, pill rotate).
    case circle(diameter: CGFloat)
}

/// Draws a platter, or nothing when `fill` is nil. Never hit-testable.
struct PlatterView: View {
    let shape: PlatterShape
    let fill: Color?

    var body: some View {
        Group {
            if let fill {
                switch shape {
                case .capsule(let size):
                    Capsule().fill(fill).frame(width: size.width, height: size.height)
                case .circle(let diameter):
                    Circle().fill(fill).frame(width: diameter, height: diameter)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Toolbar capsule items and stage-pill buttons: the label alone (under the
/// new design the system draws its own glass rim around toolbar buttons,
/// which DH's capsules do not have), DH's platter on hover and while held,
/// and DH's grey glyph when disabled (#adadad over the near-white glass; the
/// label would otherwise stay black and look clickable). Held-then-dragged-
/// out presses cancel like any system button.
struct ChromeButtonStyle: ButtonStyle {
    var platter: PlatterShape

    func makeBody(configuration: Configuration) -> some View {
        ChromeButtonBody(configuration: configuration, platter: platter)
    }
}

private struct ChromeButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let platter: PlatterShape

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .opacity(isEnabled ? 1 : ParityMetrics.chromeDisabledGlyphOpacity)
            .background {
                PlatterView(
                    shape: platter,
                    fill: PointerFeedback.fill(
                        isHovered: isHovered,
                        isPressed: configuration.isPressed,
                        isEnabled: isEnabled
                    )
                )
            }
            .onHover { isHovered = $0 }
    }
}

extension View {
    /// DH's hover platter behind a control that is not a `Button` — the
    /// borderless menus, whose labels AppKit flattens (their glyphs are
    /// drawn as overlays). `isPressed` lets a caller that tracks its own
    /// press (or an open menu/popover) show the darker platter.
    func hoverPlatter(_ shape: PlatterShape, isPressed: Bool = false) -> some View {
        modifier(HoverPlatterModifier(shape: shape, isPressed: isPressed))
    }
}

private struct HoverPlatterModifier: ViewModifier {
    let shape: PlatterShape
    let isPressed: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                PlatterView(
                    shape: shape,
                    fill: PointerFeedback.fill(isHovered: isHovered, isPressed: isPressed, isEnabled: isEnabled)
                )
            }
            .onHover { isHovered = $0 }
    }
}

/// The stage's primary action label (Start / Mirror): DH's Start button is
/// 80×30 pt, where a large glass-prominent button around a bare title
/// measures 58×28 — the label's minimum size makes up the difference (a
/// longer title keeps its natural width).
struct StagePrimaryButtonLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .frame(
                minWidth: ParityMetrics.stagePrimaryButtonLabelMinWidth,
                minHeight: ParityMetrics.stagePrimaryButtonLabelMinHeight
            )
    }
}

extension View {
    /// The stage's Start / Mirror / Restart button, Device Hub's: the
    /// accent capsule while the window is active and a plain grey capsule
    /// with dark text while it is not (measured on DH 27.0: blue in a
    /// screenshot of its active window, grey in an inactive one;
    /// the system's own prominent button keeps a washed-out grey label
    /// there instead).
    func stagePrimaryButton() -> some View {
        modifier(StagePrimaryButtonModifier())
    }

    /// A text field's whole box focuses it under the I-beam, like an
    /// `NSTextField`'s bezel (DH's search field): a plain SwiftUI field takes
    /// clicks on its text line only, so its padding and a leading magnifier
    /// did nothing.
    func textFieldHitArea(_ shape: some Shape, focus: FocusState<Bool>.Binding) -> some View {
        contentShape(shape)
            .onTapGesture { focus.wrappedValue = true }
            .pointerStyle(.horizontalText)
    }
}

private struct StagePrimaryButtonModifier: ViewModifier {
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        if activeState == .inactive {
            content.buttonStyle(StageInactiveCapsuleStyle())
        } else {
            // Device Hub's is a flat accent capsule: the system's prominent
            // glass added a light rim and a drop shadow.
            content.buttonStyle(StageActiveCapsuleStyle())
        }
    }
}

/// The grey capsule (80 × 30 with its label's minimum) a stage button takes
/// in an inactive window.
private struct StageInactiveCapsuleStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(.primary.opacity(isEnabled ? 1 : 0.4))
            .padding(.horizontal, 14)
            .frame(minWidth: ParityMetrics.stagePrimaryButtonWidth, minHeight: ParityMetrics.stagePrimaryButtonHeight)
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.2 : 0.14)))
            .contentShape(Capsule())
    }
}

/// The accent capsule (80 x 30 with its label's minimum) a stage button takes
/// in an active window: flat, no rim and no shadow (DH 27.0).
private struct StageActiveCapsuleStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.6))
            .padding(.horizontal, 14)
            .frame(minWidth: ParityMetrics.stagePrimaryButtonWidth, minHeight: ParityMetrics.stagePrimaryButtonHeight)
            .background(
                Capsule().fill(Color.accentColor.opacity(isEnabled ? 1 : 0.45))
                    .overlay(Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.15 : 0)))
            )
            .contentShape(Capsule())
    }
}
