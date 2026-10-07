import SwiftUI
import DeviceHubProKit

// A simulator's Controls rows, in Device Hub's row language (the DH*
// primitives the Android panel uses). `AppleControlsView` lays them out in
// `AppleControlsController.simulatorCards` (a physical iPhone in
// `groups`); each reads and writes through `workspace.appleControls`. Titles
// are the manifest's `ios` labels (`controls-rows.json`, checked by
// `ControlsRowManifestTests`). Pop-ups are real menus (`DHMenuRow`), as Device
// Hub's are.

struct AppleControlsRowView: View {
    @Environment(DeviceWorkspace.self) private var workspace
    let row: ControlsRow
    let udid: String
    /// Opens the Location row's custom sheet.
    let showLocationSheet: () -> Void

    private var controls: AppleControlsController { workspace.appleControls }
    private var state: AppleControlsState { controls.state }

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        switch row {
        case .appearance: appearanceRow
        case .liquidGlass: liquidGlassRow
        case .textSize: textSizeRow
        case .reduceMotion:
            DHToggleRow(
                title: "Reduce Motion",
                glyph: "circle.dotted.circle",
                help: "devicectl device settings appearance --reduce-motion on|off, read back with devicectl device info appearance.",
                value: state.reduceMotion
            ) { await controls.setReduceMotion($0) }
            .disabled(controls.isBusy(.reduceMotion))
        case .showBorders:
            DHToggleRow(
                title: "Show Borders",
                glyph: "square.on.square.dashed",
                help: "iOS Button Shapes (devicectl --show-borders): buttons draw their shapes. On Android this row shows layout bounds instead.",
                value: state.showBorders
            ) { await controls.setShowBorders($0) }
            .disabled(controls.isBusy(.showBorders))
        case .reduceTransparency:
            DHToggleRow(
                title: "Reduce Transparency",
                glyph: "square.on.square.intersection.dashed",
                help: "devicectl device settings appearance --reduce-transparency on|off: blurs and glass turn opaque.",
                value: state.reduceTransparency
            ) { await controls.setReduceTransparency($0) }
            .disabled(controls.isBusy(.reduceTransparency))
        case .sound: soundRow
        case .audioOutput: audioRow(isOutput: true)
        case .audioInput: audioRow(isOutput: false)
        case .talkBack:
            DHToggleRow(
                title: "VoiceOver",
                glyph: "accessibility",
                help: controls.isPhysical
                    ? "devicectl device settings voiceover --enable|--disable, read back with devicectl device info voiceover. VoiceOver changes how the phone answers touches: turn it off again before you use the phone."
                    : "devicectl device settings voiceover --enable|--disable, read back with devicectl device info voiceover. The simulator speaks through the Mac.",
                value: state.voiceOver
            ) { await controls.setVoiceOver($0) }
            .disabled(controls.isBusy(.voiceOver))
        case .colorFilter: colorFilterRows
        case .increaseContrast:
            DHToggleRow(
                title: "Increase Contrast",
                glyph: "circle.lefthalf.filled",
                help: controls.route(.increaseContrast).mechanism?.command ?? "simctl ui increase_contrast enabled|disabled.",
                value: state.increaseContrast
            ) { await controls.setIncreaseContrast($0) }
            .disabled(controls.isBusy(.increaseContrast))
        case .location: locationRow
        default:
            EmptyView()
        }
    }

    // MARK: - Display & sound

    private var appearanceRow: some View {
        let modes: [AppleAppearanceOption] = [.init(dark: false), .init(dark: true)]
        let selected = state.dark.map { AppleAppearanceOption(dark: $0) }
        return DHMenuRow(
            title: "Appearance",
            glyph: "circle.lefthalf.filled",
            help: controls.route(.appearance).mechanism?.command ?? "",
            valueText: selected?.title ?? "Unknown",
            entries: {
                modes.map { mode in
                    .item(id: mode.title, title: mode.title, isSelected: mode == selected) {
                        Task { await controls.setAppearance(dark: mode.dark) }
                    }
                }
            }
        )
        .disabled(state.dark == nil || controls.isBusy(.appearance))
    }

    /// Device Hub's Liquid Glass: a Clear / Tinted pop-up on an iOS 26
    /// runtime (which lists both looks), a slider (the opacity) where the
    /// runtime lists the one look (iOS 27, and every phone on iOS 27).
    @ViewBuilder
    private var liquidGlassRow: some View {
        if state.supportedLooks.count > 1 {
            let selected = state.lookAndFeel
            DHMenuRow(
                title: "Liquid Glass",
                glyph: "rectangle.on.rectangle.angled",
                help: "devicectl device settings appearance --look-and-feel clear|tinted, read back with devicectl device info appearance.",
                valueText: selected?.title ?? "Unknown",
                entries: {
                    state.supportedLooks.map { look in
                        .item(id: look.rawValue, title: look.title, isSelected: look == selected) {
                            Task { await controls.setLookAndFeel(look) }
                        }
                    }
                }
            )
            .disabled(selected == nil || controls.isBusy(.liquidGlass))
        } else {
            let values = stride(from: 0.0, through: 1.0, by: 0.05).map { ($0 * 100).rounded() / 100 }
            let current = state.liquidGlassOpacity.map { value in values.min { abs($0 - value) < abs($1 - value) } ?? value }
            DHSliderRow(
                title: "Liquid Glass",
                glyph: "rectangle.on.rectangle.angled",
                help: "The Liquid Glass opacity, from fully translucent to fully opaque (devicectl --liquid-glass-opacity, read back).",
                values: values,
                value: current ?? 0.5,
                showsDots: false,
                accessibilityValue: current.map(AppleControlsText.percent) ?? "unknown",
                onLiveChange: nil,
                onCommit: { value in Task { await controls.setLiquidGlassOpacity(value) } }
            )
            .disabled(current == nil || controls.isBusy(.liquidGlass))
        }
    }

    private var textSizeRow: some View {
        let sizes = SimulatorContentSize.settable
        let index = state.textSize.flatMap { sizes.firstIndex(of: $0) }
        return DHSliderRow(
            title: "Text Size",
            glyph: "textformat.size",
            help: controls.isPhysical
                ? "The twelve iOS text sizes, the last five the accessibility sizes (devicectl device settings appearance --text-size, after --larger-accessibility-sizes on for those). The write happens when the slider is released."
                : "The twelve iOS text sizes, the last five the accessibility sizes (simctl ui content_size, which also turns Larger Accessibility Sizes on for those). The write happens when the slider is released.",
            values: sizes.indices.map(Double.init),
            value: Double(index ?? 3),
            showsDots: true,
            accessibilityValue: state.textSize.map(AppleControlsText.textSizeName) ?? "unknown",
            onLiveChange: nil,
            onCommit: { value in
                let position = min(max(Int(value.rounded()), 0), sizes.count - 1)
                Task { await controls.setTextSize(sizes[position]) }
            }
        )
        .disabled(index == nil || controls.isBusy(.textSize))
    }

    private var soundRow: some View {
        let volume = state.volume
        return DHSliderRow(
            title: "Sound",
            glyph: "speaker.wave.2",
            help: "The simulator's volume, 0–100 (devicectl device settings audio --volume, read back with devicectl device info audio).",
            values: (0...100).map(Double.init),
            value: Double(volume ?? 0),
            showsDots: false,
            tickCount: ParityMetrics.controlsSoundTickCount,
            accessibilityValue: volume.map { "\($0) percent" } ?? "unknown",
            onLiveChange: nil,
            onCommit: { value in Task { await controls.setVolume(Int(value.rounded())) } }
        )
        .disabled(volume == nil || controls.isBusy(.volume))
    }


    // MARK: - Output and Input

    /// Sound's Output or Input: None, System (the Mac's default device) and
    /// the Mac's own devices, listed when the menu opens. Device Hub's None
    /// leaves the row on System (measured), so it follows the default.
    private func audioRow(isOutput: Bool) -> some View {
        let pinned = isOutput ? state.audioOutput : state.audioInput
        let devices = isOutput ? MacAudioDevices.outputs() : MacAudioDevices.inputs()
        let valueText: String = switch pinned {
        case .systemDefault?: "System"
        case .device(let uid)?: devices.first { $0.uid == uid }?.name ?? uid
        case nil: "System"
        }
        func choose(_ device: DevicectlAudioDevice) {
            Task {
                if isOutput { await controls.setAudioOutput(device) } else { await controls.setAudioInput(device) }
            }
        }
        return DHMenuRow(
            title: isOutput ? "Output" : "Input",
            glyph: isOutput ? "headphones" : "mic",
            help: isOutput
                ? "devicectl device settings audio --output-device: the Mac device the simulator's sound plays on."
                : "devicectl device settings audio --input-device: the Mac device the simulator listens to.",
            valueText: valueText,
            entries: {
                let now = isOutput ? MacAudioDevices.outputs() : MacAudioDevices.inputs()
                var entries: [DHMenuEntry] = [
                    .item(id: "none", title: "None") { choose(.systemDefault) },
                    .separator(id: "separator"),
                    .item(id: "system", title: "System", isSelected: pinned != nil && pinned == .systemDefault) {
                        choose(.systemDefault)
                    },
                ]
                for device in now {
                    entries.append(.item(id: device.uid, title: device.name, isSelected: pinned == .device(device.uid)) {
                        choose(.device(device.uid))
                    })
                }
                return entries
            }
        )
        .disabled(pinned == nil || controls.isBusy(.volume))
    }

    // MARK: - Accessibility

    @ViewBuilder
    private var colorFilterRows: some View {
        let types: [SimulatorColorFilterType?] = [nil, .protanopia, .deuteranopia, .tritanopia, .grayscale]
        let selected = state.colorFilter
        DHMenuRow(
            title: "Color Filter",
            glyph: "camera.filters",
            help: "devicectl --color-filter-type with its intensity, or --color-filter off; read back with devicectl device info appearance. Apps can read only whether Grayscale is on.",
            valueText: AppleControlsText.colorFilterShortTitle(selected ?? nil),
            entries: {
                var entries: [DHMenuEntry] = []
                for type in types {
                    if type == .protanopia || type == .grayscale { entries.append(.separator(id: "separator.\(type!.rawValue)")) }
                    entries.append(.item(
                        id: type?.rawValue ?? "off",
                        title: type == nil ? "None" : AppleControlsText.colorFilterTitle(type),
                        isSelected: selected.map { $0 == type } ?? false
                    ) {
                        Task { await controls.setColorFilter(type) }
                    })
                }
                return entries
            }
        )
        .disabled(state.colorFilter == nil || controls.isBusy(.colorFilter))
        if case .some(let type?) = state.colorFilter, type.hasIntensity {
            DHHairline()
            let values = stride(from: 0.25, through: 1.0, by: 0.05).map { ($0 * 100).rounded() / 100 }
            let intensity = state.colorFilterIntensity ?? 1
            DHSliderRow(
                title: "Intensity",
                glyph: "slider.horizontal.3",
                help: "The filter's intensity, 25–100 % (Grayscale has none).",
                values: values,
                value: values.min { abs($0 - intensity) < abs($1 - intensity) } ?? intensity,
                showsDots: false,
                accessibilityValue: AppleControlsText.percent(intensity),
                onLiveChange: nil,
                onCommit: { value in Task { await controls.setColorFilterIntensity(value) } }
            )
            .disabled(controls.isBusy(.colorFilter))
        }
    }

    // MARK: - Location

    /// The Location menu. A simulator shows the shared menu
    /// (`LocationMenuModel`, the same items as an emulator's): None, the
    /// fourteen places, the Trips `simctl location list` names (a simulator
    /// runs Apple's own scenarios) and Custom Location…. A physical iPhone
    /// keeps its own subset: None, the places and Custom Coordinates…
    /// (devicectl cannot run a trip).
    private var locationRow: some View {
        let current = controls.location
        return DHMenuRow(
            title: "Location",
            glyph: "location.circle",
            help: controls.isPhysical
                ? "devicectl device simulate location coordinate (a place or a coordinate) or clear. The phone keeps the simulated location until you choose None, even after Device Hub Pro quits; devicectl cannot read it back, so the row shows what Device Hub Pro set."
                : "simctl location set (a place), run (a trip), start (a route between two points) or clear. simctl cannot read the location back, so the row shows what Device Hub Pro set, and sets it again when Device Hub Pro starts or restarts the simulator.",
            valueText: current?.title ?? LocationMenuModel.noneTitle,
            entries: {
                let trips = controls.isPhysical ? [] : LocationMenuModel.trips(named: controls.locationScenarios)
                return LocationMenuModel.entries(trips: trips).map { entry in
                    switch entry {
                    case .none:
                        return .item(id: entry.id, title: LocationMenuModel.noneTitle, isSelected: current == nil) {
                            Task { await controls.setLocation(nil) }
                        }
                    case .separator(let id):
                        return .separator(id: id)
                    case .place(let place):
                        return .item(id: entry.id, title: place.name, isSelected: current == place.choice) {
                            Task { await controls.setLocation(place.choice) }
                        }
                    case .header(let title):
                        return .header(id: entry.id, title: title)
                    case .trip(let trip):
                        return .item(id: entry.id, title: trip.name, isSelected: current == .scenario(trip.name)) {
                            Task { await controls.setLocation(.scenario(trip.name)) }
                        }
                    case .custom:
                        return .item(
                            id: entry.id,
                            title: controls.isPhysical ? "Custom Coordinates…" : LocationMenuModel.customTitle
                        ) { showLocationSheet() }
                    }
                }
            }
        )
        .disabled(controls.isBusy(.location))
    }

}

