import AppKit
import DeviceHubProKit

/// The two Apply to Selected items that need input before they run: the link
/// Open URL… opens and the builds Install Build… installs. Modal, like the
/// save panel Screenshot All Selected asks through.
@MainActor
enum BatchInputPanels {
    /// The link to open on every selected device; nil when cancelled or
    /// left empty. Each platform reads it its own way when it runs (adb's
    /// `am start`, simctl's `openurl`), so it is taken as typed.
    static func askForLink() -> String? {
        let alert = NSAlert()
        alert.messageText = "Open URL on Selected Devices"
        alert.informativeText = "Each device opens the link with the app that handles its scheme."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "URL or deep link"
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The builds to install, at most one per platform
    /// (`BatchBuildSelection`); nil when cancelled.
    static func chooseBuilds() -> Result<[BatchBuild], BatchBuildProblem>? {
        let panel = NSOpenPanel()
        panel.message = "Choose an Android build (.apk, .apks or a folder of split APKs), a simulator build (.app, .ipa or .zip), or one of each."
        panel.prompt = "Install"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        // An .app is chosen whole, not opened as a folder.
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK else { return nil }
        let files = panel.urls.map { url in
            (url: url, isDirectory: (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
        }
        return BatchBuildSelection.builds(from: files)
    }
}
