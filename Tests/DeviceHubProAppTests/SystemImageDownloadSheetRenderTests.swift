import SwiftUI
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// Draws the download sheet from the fresh VM's real `sdkmanager --list`
/// (a stub sdkmanager prints the capture): recommended image on top, newest
/// stable release first, extension builds folded. PNGs land in
/// `DHP_RENDER_DIR`; without a working Java the test skips.
@MainActor
final class SystemImageDownloadSheetRenderTests: XCTestCase {
    func testSheetFromTheRealListing() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DeviceHubProKitTests/Fixtures/cmdline-tools-23/sdkmanager-list.stdout")
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("stub-sdkmanager-\(UUID().uuidString)")
        try "#!/bin/sh\ncat '\(fixture.path)'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }

        let sdk = SDKComponentModel(
            locateClient: { SdkmanagerClient(sdkmanagerURL: script) },
            locateSdkRoot: { nil },
            installSlot: SDKInstallSlot()
        )
        await sdk.refresh()
        guard sdk.availableState == .loaded else {
            throw XCTSkip("stub sdkmanager could not run (no Java?): \(sdk.availableState)")
        }
        XCTAssertEqual(
            SystemImageCatalog.recommended(
                SystemImageDownloadSheet.offered(sdk.availableImages, category: .phone, hostAbi: "arm64-v8a")
            )?.package,
            "system-images;android-37.0;google_apis;arm64-v8a"
        )

        let hosting = NSHostingView(rootView: SystemImageDownloadSheet(
            sdk: sdk, category: .phone, hostAbi: "arm64-v8a", onInstalled: { _ in }
        ).background(Color(nsColor: .windowBackgroundColor)))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let dir = ProcessInfo.processInfo.environment["DHP_RENDER_DIR"], !dir.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("system-image-download.png"))
    }
}
