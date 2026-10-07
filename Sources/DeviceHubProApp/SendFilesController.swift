import AppKit
import Foundation
import Observation
import DeviceHubProKit

/// Send Files: any file or folder from the Mac
/// to a device, by drag and drop onto the stage or a device's sidebar row, or
/// from the Send Files… panel. Apps still install (APK, `.app`, `.ipa`),
/// links still open, and everything else is copied where the platform has a
/// place for it: an Android device's shared storage (`adb push` + media
/// scan), an iOS simulator's Photos / Files / an app's Documents, a physical
/// iPhone's app container (`devicectl device copy to`).
///
/// One per `DeviceWorkspace`. It owns only the routing, the remembered
/// destinations and the copy itself; installs, media imports, certificates and
/// links go through the controllers that already do them.
@MainActor
@Observable
final class SendFilesController {
    /// The device a send is aimed at.
    enum Target: Equatable {
        case android(serial: String)
        case simulator(udid: String)
        case physical(udid: String)
    }

    /// One row of the panel's destination popup.
    struct Entry: Equatable {
        let id: String
        let title: String
    }

    /// What the panel's popup offers for a target.
    struct Choices: Equatable {
        let label: String
        let entries: [Entry]
        let selectedID: String
        /// Android only: the last entry is "Other folder…" with a text field.
        let allowsCustomFolder: Bool
        let customFolder: String
    }

    /// What the panel answered.
    struct PanelResult {
        let urls: [URL]
        let selectedID: String
        let customFolder: String
    }

    /// A send is running (one at a time per window).
    private(set) var isSending = false
    /// The Android push in flight, which Cancel Transfer ends (its partial
    /// file is removed from the device).
    @ObservationIgnored private var transferTask: Task<AndroidPushResult, any Error>?
    private(set) var canCancel = false

    /// Ends the Android push in flight: adb is stopped and the file it was
    /// writing is deleted from the device.
    func cancelTransfer() {
        transferTask?.cancel()
    }

    @ObservationIgnored private let adbClient: AdbClient?
    @ObservationIgnored private let simulators: SimulatorInventory
    @ObservationIgnored private let inventory: ApplePhysicalInventory
    @ObservationIgnored private let status: StatusCenter
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let apps: AppsController
    @ObservationIgnored private let simulatorApps: SimulatorAppsController
    @ObservationIgnored private let physicalApps: PhysicalAppsController

    /// The panel (the real one; a test's recorder).
    @ObservationIgnored var runPanel: @MainActor (_ choices: Choices, _ target: Target) -> PanelResult? = { choices, target in
        SendFilesPanel.run(choices: choices, target: target)
    }
    /// The question that picks a physical iPhone's app (the real alert; a test's answer).
    @ObservationIgnored var chooseApp: @MainActor (_ apps: [Entry], _ device: String) -> Entry? = { apps, device in
        SendFilesPanel.chooseApp(apps, device: device)
    }

    /// The question that picks the app a `.apns` file without a
    /// `Simulator Target Bundle` goes to (the real alert; a test's answer).
    @ObservationIgnored var choosePushApp: @MainActor (_ apps: [Entry], _ file: String, _ device: String) -> Entry? = { apps, file, device in
        SendFilesPanel.choosePushApp(apps, file: file, device: device)
    }

    static let androidKey = "sendFiles.androidDestination"
    static let simulatorKey = "sendFiles.simulatorDestination"
    static let simulatorAppNameKey = "sendFiles.simulatorAppName"
    static let physicalAppPrefix = "sendFiles.physicalApp."
    static let physicalAppNamePrefix = "sendFiles.physicalAppName."

    init(
        adbClient: AdbClient?,
        simulators: SimulatorInventory,
        inventory: ApplePhysicalInventory,
        status: StatusCenter,
        defaults: UserDefaults,
        apps: AppsController,
        simulatorApps: SimulatorAppsController,
        physicalApps: PhysicalAppsController
    ) {
        self.adbClient = adbClient
        self.simulators = simulators
        self.inventory = inventory
        self.status = status
        self.defaults = defaults
        self.apps = apps
        self.simulatorApps = simulatorApps
        self.physicalApps = physicalApps
    }

