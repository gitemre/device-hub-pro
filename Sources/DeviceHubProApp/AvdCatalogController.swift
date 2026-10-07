import AppKit
import Foundation
import Observation
import DeviceHubProKit

/// The AVD gallery: the installed AVDs as cards with their skin artwork and
/// running state, the SDK's skin catalog, AVD creation with its options, and
/// the AVD file actions (Show in Finder, delete, rename, wipe).
///
/// `AppModel` owns one as `catalog`; the views and tests call it directly.
/// It holds no reference to the model: the current emulator, the adb snapshot's rows and their consoles'
/// AVD names, the refresh after a change on disk, and the selection of an
/// AVD a file action deleted or renamed go through the hooks below, which
/// the model sets once it is built.
@MainActor
@Observable
final class AvdCatalogController {
    var avds: [String] = []
    /// The AVD list was read at least once (an empty `avds` before that
    /// means "not known yet", not "no AVDs").
    var avdsLoaded = false
    /// Installed AVDs with their skin artwork and running state.
    var avdCards: [AvdCard] = []
    /// Every device skin in the SDK, for the catalog section.
    var skinCatalog: [SkinCatalogEntry] = []

    // MARK: - AVD creation

    var avdCreateStatus: AvdCreateStatus = .unknown
    var avdDevices: [AvdDevice] = []
    var systemImages: [SystemImage] = []
    var isCreatingAvd = false
    /// Each profile's minimum API, read once from the cmdline-tools jars and
    /// shared by the create sheet and the Pixel catalog; nil when the jars
    /// are missing (everything is then allowed).
    private(set) var minApiTable: PixelMinApiTable?
    @ObservationIgnored private var minApiLoad: Task<PixelMinApiTable?, Never>?

    private let status: StatusCenter

    /// The current emulator. Settings' custom binary path swaps it at run
    /// time, so it is asked for at every use and never kept. Nil (no
    /// emulator) until its owner sets it.
    @ObservationIgnored var emulatorManagerProvider: @MainActor () -> EmulatorManager? = { nil }
    /// The adb snapshot's real rows (no ghost), whose online emulators the
    /// cards take their serials from.
    @ObservationIgnored var realDevicesSource: @MainActor () -> [AndroidDevice] = { [] }
    /// AVD name → serial for the online emulators among `devices`, each
    /// console asked once per adb transport (`AppModel.resolveAvdSerials`).
    @ObservationIgnored var avdSerialsResolver: @MainActor (_ devices: [AndroidDevice]) async -> [String: String] = { _ in [:] }
    /// Re-reads the devices, the AVD list and the gallery after a create,
    /// delete or rename (`AppModel.refreshAndroid()`).
    @ObservationIgnored var refresh: @MainActor () async -> Void = {}
    /// A file action deleted (`replacement` nil) or renamed the AVD
    /// `avdName`: its owner, which alone writes the stage selection, moves a
    /// selection of that AVD to `replacement`.
    @ObservationIgnored var selectionFollowsAvd: @MainActor (_ avdName: String, _ replacement: DeviceSelection?) -> Void = { _, _ in }

    /// Each AVD's last reported display shapes (`MirrorController`'s
    /// library): a deleted AVD's are forgotten and a renamed one's follow
    /// it, so an AVD later given the old name does not draw the old
    /// device's screen corner.
    let displayShapes: DisplayShapeLibrary

    init(status: StatusCenter, displayShapes: DisplayShapeLibrary) {
        self.status = status
        self.displayShapes = displayShapes
    }

    // MARK: - Gallery

    /// Light hot-plug pass (spec §6.4): only the `ps`-based running-emulator
    /// half of `refreshGallery()` — no skin catalog scan — so externally
    /// killed or started VMs stop sticking `avdIsBooting` on a stale card.
    /// Serials are reconciled too: a stopped VM's serial is dropped (the next
    /// VM to boot reuses it) and a VM started outside the app gets its
    /// serial from its console.
    func refreshAvdRunningState() async {
        guard let emulatorManager else { return }
        // Best effort: a failed `ps` read keeps the cards' last running state.
        guard let running = try? await emulatorManager.runningEmulators() else { return }
        let names = Set(running.map(\.avd))
        let serials = await resolveAvdSerials(among: realDevices)
        avdCards = Self.reconcileAvdCards(avdCards, runningAVDNames: names, serialsByAvd: serials)
    }

