/// What the clipboard sync last saw on, or wrote to, each side, so a text
/// crosses once and is never echoed back: a device text written to the Mac
/// is not sent back to the device on the next Mac poll, and a Mac text
/// written to the device is not copied back to the Mac on the next device
/// read.
///
/// The steps are fine-grained on purpose: the emulator loop awaits the
/// device write between deciding to send a Mac text and recording it on the
/// device side, and the adopter keeps that order.
///
/// `ClipboardSyncController` keeps one, edited by send, pull, `receive`,
/// `pushMacClipboard`, `seedClipboardState` and `syncClipboardOnce`. It
/// replaced `AppModel`'s `lastMacClipboardText` and
/// `lastDeviceClipboardText` (S15) and, like them, survives a device switch.
struct ClipboardEchoState: Equatable, Sendable {
    /// The Mac pasteboard text as the sync last saw or wrote it.
    private(set) var lastMacText: String?
    /// The device clipboard text as the sync last saw or wrote it.
    private(set) var lastDeviceText: String?

    init() {}

    // MARK: - Seeding

    /// Records the Mac pasteboard as it is when sync starts, so enabling
    /// sync does not overwrite the device with it at once.
    mutating func seedMac(_ text: String?) {
        lastMacText = text
    }

    /// Records the device clipboard as it is when sync starts, so enabling
    /// sync does not overwrite the Mac with it at once.
    mutating func seedDevice(_ text: String?) {
        lastDeviceText = text
    }

    /// A manual Send or Pull put `text` on both sides.
    mutating func noteSynced(_ text: String) {
        lastMacText = text
        lastDeviceText = text
    }

    // MARK: - Device → Mac

    /// A device clipboard read. True, recording it, when it changed since
    /// the sync last saw or wrote the device side; false for a repeat or
    /// for the echo of a text the sync sent there.
    mutating func acceptDeviceText(_ text: String) -> Bool {
        guard text != lastDeviceText else { return false }
        lastDeviceText = text
        return true
    }

    /// Whether writing `text` to the Mac would change what the sync last
    /// saw there.
    func macNeeds(_ text: String) -> Bool {
        text != lastMacText
    }

    /// The sync wrote `text` to the Mac pasteboard.
    mutating func noteMacWritten(_ text: String) {
        lastMacText = text
    }

    // MARK: - Mac → device

    /// A Mac pasteboard read. True, recording it, when it changed since the
    /// sync last saw or wrote the Mac side; false for a repeat or for the
    /// echo of a text the sync copied there.
    mutating func acceptMacText(_ text: String) -> Bool {
        guard text != lastMacText else { return false }
        lastMacText = text
        return true
    }

    /// Whether writing `text` to the device would change what the sync last
    /// saw there.
    func deviceNeeds(_ text: String) -> Bool {
        text != lastDeviceText
    }

    /// The sync wrote `text` to the device clipboard.
    mutating func noteDeviceWritten(_ text: String) {
        lastDeviceText = text
    }
}
