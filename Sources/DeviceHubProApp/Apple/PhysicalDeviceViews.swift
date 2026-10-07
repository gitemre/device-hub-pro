import AppKit
import SwiftUI
import DeviceHubProKit

/// The rows of a physical Apple device's Info card, as pure data, in
/// Device Hub's order: what the inspector shows
/// for a listed device, from the list entry and, once the device is enabled
/// and answered, the four `device info` reads (`PhysicalDeviceInfo`).
///
/// Device Hub's cards: Name and OS ("iOS 27.0", no build); Capacity (only
/// where `details` reports it), ECID, Model, Product Type, Serial Number and
/// UDID; Display ("1170 × 2532"). Device Hub Pro's own rows (OS Build, Pairing,
/// Connection, Developer Mode, Developer Disk Image, Lock State) are in
/// Edit Visibility and hidden by default. The values are the ones the device
/// reports: it is the user's own app.
enum PhysicalInfoLayout {
    struct Row: Equatable {
        let property: PhysicalInfoProperty
        let value: String

        var label: String { property.title }

        init(_ property: PhysicalInfoProperty, _ value: String) {
            self.property = property
            self.value = value
        }
    }

    /// The cards, top to bottom: one per section that has a visible row
    /// with a value. A device that is not enabled shows only what the list
    /// said (no command was sent). An unread Display shows two dashes, like
    /// Device Hub's.
    static func cards(
        entry: ApplePhysicalEntry,
        info: PhysicalDeviceInfo?,
        visible: Set<PhysicalInfoProperty> = PhysicalInfoProperty.defaultVisible
    ) -> [[Row]] {
        let info = info ?? PhysicalDeviceInfo.make(entry: entry, details: nil, lockState: nil, ddi: nil, displays: nil)
        return PhysicalInfoProperty.Section.allCases.compactMap { section in
            let rows: [Row] = section.properties.compactMap { property in
                guard visible.contains(property) else { return nil }
                if property == .display, entry.isEnabled {
                    return Row(property, value(of: property, entry: entry, info: info) ?? "--")
                }
                return value(of: property, entry: entry, info: info).map { Row(property, $0) }
            }
            return rows.isEmpty ? nil : rows
        }
    }

    /// The value of `property`; nil where the device has none (its row is
    /// left out).
    static func value(of property: PhysicalInfoProperty, entry: ApplePhysicalEntry, info: PhysicalDeviceInfo) -> String? {
        switch property {
        case .name: return info.name
        case .os: return info.osLabel
        case .osBuild: return info.osBuild
        case .capacity: return info.capacityBytes.map(capacityText)
        case .ecid: return info.ecid
        case .model: return info.marketingName
        case .productType: return info.modelIdentifier
        case .serialNumber: return info.serialNumber
        case .udid: return info.udid ?? entry.udid
        case .display:
            guard entry.isEnabled else { return nil }
            return info.screenSize.map { $0.hasSuffix(" px") ? String($0.dropLast(3)) : $0 }
        case .pairing: return info.pairing
        case .connection: return connectionText(info)
        case .developerMode: return info.developerMode
        case .developerDiskImage: return entry.isEnabled ? info.developerDiskImage : nil
        case .lockState: return entry.isEnabled ? info.lockState : nil
        }
    }

