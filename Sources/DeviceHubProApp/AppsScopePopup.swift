import AppKit
import ObjectiveC
import SwiftUI

/// The scope cell at the right of every Apps tab's filter capsule (Android,
/// simulator, physical iPhone): the current scope's title with the up/down
/// chevrons, and a menu of the scopes under it.
///
/// It is a plain `Button` over the whole cell that pops an `NSMenu`. The
/// earlier cell overlaid a borderless SwiftUI `Menu` with a `Color.clear`
/// label: SwiftUI sized the underlying popup button to that empty label (6 x 14
/// pt, measured in a hosted view), ignoring the `.frame` and `.contentShape`
/// put on it, so only a 6 pt spot in the middle of the cell opened the menu.
struct AppsScopePopup<Scope: Hashable>: View {
    /// One menu section; sections are separated by a divider.
    struct Section {
        let items: [(title: String, value: Scope)]
    }

    let title: String
    let sections: [Section]
    @Binding var selection: Scope

    var body: some View {
        Button(action: present) {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: ParityMetrics.inspectorAppsFilterFontSize))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .frame(maxWidth: ParityMetrics.inspectorAppsScopeLabelWidth, alignment: .leading)
            .padding(.leading, ParityMetrics.inspectorAppsScopeLeading)
            .padding(.trailing, ParityMetrics.inspectorAppsScopeTrailing)
            .frame(
                width: ParityMetrics.inspectorAppsScopeWidth,
                height: ParityMetrics.inspectorAppsFilterHeight,
                alignment: .leading
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    @MainActor func present() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let target = MenuTarget(selection: $selection)
        for (index, section) in sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for (title, value) in section.items {
                let item = NSMenuItem(title: title, action: #selector(MenuTarget.pick(_:)), keyEquivalent: "")
                item.target = target
                item.representedObject = value
                item.state = value == selection ? .on : .off
                menu.addItem(item)
            }
        }
        // The menu keeps its target alive through the item's weak reference
        // only while it is shown, which is the whole call.
        // `NSApp` is nil until an application exists (a test that opens the
        // popup on its own): no event, no anchor.
        let event = NSApp?.currentEvent
        let view = event?.window?.contentView
        let location = event?.locationInWindow ?? .zero
        // `NSMenuItem.target` is weak: the menu owns it.
        objc_setAssociatedObject(menu, &menuTargetKey, target, .OBJC_ASSOCIATION_RETAIN)
        AppsScopePresenter.present(menu, location, view)
    }

    private final class MenuTarget: NSObject {
        let selection: Binding<Scope>
        init(selection: Binding<Scope>) { self.selection = selection }
        @objc func pick(_ sender: NSMenuItem) {
            if let value = sender.representedObject as? Scope { selection.wrappedValue = value }
        }
    }
}

private nonisolated(unsafe) var menuTargetKey = 0

/// Shows the menu for a click at a location in a view. Tests replace it (a real
/// pop-up menu runs its own event loop).
@MainActor
enum AppsScopePresenter {
    static var present: (NSMenu, NSPoint, NSView?) -> Void = { menu, location, view in
        menu.popUp(positioning: nil, at: location, in: view)
    }
}

/// The Apps list's empty state: why nothing shows, and, when a narrower scope
/// is the reason, a button that widens it to All Apps.
struct AppsEmptyState: View {
    let message: String
    /// Switches the scope to All Apps; nil when the scope is not the cause.
    let showAll: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Text(message)
                .foregroundStyle(.secondary)
            if let showAll {
                Button("Show All Apps", action: showAll)
                    .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}
