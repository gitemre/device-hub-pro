import SwiftUI
import DeviceHubProKit

/// The confirmations and the rename and Open URL sheets behind a simulator
/// row's menu (the `AvdActionDialogs` pattern). Owned by the main window's
/// content, so the sidebar and the stage drive the same dialogs; the
/// operations are the lifecycle controller's.
///
/// Device Hub Pro never erases or deletes a simulator without asking (design
/// §3.8). The wording follows Device Hub's (its reset and remove
/// confirmations), in the app's own words. Uninstalling an app and trusting
/// a drop's root certificates are asked here too (the Apps inspector and the
/// stage's drop). A drop's certificates are asked about together, and a
/// drop that arrives while a question shows waits its turn
/// (`requestTrust`): nothing dropped is lost to a question already open.
@MainActor
@Observable
final class SimulatorActionDialogs {
    enum Confirmation: Equatable {
        /// Reset Content and Settings; `isRunning` says it restarts after.
        case erase(udid: String, name: String, isRunning: Bool)
        case delete(udid: String, name: String)
        /// An app on a simulator.
        case uninstallApp(udid: String, bundleIdentifier: String, name: String)
        /// The root certificates of one drop on a simulator's stage
        /// (`simulator` is its name), asked about together.
        case trustCertificates(udid: String, simulator: String, certificates: [URL])
        /// The Settings panel's Data ▸ Keychain.
        case resetKeychain(udid: String, name: String)
        /// The Settings panel's Reset to Defaults; `items` are what it puts back.
        case resetDefaults(udid: String, name: String, items: [String])

        var udid: String {
            switch self {
            case .erase(let udid, _, _), .delete(let udid, _), .uninstallApp(let udid, _, _),
                 .trustCertificates(let udid, _, _), .resetKeychain(let udid, _), .resetDefaults(let udid, _, _): udid
            }
        }

        var title: String {
            switch self {
            case .erase(_, let name, _): "Reset content and settings on \(dhQuoted(name))?"
            case .delete(_, let name): "Remove \(name)?"
            case .uninstallApp(_, _, let name): "Uninstall \(dhQuoted(name))?"
            case .trustCertificates(_, let simulator, let certificates) where certificates.count == 1:
                "Trust \"\(certificates[0].lastPathComponent)\" as a root certificate on \"\(simulator)\"?"
            case .trustCertificates(_, let simulator, let certificates):
                "Trust \(certificates.count) root certificates on \"\(simulator)\"?"
            case .resetKeychain(_, let name): "Reset the keychain on \(dhQuoted(name))?"
            case .resetDefaults(_, let name, _): "Reset the settings of \(dhQuoted(name)) to their defaults?"
            }
        }

        var message: String {
            switch self {
            case .erase(_, _, let isRunning):
                isRunning
                    ? "All apps, data, and settings on this simulator will be permanently deleted, and the simulator will restart. You can\u{2019}t undo this action."
                    : "All apps, data, and settings on this simulator will be permanently deleted. You can\u{2019}t undo this action."
            case .delete(_, let name):
                "Removing \(name) will delete this simulator and make it unavailable as a run destination in Xcode."
            case .uninstallApp(_, let bundleIdentifier, let name):
                "\"\(name)\" (\(bundleIdentifier)) and its data are removed from the simulator."
            case .trustCertificates(_, _, let certificates) where certificates.count == 1:
                "Safari and every app on the simulator will trust the websites and servers this certificate "
                    + "vouches for, until the simulator's content and settings are reset. Trust only a "
                    + "certificate you made or know."
            case .trustCertificates(_, _, let certificates):
                Self.quotedList(certificates.map(\.lastPathComponent)) + ": Safari and every app on the "
                    + "simulator will trust the websites and servers these certificates vouch for, until the "
                    + "simulator's content and settings are reset. Trust only certificates you made or know."
            case .resetKeychain:
                "Keychain items, including saved logins, are removed from this simulator."
            case .resetDefaults(_, _, let items):
                "This puts back: " + items.joined(separator: "; ") + ". Apps, data and everything else stay."
            }
        }

        var confirmTitle: String {
            switch self {
            case .erase: "Reset"
            case .delete: "Remove"
            case .uninstallApp: "Uninstall"
            case .trustCertificates: "Trust"
            case .resetKeychain, .resetDefaults: "Reset"
            }
        }

