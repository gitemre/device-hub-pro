import CryptoKit
import Foundation
import simd

/// A device's 3D model as Xcode ships it for its own Device Hub: today one,
/// iPhone Duo's (`V68.usdz`, named by the device type's `productClass`),
/// in Xcode 27.1's DeviceKit plug-ins.
///
/// The file is Apple's and stays on the user's Mac: it is read at runtime
/// from the user's Xcode, never copied into the repository or the app, and
/// nothing derived from it (meshes, textures, names) is kept. Its part and
/// joint names are scrambled, and RealityKit numbers its materials in a
/// different order on every load, so the panels are found by their shape
/// (`panels(in:)`) and the stretch of its animation that folds the device is
/// pinned per file, by SHA-256, in `known`. Another build's file (an Xcode
/// release after the one measured) is used on the listed file's numbers when
/// it loads with the same shape: the same product class, an animation as
/// long (`fits`) and both panels found; otherwise the stage keeps the 2D
/// chrome. `DHP_DISABLE_DEVICE_MODEL=1` turns the model off.
public struct AppleDeviceModel: Sendable, Hashable {
    public static let disableVariable = "DHP_DISABLE_DEVICE_MODEL"

    public static func isDisabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[disableVariable] == "1"
    }

    /// What one checked file holds.
    public struct Spec: Sendable, Hashable {
        /// The device type's `productClass` the file is named after ("V68").
        public var productClass: String
        /// The file's SHA-256, lowercase hex.
        public var sha256: String
        /// How long the file's animation runs (RealityKit's
        /// `AnimationDefinition.duration`, seconds).
        public var duration: Double
        /// The stretch of the model's animation that folds the outer panel's
        /// half over the other, so a closed device shows its outer panel: at
        /// `openTime` the device is flat (180°), at `closedTime` closed (0°),
        /// linear in between.
        public var openTime: Double
        public var closedTime: Double

        /// The animation time showing the hinge at `degrees` (0 closed,
        /// 180 flat), clamped.
        public func animationTime(forOpening degrees: Double) -> Double {
            let opening = min(max(degrees.isFinite ? degrees : 0, 0), 180)
            return openTime + (closedTime - openTime) * (180 - opening) / 180
        }
    }

    /// The checked files. Xcode 27.1 RC (27A9275), established 2026-10-09:
    /// the second of the animation's three folds turns the outer panel's half
    /// 36° a second from 5.4167 s (flat) to 10.4167 s (closed); the whole
    /// animation runs 37.5 s (both of the file's animations, measured
    /// 2026-10-10).
    public static let known: [Spec] = [
        Spec(
            productClass: "V68",
            sha256: "fd315e57c38fde5666d50de6e19b444e3d145450008126e85838119b682b7940",
            duration: 37.5,
            openTime: 5.0 + 5.0 / 12.0,
            closedTime: 10.0 + 5.0 / 12.0
        ),
    ]

    public let url: URL
    public let spec: Spec
    /// Whether the file is one of `known`; otherwise it carries the numbers
    /// of the known file of its product class and is used only if it `fits`.
    public let isChecked: Bool

    /// Whether a loaded file can be shown: a checked one always; another
    /// build's only when its animation runs as long as the checked file's,
    /// so its fold is taken to lie where that file's does. The panels are
    /// found by shape on every load either way.
    public func fits(animationDuration: Double) -> Bool {
        isChecked || abs(animationDuration - spec.duration) < 0.001
    }

    /// One mesh part as loaded: its material index and its bounds in the
    /// model's space (y up from the open device's inner face).
    public struct Part: Sendable, Equatable {
        public var material: Int
        public var lower: SIMD3<Float>
        public var upper: SIMD3<Float>

        public init(material: Int, lower: SIMD3<Float>, upper: SIMD3<Float>) {
            self.material = material
            self.lower = lower
            self.upper = upper
        }

        var area: Float { (upper.x - lower.x) * (upper.z - lower.z) }
        var thickness: Float { upper.y - lower.y }
        var facesUp: Bool { lower.y + upper.y > 0 }
    }

    /// Which materials show the panels.
    public struct PanelMaterials: Sendable, Equatable {
        public var inner: Int
        public var outer: Int
    }

    /// The panels among `parts`: each the largest perfectly flat part (under
    /// 0.001 units thick) facing up, on the open device's face, or down, on
    /// the back of the half that folds over. Measured on Xcode 27.1 RC's
    /// iPhone Duo: the inner panel 15.8 × 11.1 units, the outer one
    /// 7.7 × 11.2. Nil when either is missing or they share a material.
    ///
    /// The glass over each panel is left as Apple drew it: an opaque black
    /// slab a little larger than its panel, it draws the black border round
    /// the picture and covers the hinge's joint (cleared, the joint showed
    /// as a gap at both ends of the hinge). The panel, flush with its top,
    /// shows through it whole: measured over eight loads, open and closed,
    /// turned and from 0.75 to 5 m.
    public static func panels(in parts: [Part]) -> PanelMaterials? {
        let flat = parts.filter { $0.thickness < 0.001 }
        guard let inner = flat.filter(\.facesUp).max(by: { $0.area < $1.area }),
              let outer = flat.filter({ !$0.facesUp }).max(by: { $0.area < $1.area }),
              inner.material != outer.material
        else { return nil }
        return PanelMaterials(inner: inner.material, outer: outer.material)
    }

    /// How the 3D stage poses a device open by `opening` degrees (0 closed,
    /// 180 flat), from its flat size (the width across both halves, the
    /// height along the hinge, the thickness of one half).
    public struct FoldFraming: Sendable, Equatable {
        /// Radians about the hinge that turn a half-open device so both
        /// halves face the camera alike, the hinge away, as a book is held
        /// to be read; none closed or flat.
        public var bookTurn: Float
        /// The centre of the device's box from the hinge, in the flat
        /// device's frame: across (x, the half that stays put is +x) and in
        /// depth (y, towards the inner panel, which the other half folds
        /// over).
        public var center: SIMD2<Float>
        /// The radius of the sphere the device turns in about `center`.
        public var radius: Float
    }

    /// The opening from which a half-open device is fully turned as a book;
    /// it turns in gradually below, so a closed one faces the camera.
    public static let bookTurnFullAt: Double = 45

    public static func framing(opening: Double, width: Float, height: Float, thickness: Float) -> FoldFraming {
        let degrees = min(max(opening.isFinite ? opening : 0, 0), 180)
        let fold = Float((180 - degrees) * .pi / 180)
        let half = width / 2
        // The outer edge of the half that stays, of the half that folds, and
        // the hinge.
        let points: [SIMD2<Float>] = [[half, 0], [-half * cos(fold), half * sin(fold)], [0, 0]]
        let lower = points.dropFirst().reduce(points[0], simd_min)
        let upper = points.dropFirst().reduce(points[0], simd_max)
        let center = (lower + upper) / 2
        let reach = points.map { simd_length($0 - center) }.max() ?? 0
        let ramp = Float(min(max(degrees / bookTurnFullAt, 0), 1))
        return FoldFraming(
            bookTurn: -fold / 2 * ramp * ramp * (3 - 2 * ramp),
            center: center,
            radius: (reach * reach + height * height / 4).squareRoot() + thickness / 2
        )
    }

    /// Where a pointer lands on a panel of the 3D model, worked out on the
    /// flat panels' bounds (the model's own space: x across, y up from the
    /// open device's face, z down the device) and the fold: the half at
    /// x > 0 stays flat, the other turns about the hinge (x = 0, at the inner
    /// face's height) towards the face.
    public enum PanelHit {
        /// A flat stretch of a panel: its corner at (`u0`, top), the corner
        /// along u at (`u1`, top) and the one along v at (`u0`, bottom), v
        /// running from the panel's top edge (0) to its bottom (1).
        public struct Region: Sendable, Equatable {
            public var origin: SIMD3<Float>
            public var alongU: SIMD3<Float>
            public var alongV: SIMD3<Float>
            public var u0: Float
            public var u1: Float
        }

        /// `point` on the half that folds, with the hinge at `fold` radians
        /// from flat.
        public static func folded(_ point: SIMD3<Float>, pivotY: Float, fold: Float) -> SIMD3<Float> {
            let dx = point.x, dy = point.y - pivotY
            return [dx * cos(fold) + dy * sin(fold), pivotY - dx * sin(fold) + dy * cos(fold), point.z]
        }

        /// The stretches of `panel` open by `opening` degrees: the inner
        /// panel's two halves (u from the folding half's outer edge, through
        /// the hinge, to the other's), or the outer panel (u from its hinge
        /// side, which is on the left seen closed).
        public static func regions(
            of panel: SimulatorFoldPanel,
            inner: (lower: SIMD3<Float>, upper: SIMD3<Float>),
            outer: (lower: SIMD3<Float>, upper: SIMD3<Float>),
            opening: Double
        ) -> [Region] {
            let degrees = min(max(opening.isFinite ? opening : 0, 0), 180)
            let fold = Float((180 - degrees) * .pi / 180)
            let pivotY = inner.upper.y
            func turned(_ point: SIMD3<Float>) -> SIMD3<Float> { folded(point, pivotY: pivotY, fold: fold) }
            switch panel {
            case .inner:
                let (low, high) = inner
                let hingeU = (0 - low.x) / (high.x - low.x)
                return [
                    Region(origin: turned([low.x, high.y, low.z]), alongU: turned([0, high.y, low.z]),
                           alongV: turned([low.x, high.y, high.z]), u0: 0, u1: hingeU),
                    Region(origin: [0, high.y, low.z], alongU: [high.x, high.y, low.z],
                           alongV: [0, high.y, high.z], u0: hingeU, u1: 1),
                ]
            case .outer:
                let (low, high) = outer
                return [Region(origin: turned([high.x, low.y, low.z]), alongU: turned([low.x, low.y, low.z]),
                               alongV: turned([high.x, low.y, high.z]), u0: 0, u1: 1)]
            }
        }

        /// Where a ray meets the parallelogram `corner` + a·`edgeU` +
        /// b·`edgeV` (a, b in 0...1) from its face, the side the edges'
        /// cross product points away from: the distance along the ray, a and
        /// b. Nil when it misses, runs parallel, or meets it from behind.
        public static func intersect(
            origin: SIMD3<Float>, direction: SIMD3<Float>,
            corner: SIMD3<Float>, edgeU: SIMD3<Float>, edgeV: SIMD3<Float>
        ) -> (distance: Float, a: Float, b: Float)? {
            let normal = simd_cross(edgeU, edgeV)
            let facing = simd_dot(direction, normal)
            guard facing > 1e-9 else { return nil }
            let distance = simd_dot(corner - origin, normal) / facing
            guard distance > 0 else { return nil }
            let hit = origin + direction * distance - corner
            let uu = simd_dot(edgeU, edgeU), uv = simd_dot(edgeU, edgeV), vv = simd_dot(edgeV, edgeV)
            let hu = simd_dot(hit, edgeU), hv = simd_dot(hit, edgeV)
            let determinant = uu * vv - uv * uv
            guard abs(determinant) > 1e-12 else { return nil }
            let a = (hu * vv - hv * uv) / determinant, b = (hv * uu - hu * uv) / determinant
            guard (0...1).contains(a), (0...1).contains(b) else { return nil }
            return (distance, a, b)
        }

        /// The pixel of a `width` × `height` frame under (u, v) of the
        /// panel's texture, which shows the frame turned `turns` quarter
        /// turns clockwise (the panel feeder's sampling, inverted).
        public static func framePixel(u: Float, v: Float, turns: Int, width: Int, height: Int) -> (x: Int32, y: Int32) {
            let uv: (Float, Float)
            switch ((turns % 4) + 4) % 4 {
            case 1: uv = (v, 1 - u)
            case 2: uv = (1 - u, 1 - v)
            case 3: uv = (1 - v, u)
            default: uv = (u, v)
            }
            let x = min(max(uv.0 * Float(width), 0), Float(max(width - 1, 0)))
            let y = min(max(uv.1 * Float(height), 0), Float(max(height - 1, 0)))
            return (Int32(x), Int32(y))
        }
    }

    /// The model `productClass` names in the Xcode at `developerDir`: a
    /// `known` file checked; else, when a known file has that product class,
    /// the file on that one's numbers, unchecked (`fits`). Nil without a
    /// file, or when turned off. Reads and hashes the file (a few megabytes):
    /// call it off the main thread.
    public static func locate(
        productClass: String,
        developerDir: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        known: [Spec] = AppleDeviceModel.known
    ) -> AppleDeviceModel? {
        guard !isDisabled(environment: environment), AppleDeviceKit.isPlainName(productClass) else { return nil }
        let plugIns = developerDir
            .deletingLastPathComponent()
            .appendingPathComponent("SharedFrameworks/DeviceKit.framework/Versions/A/PlugIns", isDirectory: true)
        let bundles = (try? FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil)) ?? []
        var unchecked: URL?
        for bundle in bundles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where bundle.pathExtension == "devicekitplugin" {
            let file = bundle.appendingPathComponent("Contents/Resources/\(productClass).usdz")
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if let spec = known.first(where: { $0.sha256 == digest }) {
                return AppleDeviceModel(url: file, spec: spec, isChecked: true)
            }
            if unchecked == nil { unchecked = file }
        }
        guard let unchecked, let template = known.first(where: { $0.productClass == productClass }) else { return nil }
        return AppleDeviceModel(url: unchecked, spec: template, isChecked: false)
    }
}