    // MARK: - Remembered destinations

    var androidDestination: AndroidSendDestination {
        get { AndroidSendDestination.from(storedValue: defaults.string(forKey: Self.androidKey)) ?? .downloads }
        set { defaults.set(newValue.storedValue, forKey: Self.androidKey) }
    }

    var simulatorDestination: SimulatorFilesDestination {
        get { SimulatorFilesDestination.from(storedValue: defaults.string(forKey: Self.simulatorKey)) ?? .filesApp }
        set { defaults.set(newValue.storedValue, forKey: Self.simulatorKey) }
    }

    private func physicalApp(udid: String) -> Entry? {
        let key = PhysicalDeviceOptIn.normalize(udid)
        guard let id = defaults.string(forKey: Self.physicalAppPrefix + key), !id.isEmpty else { return nil }
        return Entry(id: id, title: defaults.string(forKey: Self.physicalAppNamePrefix + key) ?? id)
    }

    private func rememberPhysicalApp(_ entry: Entry, udid: String) {
        let key = PhysicalDeviceOptIn.normalize(udid)
        defaults.set(entry.id, forKey: Self.physicalAppPrefix + key)
        defaults.set(entry.title, forKey: Self.physicalAppNamePrefix + key)
    }

    // MARK: - The overlay's words

    /// What dropping `urls` on `target` will do, for the drop overlay.
    func overlayText(for urls: [URL], target: Target) -> String {
        let summaryTarget: SendFilesTarget
        switch target {
        case .android:
            summaryTarget = .android(destination: androidDestination)
        case .simulator:
            let destination = simulatorDestination
            summaryTarget = .simulator(
                filesDestination: destination,
                filesAppName: defaults.string(forKey: Self.simulatorAppNameKey)
            )
        case .physical(let udid):
            summaryTarget = .physical(appName: physicalApp(udid: udid)?.title)
        }
        return SendFilesSummary.describe(urls, target: summaryTarget) { file in
            (try? SimulatorPushFile.read(file))?.bundleIdentifier
        }
    }

    // MARK: - The panel

    /// Asks which files (and where) and sends them: "Send Files…".
    func presentPanel(for target: Target, confirmCertificates: @escaping @MainActor ([URL]) -> Void = { _ in }) async {
        guard !isSending else {
            status.flash("Wait for the current transfer to finish")
            return
        }
        guard let choices = await choices(for: target) else { return }
        guard let result = runPanel(choices, target) else { return }
        await send(
            result.urls,
            to: target,
            choiceID: result.selectedID,
            customFolder: result.customFolder,
            confirmCertificates: confirmCertificates
        )
    }

    /// The popup the panel shows for `target`; nil after saying why in the
    /// status line when the device cannot take files.
    func choices(for target: Target) async -> Choices? {
        switch target {
        case .android:
            var entries = AndroidSendDestination.presets.map { Entry(id: $0.storedValue, title: $0.title) }
            let current = androidDestination
            var customText = ""
            if case .custom(let path) = current { customText = path }
            entries.append(Entry(id: Self.customID, title: "Other Folder…"))
            return Choices(
                label: "Put files in:",
                entries: entries,
                selectedID: { if case .custom = current { Self.customID } else { current.storedValue } }(),
                allowsCustomFolder: true,
                customFolder: customText
            )
        case .simulator(let udid):
            var entries = [Entry(id: SimulatorFilesDestination.filesApp.storedValue, title: "Files (On My iPhone)")]
            if let simctl = simulators.simctl,
               let listed = try? await simctl.listApps(udid: udid) {
                entries += listed.filter(\.isUserApp)
                    .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                    .map { Entry(id: SimulatorFilesDestination.appDocuments(bundleIdentifier: $0.bundleIdentifier).storedValue, title: "\($0.title) — Documents") }
            }
            lastEntries = entries
            let current = simulatorDestination.storedValue
            return Choices(
                label: "Other files go to:",
                entries: entries,
                selectedID: entries.contains { $0.id == current } ? current : entries[0].id,
                allowsCustomFolder: false,
                customFolder: ""
            )
        case .physical(let udid):
            guard let entries = await physicalAppEntries(udid: udid), !entries.isEmpty else { return nil }
            lastPhysicalEntries = entries
            let remembered = physicalApp(udid: udid)?.id
            return Choices(
                label: "Copy files into:",
                entries: entries,
                selectedID: entries.contains { $0.id == remembered } ? remembered! : entries[0].id,
                allowsCustomFolder: false,
                customFolder: ""
            )
        }
    }

