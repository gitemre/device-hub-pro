import DeviceHubProKit

/// The sidebar's multi-selection: the
/// device rows ⌘-click, ⇧-click, ⇧-arrow and Select All gather, kept apart
/// from the stage's single `DeviceSelection`, which stays the primary (the
/// row the stage shows, the last one clicked). Apply to Selected and
/// Screenshot All Selected act on these rows.
///
/// Rows, not `DeviceRef`s: an AVD is selected by name and a simulator by
/// UDID, both stable across boots, where an adb serial is only the running
/// emulator's and goes to whichever AVD boots next; a stopped AVD has no
/// serial at all, yet stays selected (and is skipped as not running).
/// `MultiDeviceController` resolves the rows to devices when an action
/// runs. Pixel catalog rows are not multi-selectable: a modified click
/// there selects it alone, as before.
///
/// Pure value semantics: every gesture returns the stage's new primary for
/// the caller to assign.
struct SidebarMultiSelection: Equatable {
    /// The selected rows, in the order they joined.
    private(set) var rows: [DeviceSelection] = []
    /// Where ⇧-click and ⇧-arrow extend from: the last row clicked without
    /// ⇧.
    private(set) var anchor: DeviceSelection?

    var count: Int { rows.count }
    var isMultiple: Bool { rows.count > 1 }

    func contains(_ row: DeviceSelection) -> Bool {
        rows.contains(row)
    }

    /// Whether a row takes part in multi-selection (the device sections'
    /// rows; not the Pixel catalog's, and not a physical Apple device, which
    /// is manage-only and never takes part in Apply to Selected).
    static func isMultiSelectable(_ row: DeviceSelection) -> Bool {
        switch row {
        case .pixel, .physicalApple: false
        case .avd, .device, .simulator: true
        }
    }

    /// A plain click, an arrow, or any selection made elsewhere: `row`
    /// alone, and the anchor.
    mutating func selectOnly(_ row: DeviceSelection?) {
        rows = row.map { [$0] } ?? []
        anchor = row
    }

    /// ⌘-click: adds `row` (it becomes the primary and the anchor) or
    /// removes it. The last selected row stays: removing it would leave the
    /// stage with nothing. A removed primary hands over to the row that
    /// joined last. Returns the new primary.
    mutating func toggle(_ row: DeviceSelection, primary: DeviceSelection?) -> DeviceSelection? {
        guard Self.isMultiSelectable(row) else {
            selectOnly(row)
            return row
        }
        adopt(primary)
        if let index = rows.firstIndex(of: row) {
            guard rows.count > 1 else { return primary }
            rows.remove(at: index)
            if anchor == row { anchor = rows.last }
            return primary == row ? rows.last : primary
        }
        rows.append(row)
        anchor = row
        return row
    }

    /// ⇧-click (or ⇧-arrow): the rows from the anchor to `row` in `order`
    /// (the visible rows), replacing the selection, or added to it with ⌘
    /// (`adding`). The anchor stays; `row` becomes the primary. Without an
    /// anchor in `order`, `row` alone.
    mutating func extend(
        to row: DeviceSelection,
        in order: [DeviceSelection],
        adding: Bool,
        primary: DeviceSelection?
    ) -> DeviceSelection {
        guard Self.isMultiSelectable(row) else {
            selectOnly(row)
            return row
        }
        adopt(primary)
        let selectable = order.filter(Self.isMultiSelectable)
        guard let anchor, let from = selectable.firstIndex(of: anchor), let to = selectable.firstIndex(of: row) else {
            selectOnly(row)
            return row
        }
        let range = Array(selectable[min(from, to)...max(from, to)])
        if adding {
            rows.append(contentsOf: range.filter { !rows.contains($0) })
        } else {
            rows = range
        }
        return row
    }

    /// Select All: every multi-selectable row of `order`; the primary stays
    /// when it is one of them, else the first becomes it. Returns the new
    /// primary.
    mutating func selectAll(_ order: [DeviceSelection], primary: DeviceSelection?) -> DeviceSelection? {
        let selectable = order.filter(Self.isMultiSelectable)
        guard !selectable.isEmpty else { return primary }
        rows = selectable
        if let primary, selectable.contains(primary) {
            if !(anchor.map(selectable.contains) ?? false) { anchor = primary }
            return primary
        }
        anchor = selectable.first
        return selectable.first
    }

    /// The stage's selection changed: a row outside the selection (set by an
    /// arrow, a start, a fix-up of a stale selection) replaces it; one
    /// inside keeps it.
    mutating func follow(primary: DeviceSelection?) {
        guard let primary else {
            selectOnly(nil)
            return
        }
        if !rows.contains(primary) { selectOnly(primary) }
    }

    /// Drops rows no longer listed (a removed simulator or AVD, an unplugged
    /// phone), keeping `primary`.
    mutating func prune(keeping listed: Set<DeviceSelection>, primary: DeviceSelection?) {
        let kept = rows.filter { listed.contains($0) || $0 == primary }
        guard kept != rows else { return }
        rows = kept
        if let anchor, !rows.contains(anchor) { self.anchor = rows.last }
    }

    /// Makes sure the gesture builds on the stage's primary: a selection
    /// the primary is not part of (never multi, or out of step) starts over
    /// from it; a Pixel primary leaves nothing selected.
    private mutating func adopt(_ primary: DeviceSelection?) {
        guard let primary else { return }
        // A Pixel row a plain click selected is in `rows` alone; it must not
        // stay there beside the rows a gesture adds.
        guard Self.isMultiSelectable(primary) else {
            rows = []
            anchor = nil
            return
        }
        guard !rows.contains(primary) else { return }
        rows = [primary]
        anchor = primary
    }
}
