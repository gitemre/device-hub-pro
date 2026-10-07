import Foundation
import Observation
import DeviceHubProKit

/// The Controls panel's **Status bar** group: SystemUI demo mode (a fixed
/// clock, battery and signal for screenshots), on emulators and phones alike.
///
/// Every write is read back through the Kit (`AdbClient+StatusBarDemo`):
/// `am broadcast` answers the same whether SystemUI took a command or not,
/// so the Demo mode switch shows SystemUI's own answer (`dumpsys
/// DemoModeController`, API 31+) and the battery rows SystemUI's battery
/// (API 33+). The clock and the icons have no read-back on any release; their
/// rows show what Device Hub Pro sent (`sent`).
///
/// Demo mode Device Hub Pro turns on is put back — demo mode ended, SystemUI's
/// battery realigned, the two keys as they were — when it is turned off, on
/// disconnect, Stop and quit. The keys are on the device's disk (an AVD's
/// outlast its emulator, and a quick-boot snapshot restores SystemUI's memory
/// too), so a put-back that could not reach the device stays recorded per
/// device (`records`: the AVD name for an emulator, the serial for a phone)
/// and runs on that device's next session. The records outlive the app
/// (`StatusBarDemoRecordStore`), so a relaunch after a crash or a quit cut
/// off at its bound finishes the put-back too. Demo mode someone else
/// started is left on at disconnect, and so is one started after Device Hub Pro's
/// own ended elsewhere (`StatusBarDemoRecord.demoModeEnded`).
///
/// Owned by `DeviceConditionsController` (`conditions.statusBar`), which
/// forwards its lifecycle; the views call it directly.
@MainActor
@Observable
final class StatusBarDemoController {
    let adbClient: AdbClient?
    private let context: ActiveDeviceContext
    let status: StatusCenter

    /// How long a write reads back (about 3 s). Tests shorten it.
    @ObservationIgnored var settle: StatusBarDemoSettle = .standard

    /// - Parameter recordStore: where the records outlive the app; nil keeps
    ///   them for the process only (tests).
    init(
        adbClient: AdbClient?,
        context: ActiveDeviceContext,
        status: StatusCenter,
        recordStore: StatusBarDemoRecordStore? = nil
    ) {
        self.adbClient = adbClient
        self.context = context
        self.status = status
        self.recordStore = recordStore
        records = recordStore?.load() ?? [:]
    }

    // MARK: - Readings

    /// The last probe; nil until the device answers, and after a failed read.
    private(set) var snapshot: StatusBarDemoSnapshot?
    /// The device's API level, from the first probe that answered.
    private(set) var apiLevel: Int?
    /// Hides the group after 3 failed probes and brings it back on the next
    /// answer (the `AppearanceProbe` rule).
    private(set) var readProbe = SettingsProbe()
    /// SystemUI reported `DemoModeController` this mirror session: a later probe
    /// without it means SystemUI did not answer, not that it never reports.
    private(set) var hasReportedController = false
    /// What Device Hub Pro sent in this demo mode (the rows Android does not report).
    var sent = StatusBarDemoSent()
    /// The keys as Device Hub Pro found them before its first write, per device
    /// key (`deviceKey`), until the put-back succeeds; saved to the record
    /// store on every change.
    private(set) var records: [String: StatusBarDemoRecord] = [:] {
        didSet { recordStore?.save(records) }
    }
    @ObservationIgnored private let recordStore: StatusBarDemoRecordStore?
    /// True while a write runs (the rows disable).
    private(set) var isWriting = false

    // MARK: - Bookkeeping

    /// One mirror session of one device.
    struct DeviceSession: Hashable {
        let serial: String
        let generation: UInt64
    }

    /// Keeps a poll that overlapped a write from overwriting its read-back.
    @ObservationIgnored private var writeFence = SettingsWriteFence()
    /// The newest write; each write waits for the one before it.
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    /// The put-back `detach()` started; quit, Stop and the recovery's kill
    /// wait for it (through `DeviceConditionsController`).
    @ObservationIgnored private(set) var pendingCleanup: Task<Void, Never>?
    /// The record key of each session that needed one, so `detach()` needs no
    /// console call.
    @ObservationIgnored private var sessionKeys: [DeviceSession: String] = [:]
    /// The session whose leftover record was looked for (first answered
    /// probe whose device key could be read).
    @ObservationIgnored private var leftoverCheckedSession: DeviceSession?
    /// A session whose device is older than API 23: not probed again.
    @ObservationIgnored private var unsupportedSession: DeviceSession?
    /// The session `attach()` began, whose writes key their records under
    /// it. `detach()` puts that one back: `AppModel.tearDownMirror` moves the
    /// controls generation on before it detaches, so `currentSession` then
    /// already names a session nothing was written in.
    @ObservationIgnored private var attachedSession: DeviceSession?