    static let customID = "custom"

    /// The apps of the iPhone whose data container devicectl can write
    /// (development builds); nil after saying why when none can be listed.
    private func physicalAppEntries(udid: String) async -> [Entry]? {
        guard let client = await inventory.client(for: udid) else {
            status.errorMessage = "The iPhone is not available: enable it, pair it and connect it first."
            return nil
        }
        do {
            let listed = try await client.apps().value.apps
            let entries = listed.filter { $0.containerAccessible == true }
                .map { Entry(id: $0.bundleIdentifier, title: ($0.name?.isEmpty == false ? $0.name! : $0.bundleIdentifier)) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            if entries.isEmpty {
                status.errorMessage = "No app on this iPhone shares its Documents folder: only development builds do. Install a development build first."
                return nil
            }
            return entries
        } catch {
            status.errorMessage = "Could not list the iPhone's apps: \(ApplePhysicalController.describe(error))"
            return nil
        }
    }

    // MARK: - Sending

    /// Sends `urls` to `target`. `choiceID` and `customFolder` carry the
    /// panel's destination (remembered); a drop passes none and uses the
    /// remembered one.
    func send(
        _ urls: [URL],
        to target: Target,
        choiceID: String? = nil,
        customFolder: String = "",
        confirmCertificates: @escaping @MainActor ([URL]) -> Void = { _ in }
    ) async {
        guard !urls.isEmpty else { return }
        switch target {
        case .android(let serial):
            if let choiceID {
                guard let destination = Self.androidDestination(id: choiceID, custom: customFolder) else {
                    status.errorMessage = "“\(customFolder)” is not a folder on the device's shared storage. Use a path such as Download/Test."
                    return
                }
                androidDestination = destination
            }
            await sendToAndroid(urls, serial: serial)
        case .simulator(let udid):
            if let choiceID, let destination = SimulatorFilesDestination.from(storedValue: choiceID) {
                simulatorDestination = destination
                defaults.set(choiceID.hasPrefix("app:") ? choiceName(choiceID) : nil, forKey: Self.simulatorAppNameKey)
            }
            await sendToSimulator(urls, udid: udid, confirmCertificates: confirmCertificates)
        case .physical(let udid):
            await sendToPhysical(urls, udid: udid, chosenID: choiceID)
        }
    }

    static func androidDestination(id: String, custom: String) -> AndroidSendDestination? {
        if id == customID {
            return AndroidSendDestination.normalize(custom: custom).map(AndroidSendDestination.custom)
        }
        return AndroidSendDestination.from(storedValue: id)
    }

    /// The title the panel showed for an app destination's id, kept for the overlay.
    @ObservationIgnored private var lastEntries: [Entry] = []
    private func choiceName(_ id: String) -> String? {
        lastEntries.first { $0.id == id }?.title.replacingOccurrences(of: " — Documents", with: "")
    }

    // MARK: Android

    private func sendToAndroid(_ urls: [URL], serial: String) async {
        // A push payload is no file to keep: simctl's push has no Android twin.
        let pushes = urls.filter(SimulatorPushFile.isPushFile)
        var urls = urls
        if !pushes.isEmpty {
            urls.removeAll(where: SimulatorPushFile.isPushFile)
            status.errorMessage = SendFilesSummary.androidPushNote + "."
        }
        for route in AndroidSendRouting.route(urls) {
            switch route {
            case .install(let url):
                await apps.installAPK(at: url, serial: serial)
            case .push(let items):
                await push(items, serial: serial)
            }
        }
    }

    private func push(_ items: [URL], serial: String) async {
        guard let adbClient else {
            status.errorMessage = "Android tools are missing. Open Settings \u{25B8} Android to set them up."
            return
        }
        guard !isSending else {
            status.flash("Wait for the current transfer to finish")
            return
        }
        isSending = true
        let destination = androidDestination
        let progress = items.count == 1
            ? "Sending \(items[0].lastPathComponent) to \(destination.title)…"
            : "Sending \(items.count) items to \(destination.title)…"
        status.showProgress(progress)
        defer {
            isSending = false
            status.clear(ifShowing: progress)
        }
        let task = Task { try await adbClient.send(items, to: destination, serial: serial) }
        transferTask = task
        canCancel = true
        defer {
            transferTask = nil
            canCancel = false
        }
        do {
            let result = try await task.value
            let files = result.filesPushed == 1 ? "1 file" : "\(result.filesPushed) files"
            status.flash("Sent \(files) to \(result.destination)", seconds: 3)
        } catch is CancellationError {
            status.flash("Transfer cancelled", seconds: 3)
        } catch {
            status.errorMessage = "Could not send \(Self.names(items)) to \(destination.title): \(Self.reason(error))"
        }
    }

    // MARK: Simulator

    private func sendToSimulator(_ urls: [URL], udid: String, confirmCertificates: @escaping @MainActor ([URL]) -> Void) async {
        let plan = SimulatorSendRouting.plan(urls)
        if !plan.existing.isEmpty {
            await simulatorApps.handleDrop(plan.existing, udid: udid, confirmCertificates: confirmCertificates)
        }
        if !plan.pushes.isEmpty {
            await sendPushes(plan.pushes, udid: udid)
        }
        guard !plan.files.isEmpty else { return }
        guard let simctl = simulators.simctl else {
            status.errorMessage = "Xcode\u{2019}s simulator tools are missing. Install Xcode and open it once."
            return
        }
        guard !isSending else {
            status.flash("Wait for the current transfer to finish")
            return
        }
        isSending = true
        let destination = simulatorDestination
        let place: String
        switch destination {
        case .filesApp: place = "Files"
        case .appDocuments: place = defaults.string(forKey: Self.simulatorAppNameKey) ?? "the app"
        }
        let progress = "Copying \(Self.names(plan.files)) to \(place)…"
        status.showProgress(progress)
        defer {
            isSending = false
            status.clear(ifShowing: progress)
        }
        do {
            let folder: URL
            switch destination {
            case .filesApp:
                folder = try await simctl.filesAppStorage(udid: udid)
            case .appDocuments(let bundleIdentifier):
                folder = try await simctl.appDocumentsFolder(udid: udid, bundleIdentifier: bundleIdentifier)
            }
            let files = plan.files
            let copied = try await Task.detached { try SimctlClient.copyItems(files, into: folder) }.value
            status.flash("Copied \(copied == 1 ? "1 item" : "\(copied) items") to \(place)", seconds: 3)
        } catch {
            status.errorMessage = "Could not copy \(Self.names(plan.files)) to \(place): \(Self.reason(error))"
        }
    }

    /// Sends each `.apns` file to its app with `simctl push`, in order. The app
    /// is the payload's `Simulator Target Bundle`; a file without one asks
    /// (once for the drop: the answer serves the other files without a key).
    /// A file that cannot be sent does not stop the others; the first
    /// problem is the one shown.
    private func sendPushes(_ files: [URL], udid: String) async {
        guard let simctl = simulators.simctl else {
            status.errorMessage = "Xcode\u{2019}s simulator tools are missing. Install Xcode and open it once."
            return
        }
        guard !isSending else {
            status.flash("Wait for the current transfer to finish")
            return
        }
        isSending = true
        defer { isSending = false }
        var problem: String?
        var sentTo: [String] = []
        var picked: Entry?
        var skipUnnamed = false
        var progress: String?
        var installed: [Entry]?
        for file in files {
            let name = file.lastPathComponent
            let parsed: SimulatorPushFile
            do {
                parsed = try SimulatorPushFile.read(file)
            } catch {
                problem = problem ?? "\(error)"
                continue
            }
            var bundle = parsed.bundleIdentifier
            if bundle == nil {
                if picked == nil, !skipUnnamed {
                    if installed == nil {
                        let listed = (try? await simctl.listApps(udid: udid)) ?? []
                        installed = listed.sorted {
                            if $0.isUserApp != $1.isUserApp { return $0.isUserApp }
                            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                        }.map { Entry(id: $0.bundleIdentifier, title: "\($0.title) (\($0.bundleIdentifier))") }
                    }
                    if let entries = installed, !entries.isEmpty {
                        picked = choosePushApp(entries, name, simulators.entry(udid: udid)?.name ?? "this simulator")
                    } else {
                        problem = problem ?? "“\(name)” names no \"\(SimulatorPushFile.targetBundleKey)\" and the simulator lists no app to choose."
                    }
                    if picked == nil { skipUnnamed = true }
                }
                bundle = picked?.id
            }
            guard let bundle else { continue }
            let message = "Sending push \(name) to \(bundle)…"
            status.showProgress(message)
            progress = message
            do {
                try await simctl.push(udid: udid, bundleIdentifier: bundle, file: file)
                sentTo.append(bundle)
            } catch let failure as SimctlFailure where failure.isPushNotAuthorized {
                // iOS drops it unless the app is in front; simctl accepted it.
                sentTo.append(bundle)
                problem = problem ?? "\(bundle) never asked to post notifications, so iOS may not show “\(name)”; the app still receives it while it is in front."
            } catch {
                problem = problem ?? "Could not send “\(name)” to \(bundle): \(Self.reason(error))"
            }
        }
        status.clear(ifShowing: progress)
        if let problem {
            status.errorMessage = problem
        } else if !sentTo.isEmpty {
            status.flash(files.count == 1 ? "Sent push notification to \(sentTo[0])" : "Sent \(sentTo.count) push notifications", seconds: 3)
        }
    }

    // MARK: Physical iPhone

    private func sendToPhysical(_ urls: [URL], udid: String, chosenID: String?) async {
        let plan = PhysicalSendRouting.plan(urls)
        if !plan.unsupported.isEmpty {
            status.errorMessage = PhysicalSendRouting.unsupportedNote + "."
        }
        if !plan.existing.isEmpty {
            await physicalApps.handleDrop(plan.existing, udid: udid)
        }
        guard !plan.files.isEmpty else { return }
        guard let client = await inventory.client(for: udid) else {
            status.errorMessage = "The iPhone is not available: enable it, pair it and connect it first."
            return
        }
        // The app: the panel's choice, else the remembered one, else ask.
        var app: Entry?
        if let chosenID, let remembered = lastPhysicalEntries.first(where: { $0.id == chosenID }) {
            app = remembered
        } else if let chosenID {
            app = Entry(id: chosenID, title: chosenID)
        } else {
            app = physicalApp(udid: udid)
        }
        if app == nil {
            guard let entries = await physicalAppEntries(udid: udid) else { return }
            app = chooseApp(entries, inventory.entry(udid: udid)?.name ?? "this iPhone")
        }
        guard let app else { return }
        rememberPhysicalApp(app, udid: udid)
        guard !isSending else {
            status.flash("Wait for the current transfer to finish")
            return
        }
        isSending = true
        let progress = "Copying \(Self.names(plan.files)) into \(app.title)…"
        status.showProgress(progress)
        defer {
            isSending = false
            status.clear(ifShowing: progress)
        }
        var copied = 0
        for item in plan.files {
            do {
                _ = try await client.copyTo(
                    source: item,
                    bundleID: app.id,
                    destination: PhysicalSendRouting.containerPath(for: item)
                )
                copied += 1
            } catch {
                status.errorMessage = "Could not copy \(item.lastPathComponent) into \(app.title): \(ApplePhysicalController.describe(error))"
                return
            }
        }
        status.flash("Copied \(copied == 1 ? "1 item" : "\(copied) items") into \(app.title)’s Documents", seconds: 3)
    }

    @ObservationIgnored private var lastPhysicalEntries: [Entry] = []

    // MARK: - Words

    static func names(_ urls: [URL]) -> String {
        urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items"
    }

    static func reason(_ error: Error) -> String {
        if case AdbError.commandFailed(_, _, let message) = error, !message.isEmpty { return message }
        if let failure = error as? SimctlFailure { return failure.leadingLines.first ?? "\(failure)" }
        return "\(error)"
    }
}