        /// Device Hub's alert for the question: Remove is a plain blue
        /// answer, Reset Content and Settings a red one under the caution
        /// triangle with "Don't Reset" beside it.
        var alertSpec: DHAlertSpec {
            switch self {
            case .erase:
                DHAlertSpec(title: title, message: message, confirmTitle: confirmTitle,
                            cancelTitle: "Don\u{2019}t Reset", style: .caution)
            case .delete:
                DHAlertSpec(title: title, message: message, confirmTitle: confirmTitle, style: .plain)
            case .uninstallApp:
                DHAlertSpec(title: title, message: message, confirmTitle: confirmTitle, style: .destructive)
            case .trustCertificates:
                DHAlertSpec(title: title, message: message, confirmTitle: confirmTitle, style: .plain)
            case .resetKeychain:
                DHAlertSpec(title: title, message: message, confirmTitle: confirmTitle, style: .destructive)
            case .resetDefaults:
                DHAlertSpec(title: title, message: message, confirmTitle: confirmTitle, style: .plain)
            }
        }

        /// "\"a.pem\", \"b.pem\" and \"c.pem\"".
        private static func quotedList(_ names: [String]) -> String {
            let quoted = names.map { "\"\($0)\"" }
            guard let last = quoted.last, quoted.count > 1 else { return quoted.joined() }
            return quoted.dropLast().joined(separator: ", ") + " and " + last
        }
    }

    /// A simulator being renamed.
    struct RenameTarget: Equatable, Identifiable {
        let udid: String
        let name: String

        var id: String { udid }
    }

    /// A simulator a URL is being opened on.
    struct OpenURLTarget: Equatable, Identifiable {
        let udid: String
        let name: String

        var id: String { udid }
    }

    /// The question the alert shows.
    var confirmation: Confirmation?
    /// Drops' questions that arrived while another showed, in order.
    private(set) var queuedConfirmations: [Confirmation] = []
    var renameTarget: RenameTarget?
    var renameDraft = ""
    var openURLTarget: OpenURLTarget?
    /// Kept between sheets: deep-link testing opens variations of one URL.
    var openURLDraft = ""
    /// How long after an alert closes the next queued question shows: a new
    /// alert set in the same update as the closing one's dismissal would
    /// replace it rather than show.
    @ObservationIgnored var queuedConfirmationDelay: Duration = .milliseconds(350)
    @ObservationIgnored private var queuedPresentation: Task<Void, Never>?

    /// The Device menu's Open URL…: asks for a URL to open on `entry`.
    func requestOpenURL(_ entry: SimulatorEntry) {
        openURLTarget = OpenURLTarget(udid: entry.udid, name: entry.name)
    }

    /// Whether the URL draft can be opened: text with a scheme that is not a
    /// host file (`SimctlClient.readLink`; simctl hands the link to the app
    /// registered for its scheme). Text with a scheme that reads as no URL
    /// ("myapp://open page") is let through, as it was when the sheet handed
    /// simctl the text: Open then says why in the alert rather than staying
    /// off unexplained.
    var canOpenURL: Bool {
        switch SimctlClient.readLink(openURLDraft) {
        case .success, .failure(.unreadable): true
        case .failure(.noScheme), .failure(.hostFile): false
        }
    }

    func requestErase(_ entry: SimulatorEntry) {
        show(.erase(udid: entry.udid, name: entry.name, isRunning: entry.state == .booted || entry.state == .booting))
    }

    func requestDelete(_ entry: SimulatorEntry) {
        show(.delete(udid: entry.udid, name: entry.name))
    }

    func requestResetKeychain(udid: String, name: String) {
        show(.resetKeychain(udid: udid, name: name))
    }

    func requestResetDefaults(udid: String, name: String, items: [String]) {
        show(.resetDefaults(udid: udid, name: name, items: items))
    }

    func requestUninstall(_ app: SimulatorApp, udid: String) {
        show(.uninstallApp(udid: udid, bundleIdentifier: app.bundleIdentifier, name: app.title))
    }

    /// Asks about a drop's root certificates, all in one question. A drop
    /// arrives on its own, not from a click: while another question shows
    /// (or one just closed) it waits its turn instead of replacing it.
    func requestTrust(certificates: [URL], udid: String, simulator: String) {
        guard !certificates.isEmpty else { return }
        let question = Confirmation.trustCertificates(udid: udid, simulator: simulator, certificates: certificates)
        guard confirmation != question, !queuedConfirmations.contains(question) else { return }
        if confirmation == nil, queuedPresentation == nil {
            confirmation = question
        } else {
            queuedConfirmations.append(question)
        }
    }

    /// The shown question was answered or dismissed (the alert calls this
    /// from its buttons and its binding, so a second call does nothing): the
    /// next queued one shows after `queuedConfirmationDelay`.
    func finishConfirmation() {
        guard confirmation != nil else { return }
        confirmation = nil
        presentQueuedConfirmation()
    }

    /// A question the user asked for with a click (the row and Device menus,
    /// the Apps inspector) shows at once, as it always did. A drop's
    /// question it covers goes back to the front of the queue.
    private func show(_ question: Confirmation) {
        if let shown = confirmation, case .trustCertificates = shown, shown != question {
            queuedConfirmations.insert(shown, at: 0)
        }
        confirmation = question
    }

