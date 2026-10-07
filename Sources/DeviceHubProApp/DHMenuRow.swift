import AppKit
import SwiftUI

/// One entry of a Settings pop-up's menu.
enum DHMenuEntry: Identifiable {
    case item(id: String, title: String, isSelected: Bool = false, isEnabled: Bool = true, action: () -> Void)
    case separator(id: String)
    /// A dimmed section title ("Trips" in Device Hub's Location menu).
    case header(id: String, title: String)

    var id: String {
        switch self {
        case .item(let id, _, _, _, _), .separator(let id), .header(let id, _): id
        }
    }
}

/// Device Hub's Settings pop-up: the row (glyph, label, value and the round
/// chevron) is drawn like `DHPopupRow`'s, and clicking it opens a real
/// `NSMenu`, positioned as a pop-up button's is (the checked item over the
/// value), which is what Device Hub's `AXPopUpButton` rows do (measured on
/// Device Hub 27.0, 2026-09-29: `inspector-dh-location-menu-2026-09-28.png`,
/// `inspector-dh-color-filter-menu-2026-09-28.png`). The Location menu's sections and separators,
/// "Trips" header and check marks are the menu's own drawing.
///
/// Reached from the keyboard (Space, Return, ↓) and by VoiceOver, which sees a
/// pop-up button (`accessibilityRepresentation`).
struct DHMenuRow: View {
    let title: String
    var glyph: String?
    var help: String = ""
    let valueText: String
    /// The menu's entries, asked when the menu opens (a row's list can be
    /// read then, the Mac's audio devices for one).
    let entries: () -> [DHMenuEntry]

    @State private var isPresented = false
    @State private var isHovered = false
    @State private var valueFrame: CGRect = .zero
    @State private var anchor = DHMenuAnchor()
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            if let glyph {
                Image(systemName: glyph)
                    .accessibilityHidden(true)
                    .font(.system(size: ParityMetrics.controlsGlyphFontSize))
                    .foregroundStyle(.secondary)
                    .frame(width: ParityMetrics.controlsGlyphFrame)
                    .padding(.leading, ParityMetrics.controlsGlyphLeading)
                Text(title)
                    .font(.system(size: ParityMetrics.controlsLabelFontSize))
                    .lineLimit(1)
                    .padding(.leading, ParityMetrics.controlsLabelGap)
            } else {
                Text(title)
                    .font(.system(size: ParityMetrics.controlsLabelFontSize))
                    .lineLimit(1)
                    .padding(.leading, ParityMetrics.controlsGlyphLeading)
            }
            Spacer(minLength: ParityMetrics.controlsPopupTitleGap)
            DHPopupValueLabel(text: valueText, isHighlighted: isHovered || isPresented, truncationMode: .tail)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { valueFrame = $0 }
        }
        // DH's popup rows sit 1.5 pt above the row's centre (a toggle's or a
        // slider's are centred; measured on 27.0, 2026-09-29).
        .padding(.bottom, ParityMetrics.controlsPopupRowLift * 2)
        .frame(height: ParityMetrics.controlsRowHeight)
        .padding(.trailing, ParityMetrics.controlsTrailingInset)
        .coordinateSpace(name: Self.space)
        .background(DHMenuAnchorView(anchor: anchor))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { present() }
        .focusable(interactions: .activate)
        .onKeyActivation([.space, .return, .downArrow]) {
            guard isEnabled else { return .ignored }
            present()
            return .handled
        }
        .accessibilityRepresentation {
            Picker(title, selection: pickerSelection) {
                ForEach(entries()) { entry in
                    if case .item(let id, let itemTitle, _, let itemEnabled, _) = entry {
                        Text(itemTitle).tag(Optional(id)).disabled(!itemEnabled)
                    }
                }
            }
            .pickerStyle(.menu)
            // The menu picker exposes only its value otherwise.
            .accessibilityLabel(title)
        }
        .dhTooltip(help)
    }

    private static let space = "dhMenuRow"

    private var pickerSelection: Binding<String?> {
        Binding(
            get: {
                for case .item(let id, _, true, _, _) in entries() { return id }
                return nil
            },
            set: { chosen in
                for case .item(let id, _, _, _, let action) in entries() where id == chosen { action() }
            }
        )
    }

    private func present() {
        guard isEnabled, !isPresented, let view = anchor.view else { return }
        isPresented = true
        defer { isPresented = false }
        let menu = NSMenu()
        menu.autoenablesItems = false
        var chosen: NSMenuItem?
        for entry in entries() {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .header(_, let headerTitle):
                menu.addItem(NSMenuItem.sectionHeader(title: headerTitle))
            case .item(_, let itemTitle, let isSelected, let itemEnabled, let action):
                let item = NSMenuItem(title: itemTitle, action: #selector(DHMenuTarget.fire(_:)), keyEquivalent: "")
                let target = DHMenuTarget(action)
                item.target = target
                item.representedObject = target
                item.isEnabled = itemEnabled
                item.state = isSelected ? .on : .off
                menu.addItem(item)
                if isSelected, chosen == nil { chosen = item }
            }
        }
        // The item that shows in the value sits over the value, as a pop-up
        // button's menu does.
        let point = NSPoint(x: valueFrame.minX, y: valueFrame.midY)
        menu.popUp(positioning: chosen, at: point, in: view)
    }
}

/// The menu item's action: runs a closure. Kept alive by the item's
/// `representedObject` while the menu tracks.
@MainActor
private final class DHMenuTarget: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func fire(_ sender: NSMenuItem) {
        action()
    }
}

/// The row's own `NSView`, in SwiftUI's top-left coordinates, which
/// `NSMenu.popUp` positions against.
@MainActor
final class DHMenuAnchor {
    weak var view: NSView?
}

private struct DHMenuAnchorView: NSViewRepresentable {
    let anchor: DHMenuAnchor

    final class FlippedView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView {
        let view = FlippedView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}
