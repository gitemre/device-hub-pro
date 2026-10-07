import AppKit
import SwiftUI
import DeviceHubProKit

/// The Log focus mode's list: an `NSTableView` of drawn rows (time, level
/// badge, tag, message in one monospaced line each), because a SwiftUI list
/// of thousands of long lines re-lays out every row on each reload. Rows are
/// plain `draw(_:)` cells, the geometry is arithmetic (the font is
/// monospaced), a row is one line with a horizontal scroll or wraps by
/// character, and the tail follows until the user scrolls away.
struct LogTableView: NSViewRepresentable {
    let entries: [LogcatEntry]
    let revision: Int
    let wrap: Bool
    let jumpToken: Int
    let isFollowing: Bool
    @Binding var selection: Set<UInt64>
    let onUserScroll: (Bool) -> Void
    let onCopy: ([LogcatEntry]) -> Void

    func makeCoordinator() -> LogTableCoordinator { LogTableCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let table = LogNSTableView()
        let column = NSTableColumn(identifier: .init("log"))
        column.minWidth = 10
        column.maxWidth = 1_000_000
        column.resizingMask = []
        table.addTableColumn(column)
        table.headerView = nil
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.intercellSpacing = .zero
        table.rowHeight = LogRowMetrics.rowHeight(lines: 1)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.usesAutomaticRowHeights = false
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.dataSource = coordinator
        table.delegate = coordinator
        table.setAccessibilityLabel("Log entries")
        table.onCopy = { [weak coordinator] in coordinator?.copySelection() }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        coordinator.attach(scroll: scroll, table: table)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onUserScroll = onUserScroll
        coordinator.onCopy = onCopy
        coordinator.selectionBinding = $selection
        coordinator.update(
            entries: entries,
            revision: revision,
            wrap: wrap,
            jumpToken: jumpToken,
            isFollowing: isFollowing,
            selection: selection
        )
    }
}

/// An `NSTableView` that copies the selected rows on ⌘C.
final class LogNSTableView: NSTableView {
    var onCopy: (() -> Void)?

    @objc func copy(_ sender: Any?) { onCopy?() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedRow >= 0 }
        return super.validateUserInterfaceItem(item)
    }
}

