import AppKit
import Foundation
import Observation
import DeviceHubProKit

/// What the Info card of a physical iPhone or iPad shows, read
/// from the list entry and four `devicectl device info` answers (`details`,
/// `lockState`, `ddiServices`, `displays`). Every field is optional: a read
/// that failed leaves its fields as the last good read had them.
struct PhysicalDeviceInfo: Equatable, Sendable {
    var name: String
    /// "iPhone 12".
    var marketingName: String?
    /// "iPhone13,2".
    var modelIdentifier: String?
    /// "27.0".
    var osVersion: String?
    /// "24A5380h".
    var osBuild: String?
    /// "Paired".
    var pairing: String?
    /// "Connected".
    var connection: String?
    /// "Wired", "Local Network".
    var transport: String?
    /// "On" or "Off".
    var developerMode: String?
    /// "Ready (27A266a)", "Not usable", "Not available".
    var developerDiskImage: String?
    /// "Unlocked", "Locked".
    var lockState: String?
    /// "1170 × 2532 px".
    var screenSize: String?
    /// The internal storage in bytes (`details`), e.g. 64 000 000 000.
    var capacityBytes: Int64?
    /// The ECID, decimal digits, as the device reports it (`details`).
    var ecid: String?
    /// The serial number, as the device reports it (`details`).
    var serialNumber: String?
    /// The hardware UDID (`details`, else the list's).
    var udid: String?
    var isIPad = false

    /// "iOS 27.0": Device Hub's OS row, without the build.
    var osLabel: String? {
        guard let osVersion else { return nil }
        return "\(isIPad ? "iPadOS" : "iOS") \(osVersion)"
    }

    /// "iOS 27.0 (24A5380h)", "iOS 27.0", or nil.
    var os: String? {
        guard let osVersion else { return nil }
        let label = "\(isIPad ? "iPadOS" : "iOS") \(osVersion)"
        return osBuild.map { "\(label) (\($0))" } ?? label
    }

    /// The card's values for this device. `details`, `lockState`, `ddi` and
    /// `displays` are the reads' answers, nil for one that failed; a failed
    /// read keeps what `previous` had for its fields.
    static func make(
        entry: ApplePhysicalEntry,
        details: DevicectlDeviceDetails?,
        lockState: DevicectlLockState?,
        ddi: DevicectlDDIServices?,
        displays: DevicectlDisplays?,
        previous: PhysicalDeviceInfo? = nil
    ) -> PhysicalDeviceInfo {
        let device = entry.device
        var info = PhysicalDeviceInfo(name: details?.name ?? entry.name)
        info.isIPad = entry.isIPad
        info.marketingName = details?.marketingName ?? device.marketingName ?? previous?.marketingName
        info.modelIdentifier = details?.productType ?? device.productType ?? previous?.modelIdentifier
        info.osVersion = details?.osVersion ?? device.osVersion ?? previous?.osVersion
        info.osBuild = details?.osBuild ?? previous?.osBuild
        info.capacityBytes = details?.internalStorageCapacity ?? previous?.capacityBytes
        info.ecid = details?.ecid ?? previous?.ecid
        info.serialNumber = details?.serialNumber ?? previous?.serialNumber
        info.udid = details?.udid ?? previous?.udid ?? device.hardwareUDID
        info.pairing = device.pairingState.map(humanize)
        info.connection = device.tunnelState.map(humanize)
        info.transport = device.transport.map(humanize)
        info.developerMode = device.developerModeStatus.map { $0 == "enabled" ? "On" : "Off" }

        if let lockState {
            info.lockState = lockState.passcodeRequired == true ? "Locked" : "Unlocked"
        } else {
            info.lockState = previous?.lockState
        }

        if let metadata = ddi?.ddiMetadata {
            if metadata.isUsable == true {
                info.developerDiskImage = metadata.buildUpdate.map { "Ready (\($0))" } ?? "Ready"
            } else {
                info.developerDiskImage = "Not usable"
            }
        } else if ddi != nil {
            info.developerDiskImage = "Not available"
        } else {
            info.developerDiskImage = previous?.developerDiskImage
                ?? device.ddiServicesAvailable.map { $0 ? "Available" : "Not available" }
        }

        if let displays {
            let primary = displays.displays.first(where: { $0.primary == true }) ?? displays.displays.first
            if let size = primary?.nativeSize, size.count == 2 {
                info.screenSize = "\(Int(size[0])) × \(Int(size[1])) px"
            } else {
                info.screenSize = previous?.screenSize
            }
        } else {
            info.screenSize = previous?.screenSize
        }
        return info
    }

