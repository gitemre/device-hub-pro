import AppKit
import Foundation
import DeviceHubProKit

/// The Send Files… panel: an open panel for files and folders (several at
/// once) with the destination popup as its accessory, and the question that
/// picks a physical iPhone's app.
@MainActor
enum SendFilesPanel {
    /// Runs the panel; nil when the user cancelled.
    static func run(choices: SendFilesController.Choices, target: SendFilesController.Target) -> SendFilesController.PanelResult? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.prompt = "Send"
        panel.message = message(for: target)

        let accessory = AccessoryView(choices: choices)
        panel.accessoryView = accessory.view
        panel.isAccessoryViewDisclosed = true

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return nil }
        return SendFilesController.PanelResult(
            urls: panel.urls,
            selectedID: accessory.selectedID,
            customFolder: accessory.customFolder
        )
    }

    static func message(for target: SendFilesController.Target) -> String {
        switch target {
        case .android: "Choose files or folders to send to the device. APKs are installed."
        case .simulator: "Choose files or folders to send to the simulator. Photos and videos go to Photos; apps are installed; .apns files are sent as push notifications."
        case .physical: "Choose files or folders to copy into an app on the iPhone. Photos can't be added to a physical iPhone."
        }
    }

    /// Asks which app of a physical iPhone gets the files.
    static func chooseApp(_ apps: [SendFilesController.Entry], device: String) -> SendFilesController.Entry? {
        let alert = NSAlert()
        alert.messageText = "Copy files into which app on \(device)?"
        alert.informativeText = "Files go into the app's Documents folder. Only development builds share their container."
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Cancel")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        popup.addItems(withTitles: apps.map(\.title))
        alert.accessoryView = popup
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let index = popup.indexOfSelectedItem
        return apps.indices.contains(index) ? apps[index] : nil
    }

    /// The question for a `.apns` file that names no app: which installed app
    /// gets the push.
    @MainActor
    static func choosePushApp(_ apps: [SendFilesController.Entry], file: String, device: String) -> SendFilesController.Entry? {
        let alert = NSAlert()
        alert.messageText = "Send “\(file)” to which app on \(device)?"
        alert.informativeText = "The file has no \"\(SimulatorPushFile.targetBundleKey)\" key, so the app is chosen here. It also serves the other push files in this drop that name no app."
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26), pullsDown: false)
        popup.addItems(withTitles: apps.map(\.title))
        alert.accessoryView = popup
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let index = popup.indexOfSelectedItem
        return apps.indices.contains(index) ? apps[index] : nil
    }

    /// The popup (and, for Android, the custom folder field) under the list.
    @MainActor
    final class AccessoryView: NSObject, NSTextFieldDelegate {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 64))
        private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        private let field = NSTextField()
        private let choices: SendFilesController.Choices

        init(choices: SendFilesController.Choices) {
            self.choices = choices
            super.init()
            let label = NSTextField(labelWithString: choices.label)
            label.frame = NSRect(x: 12, y: 36, width: 130, height: 18)
            popup.frame = NSRect(x: 146, y: 32, width: 262, height: 26)
            popup.addItems(withTitles: choices.entries.map(\.title))
            if let index = choices.entries.firstIndex(where: { $0.id == choices.selectedID }) {
                popup.selectItem(at: index)
            }
            popup.target = self
            popup.action = #selector(selectionChanged)
            view.addSubview(label)
            view.addSubview(popup)
            if choices.allowsCustomFolder {
                field.frame = NSRect(x: 146, y: 4, width: 262, height: 22)
                field.placeholderString = "Download/Test"
                field.stringValue = choices.customFolder
                view.addSubview(field)
            }
            selectionChanged()
        }

        @objc private func selectionChanged() {
            field.isEnabled = choices.allowsCustomFolder && selectedID == SendFilesController.customID
        }

        var selectedID: String {
            let index = popup.indexOfSelectedItem
            return choices.entries.indices.contains(index) ? choices.entries[index].id : choices.selectedID
        }

        var customFolder: String { field.stringValue }
    }
}