@MainActor
final class LogTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private weak var scroll: NSScrollView?
    private weak var table: LogNSTableView?
    private var entries: [LogcatEntry] = []
    private var revision = -1
    private var wrap = false
    private var jumpToken = 0
    private var isFollowing = true
    private var maxMessageColumns = 0
    private var isProgrammatic = false
    private var isApplyingSelection = false
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    var onUserScroll: (Bool) -> Void = { _ in }
    var onCopy: ([LogcatEntry]) -> Void = { _ in }
    var selectionBinding: Binding<Set<UInt64>>?

    static let charWidth: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: LogRowMetrics.fontSize, weight: .regular)
        return ("M" as NSString).size(withAttributes: [.font: font]).width
    }()

    func attach(scroll: NSScrollView, table: LogNSTableView) {
        self.scroll = scroll
        self.table = table
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.clipBoundsChanged() } })
        observers.append(center.addObserver(
            forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.clipFrameChanged() } })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Updates

    func update(
        entries: [LogcatEntry],
        revision: Int,
        wrap: Bool,
        jumpToken: Int,
        isFollowing: Bool,
        selection: Set<UInt64>
    ) {
        guard let scroll, let table else { return }
        let wrapChanged = wrap != self.wrap
        let jumped = jumpToken != self.jumpToken
        self.isFollowing = isFollowing
        self.jumpToken = jumpToken
        self.wrap = wrap

        if revision != self.revision || wrapChanged {
            reload(entries: entries, table: table, scroll: scroll)
            self.revision = revision
        }
        applySelection(selection, to: table)
        if jumped || isFollowing { scrollToBottom() }
    }

    private func reload(entries newEntries: [LogcatEntry], table: NSTableView, scroll: NSScrollView) {
        // Keep the top visible row where it is when the user reads history.
        let anchor: (id: UInt64, offset: CGFloat)? = {
            guard !isFollowing, !entries.isEmpty else { return nil }
            let clip = scroll.contentView.bounds
            let row = table.row(at: NSPoint(x: 0, y: clip.minY))
            guard row >= 0, row < entries.count else { return nil }
            return (entries[row].id, clip.minY - table.rect(ofRow: row).minY)
        }()

        isProgrammatic = true
        entries = newEntries
        maxMessageColumns = newEntries.reduce(0) { max($0, Self.displayColumns(of: $1)) }
        layoutColumn()
        table.reloadData()
        if let anchor, let index = newEntries.firstIndex(where: { $0.id == anchor.id }) {
            let y = table.rect(ofRow: index).minY + anchor.offset
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        isProgrammatic = false
    }

    private func applySelection(_ selection: Set<UInt64>, to table: NSTableView) {
        let wanted = IndexSet(entries.indices.filter { selection.contains(entries[$0].id) })
        guard wanted != table.selectedRowIndexes else { return }
        isApplyingSelection = true
        table.selectRowIndexes(wanted, byExtendingSelection: false)
        isApplyingSelection = false
    }

    private func scrollToBottom() {
        guard let scroll, let table else { return }
        let clip = scroll.contentView
        let target = max(0, table.frame.height - clip.bounds.height)
        guard abs(clip.bounds.minY - target) > 0.5 else { return }
        isProgrammatic = true
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
        scroll.reflectScrolledClipView(clip)
        isProgrammatic = false
    }

    // MARK: - Geometry

    private static let leftInset: CGFloat = 10
    private static let timeColumns = 12
    private static let levelWidth: CGFloat = 18
    private static let tagWidth: CGFloat = 150
    private static let gap: CGFloat = 8
    private static let rightInset: CGFloat = 12

    static var messageX: CGFloat {
        leftInset + CGFloat(timeColumns) * charWidth + gap + levelWidth + gap + tagWidth + gap
    }

    static func displayColumns(of entry: LogcatEntry) -> Int {
        entry.message.count + (entry.subsystem.isEmpty ? 0 : entry.subsystem.count + 2)
    }

    private var clipWidth: CGFloat { scroll?.contentView.bounds.width ?? 0 }

    /// Characters per line when wrapping.
    private var wrapColumns: Int {
        max(8, Int((clipWidth - Self.messageX - Self.rightInset) / Self.charWidth))
    }

    private func layoutColumn() {
        guard let column = table?.tableColumns.first else { return }
        if wrap {
            column.width = max(clipWidth, 200)
        } else {
            let content = Self.messageX + CGFloat(maxMessageColumns) * Self.charWidth + Self.rightInset
            column.width = max(clipWidth, content)
        }
    }

    private func clipFrameChanged() {
        guard let table else { return }
        let previous = table.tableColumns.first?.width ?? 0
        layoutColumn()
        if wrap, table.tableColumns.first?.width != previous {
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<entries.count))
        }
        // A shorter or taller pane (the detail strip opening) keeps the
        // tail in view.
        if isFollowing { scrollToBottom() }
    }

    private func clipBoundsChanged() {
        guard !isProgrammatic, let scroll, let table else { return }
        let clip = scroll.contentView.bounds
        let atBottom = clip.maxY >= table.frame.height - 4
        onUserScroll(atBottom)
    }

    // MARK: - Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard wrap, row < entries.count else { return LogRowMetrics.rowHeight(lines: 1) }
        let entry = entries[row]
        let text = LogRowCell.messageString(entry)
        return LogRowMetrics.rowHeight(lines: LogRowMetrics.wrappedLineCount(of: text, columns: wrapColumns))
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("logRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? LogRowCell) ?? {
            let cell = LogRowCell()
            cell.identifier = id
            return cell
        }()
        cell.configure(entry: entries[row], wrap: wrap)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection, let table else { return }
        let ids = Set(table.selectedRowIndexes.compactMap { $0 < entries.count ? entries[$0].id : nil })
        DispatchQueue.main.async { [weak self] in self?.selectionBinding?.wrappedValue = ids }
    }

    func copySelection() {
        guard let table else { return }
        let rows = table.selectedRowIndexes.filter { $0 < entries.count }.map { entries[$0] }
        guard !rows.isEmpty else { return }
        onCopy(rows)
    }
}

