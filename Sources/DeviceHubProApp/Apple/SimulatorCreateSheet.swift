import AppKit
import SwiftUI
import DeviceHubProKit

/// Which simulator runtimes Device Hub still shows (S1): a device whose
/// runtime's equivalent iOS version is below 17.0 is hidden ("Hiding device
/// … - OS version too old (equivalent iOS version …)", logged by CoreDevice's
/// simulator plug-in). The 17.0 threshold, and that a device without a
/// runtime is never checked, were established against Xcode 27.0
/// (CoreSimulator 1171.7) on 2026-09-26; the notes stay outside the
/// repository (AGENTS.md, iOS rules). Re-check it with each Xcode major.
enum SimulatorOSSupport {
    /// The oldest equivalent iOS major version that is shown (17.0).
    static let oldestEquivalentIOSMajor = 17

    /// The iOS major version a runtime's version stands beside: tvOS shares
    /// iOS's numbers; watchOS (up to 11) is iOS − 7 and visionOS (up to 2)
    /// iOS − 16; from 26 every platform shares iOS's number. Nil when the
    /// platform or version is unknown.
    static func equivalentIOSMajor(platform: String?, version: String?) -> Int? {
        guard let major = version?.split(separator: ".").first.flatMap({ Int($0) }) else { return nil }
        switch platform {
        case "iOS", "tvOS":
            return major
        case "watchOS":
            return major >= 26 ? major : major + 7
        case "xrOS", "visionOS":
            return major >= 26 ? major : major + 16
        default:
            return nil
        }
    }

    /// Whether a runtime is too old to show (unknown ones are kept).
    static func isTooOld(platform: String?, version: String?) -> Bool {
        guard let major = equivalentIOSMajor(platform: platform, version: version) else { return false }
        return major < oldestEquivalentIOSMajor
    }

    /// Whether dotted version `lhs` is newer than `rhs` ("27.0" > "26.5").
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l > r }
        }
        return false
    }
}

/// The families of Device Hub's + menu (S6): each is a device-type product
/// family and the runtime platform it runs.
enum SimulatorFamily: String, CaseIterable, Identifiable, Sendable {
    case iPhone
    case iPad
    case appleWatch
    case appleTV
    case appleVision

    var id: String { rawValue }

    /// `productFamily` of `simctl list -j devicetypes`.
    var productFamily: String {
        switch self {
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        case .appleWatch: "Apple Watch"
        case .appleTV: "Apple TV"
        case .appleVision: "Apple Vision"
        }
    }

    /// `platform` of `simctl list -j runtimes`.
    var runtimePlatform: String {
        switch self {
        case .iPhone, .iPad: "iOS"
        case .appleWatch: "watchOS"
        case .appleTV: "tvOS"
        case .appleVision: "xrOS"
        }
    }

    /// The + menu's item (Device Hub's family names).
    var menuTitle: String {
        switch self {
        case .iPhone: "iPhone…"
        case .iPad: "iPad…"
        case .appleWatch: "Apple Watch…"
        case .appleTV: "Apple TV…"
        case .appleVision: "Apple Vision Pro…"
        }
    }

    /// The sheet's title.
    var sheetTitle: String {
        switch self {
        case .iPhone: "New iPhone Simulator"
        case .iPad: "New iPad Simulator"
        case .appleWatch: "New Apple Watch Simulator"
        case .appleTV: "New Apple TV Simulator"
        case .appleVision: "New Apple Vision Pro Simulator"
        }
    }

    /// The families the + and File menus offer: all five, as Device Hub lists
    /// them. One with no runtime installed opens the sheet with "No Runtimes
    /// Available" (Device Hub's own state for Apple Watch and Apple Vision
    /// Pro on a Mac without those platforms).
    static func offered(runtimes: [SimulatorRuntime]) -> [SimulatorFamily] {
        allCases
    }
}

/// The New Simulator sheet's choices (Device Hub's S7, without the runtime
/// build pin): a name, a model of the family and an OS version that runs it.
///
/// The OS versions are every installed, available, not-too-old runtime of the
/// family's platform, newest first (Device Hub lists iOS 26.5 beside 27.0
/// although the newest model runs on 27.0 only). The models offered are the
/// family's device types the chosen runtime supports, in the catalog's order
/// (newest first). Choosing an OS version keeps the model when it runs there,
/// else takes the first that does; choosing a model keeps the OS version when
/// it runs the model, else takes the newest that does. The name follows the
/// model until the user types one.
struct SimulatorCreateDraft: Equatable {
    let family: SimulatorFamily
    /// The family's usable runtimes, newest first.
    let runtimes: [SimulatorRuntime]
    /// The family's device types some runtime supports, catalog order.
    let models: [SimulatorDeviceType]
    private(set) var name: String
    private(set) var modelIdentifier: String?
    private(set) var runtimeIdentifier: String?
    private(set) var nameEdited = false

