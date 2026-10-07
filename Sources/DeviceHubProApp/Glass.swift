import SwiftUI

extension View {
    /// Liquid glass surface. The app requires macOS 26, where the Glass API
    /// always exists; the compiler gate keeps the repo building with a Swift
    /// 6.1 toolchain (Xcode 16's SDK has no Glass API), which draws a
    /// material instead. The same gate picks glass or its fallback in every
    /// helper below.
    @ViewBuilder
    func liquidGlass(in shape: some InsettableShape = Capsule()) -> some View {
        liquidGlass(interactive: false, tint: nil, in: shape)
    }

    @ViewBuilder
    func liquidGlass(
        interactive: Bool,
        in shape: some InsettableShape = Capsule()
    ) -> some View {
        liquidGlass(interactive: interactive, tint: nil, in: shape)
    }

    @ViewBuilder
    func liquidGlass(
        interactive: Bool,
        tint: Color?,
        in shape: some InsettableShape = Capsule()
    ) -> some View {
        #if swift(>=6.2)
        if let tint {
            if interactive {
                self.glassEffect(.regular.tint(tint).interactive(), in: shape)
            } else {
                self.glassEffect(.regular.tint(tint), in: shape)
            }
        } else if interactive {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.glassEffect(.regular, in: shape)
        }
        #else
        self.background(.regularMaterial, in: shape)
        #endif
    }

    /// Toolbar-adjacent controls: glass, bordered on the Swift 6.1 fallback.
    @ViewBuilder
    func glassButton() -> some View {
        #if swift(>=6.2)
        self.buttonStyle(.glass)
        #else
        self.buttonStyle(.bordered)
        #endif
    }

    /// Hairline edge light + soft shadow so the flat material fallback reads
    /// as glass even over flat backgrounds, Device Hub style. Real glass
    /// draws its own edges, so this only applies on the fallback (Swift 6.1)
    /// path — never hardcode edges over real glass.
    @ViewBuilder
    func glassHairline<S: InsettableShape>(in shape: S) -> some View {
        #if swift(>=6.2)
        self
        #else
        self.overlay(shape.strokeBorder(.white.opacity(0.5), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 2)
        #endif
    }

    /// Device Hub's toolbar control surface (TB-01…TB-04): the real Liquid
    /// Glass (one glass surface per cluster), material + hairline on the
    /// Swift 6.1 fallback. The system's *shared toolbar background* is hidden
    /// at the ToolbarItem level (`sharedBackgroundVisibility(.hidden)`) —
    /// that shared background was what drew a glass rim around every button
    /// inside the cluster; the glass below is DH's actual material.
    ///
    /// WARNING: a group of controls takes one parent glass like this one,
    /// never a glass per control joined with `glassEffectUnion` in a
    /// `GlassEffectContainer`. On macOS 27 that construct hung the app in an
    /// AppKit key-view/layout loop twice: in toolbar items (no window
    /// appeared, the main thread spun in `NSToolbarView` layout) and around
    /// the stage pill's focusable buttons (focusing any text field while a
    /// device was live, SIM-18, `DeviceControlPillKeyViewTests`). The helpers
    /// that built it (`glassUnion`, `glassSegment`, `LiquidGlassContainer`)
    /// were removed with their last caller.
    @ViewBuilder
    func toolbarControlSurface<S: InsettableShape>(in shape: S = Capsule()) -> some View {
        dhGlassDepth(in: shape, profile: .raised)
            .liquidGlass(interactive: true, in: shape)
            .glassHairline(in: shape)
            .dhGlassRim(in: shape)
    }

    /// Device Hub's glass depth (see `GlassDepthProfile`), for a view that
    /// takes `glassEffect` right after it: the light sits under the glass, so
    /// the content stays untouched.
    func dhGlassDepth<S: InsettableShape>(in shape: S, profile: GlassDepthProfile) -> some View {
        modifier(GlassDepth(shape: shape, profile: profile))
    }

    /// The rest of Device Hub's glass depth, for the view after its
    /// `glassEffect`: the outline is white along the top edge (the glass's
    /// own hairline is gray all round), and a soft shadow sits under it.
    func dhGlassRim<S: InsettableShape>(in shape: S) -> some View {
        modifier(GlassRim(shape: shape))
    }

    /// Primary actions: glass prominent, bordered prominent on the Swift 6.1
    /// fallback.
    @ViewBuilder
    func glassProminentButton() -> some View {
        #if swift(>=6.2)
        self.buttonStyle(.glassProminent)
        #else
        self.buttonStyle(.borderedProminent)
        #endif
    }
}

/// The vertical light profile of one of Device Hub's glass capsules, measured
/// on Device Hub 27.0 (2x capture, light appearance, 2026-09-29): a 1 px white
/// rim on the top and the bottom edge, a soft highlight falling from the top
/// rim, and a fill that brightens again toward the bottom; the search field
/// (`recessed`) sits about 4 % darker than the bar around it in the middle,
/// under the same rims. `glassEffect` alone draws one flat fill here, so the
/// stops (offset from the top as a fraction of the height, then the white or
/// black alpha over that flat fill) are laid over it.
struct GlassDepthProfile {
    struct Stop {
        let at: Double
        /// Positive: white over the fill; negative: black.
        let alpha: Double
    }

