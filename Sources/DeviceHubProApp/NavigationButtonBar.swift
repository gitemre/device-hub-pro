import DeviceHubProKit
import SwiftUI

/// What decides, and says, whether and how the stage's navigation bar shows.
enum NavigationBarSpec {
    /// Back, Home and Recents under the device: an Android handheld (phone,
    /// tablet, foldable; emulator or physical) while View ▸ Show Navigation
    /// Buttons is on. Wear OS, TV, Automotive, desktop and XR images have
    /// their own navigation, and an Apple device has no such keys.
    static func isShown(preference: Bool, device: DeviceRef?, formFactor: SystemImage.FormFactor?) -> Bool {
        preference && device?.platform == .android && NavigationBarRules.appliesTo(formFactor)
    }

    /// Whether View ▸ Show Navigation Buttons is listed: only the family the bar
    /// is drawn for (an Android handheld) has anything for it to switch.
    static func offersToggle(family: ControlsFamily?) -> Bool {
        family == .androidHandheld
    }

    static func title(for key: NavigationKey) -> String {
        switch key {
        case .back: return "Back"
        case .home: return "Home"
        case .recents: return "Recents"
        }
    }

    /// The Device menu's shortcut for the key (`AndroidDeviceMenu`), spelled
    /// for the tooltip.
    static func shortcutHint(for key: NavigationKey) -> String {
        switch key {
        case .back: return "\u{2318}["
        case .home: return "\u{21E7}\u{2318}H"
        case .recents: return "\u{2318}]"
        }
    }

    static func toolTip(for key: NavigationKey) -> String {
        switch key {
        case .back: return "Back (\(shortcutHint(for: key)))"
        case .home: return "Home (\(shortcutHint(for: key)))"
        case .recents: return "Recents: all open apps (\(shortcutHint(for: key)))"
        }
    }

    /// The bar's laid-out height, where the stage starts before the bar has
    /// reported its own (`FoldStripStage`).
    static let barHeight: CGFloat = 32
    static let buttonSize = CGSize(width: 44, height: 26)
}

/// Everything the stage keeps in the band under the device: the navigation
/// bar right under it, then the fold strip of a foldable emulator.
struct StageAccessoryStrip: View {
    @Environment(DeviceWorkspace.self) private var workspace
    let showsNavigation: Bool
    let showsFold: Bool

    var body: some View {
        VStack(spacing: 6) {
            if showsNavigation {
                NavigationButtonBar { key in
                    Task { await workspace.mirror.pressNavigationKey(key) }
                }
            }
            if showsFold {
                FoldControlStrip(driver: workspace.hardware, showsSlider: workspace.context.port != nil)
            }
        }
    }
}

/// Android's navigation keys on the stage: Back, Home and Recents on one
/// glass capsule, in the look of the stage pill (one glass behind the
/// buttons, the system's hover and press platters). It sits in the band
/// under the device, so it never covers the touch area, and stays under the
/// device on screen however the device turns.
struct NavigationButtonBar: View {
    /// Runs when a button is pressed (the stage presses the key on the
    /// device).
    let press: (NavigationKey) -> Void
    /// ImageRenderer draws neither buttons nor glass: the render test asks
    /// for plain labels on a flat capsule, which still shows the glyphs'
    /// geometry and the bar's size.
    var rendersStatically = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(NavigationKey.allCases, id: \.self) { key in
                if rendersStatically {
                    NavigationGlyph(key: key)
                        .frame(width: NavigationBarSpec.buttonSize.width, height: NavigationBarSpec.buttonSize.height)
                } else {
                Button {
                    press(key)
                } label: {
                    NavigationGlyph(key: key)
                        .frame(width: NavigationBarSpec.buttonSize.width, height: NavigationBarSpec.buttonSize.height)
                        .contentShape(Capsule())
                }
                .buttonStyle(ChromeButtonStyle(platter: .capsule(NavigationBarSpec.buttonSize)))
                .focusable(false)
                .help(NavigationBarSpec.toolTip(for: key))
                .accessibilityLabel(NavigationBarSpec.title(for: key))
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(height: NavigationBarSpec.barHeight)
        .modifier(NavigationBarSurface(isStatic: rendersStatically))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation buttons")
    }
}

/// The Material navigation glyphs: a rounded left-pointing triangle (Back),
/// a circle (Home) and a rounded square (Recents), outlined in the primary
/// colour.
struct NavigationGlyph: View {
    let key: NavigationKey

    var body: some View {
        Group {
            switch key {
            case .back:
                BackTriangle().stroke(style: Self.stroke)
            case .home:
                Circle().stroke(style: Self.stroke)
            case .recents:
                RoundedRectangle(cornerRadius: 2.5, style: .continuous).stroke(style: Self.stroke)
            }
        }
        .foregroundStyle(.primary)
        .frame(width: Self.glyphSize, height: Self.glyphSize)
        .accessibilityHidden(true)
    }

    static let glyphSize: CGFloat = 12
    private static let stroke = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
}

/// A triangle pointing left, its corners rounded by the stroke's join.
private struct BackTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let inset: CGFloat = 0.75
        path.move(to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

/// One glass behind the buttons and no GlassEffectContainer
/// (`DeviceControlPill`, SIM-18).
private struct NavigationBarSurface: ViewModifier {
    let isStatic: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if isStatic {
            content.background(Capsule().fill(colorScheme == .dark ? Color(white: 0.22) : Color.white))
        } else {
            content
                .background(ParityMetrics.pillLift, in: Capsule())
                .liquidGlass(interactive: true, tint: ParityMetrics.pillTint, in: Capsule())
                .glassHairline(in: Capsule())
                .dhGlassRim(in: Capsule())
        }
    }
}
