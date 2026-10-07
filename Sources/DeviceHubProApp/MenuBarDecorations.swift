import AppKit
import SwiftUI

/// What SwiftUI's `CommandMenu` cannot express: the Option alternate of Shut
/// Down (Device Hub's `Force Shut Down`, shown in its place while Option is
/// held). Applied while the Device menu is built and by the app delegate's
/// watchdog, so a menu SwiftUI rebuilt is decorated again before it is seen.
enum DeviceMenuAlternates {
    static let forceShutDownTitle = "Force Shut Down"
    static let shutDownTitle = "Shut Down"
}

@MainActor
enum MenuBarDecorations {
    /// Decorates the Device menu whenever SwiftUI adds an item to it.
    static func observeAddedItems() {
        NotificationCenter.default.addObserver(
            forName: NSMenu.didAddItemNotification, object: nil, queue: .main
        ) { note in
            let title = (note.object as? NSMenu)?.title
            MainActor.assumeIsolated {
                guard title == "Device" || title == "File" else { return }
                apply(to: NSApp.mainMenu)
            }
        }
    }

    static func apply(to mainMenu: NSMenu?) {
        if let device = mainMenu?.items.first(where: { $0.title == "Device" })?.submenu {
            makeForceShutDownAlternate(in: device)
        }
        if let file = mainMenu?.items.first(where: { $0.title == "File" })?.submenu {
            makeCloseAllItem(in: file)
        }
    }

    /// Device Hub's File menu lists Close All as its own item on ⇧⌘W. The
    /// system's is the Option alternate of Close (⌥⌘W), and AppKit puts that
    /// back every time the menu is validated (a converted item did not
    /// stick), so the system item is hidden and an item of ours, which
    /// nothing validates into an alternate, takes its place. SwiftUI may
    /// rebuild the menu; this runs on every add, on tracking and on the
    /// watchdog.
    private static func makeCloseAllItem(in menu: NSMenu) {
        for item in menu.items where item.title == "Close All" && item !== closeAllItem && !item.isHidden {
            item.isHidden = true
        }
        guard !menu.items.contains(where: { $0 === closeAllItem }),
              let close = menu.items.first(where: { $0.title == "Close" && $0.keyEquivalent == "w" })
        else { return }
        menu.insertItem(closeAllItem, at: menu.index(of: close) + 1)
    }

    private static let closeAllTarget = CloseAllTarget()
    private static let closeAllItem: NSMenuItem = {
        let item = NSMenuItem(title: "Close All", action: #selector(CloseAllTarget.closeAll), keyEquivalent: "w")
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = closeAllTarget
        return item
    }()

    /// Force Shut Down follows Shut Down and shows in its place while Option
    /// is held (Device Hub's `[⌥` item).
    private static func makeForceShutDownAlternate(in menu: NSMenu) {
        guard let force = menu.items.first(where: { $0.title == DeviceMenuAlternates.forceShutDownTitle }),
              let index = menu.items.firstIndex(of: force), index > 0,
              menu.items[index - 1].title == DeviceMenuAlternates.shutDownTitle
        else { return }
        // An alternate pairs with the item above only when both carry the same
        // key: Shut Down's ⌘. makes this one ⌥⌘.
        let shutDown = menu.items[index - 1]
        let mask = shutDown.keyEquivalentModifierMask.union(.option)
        if !force.isAlternate || force.keyEquivalent != shutDown.keyEquivalent || force.keyEquivalentModifierMask != mask {
            force.keyEquivalent = shutDown.keyEquivalent
            force.keyEquivalentModifierMask = mask
            force.isAlternate = true
        }
    }
}

/// A menu whose row carries an SF Symbol, as every submenu of Device Hub's
/// Device menu does.
struct IconMenu<Content: View>: View {
    let title: String
    let symbol: String
    let isDisabled: Bool
    @ViewBuilder let content: () -> Content

    init(_ title: String, _ symbol: String, disabled: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.symbol = symbol
        self.isDisabled = disabled
        self.content = content
    }

    var body: some View {
        Menu {
            content()
        } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
        }
        .disabled(isDisabled)
    }
}

/// Close All's action: closes every window that can close, as the system's
/// does.
@MainActor
private final class CloseAllTarget: NSObject, NSMenuItemValidation {
    @objc func closeAll() {
        for window in NSApp.windows where window.isVisible && window.styleMask.contains(.closable) {
            window.performClose(nil)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.closable) }
    }
}