    let stops: [Stop]

    /// A toolbar capsule: 72 px tall at 2x, f1 at a quarter of the height, f5
    /// at the middle, fb by the bottom (over the glass's own #ebebec).
    static let raised = GlassDepthProfile(stops: [
        Stop(at: 0.000, alpha: 1.00), Stop(at: 0.014, alpha: 0.90), Stop(at: 0.056, alpha: 0.75),
        Stop(at: 0.110, alpha: 0.50), Stop(at: 0.170, alpha: 0.40), Stop(at: 0.220, alpha: 0.30),
        Stop(at: 0.330, alpha: 0.30), Stop(at: 0.390, alpha: 0.35), Stop(at: 0.440, alpha: 0.40),
        Stop(at: 0.500, alpha: 0.45), Stop(at: 0.560, alpha: 0.50), Stop(at: 0.780, alpha: 0.50),
        Stop(at: 0.830, alpha: 0.55), Stop(at: 0.890, alpha: 0.65), Stop(at: 0.940, alpha: 0.80),
        Stop(at: 0.972, alpha: 1.00), Stop(at: 1.000, alpha: 1.00),
    ])

    /// The sidebar's search field: 56 px tall at 2x, #e9e9e9 in the middle.
    static let recessed = GlassDepthProfile(stops: [
        Stop(at: 0.000, alpha: 1.00), Stop(at: 0.014, alpha: 0.90), Stop(at: 0.036, alpha: 0.65),
        Stop(at: 0.070, alpha: 0.40), Stop(at: 0.107, alpha: 0.25), Stop(at: 0.143, alpha: 0.10),
        Stop(at: 0.180, alpha: 0.00), Stop(at: 0.250, alpha: -0.01), Stop(at: 0.430, alpha: -0.01),
        Stop(at: 0.500, alpha: -0.005), Stop(at: 0.540, alpha: 0.00), Stop(at: 0.600, alpha: 0.05),
        Stop(at: 0.680, alpha: 0.05), Stop(at: 0.750, alpha: 0.15), Stop(at: 0.820, alpha: 0.20),
        Stop(at: 0.890, alpha: 0.30), Stop(at: 0.930, alpha: 0.50), Stop(at: 0.960, alpha: 1.00),
        Stop(at: 1.000, alpha: 1.00),
    ])

    func gradient() -> LinearGradient {
        LinearGradient(
            stops: stops.map {
                Gradient.Stop(
                    color: $0.alpha >= 0 ? Color.white.opacity($0.alpha) : Color.black.opacity(-$0.alpha),
                    location: $0.at
                )
            },
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Lays `GlassDepthProfile` under a glass capsule in the light appearance
/// (dark mode keeps the plain glass: Device Hub's dark glass was not
/// measured).
private struct GlassDepth<S: InsettableShape>: ViewModifier {
    let shape: S
    let profile: GlassDepthProfile
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if colorScheme == .light {
            content
                .background {
                    shape.inset(by: 0.5).fill(profile.gradient()).allowsHitTesting(false)
                }
        } else {
            content
        }
    }
}

private struct GlassRim<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if colorScheme == .light {
            content
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(
                            stops: [
                                Gradient.Stop(color: .white, location: 0),
                                Gradient.Stop(color: .white.opacity(0), location: 0.14),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
                    .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.05), radius: 2.5, x: 0, y: 1)
        } else {
            content
        }
    }
}
