import Foundation
import Observation
import DeviceHubProKit

/// The Accessibility group's Color Filter and Color inversion rows: Android's
/// Color correction and Color inversion, read back from SurfaceFlinger's color
/// matrix on Android 13 and newer.
///
/// Owned by `DeviceControlsController` (`controlsPanel.colorFilters`), which
/// runs `refresh()` inside its two-second poll and `detach()`es it when the
/// mirrored device changes. The API level is read once per device
/// (`ColorFilterSupport`); below `ColorFilterSupport.minimumAPI` the rows stay
/// hidden and the poll reads nothing. Every write shows its value at once,
/// holds the write fence so a poll cannot flip it back, disables both rows
/// (`isWriting`), is read back by the Kit (which throws when the device did
/// not keep the keys), and rolls back on failure. A write that a later one
/// overtook (a double click before the rows disable) reports nothing and
/// leaves the rows to the later write. Nothing is restored by itself: these
/// are persistent accessibility settings, and None is the way back.
@MainActor
@Observable
final class ColorFilterController {
    let adbClient: AdbClient?
    private let context: ActiveDeviceContext
    let status: StatusCenter

    init(adbClient: AdbClient?, context: ActiveDeviceContext, status: StatusCenter) {
        self.adbClient = adbClient
        self.context = context
        self.status = status
    }

    /// The mirrored device's API level; nil until it answers.
    private(set) var support: ColorFilterSupport?
    private(set) var supportSerial: String?
    /// The latest readings; nil until the device answers, and after a failed
    /// read (the rows show unknown rather than a stale value).
    var readings: ColorFilterReadings?
    /// How SurfaceFlinger's matrix compares with the keys; nil during a write.
    var check: ColorTransformCheck?
    /// Hides the rows after 3 consecutive failed reads (the `AppearanceProbe`
    /// rule) and brings them back on the next answer.
    private(set) var readProbe = SettingsProbe()
    private(set) var writeFence = SettingsWriteFence()
    /// True while a write runs (both rows disable, as the Conditions rows do).
    private(set) var isWriting = false
    /// Counts the writes; only the latest applies its outcome.
    private var writeSequence: UInt64 = 0

    // MARK: - Rows

    private var answered: Bool { support?.offersRows == true && readProbe.isAvailable }

    var showsColorFilterRow: Bool { answered }

    /// Whether the mirrored device is an emulator, by its serial, as the
    /// Status bar and conditions groups decide: the captions are about the
    /// emulator's drawing, which an emulator mirrored through scrcpy
    /// (`DHP_FORCE_PHYSICAL`, no gRPC port) still does.
    var isEmulator: Bool { DeviceConditionsController.isEmulatorSerial(context.serial) }

    // MARK: - Poll

    /// Reads the rows (and, once per device, the API level). A read that
    /// overlapped a write, or finished after the mirrored device changed,
    /// applies nothing.
    func refresh() async {
        guard let adbClient, let serial = context.serial else { return }
        let generation = context.controlsGeneration
        if supportSerial != serial {
            guard let probed = try? await adbClient.colorFilterSupport(serial: serial) else { return }
            guard isCurrent(serial: serial, generation: generation), !Task.isCancelled else { return }
            support = probed
            supportSerial = serial
        }
        guard let support, support.offersRows, writeFence.isIdle else { return }
        let ticket = writeFence.pollTicket
        let read = try? await adbClient.colorFilterReadings(serial: serial, support: support)
        guard isCurrent(serial: serial, generation: generation), !Task.isCancelled else { return }
        readProbe.record(answered: read != nil)
        guard writeFence.admits(pollStartedAt: ticket) else { return }
        readings = read
        check = read?.check(apiLevel: support.apiLevel)
    }

    private func isCurrent(serial: String, generation: UInt64) -> Bool {
        context.serial == serial && context.controlsGeneration == generation
    }

    /// Forgets the device. No device writes: the rows restore nothing.
    func detach() {
        support = nil
        supportSerial = nil
        readings = nil
        check = nil
        readProbe.reset()
    }

    // MARK: - Writes

    /// Chooses a filter; None turns only Color correction's switch off.
    func setColorFilter(_ option: ColorFilterOption) async {
        await write(optimistic: { $0.writing(option) }, message: { check in
            colorFilterWriteMessage(option: option, check: check)
        }) { adbClient, serial, support in
            try await adbClient.setColorFilter(serial: serial, option, support: support)
        }
    }

    private func write(
        optimistic: (ColorFilterReadings) -> ColorFilterReadings,
        message: (ColorTransformCheck) -> (flash: String?, error: String?),
        perform: (AdbClient, String, ColorFilterSupport) async throws -> ColorFilterWriteOutcome
    ) async {
        guard let adbClient, let serial = context.serial, let support, supportSerial == serial else { return }
        let generation = context.controlsGeneration
        writeSequence += 1
        let sequence = writeSequence
        writeFence.beginWrite()
        isWriting = true
        defer {
            writeFence.endWrite()
            isWriting = !writeFence.isIdle
        }
        let previous = (readings: readings, check: check)
        readings = readings.map(optimistic)
        check = nil
        do {
            let outcome = try await perform(adbClient, serial, support)
            // An overtaken write read back the later write's keys: the later
            // write owns the rows and the status line.
            guard sequence == writeSequence else { return }
            if isCurrent(serial: serial, generation: generation) {
                readings = outcome.readings
                check = outcome.check
            }
            let text = message(outcome.check)
            if let error = text.error {
                status.errorMessage = error
            } else if let flash = text.flash {
                status.flash(flash)
            }
        } catch {
            guard sequence == writeSequence else { return }
            if isCurrent(serial: serial, generation: generation) {
                readings = previous.readings
                check = previous.check
            }
            if !error.isCancellation { status.errorMessage = "\(error)" }
        }
    }
}