    /// "localNetwork" -> "Local Network", "wired" -> "Wired".
    static func humanize(_ token: String) -> String {
        var words: [String] = []
        var current = ""
        for character in token {
            if character.isUppercase, !current.isEmpty {
                words.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

/// A capability a physical device can lack, as the calls that use it find out
/// (CoreDevice error 1001, `DevicectlPhysicalError.unsupportedCapability`).
enum PhysicalFeature: String, CaseIterable, Sendable {
    case screenshot
    case screenRecording

    var title: String {
        switch self {
        case .screenshot: "screenshots"
        case .screenRecording: "screen recording"
        }
    }
}

/// What the app does with an enabled physical iPhone or iPad beyond the list:
/// reads its Info card, takes screenshots and
/// records the screen, and remembers which of those the device reported
/// unsupported so the stage hides the matching button. The Apps tab, launch,
/// terminate, install, open URL, container files and crash logs are the next
/// step (9B-2b).
///
/// Every call goes through `ApplePhysicalInventory.client(for:)`, which
/// answers nil for a device that is not enabled, paired and connected, so a
/// device the user did not enable never gets a command from here.
@MainActor
@Observable
final class ApplePhysicalController {
    struct Screenshot: Equatable {
        let png: Data
        let date: Date
        /// The PNG decoded once, when the screenshot lands, so the view's
        /// body never decodes it.
        let image: NSImage?

        init(png: Data, date: Date, image: NSImage? = nil) {
            self.png = png
            self.date = date
            self.image = image
        }

        static func == (lhs: Screenshot, rhs: Screenshot) -> Bool {
            lhs.png == rhs.png && lhs.date == rhs.date
        }
    }

    /// A screenshot file read and decoded off the main actor.
    private struct DecodedScreenshot: @unchecked Sendable {
        let png: Data
        let image: NSImage?

        static func load(_ file: URL) throws -> DecodedScreenshot {
            let png = try Data(contentsOf: file)
            return DecodedScreenshot(png: png, image: NSImage(data: png))
        }
    }

    enum Operation: Equatable {
        case screenshot
        case recording
    }

    /// The Info cards, by hardware UDID.
    private(set) var infos: [String: PhysicalDeviceInfo] = [:]
    /// Why the last Info refresh got no answer at all (a locked or busy
    /// device), by hardware UDID.
    private(set) var infoErrors: [String: String] = [:]
    /// The last screenshot of each device, shown in its stage.
    private(set) var screenshots: [String: Screenshot] = [:]
    /// What runs now.
    private(set) var operations: [String: Operation] = [:]
    /// The last action's outcome or failure, in a line for the stage.
    private(set) var messages: [String: String] = [:]
    /// The features each device answered with "not supported".
    private(set) var unsupported: [String: Set<PhysicalFeature>] = [:]

    private let inventory: ApplePhysicalInventory
    private let picker: any FileDestinationPicker
    private let temporaryDirectory: URL
    /// How long Record Screen records.
    static let recordingDuration: Duration = .seconds(10)

    init(
        inventory: ApplePhysicalInventory,
        picker: any FileDestinationPicker,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.inventory = inventory
        self.picker = picker
        self.temporaryDirectory = temporaryDirectory
        inventory.deviceDisabled = { [weak self] udid in self?.forget(udid: udid) }
    }

    // MARK: - Capabilities

    /// Whether the device may still be asked for `feature`: false once one
    /// of its calls answered that it lacks the capability.
    func isSupported(_ feature: PhysicalFeature, udid: String) -> Bool {
        !(unsupported[PhysicalDeviceOptIn.normalize(udid)]?.contains(feature) ?? false)
    }

    /// What a device offers as a `DeviceCapabilities` set.
    func capabilities(udid: String) -> DeviceCapabilities {
        .physicalApple(supportsRecording: isSupported(.screenRecording, udid: udid))
    }

    private func recordUnsupported(_ feature: PhysicalFeature, key: String) {
        unsupported[key, default: []].insert(feature)
    }

    /// A call made elsewhere (the screenshot preview) answered "not
    /// supported": remembered like this controller's own, so the stage stops
    /// asking.
    func noteUnsupported(_ feature: PhysicalFeature, udid: String) {
        recordUnsupported(feature, key: PhysicalDeviceOptIn.normalize(udid))
    }

    // MARK: - Info

    /// Reads the Info card's four answers, concurrently. Nothing is sent to
    /// a device that is not enabled, paired and connected. A read that
    /// failed keeps its fields; when all four failed the reason shows
    /// (`infoErrors`).
    func refreshInfo(udid: String) async {
        let key = PhysicalDeviceOptIn.normalize(udid)
        guard let client = await inventory.client(for: key) else { return }
        async let details = Self.outcome { try await client.details().value }
        async let lock = Self.outcome { try await client.lockState().value }
        async let ddi = Self.outcome { try await client.ddiServices().value }
        async let displays = Self.outcome { try await client.displays().value }
        let (detailsResult, lockResult, ddiResult, displaysResult) = await (details, lock, ddi, displays)
        // The device may have been disabled while the reads ran.
        guard let current = inventory.entry(udid: key), current.isEnabled else { return }
        infos[key] = PhysicalDeviceInfo.make(
            entry: current,
            details: detailsResult.value,
            lockState: lockResult.value,
            ddi: ddiResult.value,
            displays: displaysResult.value,
            previous: infos[key]
        )
        let failures = [detailsResult.error, lockResult.error, ddiResult.error, displaysResult.error]
        if let first = failures.compactMap({ $0 }).first, failures.allSatisfy({ $0 != nil }) {
            infoErrors[key] = Self.describe(first)
        } else {
            infoErrors[key] = nil
        }
    }

    // MARK: - Screenshot

    /// Takes a screenshot (`devicectl device capture screenshot`, to a
    /// temporary PNG), keeps it as the device's last one and returns it.
    /// Nil when the device cannot be asked, is busy, lacks the capability or
    /// the call failed (the reason is in `messages`).
    func takeScreenshot(udid: String) async -> Data? {
        let key = PhysicalDeviceOptIn.normalize(udid)
        guard operations[key] == nil, isSupported(.screenshot, udid: key),
              let client = await inventory.client(for: key)
        else { return nil }
        operations[key] = .screenshot
        messages[key] = nil
        defer { operations[key] = nil }
        let file = temporaryDirectory.appendingPathComponent("devicehubpro-physical-\(UUID().uuidString).png")
        defer {
            // Best effort: a leftover temporary file must not fail a capture.
            try? FileManager.default.removeItem(at: file)
        }
        do {
            _ = try await client.screenshot(to: file)
            let decoded = try await Task.detached { try DecodedScreenshot.load(file) }.value
            screenshots[key] = Screenshot(png: decoded.png, date: Date(), image: decoded.image)
            return decoded.png
        } catch {
            fail(error, feature: .screenshot, action: "Screenshot", key: key)
            return nil
        }
    }

    // MARK: - Screen recording

    /// Records the screen for `recordingDuration` (`devicectl device capture
    /// screen-record`, to a temporary `.mp4`), then asks where to save it.
    /// A device that answers "not supported" is remembered and its button
    /// hidden.
    func recordScreen(udid: String) async {
        let key = PhysicalDeviceOptIn.normalize(udid)
        guard operations[key] == nil, isSupported(.screenRecording, udid: key),
              let client = await inventory.client(for: key)
        else { return }
        operations[key] = .recording
        messages[key] = nil
        defer { operations[key] = nil }
        let file = temporaryDirectory.appendingPathComponent("devicehubpro-physical-\(UUID().uuidString).mp4")
        defer {
            // Best effort: a leftover temporary file must not fail a recording.
            try? FileManager.default.removeItem(at: file)
        }
        do {
            _ = try await client.screenRecord(to: file, duration: Self.recordingDuration)
        } catch {
            fail(error, feature: .screenRecording, action: "Recording", key: key)
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        guard let destination = picker.chooseDestination(
            suggestedName: "devicehubpro-\(formatter.string(from: Date())).mp4",
            directory: picker.autoSaveDirectory
        ) else {
            messages[key] = "Recording discarded."
            return
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: file, to: destination)
            messages[key] = "Saved \(destination.lastPathComponent)."
        } catch {
            messages[key] = "Could not save the recording: \(error.localizedDescription)"
        }
    }

    // MARK: - Forgetting

    /// The user stopped using the device: what was read and kept for it goes.
    func forget(udid: String) {
        let key = PhysicalDeviceOptIn.normalize(udid)
        infos[key] = nil
        infoErrors[key] = nil
        screenshots[key] = nil
        messages[key] = nil
        operations[key] = nil
    }

    // MARK: - Errors

    private func fail(_ error: Error, feature: PhysicalFeature, action: String, key: String) {
        if case DevicectlPhysicalError.unsupportedCapability = error {
            recordUnsupported(feature, key: key)
            messages[key] = "This device does not support \(feature.title)."
        } else {
            messages[key] = "\(action) failed: \(Self.describe(error))"
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case let error as DevicectlPhysicalError: error.description
        case let error as DevicectlError: error.frames.first?.message ?? error.description
        case let error as DevicectlClientError: "\(error)"
        default: error.localizedDescription
        }
    }

    /// One read's answer or its error, so the reads run side by side and a
    /// failed one does not cancel the others.
    private struct Outcome<Value: Sendable>: Sendable {
        let value: Value?
        let error: Error?

        init(_ value: Value) {
            self.value = value
            error = nil
        }

        init(error: Error) {
            value = nil
            self.error = error
        }
    }

    private static func outcome<Value: Sendable>(_ read: @Sendable () async throws -> Value) async -> Outcome<Value> {
        do {
            return Outcome(try await read())
        } catch {
            return Outcome(error: error)
        }
    }
}
