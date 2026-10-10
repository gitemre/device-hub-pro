import Foundation
import RealityKit
import XCTest
@testable import DeviceHubProKit

/// The canary of the device model (`DHP_DISABLE_DEVICE_MODEL`): loads the
/// installed iPhone Duo model the way the 3D stage does and checks what the
/// stage relies on. Behind `DHP_DEVICE_MODEL_LIVE=1`, on a Mac whose Xcode
/// ships a known model: the one `DHP_DEVICE_MODEL_DEVELOPER_DIR` names (its
/// `Contents/Developer`; not `DEVELOPER_DIR`, which would also pick the
/// toolchain that builds the tests), else the selected one:
///
///     DHP_DEVICE_MODEL_LIVE=1 swift test --filter AppleDeviceModelLiveTests
///
/// Nothing from the file is kept: the test reads it in place.
@MainActor
final class AppleDeviceModelLiveTests: XCTestCase {
    private func installedModel() throws -> AppleDeviceModel {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DHP_DEVICE_MODEL_LIVE"] == "1" else {
            throw XCTSkip("set DHP_DEVICE_MODEL_LIVE=1 to load the installed device model")
        }
        let developer = (environment["DHP_DEVICE_MODEL_DEVELOPER_DIR"] ?? environment["DEVELOPER_DIR"])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"))
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard let developer,
              let model = AppleDeviceModel.locate(productClass: "V68", developerDir: developer, environment: [:])
        else {
            throw XCTSkip("the selected Xcode ships no known iPhone Duo model")
        }
        return model
    }

    /// The panels are found by shape, the animation runs as long as
    /// measured, and the pinned fold lies within it.
    func testTheInstalledModelHasTheLayoutTheStageNeeds() async throws {
        let model = try installedModel()
        let entity = try await Entity(contentsOf: model.url)
        let animation = try XCTUnwrap(entity.availableAnimations.first, "no animation")
        XCTAssertLessThanOrEqual(model.spec.closedTime, animation.definition.duration)
        if model.isChecked {
            XCTAssertEqual(animation.definition.duration, model.spec.duration, accuracy: 0.001)
        }
        XCTAssertTrue(model.fits(animationDuration: animation.definition.duration))
        let panels = try XCTUnwrap(Self.panels(of: entity), "no panel layout")
        XCTAssertNotEqual(panels.inner, panels.outer)
    }

    /// Another build of the model, made here from the installed file by
    /// giving its zip archive another comment (a new digest, the same
    /// content), in a temporary Xcode layout: found unchecked, and it loads
    /// with the shape the stage needs.
    func testAnotherBuildOfTheSameShapeIsUsed() async throws {
        let installed = try installedModel()
        var data = try Data(contentsOf: installed.url)
        // The end of central directory record ends with the comment's length
        // and the comment.
        let end = try XCTUnwrap(data.range(of: Data([0x50, 0x4B, 0x05, 0x06]), options: .backwards))
        data = data.prefix(end.lowerBound + 20) + Data([4, 0]) + Data("test".utf8)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleDeviceModelLiveTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Xcode.app/Contents", isDirectory: true)
        let resources = contents.appendingPathComponent(
            "SharedFrameworks/DeviceKit.framework/Versions/A/PlugIns/Fold.devicekitplugin/Contents/Resources",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("Developer", isDirectory: true), withIntermediateDirectories: true
        )
        try data.write(to: resources.appendingPathComponent("V68.usdz"))

        let copy = try XCTUnwrap(AppleDeviceModel.locate(
            productClass: "V68", developerDir: contents.appendingPathComponent("Developer"), environment: [:]
        ))
        XCTAssertFalse(copy.isChecked)
        let entity = try await Entity(contentsOf: copy.url)
        let animation = try XCTUnwrap(entity.availableAnimations.first, "no animation")
        XCTAssertTrue(copy.fits(animationDuration: animation.definition.duration))
        XCTAssertNotNil(Self.panels(of: entity))
    }

    /// The panels of a loaded model, found as the stage finds them.
    private static func panels(of entity: Entity) -> AppleDeviceModel.PanelMaterials? {
        var found: ModelEntity?
        func find(_ node: Entity) {
            if let candidate = node as? ModelEntity, candidate.components[ModelComponent.self] != nil { found = candidate }
            node.children.forEach(find)
        }
        find(entity)
        guard let component = found?.components[ModelComponent.self] else { return nil }
        var parts: [AppleDeviceModel.Part] = []
        for mesh in component.mesh.contents.models {
            for part in mesh.parts {
                var lower = SIMD3<Float>(repeating: .infinity), upper = SIMD3<Float>(repeating: -.infinity)
                for point in part.positions.elements {
                    lower = simd_min(lower, point)
                    upper = simd_max(upper, point)
                }
                parts.append(AppleDeviceModel.Part(material: part.materialIndex, lower: lower, upper: upper))
            }
        }
        return AppleDeviceModel.panels(in: parts)
    }
}
