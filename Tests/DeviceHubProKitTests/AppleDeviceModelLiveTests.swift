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

    /// The panels are found by shape, and the pinned fold lies within the
    /// file's animation.
    func testTheInstalledModelHasTheLayoutTheStageNeeds() async throws {
        let model = try installedModel()
        let entity = try await Entity(contentsOf: model.url)
        let animation = try XCTUnwrap(entity.availableAnimations.first, "no animation")
        XCTAssertLessThanOrEqual(model.spec.closedTime, animation.definition.duration)

        var found: ModelEntity?
        func find(_ node: Entity) {
            if let candidate = node as? ModelEntity, candidate.components[ModelComponent.self] != nil { found = candidate }
            node.children.forEach(find)
        }
        find(entity)
        let component = try XCTUnwrap(found?.components[ModelComponent.self])
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
        let panels = try XCTUnwrap(AppleDeviceModel.panels(in: parts), "no panel layout")
        XCTAssertNotEqual(panels.inner, panels.outer)
    }
}
