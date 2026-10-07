import CoreGraphics
import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

final class DeviceCatalogTests: XCTestCase {
    private func skin(_ name: String) -> SkinCatalogEntry {
        SkinCatalogEntry(
            name: name,
            displayName: SkinResolver.displayName(forSkinName: name),
            category: SkinResolver.category(forSkinName: name),
            directory: URL(fileURLWithPath: "/tmp/\(name)"),
            variants: []
        )
    }

    private let types = [
        SimulatorDeviceType(identifier: "t.iphone17", name: "iPhone 17", productFamily: "iPhone", modelIdentifier: "iPhone18,3"),
        SimulatorDeviceType(identifier: "t.iphone4s", name: "iPhone 4s", productFamily: "iPhone", modelIdentifier: "iPhone4,1"),
        SimulatorDeviceType(identifier: "t.watch", name: "Apple Watch Series 11 (46mm)", productFamily: "Apple Watch"),
        SimulatorDeviceType(identifier: "t.homepod", name: "HomePod", productFamily: "HomePod"),
    ]

    private let runtimes = [
        SimulatorRuntime(
            identifier: "rt.ios26", name: "iOS 26.0", version: "26.0", buildVersion: "", platform: "iOS",
            isAvailable: true, supportedDeviceTypeIdentifiers: ["t.iphone17"]
        ),
        SimulatorRuntime(
            identifier: "rt.ios16", name: "iOS 16.0", version: "16.0", buildVersion: "", platform: "iOS",
            isAvailable: true, supportedDeviceTypeIdentifiers: ["t.iphone4s"]
        ),
    ]

    private func items() -> [CatalogItem] {
        DeviceCatalog.items(
            skins: [skin("pixel_9"), skin("wearos_small_round"), skin("tv_4k")],
            deviceTypes: types,
            runtimes: runtimes
        )
    }

    func testItemsCoverBothPlatformsAndDropUnknownFamilies() {
        let items = items()
        XCTAssertEqual(items.filter { $0.platform == .android }.count, 3)
        XCTAssertEqual(items.filter { $0.platform == .apple }.map(\.name), ["iPhone 17", "iPhone 4s", "Apple Watch Series 11 (46mm)"])
    }

    func testCreatableMeansAnInstalledNotTooOldRuntimeRunsIt() {
        let apple = items().filter { $0.platform == .apple }
        XCTAssertEqual(apple.map(\.isCreatable), [true, false, false])
        XCTAssertEqual(apple[0].runtimeNames, ["iOS 26.0"])
    }

    func testAndroidGroupsFollowTheSkinCategory() {
        let groups = items().filter { $0.platform == .android }.map(\.group)
        XCTAssertEqual(groups, [.androidPhones, .wear, .tv])
        XCTAssertEqual(items().first { $0.group == .wear }?.name, "Wear OS Small Round")
    }

    func testFilterByPlatformGroupSearchAndAvailability() {
        let all = items()
        XCTAssertEqual(DeviceCatalog.filter(all, platform: .apple, group: nil, search: "", onlyCreatable: false).count, 3)
        XCTAssertEqual(DeviceCatalog.filter(all, platform: .apple, group: nil, search: "", onlyCreatable: true).count, 1)
        XCTAssertEqual(DeviceCatalog.filter(all, platform: .apple, group: .appleWatch, search: "", onlyCreatable: false).count, 1)
        XCTAssertEqual(DeviceCatalog.filter(all, platform: .android, group: nil, search: "wear small", onlyCreatable: false).count, 1)
        XCTAssertEqual(DeviceCatalog.filter(all, platform: .apple, group: nil, search: "iPhone18", onlyCreatable: false).map(\.name), ["iPhone 17"])
        XCTAssertTrue(DeviceCatalog.filter(all, platform: .android, group: nil, search: "zzz", onlyCreatable: false).isEmpty)
    }

    func testSectionsAndGroupsKeepGroupOrderAndSkipEmptyOnes() {
        let all = items()
        XCTAssertEqual(DeviceCatalog.groups(in: all, platform: .android), [.androidPhones, .wear, .tv])
        XCTAssertEqual(DeviceCatalog.groups(in: all, platform: .apple), [.iPhone, .appleWatch])
        XCTAssertEqual(DeviceCatalog.sections(all).map(\.group), [.androidPhones, .wear, .tv, .iPhone, .appleWatch])
    }

    func testEveryGroupBelongsToOnePlatformAndAndroidOnesMapBack() {
        for group in CatalogGroup.allCases {
            XCTAssertEqual(group.androidCategory != nil, group.platform == .android)
            if let category = group.androidCategory {
                XCTAssertEqual(CatalogGroup(category: category), group)
            }
        }
    }

    func testScreenText() {
        XCTAssertEqual(CatalogScreenText.resolution(CGSize(width: 1206, height: 2622)), "1206 \u{00D7} 2622 px")
        XCTAssertNil(CatalogScreenText.resolution(.zero))
        XCTAssertEqual(CatalogScreenText.scale(3), "@3x")
        XCTAssertNil(CatalogScreenText.scale(1))
    }

    func testCreateDraftPreselectsTheCatalogsModel() {
        let more = types + [SimulatorDeviceType(identifier: "t.iphone17pro", name: "iPhone 17 Pro", productFamily: "iPhone")]
        let rts = [SimulatorRuntime(
            identifier: "rt.ios26", name: "iOS 26.0", version: "26.0", buildVersion: "", platform: "iOS",
            isAvailable: true, supportedDeviceTypeIdentifiers: ["t.iphone17", "t.iphone17pro"]
        )]
        var draft = SimulatorCreateDraft(family: .iPhone, runtimes: rts, deviceTypes: more)
        draft.selectModel("t.iphone17pro")
        XCTAssertEqual(draft.model?.name, "iPhone 17 Pro")
        XCTAssertEqual(draft.name, "iPhone 17 Pro")
    }

    func testXRSkinsAreACategory() {
        XCTAssertEqual(SkinResolver.category(forSkinName: "xr_headset"), .xr)
        XCTAssertEqual(SkinResolver.displayName(forSkinName: "xr_headset"), "XR Headset")
    }

    /// A round watch whose artwork is an opaque square: the ring's outer
    /// edge is found on the middle row; artwork with transparent corners
    /// (or no ring) has none.
    func testRoundOutlineIsFoundOnOpaqueSquareArtworkOnly() throws {
        func image(opaqueCorners: Bool) throws -> CGImage {
            let size = 200
            let context = try XCTUnwrap(CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            if opaqueCorners {
                context.setFillColor(CGColor(gray: 0.125, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            }
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fillEllipse(in: CGRect(x: 10, y: 10, width: 180, height: 180))
            return try XCTUnwrap(context.makeImage())
        }
        let fraction = try XCTUnwrap(SkinThumbnail.roundOutlineRadiusFraction(of: image(opaqueCorners: true)))
        XCTAssertEqual(fraction, 0.45, accuracy: 0.01)
        XCTAssertNil(SkinThumbnail.roundOutlineRadiusFraction(of: try image(opaqueCorners: false)))
    }
}
