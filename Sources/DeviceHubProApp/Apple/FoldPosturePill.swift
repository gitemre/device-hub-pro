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

    /// The glyph's name in the plug-in's catalog.
    static func name(of posture: PostureKind, productClass: String) -> String {
        let prefix = productClass.lowercased()
        switch posture {
        case .closed: return "\(prefix)_Closed"
        case .halfOpened: return "\(prefix)_HalfOpen_Landscape"
        case .opened: return "\(prefix)_Open"
        }
    }

    /// Whether the plug-in has `posture`'s glyph.
    static func hasGlyph(_ posture: PostureKind, model: AppleDeviceModel) -> Bool {
        hasSymbol(name(of: posture, productClass: model.spec.productClass), model: model)
    }

    /// Device Hub's Rotate on a foldable's pill: arrows at the top left and
    /// the bottom right (the circle's on other devices are the other way
    /// round, `PillRotateGlyph`).
    static let rotateName = "rotate.device.right"

    static func hasSymbol(_ name: String, model: AppleDeviceModel) -> Bool {
        guard let bundle = bundle(for: model) else { return false }
        return NSImage(symbolName: name, bundle: bundle, variableValue: 0) != nil
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

    var body: some View {
        image
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: ParityMetrics.pillIconSize, weight: .medium))
            .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    }

    private var image: Image {
        switch choice {
        case .preset(let posture):
            if let model, let bundle = FoldPostureGlyphs.bundle(for: model),
               FoldPostureGlyphs.hasGlyph(posture, model: model) {
                return Image(FoldPostureGlyphs.name(of: posture, productClass: model.spec.productClass), bundle: bundle)
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