    // MARK: - Device

    var activeSerial: String? { context.serial }

    var currentSession: DeviceSession? {
        activeSerial.map { DeviceSession(serial: $0, generation: context.controlsGeneration) }
    }

    func isCurrent(_ session: DeviceSession) -> Bool {
        !Task.isCancelled && currentSession == session
    }

    /// The AVD behind the mirror, when the session knows it.
    var mirroredAvdName: String? { context.avdName }

    /// A phone: its maker's SystemUI may ignore demo mode.
    var isPhysical: Bool { !DeviceConditionsController.isEmulatorSerial(activeSerial) }

    /// The record of the mirrored device, once its key is known this mirror session.
    var currentRecord: StatusBarDemoRecord? {
        currentSession.flatMap { sessionKeys[$0] }.flatMap { records[$0] }
    }

    /// Device Hub Pro turned on the demo mode the device is in: a record of its
    /// own whose demo mode has not ended elsewhere since.
    var ownsDemoMode: Bool { currentRecord.map { !$0.isSomeoneElses && !$0.demoModeEnded } ?? false }

    // MARK: - Availability and row state

    /// A mirrored device whose probe answered, API 23+, not hidden by failed
    /// probes.
    var showsGroup: Bool {
        activeSerial != nil && (apiLevel ?? 0) >= StatusBarDemo.minimumAPI && readProbe.isAvailable
    }

    var demoModeRow: StatusBarDemoModeRowModel {
        demoModeRowModel(
            snapshot: snapshot,
            hasRecord: ownsDemoMode,
            hasReportedController: hasReportedController,
            isPhysical: isPhysical
        )
    }

    // MARK: - Session

    /// A mirror started (called once the context names the device and its
    /// generation): forgets the previous device's readings and notes the
    /// session. The records stay (they are per device); no adb command is
    /// sent — a leftover record is put back by the first probe that answers.
    func attach() {
        clearDeviceState()
        attachedSession = currentSession
    }

    /// The mirror is going away (called while the context still names the
    /// device, after the generation moved on): once the write in flight has
    /// landed, puts back demo mode Device Hub Pro turned on there in the attached
    /// session. Best effort: a device that already left keeps its record for
    /// its next session. Someone else's demo mode is left on.
    func detach() {
        let session = attachedSession.flatMap { $0.serial == activeSerial ? $0 : nil } ?? currentSession
        attachedSession = nil
        if let session, let adbClient {
            let inFlight = writeTask
            let previous = pendingCleanup
            let settle = self.settle
            let expectsController = hasReportedController
            pendingCleanup = Task { [weak self] in
                // Quit waits for the newest cleanup only, so it chains the
                // earlier ones; an enter script still running must not land
                // after the put-back.
                await previous?.value
                await inFlight?.value
                await self?.putBack(
                    session: session,
                    adbClient: adbClient,
                    settle: settle,
                    expectsController: expectsController
                )
            }
        }
        clearDeviceState()
    }

    /// Waits for `detach()`'s put-back.
    func waitForPendingCleanup() async {
        await pendingCleanup?.value
    }

    /// The emulator on `serial` exited. A record under its AVD name waits
    /// for that AVD's next session (the keys live on its disk); one kept
    /// under the serial (the AVD name was unreadable) is dropped, since the
    /// next emulator on that serial may be another AVD.
    func emulatorExited(serial: String) {
        records[serial] = nil
    }

    /// The disconnect's put-back. Out of demo mode it realigns SystemUI's
    /// battery even where it cannot read it (API 31–32): Device Hub Pro's demo mode
    /// ended without its exit. The leftover put-back does the same
    /// (`putBackLeftover`).
    private func putBack(
        session: DeviceSession,
        adbClient: AdbClient,
        settle: StatusBarDemoSettle,
        expectsController: Bool
    ) async {
        guard let key = sessionKeys.removeValue(forKey: session), let record = records[key] else { return }
        _ = await putBack(
            record,
            key: key,
            serial: session.serial,
            adbClient: adbClient,
            settle: settle,
            expectsController: expectsController,
            realignBattery: true
        )
    }