// MARK: - Options

struct AppleAppearanceOption: Identifiable, Hashable {
    let dark: Bool
    var id: Bool { dark }
    var title: String { dark ? "Dark" : "Light" }
}

/// Device Hub's Location menu places, in its order (the fourteen the menu
/// lists on Device Hub 27.0; the coordinates are the cities' own).
struct AppleLocationPlace: Identifiable, Hashable {
    let name: String
    let latitude: Double
    let longitude: Double
    var id: String { name }
    var choice: AppleLocationChoice { .coordinate(name: name, latitude: latitude, longitude: longitude) }
}

enum AppleLocationPlaces {
    static let all: [AppleLocationPlace] = [
        AppleLocationPlace(name: "Berlin, Germany", latitude: 52.5200, longitude: 13.4050),
        AppleLocationPlace(name: "Cupertino, CA, USA", latitude: 37.3230, longitude: -122.0322),
        AppleLocationPlace(name: "Hong Kong, China", latitude: 22.3193, longitude: 114.1694),
        AppleLocationPlace(name: "Johannesburg, South Africa", latitude: -26.2041, longitude: 28.0473),
        AppleLocationPlace(name: "London, England", latitude: 51.5074, longitude: -0.1278),
        AppleLocationPlace(name: "Mexico City, Mexico", latitude: 19.4326, longitude: -99.1332),
        AppleLocationPlace(name: "Mumbai, India", latitude: 19.0760, longitude: 72.8777),
        AppleLocationPlace(name: "New York, NY, USA", latitude: 40.7128, longitude: -74.0060),
        AppleLocationPlace(name: "Paris, France", latitude: 48.8566, longitude: 2.3522),
        AppleLocationPlace(name: "Rio de Janeiro, Brazil", latitude: -22.9068, longitude: -43.1729),
        AppleLocationPlace(name: "San Francisco, CA, USA", latitude: 37.7749, longitude: -122.4194),
        AppleLocationPlace(name: "Sydney, Australia", latitude: -33.8688, longitude: 151.2093),
        AppleLocationPlace(name: "Tokyo, Japan", latitude: 35.6762, longitude: 139.6503),
        AppleLocationPlace(name: "Warsaw, Poland", latitude: 52.2297, longitude: 21.0122),
    ]
}

struct AppleColorFilterOption: Identifiable, Hashable {
    let type: SimulatorColorFilterType?
    var id: String { type?.rawValue ?? "off" }
}

struct AppleRecentLink: Identifiable, Hashable {
    let uri: String
    var id: String { uri }
}

