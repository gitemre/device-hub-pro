import SwiftUI
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// Draws each screen of the "Set up Android tools" card and the sidebar hint
/// cards, light and dark. The PNGs land in
/// `DHP_RENDER_DIR` when it is set (to look at them); without it the
/// test only checks that every screen draws to a non-empty image.
@MainActor
final class AndroidSetupRenderTests: XCTestCase {
    /// `ImageRenderer` draws AppKit-backed controls (prominent buttons, the
    /// linear progress bar, link buttons) as yellow "prohibited" boxes, so the
    /// view is laid out in an offscreen, never-shown window and its backing
    /// store is captured instead.
    private func render<V: View>(_ view: V, name: String, dark: Bool) throws {
        let framed = view
            .padding(24)
            .frame(width: 520)
            .background(Color(nsColor: .textBackgroundColor))
        let hosting = NSHostingView(rootView: framed)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.appearance = appearance
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds), name)
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        XCTAssertGreaterThan(size.height, 100, name)
        guard let dir = ProcessInfo.processInfo.environment["DHP_RENDER_DIR"], !dir.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }

    private func model() -> AndroidSetupModel {
        AndroidSetupModel(
            preferences: AppPreferences(defaults: .scratch()),
            environment: [:],
            studioIsInstalled: false
        )
    }

    func testTheReadyCardDraws() throws {
        for dark in [false, true] {
            try render(AndroidReadyCard(), name: "ready-card", dark: dark)
        }
    }

    func testEveryScreenOfTheSetupCardDraws() throws {
        for dark in [false, true] {
            let idle = model()
            try render(AndroidSetupView(model: idle), name: "setup-idle", dark: dark)

            let refused = model()
            refused.showForPreview(
                phase: .idle,
                locateError: "Downloads has no platform-tools folder with adb in it. Choose the SDK folder itself, or install the tools with Install Android Tools."
            )
            try render(AndroidSetupView(model: refused), name: "setup-locate-error", dark: dark)

            let java = model()
            java.showForPreview(phase: .needsJava)
            try render(AndroidSetupView(model: java), name: "setup-needs-java", dark: dark)

            let running = model()
            running.showForPreview(
                phase: .installing,
                progress: .init(step: .installingEmulator, fraction: 0.42, detail: "42 %"),
                completed: [.downloadingCommandLineTools, .installingPlatformTools]
            )
            try render(AndroidSetupView(model: running), name: "setup-installing", dark: dark)

            let downloading = model()
            downloading.showForPreview(
                phase: .installing,
                progress: .init(step: .downloadingCommandLineTools, fraction: 0.31, detail: "48 MB of 155 MB")
            )
            try render(AndroidSetupView(model: downloading), name: "setup-downloading", dark: dark)

            let license = model()
            license.showForPreview(phase: .awaitingLicense(SDKLicensePrompt(text: """
                Terms and Conditions

                This is the Android Software Development Kit License Agreement.

                1. Introduction

                1.1 The Android Software Development Kit (referred to in the License Agreement as the "SDK" and specifically including the Android system files, packaged APIs, and Google APIs add-ons) is licensed to you subject to the terms of the License Agreement.
                """)))
            try render(AndroidSetupView(model: license), name: "setup-license", dark: dark)

            let failed = model()
            failed.showForPreview(phase: .failed("The download failed: The Internet connection appears to be offline."))
            try render(AndroidSetupView(model: failed), name: "setup-failed", dark: dark)

            let done = model()
            done.showForPreview(phase: .finished)
            try render(AndroidSetupView(model: done), name: "setup-finished", dark: dark)

            try render(AndroidSetupView(model: model(), placement: .sheet), name: "setup-sheet", dark: dark)
        }
    }

    func testTheSidebarHintCardsDraw() throws {
        for dark in [false, true] {
            let card = VStack(alignment: .leading, spacing: 4) {
                Text("Android").font(.system(size: ParityMetrics.sidebarHeaderFontSize)).foregroundStyle(.secondary)
                SidebarHintCard(
                    symbol: "smartphone",
                    message: "Android devices and emulators need Google\u{2019}s Android tools.",
                    actionTitle: "Set Up\u{2026}",
                    action: {},
                    dismiss: {}
                )
                Text("iOS").font(.system(size: ParityMetrics.sidebarHeaderFontSize)).foregroundStyle(.secondary)
                SidebarHintCard(
                    symbol: "iphone",
                    message: "iOS simulators and iPhones need Xcode.",
                    actionTitle: "Get Xcode\u{2026}",
                    action: {},
                    dismiss: {}
                )
                SidebarHintCard(
                    symbol: "iphone",
                    message: AppleToolchain.XcodeGuidance.notSelected(
                        xcodeName: "Xcode", app: URL(fileURLWithPath: "/Applications/Xcode.app")
                    ).message,
                    actionTitle: "Open Xcode\u{2026}",
                    action: {},
                    dismiss: {}
                )
            }
            .frame(width: 300)
            try render(card, name: "sidebar-cards", dark: dark)
        }
    }
}