    /// Puts `record` back on `serial`: someone else's record is dropped; one
    /// whose demo mode ended elsewhere waits while SystemUI is in (someone
    /// else's) demo mode. Returns the reading after a put-back that
    /// succeeded (its record is dropped then, unless a newer one was recorded
    /// meanwhile); nil when there was nothing to do, the record waits, or
    /// the put-back failed (the record is kept for the device's next
    /// session).
    func putBack(
        _ record: StatusBarDemoRecord,
        key: String,
        serial: String,
        adbClient: AdbClient,
        settle: StatusBarDemoSettle,
        expectsController: Bool,
        realignBattery: Bool
    ) async -> StatusBarDemoSnapshot? {
        guard !record.isSomeoneElses else {
            // Someone else's demo mode: left on.
            if records[key]?.original == record.original { records[key] = nil }
            return nil
        }
        do {
            if record.demoModeEnded {
                let now = try await adbClient.statusBarDemo(
                    serial: serial,
                    expectsController: expectsController,
                    settle: settle
                )
                // Someone else's demo mode: left on; the keys wait for it.
                guard !now.isInDemoMode else { return nil }
            }
            let after = try await adbClient.exitStatusBarDemo(
                serial: serial,
                original: record.original,
                realignBattery: realignBattery || record.demoModeEnded,
                expectsController: expectsController,
                settle: settle
            )
            if records[key]?.original == record.original { records[key] = nil }
            return after
        } catch {
            return nil
        }
    }

    private func clearDeviceState() {
        snapshot = nil
        apiLevel = nil
        readProbe.reset()
        hasReportedController = false
        endSent()
        leftoverCheckedSession = nil
        unsupportedSession = nil
    }

    // MARK: - Poll

    /// One Controls poll: one probe, applied unless a write overlapped it or
    /// the device changed. The first answer of a session puts back a record
    /// an earlier session of this device left.
    func refresh() async {
        guard let adbClient, let session = currentSession, unsupportedSession != session else { return }
        let ticket = writeFence.pollTicket
        let read = try? await adbClient.statusBarDemo(serial: session.serial)
        guard isCurrent(session) else { return }
        readProbe.record(answered: read != nil)
        guard writeFence.admits(pollStartedAt: ticket) else { return }
        apply(read)
        guard let read else { return }
        if let level = read.apiLevel, level < StatusBarDemo.minimumAPI {
            unsupportedSession = session
            return
        }
        noteDemoModeEnded(read, session: session)
        if leftoverCheckedSession != session {
            // Marked first so an overlapping poll does not look too; undone
            // when the device key could not be read, so the next poll does.
            leftoverCheckedSession = session
            if await !putBackLeftover(session: session), leftoverCheckedSession == session {
                leftoverCheckedSession = nil
            }
        }
    }

    /// A reading the rows show. Demo mode off ends what Device Hub Pro sent.
    func apply(_ read: StatusBarDemoSnapshot?) {
        snapshot = read
        guard let read else { return }
        if let level = read.apiLevel { apiLevel = level }
        if read.controller != nil { hasReportedController = true }
        if !read.isInDemoMode { endSent() }
    }

    /// Demo mode ended: nothing Device Hub Pro sent is on the status bar any more.
    func endSent() {
        sent = StatusBarDemoSent()
    }

    /// A poll (no write in flight or started since) found SystemUI out of
    /// demo mode while Device Hub Pro holds its own record: its demo mode ended
    /// elsewhere, so the next demo mode is someone else's. A gate found on
    /// at Device Hub Pro's first write and read off now was closed by the user
    /// (Developer options ▸ Enable demo mode): the record keeps it closed,
    /// so a later enter or realign that opens it again puts it back to off.
    private func noteDemoModeEnded(_ read: StatusBarDemoSnapshot, session: DeviceSession) {
        guard !read.isInDemoMode,
              read.answers(expectingController: hasReportedController),
              let key = sessionKeys[session],
              var record = records[key],
              !record.isSomeoneElses
        else { return }
        let original = record.original.closingTheGate(as: read)
        guard !record.demoModeEnded || original != record.original else { return }
        record.demoModeEnded = true
        record.original = original
        records[key] = record
    }

    /// Before Device Hub Pro opens the gate for its own enter: a gate its record
    /// found on and `read` finds off was closed by the user since, and stays
    /// closed at the put-back.
    func noteGateClosed(_ read: StatusBarDemoSnapshot, key: String) {
        guard var record = records[key], !record.isSomeoneElses else { return }
        let original = record.original.closingTheGate(as: read)
        guard original != record.original else { return }
        record.original = original
        records[key] = record
    }