    /// The running-state pass on the cards: a card whose VM is not running
    /// loses its serial; a running card takes the serial its console answered
    /// for, else keeps its own unless another AVD's console now claims it.
    static func reconcileAvdCards(
        _ cards: [AvdCard],
        runningAVDNames: Set<String>,
        serialsByAvd: [String: String]
    ) -> [AvdCard] {
        let claimed = Set(serialsByAvd.values)
        return cards.map { card in
            let isRunning = runningAVDNames.contains(card.name)
            var serial: String?
            if isRunning {
                if let answered = serialsByAvd[card.name] {
                    serial = answered
                } else if let own = card.serial, !claimed.contains(own) {
                    serial = own
                }
            }
            return AvdCard(
                name: card.name,
                displayName: card.displayName,
                target: card.target,
                skin: card.skin,
                isRunning: isRunning,
                serial: serial,
                hasHardwareKeyboard: card.hasHardwareKeyboard,
                formFactor: card.formFactor
            )
        }
    }

    /// Builds the gallery model: installed AVDs with resolved skins and
    /// running state, plus the full SDK skin catalog.
    func refreshGallery() async {
        let skinsDirectory = SkinLocator.skinsDirectory()
        if let skinsDirectory {
            // The catalog parses every skin layout in the SDK: off the main
            // actor, since refresh runs after every stop, delete and rename.
            skinCatalog = await Task.detached(priority: .userInitiated) {
                SkinResolver.catalog(skinsDirectory: skinsDirectory)
            }.value
        } else {
            skinCatalog = []
        }

        // No manager: nothing can be running. A failed or cancelled `ps` read
        // keeps each card's last running state instead of marking every AVD
        // stopped (same as `refreshAvdRunningState`).
        let running: [RunningEmulator]? = emulatorManager == nil
            ? []
            : try? await emulatorManager?.runningEmulators()
        let previousCards = Dictionary(avdCards.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        // One console question per online emulator (cached per transport),
        // not one per AVD × device.
        let serials = await resolveAvdSerials(among: realDevices)
        var cards: [AvdCard] = []
        for avd in avds {
            let skin = skinsDirectory.flatMap {
                SkinResolver.resolve(avdName: avd, skinsDirectory: $0)
            }
            let isRunning = running.map { $0.contains(where: { $0.avd == avd }) }
                ?? (previousCards[avd]?.isRunning ?? false)
            let avdSerial = isRunning ? (serials[avd] ?? (running == nil ? previousCards[avd]?.serial : nil)) : nil
            cards.append(
                AvdCard(
                    name: avd,
                    displayName: AvdConfig.displayName(avdName: avd),
                    target: AvdConfig.target(avdName: avd),
                    skin: skin,
                    isRunning: isRunning,
                    serial: avdSerial,
                    hasHardwareKeyboard: AvdConfig.hardwareKeyboard(avdName: avd) ?? true,
                    formFactor: AvdConfig.formFactor(avdName: avd)
                )
            )
        }
        avdCards = cards.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Forgets the table and its load, so the next `ensureMinApiTable()` reads
    /// the SDK again: called when the Android tools were just adopted.
    func resetMinApiTable() {
        minApiLoad = nil
        minApiTable = nil
    }

    /// Loads the minimum-API table once (concurrent callers share the one
    /// read) and returns it.
    @discardableResult
    func ensureMinApiTable() async -> PixelMinApiTable? {
        if let existing = minApiLoad {
            if let table = await existing.value { return table }
            // The read found nothing (no SDK yet, jars not installed): do not
            // cache that forever. The first waiter to see it clears the load;
            // a later call (or one that lost the race) reads again.
            guard minApiLoad == existing else { return await minApiLoad?.value }
            minApiLoad = nil
        }
        guard let root = AvdmanagerClient.sdkRoot() else { return nil }
        let task = Task { await PixelMinApiTable.load(sdkRoot: root) }
        minApiLoad = task
        minApiTable = await task.value
        return minApiTable
    }

    /// Loads the AVD creation prerequisites: installed system images (no
    /// Java needed) and the `avdmanager` device list (starts a JVM, so this
    /// runs lazily when the create sheet opens, not on every refresh).
    func refreshAvdCreateOptions() async {
        guard avdCreateStatus != .checking else { return }
        let previousStatus = avdCreateStatus
        avdCreateStatus = .checking
        // Never stays `.checking`: a cancelled check (the sheet closed) puts the
        // status back so the next open checks again.
        defer { if avdCreateStatus == .checking { avdCreateStatus = previousStatus == .checking ? .unknown : previousStatus } }

        if let root = AvdmanagerClient.sdkRoot() {
            systemImages = AvdmanagerClient.installedSystemImages(sdkRoot: root)
        } else {
            systemImages = []
        }

        guard let client = AvdmanagerClient.locate() else {
            avdCreateStatus = .missingAvdmanager
            return
        }
        guard await client.workingJava() != nil else {
            if Task.isCancelled { return }
            avdCreateStatus = .missingJava
            return
        }
        do {
            avdDevices = try await client.listDevices()
        } catch {
            if error.isCancellation { return }
            avdCreateStatus = .loadFailed("\(error)")
            return
        }
        // With sdkmanager available the sheet offers downloads, so an empty
        // installed list is not a dead end.
        if systemImages.isEmpty, SdkmanagerClient.locate() == nil {
            avdCreateStatus = .noSystemImages
            return
        }
        avdCreateStatus = .ready
    }

    /// Creates the AVD and refreshes the gallery. Returns nil on success,
    /// otherwise the error message to show.
    ///
    /// Never replaces an existing AVD and never renames behind the caller's
    /// back: a name that needs sanitizing, or that an AVD already uses
    /// (ignoring case), is refused with the same message the sheets show
    /// inline, and the Kit re-checks the AVD home right before avdmanager
    /// runs (which it does without `-f`). One create runs at a time.
    func createAvd(name: String, deviceId: String, systemImage: String, displayName: String? = nil) async -> String? {
        guard !isCreatingAvd else { return "Another AVD is being created. Try again when it finishes." }
        if let problem = AvdNameValidation.validate(name, existing: avds).message {
            return problem
        }
        guard let client = AvdmanagerClient.locate() else {
            return AvdmanagerError.avdmanagerNotFound.description
        }
        isCreatingAvd = true
        defer { isCreatingAvd = false }
        do {
            try await client.createAvd(
                name: name,
                deviceId: deviceId,
                systemImage: systemImage
            )
        } catch AvdmanagerError.avdAlreadyExists(let existing) {
            // Created outside Device Hub Pro (or left behind as an orphan) since the
            // last refresh: pick it up so the next suggestion avoids it.
            await refresh()
            return AvdmanagerError.avdAlreadyExists(existing).description
        } catch {
            return "\(error)"
        }
        if let problem = Self.completeNewAvdConfig(
            avdName: name,
            deviceId: deviceId,
            displayName: displayName,
            skinsDirectory: SkinLocator.skinsDirectory()
        ) {
            flashStatus(problem)
        }
        await refresh()
        return nil
    }

    /// Writes what avdmanager leaves out of a new AVD's `config.ini`, where
    /// Android Studio writes it; returns the first write that failed, as the
    /// status to flash (nil when all went in). Both creation paths (the
    /// create sheet and the Pixel catalog's Create & Start) come through
    /// `createAvd`, so every AVD Device Hub Pro creates gets them.
    ///
    /// - The hardware keyboard (`hw.keyboard=yes`, Studio's "Enable keyboard
    ///   input", on by default there): avdmanager copies the emulator's
    ///   default, `no`, and without the keyboard device every key the
    ///   emulator injects is dropped, the frame's side buttons and typing
    ///   included (`EmulatorKeyRoute`). Written before the first boot, it
    ///   costs no cold boot.
    /// - The SDK skin, when one matches the device profile, so launching the
    ///   AVD directly in the emulator shows the same device frame Device Hub Pro
    ///   renders (avdmanager writes no skin keys of its own).
    ///
    /// Studio's other differences are left alone: `PlayStore.enabled` (the
    /// emulator's handling of it is unchecked) and `hw.gpu.enabled`
    /// (Device Hub Pro always launches with `-gpu host`).
    nonisolated static func completeNewAvdConfig(
        avdName: String,
        deviceId: String,
        displayName: String? = nil,
        skinsDirectory: URL?,
        avdHome: URL? = nil
    ) -> String? {
        var problem: String?
        do {
            try AvdConfig.setHardwareKeyboard(true, avdName: avdName, avdHome: avdHome)
        } catch {
            problem = "Could not turn on the hardware keyboard"
        }
        do {
            try AvdConfig.completeDeviceKeys(
                avdName: avdName, deviceId: deviceId, displayName: displayName, avdHome: avdHome
            )
        } catch {
            problem = problem ?? "Could not write the device's orientation and name"
        }
        if let skinsDirectory,
           let skin = skinDirectory(forDeviceID: deviceId, in: skinsDirectory)
        {
            do {
                try AvdConfig.setSkin(
                    avdName: avdName,
                    skinName: skin.lastPathComponent,
                    skinPath: skin.path,
                    avdHome: avdHome
                )
            } catch {
                problem = problem ?? "Could not pin the device skin"
            }
        }
        return problem
    }

    /// The SDK skin directory for a device profile id, trying the exact id
    /// first and then the normalized form (`Galaxy Nexus` → `galaxy_nexus`).
    private nonisolated static func skinDirectory(forDeviceID deviceId: String, in skinsDirectory: URL) -> URL? {
        let normalized = deviceId.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        let manager = FileManager.default
        for name in [deviceId, normalized] {
            let url = skinsDirectory.appendingPathComponent(name, isDirectory: true)
            if manager.fileExists(atPath: url.appendingPathComponent("layout").path)
                || manager.fileExists(atPath: url.appendingPathComponent("default/layout").path)
            {
                return url
            }
        }
        return nil
    }

    /// Every AVD name a new AVD must not reuse: the AVD home on disk (which
    /// also holds orphaned `.ini`/`.avd` entries and AVDs created outside
    /// Device Hub Pro since the last refresh) plus the model's own list.
    func existingAvdNames(avdHome: URL? = nil) -> [String] {
        AvdHome.avdNames(in: avdHome ?? AvdHome.url()) + avds
    }

    var pixelCatalogInputs: PixelCatalogInputs {
        PixelCatalogInputs(
            skins: skinCatalog,
            avds: avds,
            avdSkins: avdCards.map { $0.skin?.name },
            avdDevices: avdDevices
        )
    }

    // MARK: - AVD file actions

    /// The AVD home (`~/.android/avd`) the file operations work in.
    static var avdHomeURL: URL { AvdConfig.homeURL() }

    /// The installed AVDs whose skin is `skinName`, in card order.
    func avdCards(forPixelSkin skinName: String) -> [AvdCard] {
        avdCards.filter { $0.skin?.name == skinName }
    }

    /// Shows an AVD in Finder: its content directory (where its `.ini`
    /// points — outside the AVD home for AVDs created with `-p`), or the
    /// `.ini` when that is gone, else the AVD home itself. Device Hub's
    /// "Show in Finder".
    func revealAVDInFinder(_ avdName: String) {
        let home = Self.avdHomeURL
        let candidates = [
            AvdConfig.contentDirectory(avdName: avdName, avdHome: home),
            home.appendingPathComponent("\(avdName).ini"),
        ]
        let target = candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? home
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    /// Moves `<Name>.ini` and `<Name>.avd/` to the macOS Trash. Stopped AVDs only.
    func deleteAVD(_ avdName: String) async {
        guard await avdFileActionAllowed(avdName) else { return }
        do {
            try AvdFileOperations.delete(avdName: avdName, avdHome: Self.avdHomeURL)
        } catch {
            if !error.isCancellation { errorMessage = "\(error)" }
            return
        }
        displayShapes.forget(avdName: avdName)
        selectionFollowsAvd(avdName, nil)
        flashStatus("Moved \"\(avdName)\" to the Trash")
        await refresh()
    }

    /// Renames the AVD on disk (ini + directory, `path=` rewritten). Stopped AVDs only.
    func renameAVD(_ avdName: String, to newName: String) async {
        guard await avdFileActionAllowed(avdName) else { return }
        let renamed: String
        do {
            renamed = try AvdFileOperations.rename(
                avdName: avdName,
                to: newName,
                avdHome: Self.avdHomeURL
            )
        } catch {
            if !error.isCancellation { errorMessage = "\(error)" }
            return
        }
        displayShapes.move(fromAvd: avdName, toAvd: renamed)
        selectionFollowsAvd(avdName, .avd(renamed))
        flashStatus("Renamed \"\(avdName)\" to \"\(renamed)\"")
        await refresh()
    }

    /// Resets the AVD's content and settings: removes userdata and snapshots,
    /// keeping `config.ini`. Stopped AVDs only.
    func wipeAVDData(_ avdName: String) async {
        guard await avdFileActionAllowed(avdName) else { return }
        let home = Self.avdHomeURL
        do {
            // Off the main actor: userdata and snapshots run to gigabytes.
            let removed = try await Task.detached(priority: .userInitiated) {
                try AvdFileOperations.wipeData(avdName: avdName, avdHome: home)
            }.value
            flashStatus(
                removed.isEmpty
                    ? "Nothing to reset on \"\(avdName)\""
                    : "Reset content and settings on \"\(avdName)\""
            )
        } catch {
            if !error.isCancellation { errorMessage = "\(error)" }
        }
    }

    /// Turns on the hardware keyboard of an AVD created without one
    /// (`hw.keyboard=yes`, Android Studio's "Enable keyboard input"), so the
    /// emulator's keys reach it again: the frame's side buttons with real
    /// holds, and typing. Stopped AVDs only: the emulator reads the key at
    /// launch. Its next start is a cold boot (the emulator refuses the
    /// quick-boot snapshot saved with other hardware), and the named
    /// snapshots saved before no longer load either; apps and data are
    /// kept. `avdHome` is the AVD home the file actions work in unless a
    /// test names another.
    func enableHardwareKeyboard(_ avdName: String, avdHome: URL? = nil) async {
        guard await avdFileActionAllowed(avdName) else { return }
        do {
            try AvdConfig.setHardwareKeyboard(true, avdName: avdName, avdHome: avdHome ?? Self.avdHomeURL)
        } catch {
            errorMessage = "Could not turn on the hardware keyboard of \"\(avdName)\": \(error.localizedDescription)"
            return
        }
        flashStatus("Keyboard input on for \"\(avdName)\". Its next start is a cold boot; snapshots saved before it will not load.")
        await refresh()
    }

    /// Establishes the running state right before a file mutation. Fails
    /// closed: an AVD whose state cannot be verified (no emulator manager, or
    /// a failing process query) is never deleted, renamed or wiped. Any VM
    /// on the Mac counts, whatever the emulator's process scope: one that
    /// someone else runs holds the AVD's files just the same, and a test
    /// model that sees only its own VMs must not take it for stopped.
    private func avdFileActionAllowed(_ avdName: String) async -> Bool {
        let manager = emulatorManager
        let state = await AvdFileOperations.runState {
            guard let manager else { throw EmulatorError.emulatorNotFound }
            return try await manager.isAnyVMRunning(avd: avdName)
        }
        switch state {
        case .stopped:
            return true
        case .running:
            errorMessage = "\"\(avdName)\" is running. Stop it first, then try again."
            return false
        case .unknown:
            errorMessage = "Couldn't verify whether \"\(avdName)\" is running — try again."
            return false
        }
    }

    // MARK: - Shims

    // Its owner's emulator, adb rows and console answers, and `StatusCenter`,
    // under the names the moved call sites use, so their text is unchanged.

    private var emulatorManager: EmulatorManager? { emulatorManagerProvider() }

    private var realDevices: [AndroidDevice] { realDevicesSource() }

    private func resolveAvdSerials(among devices: [AndroidDevice]) async -> [String: String] {
        await avdSerialsResolver(devices)
    }

    private var errorMessage: String? {
        get { status.errorMessage }
        set { status.errorMessage = newValue }
    }

    private func flashStatus(_ message: String) {
        status.flash(message)
    }
}