    /// "64 GB": the decimal units storage is sold in.
    static func capacityText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }

    /// "Connected · Wired".
    static func connectionText(_ info: PhysicalDeviceInfo) -> String? {
        let parts = [info.connection, info.transport].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// What the chrome of a physical device depends on: its model identifier and
/// whether Xcode's device types were listed yet.
struct PhysicalChromeLoadKey: Equatable {
    let productType: String?
    let deviceTypeCount: Int
}

/// The stage of a selected physical iPhone or iPad: a static panel (
/// is manage-only, there is no live screen). The device's glyph, name,
/// model, OS and state; "Use This Device…" until the user enables it; then
/// Take Screenshot (and Record Screen, until the device reports it
/// unsupported) and the last screenshot. An app or a link dropped on it
/// installs or opens.
struct PhysicalDeviceStageView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    let entry: ApplePhysicalEntry

    var body: some View {
        let devices = model.physicalDevices
        let operation = devices.operations[entry.udid]
        VStack(spacing: 14) {
            Image(systemName: entry.symbolName)
                .font(.system(size: 88, weight: .thin))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(entry.name)
                    .font(.title2.weight(.semibold))
                Text([entry.modelName, entry.osLabel].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
            }

            Text(entry.stateLabel)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(stateColor.opacity(0.18), in: Capsule())
                .foregroundStyle(stateColor)

            if let hint = entry.hint {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            if entry.isEnabled {
                enabledControls(devices: devices, operation: operation)
            } else {
                Button("Use This Device…") {
                    model.physicalInventory.requestEnable(entry)
                }
                .glassProminentButton()
            }

            if let screenshot = devices.screenshots[entry.udid], let image = screenshot.image {
                VStack(spacing: 4) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(radius: 3, y: 1)
                        .accessibilityLabel("Last screenshot of \(entry.name)")
                    Text("Screenshot at \(screenshot.date.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            if let message = devices.messages[entry.udid] {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            if entry.isEnabled, entry.state == .ready {
                // Why the live capture is not showing, when it is not (the
                // switches themselves are menu items).
                PhysicalStatusLineView(session: nil)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        // The live view draws the phone in its Apple chrome: read here, ahead
        // of the session, from the device type with the phone's model
        // identifier (`SimulatorInventory.loadDisplayShape(forModelIdentifier:)`).
        .task(id: PhysicalChromeLoadKey(
            productType: entry.device.productType,
            deviceTypeCount: model.simulators.deviceTypes.count
        )) {
            await model.simulators.loadDisplayShape(forModelIdentifier: entry.device.productType)
        }
        // An app installs, a link opens and any other file is copied into an
        // app's Documents (`SendFilesController`); a device that cannot be
        // asked takes nothing.
        .sendFilesDrop(
            controller: workspace.sendFiles,
            platform: .apple,
            target: { entry.canUseClient ? .physical(udid: entry.udid) : nil }
        )
    }

    @ViewBuilder
    private func enabledControls(devices: ApplePhysicalController, operation: ApplePhysicalController.Operation?) -> some View {
        let ready = entry.state == .ready && operation == nil
        HStack(spacing: 10) {
            if devices.isSupported(.screenshot, udid: entry.udid) {
                Button {
                    Task { await takeScreenshot() }
                } label: {
                    Label(operation == .screenshot ? "Taking Screenshot…" : "Take Screenshot", systemImage: "camera")
                }
                .glassProminentButton()
                .disabled(!ready)
            }
            if devices.isSupported(.screenRecording, udid: entry.udid) {
                Button {
                    Task { await devices.recordScreen(udid: entry.udid) }
                } label: {
                    Label(
                        operation == .recording ? "Recording…" : "Record Screen",
                        systemImage: "record.circle"
                    )
                }
                .glassButton()
                .disabled(!ready)
            }
        }
        if operation != nil {
            ProgressView()
                .controlSize(.small)
        }
        if !entry.isEnabledByLaunchOption {
            Button("Stop Using This Device") {
                model.physicalInventory.disable(udid: entry.udid)
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
        }
    }

    /// A screenshot goes through the annotation editor and its save panel,
    /// where every other device's screenshots go, and stays in the stage.
    private func takeScreenshot() async {
        guard let png = await model.physicalDevices.takeScreenshot(udid: entry.udid) else { return }
        workspace.capture.editScreenshot(png)
    }

    private var stateColor: Color {
        switch entry.state {
        case .ready: .green
        case .notEnabled: .secondary
        case .unpaired, .disconnected, .developerModeOff, .restarting: .orange
        }
    }
}

/// The confirmation "Use This Device…" shows, naming the device. Hosted by
/// the window's content; the inventory holds the pending question.
struct PhysicalDeviceEnableDialogHost: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let inventory = model.physicalInventory
        content.alert(
            "Use \"\(inventory.pendingEnable?.name ?? "this device")\" with Device Hub Pro?",
            isPresented: Binding(
                get: { inventory.pendingEnable != nil },
                set: { if !$0 { inventory.pendingEnable = nil } }
            ),
            presenting: inventory.pendingEnable
        ) { entry in
            Button("Cancel", role: .cancel) { inventory.pendingEnable = nil }
            Button("Use This Device") { inventory.enable(udid: entry.udid) }
        } message: { entry in
            Text(
                "Device Hub Pro will read \(entry.name)'s state, list, launch, stop, install and uninstall its apps, "
                    + "read the files of development builds and its crash logs (nothing is ever deleted on it), "
                    + "and take screenshots and record its screen. "
                    + "It pairs a phone only when you press Pair in Pair Nearby Device, and never trusts it or changes "
                    + "Developer Mode: those stay your own steps on the phone. "
                    + "You can stop using it any time."
            )
        }
    }
}
