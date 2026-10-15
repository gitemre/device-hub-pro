import AppKit
import DeviceHubProKit
import SwiftUI

/// Device Hub's posture glyphs for a foldable simulator, read at runtime from
/// the user's Xcode: custom symbols in the asset catalog of the DeviceKit
/// plug-in that ships the device's 3D model (`v68_Closed`,
/// `v68_HalfOpen_Landscape`, `v68_Open` for iPhone Duo, Xcode 27.1), never
/// copied. Without them (another Xcode build) the pill falls back to SF
/// Symbols of the same shapes.
@MainActor
enum FoldPostureGlyphs {
    private static var bundles: [URL: Bundle?] = [:]

    /// The plug-in bundle holding `model`'s file.
    static func bundle(for model: AppleDeviceModel) -> Bundle? {
        // …/<plug-in>.devicekitplugin/Contents/Resources/<productClass>.usdz
        let plugIn = model.url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if let cached = bundles[plugIn] { return cached }
        let bundle = plugIn.pathExtension == "devicekitplugin" ? Bundle(url: plugIn) : nil
        bundles[plugIn] = bundle
        return bundle
    }

    /// Whether the device is a quarter turn from its resting pose (either
    /// way): the stage's 3D roll, odd. Device Hub 27.1 draws the glyphs for
    /// the held orientation, and a half turn looks like the resting pose.
    static func isQuarterTurned(targetTurns: Int, restingTurns: Int) -> Bool {
        (((targetTurns - restingTurns) % 4 + 4) % 4) % 2 == 1
    }

    /// The glyph's name in the plug-in's catalog. Quarter-turned, Partially
    /// Open is the catalog's portrait drawing (Closed and Open are the same
    /// drawings, turned: `rotationDegrees`).
    static func name(of posture: PostureKind, productClass: String, quarterTurned: Bool = false) -> String {
        let prefix = productClass.lowercased()
        switch posture {
        case .closed: return "\(prefix)_Closed"
        case .halfOpened: return "\(prefix)_HalfOpen_\(quarterTurned ? "Portrait" : "Landscape")"
        case .opened: return "\(prefix)_Open"
        }
    }

    /// How far the glyph is turned clockwise: Device Hub turns Closed and
    /// Open a quarter when the device is, and draws Partially Open upright.
    static func rotationDegrees(of posture: PostureKind, quarterTurned: Bool) -> Double {
        quarterTurned && posture != .halfOpened ? 90 : 0
    }

    /// Whether the plug-in has `posture`'s glyph.
    static func hasGlyph(_ posture: PostureKind, model: AppleDeviceModel, quarterTurned: Bool = false) -> Bool {
        hasSymbol(name(of: posture, productClass: model.spec.productClass, quarterTurned: quarterTurned), model: model)
    }

    /// Device Hub's Rotate on a foldable's pill: arrows at the top left and
    /// the bottom right (the circle's on other devices are the other way
    /// round, `PillRotateGlyph`).
    static let rotateName = "rotate.device.right"
    /// Its mirror, which Device Hub shows while Option is held.
    static let rotateLeftName = "rotate.device.left"

    private static var symbolPresence: [String: Bool] = [:]

    /// Whether the plug-in has the symbol `name`. Remembered: the pill asks
    /// for each of its glyphs on every update, in every width tier it
    /// measures, and the answer for a plug-in on disk does not change.
    static func hasSymbol(_ name: String, model: AppleDeviceModel) -> Bool {
        guard let bundle = bundle(for: model) else { return false }
        let key = bundle.bundleURL.path + "#" + name
        if let known = symbolPresence[key] { return known }
        let present = NSImage(symbolName: name, bundle: bundle, variableValue: 0) != nil
        symbolPresence[key] = present
        return present
    }

    static func fallbackSymbol(_ posture: PostureKind) -> String {
        switch posture {
        case .closed: return "iphone.gen3"
        case .halfOpened: return "book.pages"
        case .opened: return "ipad.landscape"
        }
    }
}

/// A posture button's glyph on the stage's pill: Device Hub's symbol from
/// the user's Xcode (a laptop's and a tent's from SF Symbols), the current
/// one in the accent colour, as Device Hub shows it.
struct FoldPostureGlyph: View {
    let choice: SimulatorFoldPostureChoice
    let model: AppleDeviceModel?
    let isCurrent: Bool
    /// The device is a quarter turn from its resting pose
    /// (`FoldPostureGlyphs.isQuarterTurned`).
    var quarterTurned = false

    var body: some View {
        image
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: ParityMetrics.pillIconSize, weight: .medium))
            .rotationEffect(.degrees(degrees))
            .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    }

    private var degrees: Double {
        if case .preset(let posture) = choice {
            return FoldPostureGlyphs.rotationDegrees(of: posture, quarterTurned: quarterTurned)
        }
        return 0
    }

    private var image: Image {
        switch choice {
        case .preset(let posture):
            if let model, let bundle = FoldPostureGlyphs.bundle(for: model),
               FoldPostureGlyphs.hasGlyph(posture, model: model, quarterTurned: quarterTurned) {
                return Image(
                    FoldPostureGlyphs.name(of: posture, productClass: model.spec.productClass, quarterTurned: quarterTurned),
                    bundle: bundle
                )
            }
            return Image(systemName: FoldPostureGlyphs.fallbackSymbol(posture))
        case .held(let posture):
            return Image(systemName: posture.systemImage)
        }
    }
}

extension SimulatorFoldPostureChoice {
    /// The button's tooltip: Device Hub's names for its three.
    var title: String {
        switch self {
        case .preset(.closed): return "Closed"
        case .preset(.halfOpened): return "Partially Open"
        case .preset(.opened): return "Open"
        case .held(let posture): return posture.label
        }
    }

    /// The pill's buttons in order: Device Hub's three, then a laptop and a
    /// tent beside them.
    static let pillOrder: [SimulatorFoldPostureChoice] =
        PostureKind.allCases.map { .preset($0) } + SimulatorHeldPosture.allCases.map { .held($0) }
}