    private func presentQueuedConfirmation() {
        guard !queuedConfirmations.isEmpty, queuedPresentation == nil else { return }
        queuedPresentation = Task { [weak self, queuedConfirmationDelay] in
            try? await Task.sleep(for: queuedConfirmationDelay)
            guard let self else { return }
            self.queuedPresentation = nil
            guard self.confirmation == nil, !self.queuedConfirmations.isEmpty else { return }
            self.confirmation = self.queuedConfirmations.removeFirst()
        }
    }

    func requestRename(_ entry: SimulatorEntry) {
        renameDraft = entry.name
        renameTarget = RenameTarget(udid: entry.udid, name: entry.name)
    }

    /// Whether the draft can be applied: a name that is not empty and is
    /// not the current one (simctl allows any other, duplicates included,
    /// as Device Hub does).
    var canRename: Bool {
        guard let renameTarget else { return false }
        let draft = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !draft.isEmpty && draft != renameTarget.name
    }
}

/// Presents `SimulatorActionDialogs` over the main window: the destructive
/// confirmations as alerts; the Open URL and the new-simulator sheets as
/// sheets. Rename is not presented here: the sidebar row edits the name in
/// place (`renameTarget` is the row being edited).
struct SimulatorActionDialogsHost: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Bindable var dialogs: SimulatorActionDialogs

    func body(content: Content) -> some View {
        content
            .dhAlert(
                item: dialogs.confirmation,
                spec: { $0.alertSpec },
                resolve: { confirmation, confirmed in
                    dialogs.finishConfirmation()
                    guard confirmed else { return }
                    let lifecycle = model.simulatorLifecycle
                    switch confirmation {
                    case .erase(let udid, _, _):
                        Task { await lifecycle.erase(udid) }
                    case .delete(let udid, _):
                        Task { await lifecycle.delete(udid) }
                    case .uninstallApp(let udid, let bundleIdentifier, let name):
                        Task { await workspace.simulatorApps.uninstall(bundleIdentifier: bundleIdentifier, name: name, udid: udid) }
                    case .trustCertificates(let udid, _, let certificates):
                        Task { await workspace.simulatorApps.trustRootCertificates(certificates, udid: udid) }
                    case .resetKeychain(let udid, _):
                        Task { await workspace.simulatorApps.resetKeychain(udid: udid) }
                    case .resetDefaults(let udid, _, _):
                        let osVersion = model.simulators.entry(udid: udid)?.osVersion
                        Task { await workspace.appleControls.resetToDefaults(osVersion: osVersion) }
                    }
                }
            )
            .sheet(item: Binding(
                get: { workspace.window.simulatorCreateFamily },
                set: { workspace.window.simulatorCreateFamily = $0 }
            )) { family in
                SimulatorCreateSheet(family: family)
                    .environment(model)
            }
            .sheet(item: $dialogs.openURLTarget) { target in
                SimulatorOpenURLSheet(target: target)
                    .environment(model)
                    .environment(workspace)
                    .environment(dialogs)
            }
    }
}

/// Opens a URL on a simulator (`simctl openurl`): a web page in Safari, or a
/// deep link in the app registered for its scheme. The recent links are the
/// ones Android's Links row keeps (`RecentLinkStore`), so one deep link is
/// tried on both platforms.
private struct SimulatorOpenURLSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(SimulatorActionDialogs.self) private var dialogs
    let target: SimulatorActionDialogs.OpenURLTarget

    var body: some View {
        @Bindable var dialogs = dialogs
        let recents = workspace.links.recents.links

        DHSheet(
            title: "Open URL on \(dhQuoted(target.name))",
            width: 470,
            actions: [
                DHSheetAction(title: "Open", isEnabled: dialogs.canOpenURL, isDefault: true) {
                    let url = dialogs.openURLDraft
                    dialogs.openURLTarget = nil
                    Task { await workspace.simulatorApps.openURL(url, udid: target.udid) }
                },
            ]
        ) {
            DHSheetCard {
                DHSheetRow(title: "URL:") {
                    HStack(spacing: 6) {
                        DHSheetTextField(
                            placeholder: "https://example.com or myapp://path",
                            text: $dialogs.openURLDraft,
                            width: 250
                        )
                        SavedLinksControl(draft: $dialogs.openURLDraft)
                        Menu {
                            // Titled and drawn as the Links row's Recent popup.
                            ForEach(recents, id: \.self) { link in
                                Button(LinksRowText.recentTitle(link)) { dialogs.openURLDraft = link }
                            }
                            Divider()
                            Button("Clear Recents") { workspace.links.recents.clear() }
                        } label: {
                            Image(systemName: LinksRowText.recentGlyph)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(recents.isEmpty)
                        .help("Recent URLs")
                        .accessibilityLabel("Recent URLs")
                    }
                }
            }
        }
    }
}
