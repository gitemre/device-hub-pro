import SwiftUI
import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// Draws the sidebar's hint cards (Android tools, Xcode, iOS platform) at
/// the sidebar's widths, light and dark, standalone and inside a sidebar
/// `List` (where the real cards live). The PNGs land in `DHP_RENDER_DIR`
/// when it is set; the checks hold the text to its full height at every
/// width.
@MainActor
final class SidebarHintCardRenderTests: XCTestCase {
    private struct Card {
        let name: String
        let symbol: String
        let message: String
        let action: String
    }

    private let cards = [
        Card(name: "android", symbol: "smartphone",
             message: "Android devices and emulators need Google\u{2019}s Android tools.", action: "Set Up\u{2026}"),
        Card(name: "xcode-missing", symbol: "iphone",
             message: AppleToolchain.XcodeGuidance.notInstalled.message, action: "Get Xcode\u{2026}"),
        Card(name: "xcode-first-launch", symbol: "iphone",
             message: AppleToolchain.XcodeGuidance.finishInstalling(app: nil).message, action: "Open Xcode\u{2026}"),
        Card(name: "ios-platform", symbol: "iphone",
             message: DeviceSidebarView.platformCardMessage, action: DeviceSidebarView.platformCardActionTitle),
    ]

    private func hostingHeight<V: View>(_ view: V, width: CGFloat, dark: Bool, name: String) throws -> CGFloat {
        let framed = view.frame(width: width).background(Color(nsColor: .windowBackgroundColor))
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
        if let dir = ProcessInfo.processInfo.environment["DHP_RENDER_DIR"], !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return size.height
    }

    private func card(_ card: Card) -> some View {
        SidebarHintCard(symbol: card.symbol, message: card.message, actionTitle: card.action, action: {}, dismiss: {})
    }

    func testTheCardsGrowToTheirTextAtEverySidebarWidth() throws {
        for dark in [false, true] {
            for width in [200.0, 230.0, 280.0] {
                for item in cards {
                    let name = "hint-\(item.name)-\(Int(width))-\(dark ? "dark" : "light")"
                    let height = try hostingHeight(card(item), width: width, dark: dark, name: name)
                    // Icon + at least one text line + a button row.
                    XCTAssertGreaterThan(height, 60, name)
                }
            }
            // A narrower sidebar never makes a card shorter.
            let narrow = try hostingHeight(card(cards[3]), width: 200, dark: dark, name: "hint-probe-narrow")
            let wide = try hostingHeight(card(cards[3]), width: 280, dark: dark, name: "hint-probe-wide")
            XCTAssertGreaterThanOrEqual(narrow, wide)
        }
    }

    func testTheCardsInASidebarListDraw() throws {
        for dark in [false, true] {
            for width in [200.0, 230.0, 280.0] {
                let list = List {
                    ForEach(cards, id: \.name) { item in
                        Section {
                            self.card(item)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        } header: {
                            Text(item.name)
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(height: 900)
                let height = try hostingHeight(list, width: width, dark: dark, name: "hint-list-\(Int(width))-\(dark ? "dark" : "light")")
                XCTAssertGreaterThan(height, 100)
            }
        }
    }
}