    /// A record for this device survived (a disconnect that could not reach
    /// it, an emulator killed, stopped or snapshot-loaded elsewhere, a
    /// relaunch): put it back now, after any cleanup still running (which
    /// may do it itself). Out of demo mode it realigns the battery as the
    /// disconnect does: Device Hub Pro's demo mode ended without its exit, maybe
    /// elsewhere while Device Hub Pro was not running to see it (on API 31–32,
    /// where SystemUI does not report its battery, a restarted device gets a
    /// realign it did not need). False when the device key could not be
    /// read yet (the next poll looks again).
    private func putBackLeftover(session: DeviceSession) async -> Bool {
        guard !records.isEmpty else { return true }
        guard let key = await resolvedDeviceKey(for: session, avdName: context.avdName) else { return false }
        guard isCurrent(session) else { return false }
        guard records[key] != nil else { return true }
        let cleanup = pendingCleanup
        let settle = self.settle
        let expectsController = hasReportedController
        // Queued, not awaited: the poll goes on while it runs, and a detach
        // meanwhile waits for it.
        enqueueWrite { controller, adbClient in
            await cleanup?.value
            guard let record = controller.records[key] else { return true }
            let after = await controller.putBack(
                record,
                key: key,
                serial: session.serial,
                adbClient: adbClient,
                settle: settle,
                expectsController: expectsController,
                realignBattery: true
            )
            guard let after else { return controller.records[key] == nil }
            if controller.isCurrent(session) { controller.apply(after) }
            return true
        }
        return true
    }

    // MARK: - Writes

    /// Runs `body` as the next write and waits for it: after the previous
    /// write, holding the write fence (so a poll cannot flip the rows back).
    /// Returns what `body` returned (false when it did not run).
    @discardableResult
    func performWrite(
        _ body: @escaping @MainActor (StatusBarDemoController, AdbClient) async -> Bool
    ) async -> Bool {
        await enqueueWrite(body)?.value ?? false
    }

    /// Queues `body` as the next write at once (`detach()` waits for it).
    @discardableResult
    func enqueueWrite(
        _ body: @escaping @MainActor (StatusBarDemoController, AdbClient) async -> Bool
    ) -> Task<Bool, Never>? {
        guard let adbClient else { return nil }
        beginWrite()
        let previous = writeTask
        let task = Task { @MainActor [weak self] () -> Bool in
            await previous?.value
            guard let self else { return false }
            defer { self.endWrite() }
            return await body(self, adbClient)
        }
        writeTask = Task { _ = await task.value }
        return task
    }

    private func beginWrite() {
        writeFence.beginWrite()
        isWriting = true
    }

    private func endWrite() {
        writeFence.endWrite()
        isWriting = !writeFence.isIdle
    }

    /// The key a record of `session`'s device is kept under: the AVD name for
    /// an emulator (its keys live on the AVD's disk), else the serial. Read
    /// once per session, only when a record is written or looked for. nil
    /// while an emulator's AVD name is unknown — its console did not answer,
    /// or the task was cancelled during the lookup — and nothing is cached
    /// then, so the next call asks again.
    func resolvedDeviceKey(for session: DeviceSession, avdName: String?) async -> String? {
        if let key = sessionKeys[session] { return key }
        var key = avdName ?? session.serial
        if avdName == nil, DeviceConditionsController.isEmulatorSerial(session.serial) {
            // A cancelled lookup throws; a console that did not answer is nil.
            guard let adbClient,
                  let name = (try? await adbClient.avdName(serial: session.serial)) ?? nil
            else { return sessionKeys[session] }
            key = name
        }
        if let cached = sessionKeys[session] { return cached }
        sessionKeys[session] = key
        return key
    }

    /// The key for a write, which needs one now: `resolvedDeviceKey`, else
    /// the serial, kept for the session (and never stored past the app,
    /// `StatusBarDemoRecordStore`; dropped when the emulator exits).
    func deviceKey(for session: DeviceSession, avdName: String?) async -> String {
        if let key = await resolvedDeviceKey(for: session, avdName: avdName) { return key }
        if let key = sessionKeys[session] { return key }
        sessionKeys[session] = session.serial
        return session.serial
    }

    /// Records `original` for `key` unless Device Hub Pro already holds its own
    /// record there; a record of someone else's demo mode that has since
    /// ended is replaced. Returns whether it recorded now.
    @discardableResult
    func record(_ original: StatusBarDemoOriginal, key: String) -> Bool {
        if let existing = records[key], !existing.isSomeoneElses || original.wasInDemoMode {
            return false
        }
        records[key] = StatusBarDemoRecord(original)
        return true
    }

    /// Device Hub Pro is entering demo mode itself (its enter script is next): its
    /// record's demo mode is its own again.
    func markDemoModeOwned(key: String) {
        guard var record = records[key], !record.isSomeoneElses, record.demoModeEnded else { return }
        record.demoModeEnded = false
        records[key] = record
    }

    /// Drops the record of `key` (tests and a refused first write).
    func forgetRecord(key: String) {
        records[key] = nil
    }
}