    init(family: SimulatorFamily, runtimes allRuntimes: [SimulatorRuntime], deviceTypes: [SimulatorDeviceType]) {
        self.family = family
        let runtimes = allRuntimes
            .filter { $0.isAvailable && $0.platform == family.runtimePlatform }
            .filter { !SimulatorOSSupport.isTooOld(platform: $0.platform, version: $0.version) }
            .sorted { SimulatorOSSupport.isNewer($0.version, than: $1.version) }
        self.runtimes = runtimes
        let supported = Set(runtimes.flatMap(\.supportedDeviceTypeIdentifiers))
        models = deviceTypes.filter { $0.productFamily == family.productFamily && supported.contains($0.identifier) }
        name = ""
        runtimeIdentifier = runtimes.first?.identifier
        if let first = availableModels.first {
            selectModel(first.identifier)
        }
    }

    /// Every usable runtime of the platform, newest first.
    var osVersions: [SimulatorRuntime] { runtimes }

    /// The models the chosen OS version runs, catalog order.
    var availableModels: [SimulatorDeviceType] {
        guard let runtime else { return [] }
        let supported = Set(runtime.supportedDeviceTypeIdentifiers)
        return models.filter { supported.contains($0.identifier) }
    }

    /// The runtimes that run a model, newest first.
    private func runtimes(running identifier: String) -> [SimulatorRuntime] {
        runtimes.filter { $0.supportedDeviceTypeIdentifiers.contains(identifier) }
    }

    var model: SimulatorDeviceType? { models.first { $0.identifier == modelIdentifier } }
    var runtime: SimulatorRuntime? { runtimes.first { $0.identifier == runtimeIdentifier } }

    /// No runtime for the family is installed: the sheet offers Xcode's
    /// platform download instead.
    var needsPlatform: Bool { runtimes.isEmpty }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canCreate: Bool {
        guard !trimmedName.isEmpty, let model, let runtime else { return false }
        return runtime.supportedDeviceTypeIdentifiers.contains(model.identifier)
    }

    mutating func selectModel(_ identifier: String) {
        guard let chosen = models.first(where: { $0.identifier == identifier }) else { return }
        modelIdentifier = chosen.identifier
        let running = runtimes(running: chosen.identifier)
        if !running.contains(where: { $0.identifier == runtimeIdentifier }) {
            runtimeIdentifier = running.first?.identifier
        }
        if !nameEdited {
            name = chosen.name
        }
    }

    mutating func selectRuntime(_ identifier: String) {
        guard osVersions.contains(where: { $0.identifier == identifier }) else { return }
        runtimeIdentifier = identifier
        // The Model popup follows: a model the OS version does not run gives
        // way to the first one it does.
        if let current = modelIdentifier, availableModels.contains(where: { $0.identifier == current }) { return }
        if let first = availableModels.first {
            selectModel(first.identifier)
        } else {
            modelIdentifier = nil
        }
    }

    /// A typed name; an emptied field is Device Hub's placeholder again: the
    /// model's name, which it follows.
    mutating func setName(_ newName: String) {
        let blank = newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        nameEdited = !blank
        name = blank ? (model?.name ?? "") : newName
    }
}