/// One drawn log row: time, level badge, tag and message.
final class LogRowCell: NSTableCellView {
    private var entry: LogcatEntry?
    private var wrap = false

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { needsDisplay = true }
    }
    override var isFlipped: Bool { true }

    func configure(entry: LogcatEntry, wrap: Bool) {
        self.entry = entry
        self.wrap = wrap
        needsDisplay = true
    }

    /// What the message column shows: the message and, for a simulator's
    /// event, its subsystem after it.
    static func messageString(_ entry: LogcatEntry) -> String {
        entry.subsystem.isEmpty ? entry.message : entry.message + "  " + entry.subsystem
    }

    static let font = NSFont.monospacedSystemFont(ofSize: LogRowMetrics.fontSize, weight: .regular)
    private static let badgeFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)

    static func levelColor(_ level: LogcatLevel) -> NSColor {
        switch level {
        case .verbose: return .systemGray
        case .debug: return .systemBlue
        case .info: return .systemGreen
        case .warning: return .systemOrange
        case .error: return .systemRed
        case .fatal: return .systemPurple
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let entry else { return }
        let emphasized = backgroundStyle == .emphasized
        let primary: NSColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
        let secondary: NSColor = emphasized ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
        let tertiary: NSColor = emphasized ? .alternateSelectedControlTextColor.withAlphaComponent(0.65) : .tertiaryLabelColor

        if !emphasized {
            if entry.isCrash {
                NSColor.systemRed.withAlphaComponent(0.16).setFill()
                bounds.fill()
            } else if entry.level.severity >= LogcatLevel.error.severity {
                NSColor.systemRed.withAlphaComponent(0.07).setFill()
                bounds.fill()
            } else if entry.level == .warning {
                NSColor.systemOrange.withAlphaComponent(0.06).setFill()
                bounds.fill()
            }
        }

        let line = NSMutableParagraphStyle()
        line.minimumLineHeight = LogRowMetrics.lineHeight
        line.maximumLineHeight = LogRowMetrics.lineHeight
        line.lineBreakMode = .byClipping
        let top = LogRowMetrics.verticalPadding
        let cw = LogTableCoordinator.charWidth

        // Time: the clock part of "MM-dd HH:mm:ss.SSS".
        let time: String = {
            guard let space = entry.timestamp.firstIndex(of: " ") else { return entry.timestamp }
            return String(entry.timestamp[entry.timestamp.index(after: space)...])
        }()
        var x: CGFloat = 10
        (time as NSString).draw(
            in: NSRect(x: x, y: top, width: CGFloat(12) * cw + 2, height: LogRowMetrics.lineHeight),
            withAttributes: [.font: Self.font, .foregroundColor: secondary, .paragraphStyle: line]
        )
        x += CGFloat(12) * cw + 8

        // Level badge.
        let badge = NSRect(x: x, y: top + 0.5, width: 18, height: LogRowMetrics.lineHeight - 1)
        let badgeColor = emphasized ? NSColor.white.withAlphaComponent(0.28) : Self.levelColor(entry.level)
        badgeColor.setFill()
        NSBezierPath(roundedRect: badge, xRadius: 3.5, yRadius: 3.5).fill()
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        (entry.level.rawValue as NSString).draw(
            in: NSRect(x: badge.minX, y: badge.minY + 0.5, width: badge.width, height: badge.height),
            withAttributes: [.font: Self.badgeFont, .foregroundColor: NSColor.white, .paragraphStyle: center]
        )
        x += 18 + 8

        // Tag (process), truncated at the column's end.
        let tagStyle = NSMutableParagraphStyle()
        tagStyle.lineBreakMode = .byTruncatingTail
        tagStyle.minimumLineHeight = LogRowMetrics.lineHeight
        tagStyle.maximumLineHeight = LogRowMetrics.lineHeight
        (entry.tag as NSString).draw(
            in: NSRect(x: x, y: top, width: 150, height: LogRowMetrics.lineHeight),
            withAttributes: [
                .font: Self.font,
                .foregroundColor: emphasized ? primary : NSColor.systemTeal,
                .paragraphStyle: tagStyle,
            ]
        )
        x = LogTableCoordinator.messageX

        // Message.
        let message = NSMutableParagraphStyle()
        message.minimumLineHeight = LogRowMetrics.lineHeight
        message.maximumLineHeight = LogRowMetrics.lineHeight
        message.lineBreakMode = wrap ? .byCharWrapping : .byClipping
        var text = entry.message
        if !wrap { text = text.replacingOccurrences(of: "\n", with: " ⏎ ") }
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: Self.font, .foregroundColor: primary, .paragraphStyle: message]
        )
        if !entry.subsystem.isEmpty {
            attributed.append(NSAttributedString(
                string: "  " + entry.subsystem,
                attributes: [.font: Self.font, .foregroundColor: tertiary, .paragraphStyle: message]
            ))
        }
        let width = wrap ? max(bounds.width - x - 12, 40) : 1_000_000
        let height = wrap ? bounds.height - top : LogRowMetrics.lineHeight
        attributed.draw(
            with: NSRect(x: x, y: top, width: width, height: height),
            options: [.usesLineFragmentOrigin]
        )
    }
}
