import Foundation

/// Device Hub's per-device "..." menu: Start, or Stop /
/// Shut Down while running, then Show in Finder and Rename…, then Reset
/// Content and Settings…, then Remove…, each behind its own separator.
///
/// Pure data — computed here so the enablement is unit-testable without
/// SwiftUI — that the toolbar's overflow menu renders from. It dispatches to
/// the very actions `DeviceSidebarView`'s row context menu already uses
/// (`AppModel.startAndMirror`/`stopEmulator`/`revealAVDInFinder`,
/// `AvdActionDialogs`, `SimulatorLifecycleController`,
/// `SimulatorInventory.deviceFolder`, `SimulatorActionDialogs`): this is a
/// second surface for the same operations, not a second implementation of
/// them.
enum ToolbarDeviceMenu {
    /// One item's title and whether it is enabled.
    struct Item: Equatable {
        let title: String
        var isEnabled = true
    }

    /// An item that cannot work on the selection is nil: not listed (no disabled placeholders). Disabled items are only the ones
    /// a busy or running device turns off for a while.
    struct Section: Equatable {
        let lifecycle: Item?
        /// A running simulator's Restart, in a section of its own between
        /// the lifecycle item and Show in Finder (measured live against
        /// Device Hub 27.0: Shut Down │ Restart │ Show in Finder, Rename… │
        /// Reset… │ Remove…). Absent while stopped: the stopped menu
        /// has no Restart row at all.
        var restart: Item?
        let showInFinder: Item?
        let rename: Item?
        let reset: Item?
        let remove: Item?

        /// Whether no item applies (nothing to pop up: the "..." button is not shown).
        var isEmpty: Bool {
            lifecycle == nil && restart == nil && showInFinder == nil && rename == nil && reset == nil && remove == nil
        }

        /// An adb device, a Pixel catalog entry with no AVD yet, or nothing
        /// selected: none of the items apply to a device we did not create.
        /// Device Hub shows its menu dimmed there; here the "..." button is not shown.
        static let unavailable = Section(
            lifecycle: nil, showInFinder: nil, rename: nil, reset: nil, remove: nil
        )
    }

    /// An AVD row's section. `isBusy` mirrors the sidebar's own guard on a
    /// second Start while one is already in flight (`AppModel.isBusy`); the
    /// file actions are off while the AVD runs, like the sidebar's.
    static func avdSection(isRunning: Bool, isBusy: Bool) -> Section {
        Section(
            lifecycle: Item(title: isRunning ? "Shut Down" : "Start", isEnabled: isRunning || !isBusy),
            showInFinder: Item(title: "Show in Finder"),
            rename: Item(title: "Rename…", isEnabled: !isRunning),
            reset: Item(title: "Reset Content and Settings…", isEnabled: !isRunning),
            remove: Item(title: "Remove…", isEnabled: !isRunning)
        )
    }

    /// A simulator row's section. `isFree` mirrors the sidebar's own guard
    /// (no operation in flight, or a boot still waiting to be ready); an
    /// unavailable runtime (S1's Unavailable section) cannot Start or Reset.
    static func simulatorSection(isRunning: Bool, isFree: Bool, isAvailable: Bool) -> Section {
        Section(
            // A simulator whose runtime is missing can neither start nor be erased.
            lifecycle: isAvailable
                ? Item(title: isRunning ? "Shut Down" : "Start", isEnabled: isRunning ? isFree : true)
                : nil,
            restart: isRunning ? Item(title: "Restart", isEnabled: isFree) : nil,
            showInFinder: Item(title: "Show in Finder"),
            rename: Item(title: "Rename…", isEnabled: isFree),
            reset: isAvailable ? Item(title: "Reset Content and Settings…", isEnabled: isFree) : nil,
            remove: Item(title: "Remove…", isEnabled: isFree)
        )
    }
}