/// Device Hub's New Simulator sheet (S7), measured on DH 27.0 (2026-09-29): a
/// 470 pt sheet with no title, a rounded card of Name / OS Version / Model
/// rows (an empty Name shows the model's name as its placeholder), a rule,
/// then Cancel and a blue Create. Without a runtime for the family the
/// rows read "No Runtimes Available" and "No Models Available"; the OS
/// Version row's menu points to Xcode's platform download ("Add Platforms in
/// Xcode", `xcode://settings/components/addSimulator`).
struct SimulatorCreateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(DeviceWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let family: SimulatorFamily
    /// The device type the sheet was opened for (the Browse Catalog's card):
    /// preselected as the Model when an installed runtime runs it.
    var preferredModel: String? = nil
    /// Called after the simulator was created, before the sheet dismisses.
    var onCreated: (() -> Void)? = nil
    @State private var draft: SimulatorCreateDraft?
    @State private var isCreating = false

    /// Device Hub's handoff to Xcode's Components settings.
    static let addPlatformsURL = URL(string: "xcode://settings/components/addSimulator")

    /// Opens Xcode's platform download; when macOS has no handler for the
    /// `xcode://` link (an Xcode that is not registered yet), opens Xcode
    /// itself instead of doing nothing. The closures are the tests' seam.
    @MainActor
    static func openAddPlatforms(
        open: (URL) -> Bool = { NSWorkspace.shared.open($0) },
        openXcode: () -> Void = {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    ) {
        guard let url = addPlatformsURL else { return openXcode() }
        if !open(url) { openXcode() }
    }

    /// The sheet's measured metrics.
    static let width: CGFloat = 470
    static let cardInset: CGFloat = 20
    static let rowHeight: CGFloat = 39.2
    static let rowInset: CGFloat = 10
    static let fieldWidth: CGFloat = 225.5

    var body: some View {
        VStack(spacing: 0) {
            if let draft {
                card(draft)
                    .padding(Self.cardInset)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(30)
            }
            Divider()
            footer
        }
        .frame(width: Self.width)
        .task {
            // Best effort: the catalogs load with the provider.
            await model.simulators.refresh()
            var made = SimulatorCreateDraft(
                family: family,
                runtimes: model.simulators.runtimes,
                deviceTypes: model.simulators.deviceTypes
            )
            if let preferredModel { made.selectModel(preferredModel) }
            draft = made
        }
    }

    private func card(_ current: SimulatorCreateDraft) -> some View {
        VStack(spacing: 0) {
            row("Name:") {
                TextField(
                    "",
                    text: Binding(
                        get: { draft?.nameEdited == true ? (draft?.name ?? "") : "" },
                        set: { draft?.setName($0) }
                    ),
                    prompt: Text(current.model?.name ?? "")
                )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .labelsHidden()
                .frame(width: Self.fieldWidth)
            }
            Divider().padding(.horizontal, Self.rowInset)
            row("OS Version:") { osVersionMenu(current) }
            Divider().padding(.horizontal, Self.rowInset)
            row("Model:") { modelMenu(current) }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .quaternarySystemFill))
        )
        .disabled(isCreating)
    }

    private func row<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, Self.rowInset)
        .frame(height: Self.rowHeight)
    }

    private func osVersionMenu(_ current: SimulatorCreateDraft) -> some View {
        Menu {
            ForEach(current.osVersions) { runtime in
                Toggle(runtime.name, isOn: Binding(
                    get: { current.runtimeIdentifier == runtime.identifier },
                    set: { if $0 { draft?.selectRuntime(runtime.identifier) } }
                ))
            }
            if !current.osVersions.isEmpty { Divider() }
            Button("Add Platforms in Xcode\u{2026}") { addPlatforms() }
        } label: {
            Text(current.needsPlatform ? "No Runtimes Available" : (current.runtime?.name ?? ""))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .modifier(DHSheetPopupChrome(symbol: "chevron.down"))
    }

    private func modelMenu(_ current: SimulatorCreateDraft) -> some View {
        Menu {
            ForEach(current.availableModels) { type in
                Toggle(type.name, isOn: Binding(
                    get: { current.modelIdentifier == type.identifier },
                    set: { if $0 { draft?.selectModel(type.identifier) } }
                ))
            }
        } label: {
            Text(current.availableModels.isEmpty ? "No Models Available" : (current.model?.name ?? ""))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(current.availableModels.isEmpty)
        .modifier(DHSheetPopupChrome())
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if isCreating {
                ProgressView().controlSize(.small)
                Text("Creating \(draft?.trimmedName ?? "")\u{2026}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isCreating)
            Button("Create") { create() }
                .glassProminentButton()
                .keyboardShortcut(.defaultAction)
                .disabled(draft?.canCreate != true || isCreating)
        }
        .padding(.horizontal, 16)
        .padding(.top, 17)
        .padding(.bottom, 16)
    }

    /// Opens Xcode's Components settings with the "Select simulators to
    /// download and install" sheet; this sheet and its selection stay.
    private func addPlatforms() {
        Self.openAddPlatforms()
    }

    private func create() {
        guard let draft, draft.canCreate, let type = draft.model, let runtime = draft.runtime, !isCreating else { return }
        isCreating = true
        Task {
            let udid = await model.simulatorLifecycle.create(
                name: draft.trimmedName,
                deviceTypeIdentifier: type.identifier,
                runtimeIdentifier: runtime.identifier
            )
            isCreating = false
            guard let udid else { return }
            workspace.deviceSelection = .simulator(udid)
            onCreated?()
            dismiss()
        }
    }
}
