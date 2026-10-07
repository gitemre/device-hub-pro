import AppKit

/// Device Hub's quit choice (A5) in the app menu: Quit (⌘Q) does what
/// Settings says with the simulators Device Hub Pro started, and its Option
/// alternate (⌥⌘Q) the other: "Quit and Shut Down Simulators Device Hub Pro
/// Started" or "Quit and Keep Simulators Running". A simulator Device Hub Pro did
/// not start is never shut down either way.
///
/// SwiftUI owns the main menu and may build it again, so the app delegate
/// installs the alternate at launch, whenever the menu bar starts tracking
/// and on its watchdog; `install` is idempotent.
@MainActor
enum SimulatorQuitMenu {
    /// The alternate item's identifier.
    static let identifier = NSUserInterfaceItemIdentifier("devicehubpro.quit-alternate")

    /// Puts the alternate for `alternate` right after `menu`'s Quit item
    /// (the one that sends `terminate:`), or brings the one there up to
    /// date: Quit's key with Option added, `isAlternate`, hidden when
    /// `isHidden` (a Mac without simulators). Returns it; nil when the menu
    /// has no Quit item.
    @discardableResult
    static func install(
        in menu: NSMenu,
        alternate: SimulatorLifecycleController.QuitChoice,
        isHidden: Bool,
        target: AnyObject,
        action: Selector
    ) -> NSMenuItem? {
        guard let quit = menu.items.first(where: { $0.action == #selector(NSApplication.terminate(_:)) }) else {
            return nil
        }
        let item: NSMenuItem
        if let existing = menu.items.first(where: { $0.identifier == identifier }) {
            item = existing
        } else {
            item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            item.identifier = identifier
        }
        // Right after Quit: an alternate must follow the item it replaces.
        let wanted = menu.index(of: quit) + 1
        if menu.index(of: item) != wanted {
            if item.menu != nil { menu.removeItem(item) }
            menu.insertItem(item, at: menu.index(of: quit) + 1)
        }
        if item.title != alternate.menuTitle { item.title = alternate.menuTitle }
        item.target = target
        item.action = action
        let key = quit.keyEquivalent.isEmpty ? "q" : quit.keyEquivalent
        if item.keyEquivalent != key { item.keyEquivalent = key }
        let modifiers = quit.keyEquivalentModifierMask.union(.option)
        if item.keyEquivalentModifierMask != modifiers { item.keyEquivalentModifierMask = modifiers }
        if !item.isAlternate { item.isAlternate = true }
        if item.isHidden != isHidden { item.isHidden = isHidden }
        return item
    }
}
