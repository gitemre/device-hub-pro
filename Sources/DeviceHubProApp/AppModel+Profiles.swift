import Foundation
import DeviceHubProKit

/// Settings profiles over the devices (Device Hub Pro's addition beyond Device
/// Hub): apply one to the current device or to every selected device, and
/// save what the current device reads as a new profile. Applying goes
/// through Apply to Selected's path (`MultiDeviceController`,
/// `BatchPlanner`, `BatchPerformer`), so an emulator, a simulator and a
/// phone mix in one selection, each taking the settings its platform has and
/// reporting the rest.
extension AppModel {
    /// The devices a profile goes to: the multi-selection's rows, else the
    /// device shown. A physical Apple device and a Pixel catalog row are not
    /// targets.
    func profileTargets(in target: DeviceWorkspace? = nil) -> [BatchTarget] {
        let ws = target ?? registry.focused ?? workspace
        if ws.multiSelection.isMultiple { return batchTargets(in: ws) }
        guard let row = ws.deviceSelection,
              let target = BatchTargeting.target(for: row, in: batchTargetingSnapshot)
        else { return [] }
        return [target]
    }

    /// A single device must be running: a stopped one was offered the
    /// profiles only to answer "Skipped the device: Not running", while every
    /// other setting item of its Device menu is off. A multi-selection keeps
    /// them (its stopped members are skipped and named).
    func canApplyProfile(in target: DeviceWorkspace? = nil) -> Bool {
        let ws = target ?? registry.focused ?? workspace
        let targets = profileTargets(in: ws)
        guard !multiDevice.isRunning, !targets.isEmpty else { return false }
        return ws.multiSelection.isMultiple || targets.contains { $0.ref != nil }
    }

    func applyProfile(_ profile: SettingsProfile, in target: DeviceWorkspace? = nil) async {
        let targets = profileTargets(in: target)
        guard !targets.isEmpty else {
            status.errorMessage = "Select an Android device or a simulator to apply a profile to."
            return
        }
        let ws = target ?? registry.focused ?? workspace
        await multiDevice.run(.profile(profile), on: targets,
                              excluded: ws.multiSelection.isMultiple ? batchExcludedNames(in: ws) : [])
    }

    /// What the device shown reads now, for Save Current Settings as
    /// Profile…; nil when it is not a running device the controllers read.
    func currentProfileReadings(in target: DeviceWorkspace? = nil) -> ProfileReadings? {
        let ws = target ?? registry.focused ?? workspace
        guard let row = ws.deviceSelection else { return nil }
        switch row {
        case .avd, .device:
            guard ws.menuTargetSerial != nil else { return nil }
            return androidReadings(in: ws)
        case .simulator(let udid):
            return appleReadings(udid: udid, in: ws)
        case .pixel, .physicalApple:
            return nil
        }
    }

    func canSaveCurrentProfile(in target: DeviceWorkspace? = nil) -> Bool { currentProfileReadings(in: target) != nil }

    private func androidReadings(in workspace: DeviceWorkspace) -> ProfileReadings {
        let panel = workspace.controlsPanel
        var readings = ProfileReadings()
        switch panel.controls.appearance?.mode {
        case .dark?: readings.dark = true
        case .light?: readings.dark = false
        case .system?, nil: break
        }
        let settings = panel.deviceSettings
        readings.textScale = settings.fontScale?.value
        readings.reduceMotion = settings.reduceMotion?.isEnabled
        readings.increaseContrast = settings.increaseContrast?.isOn
        readings.showBorders = settings.showBorders?.isOn
        readings.screenReader = settings.voiceOver?.isOn
        readings.languageTag = panel.languageTime.readings?.locales?.first?.tag
        readings.timeFormat = panel.languageTime.readings?.timeFormat
        readings.statusBarClean = workspace.conditions.statusBar.ownsDemoMode
        if workspace.context.port != nil, let fix = workspace.location.currentFix() {
            readings.latitude = fix.latitude
            readings.longitude = fix.longitude
        }
        return readings
    }

    private func appleReadings(udid: String, in workspace: DeviceWorkspace) -> ProfileReadings? {
        let controls = workspace.appleControls
        guard controls.udid == udid, controls.isLoaded, !controls.isPhysical else { return nil }
        let state = controls.state
        var readings = ProfileReadings()
        readings.dark = state.dark
        if let points = state.textSize?.bodyPointSize, let base = SimulatorContentSize.large.bodyPointSize {
            readings.textScale = points / base
        }
        readings.reduceMotion = state.reduceMotion
        readings.increaseContrast = state.increaseContrast
        readings.showBorders = state.showBorders
        readings.screenReader = state.voiceOver
        readings.statusBarClean = controls.statusBarActive
        if case .coordinate(let name, let latitude, let longitude)? = controls.locations[udid] {
            readings.latitude = latitude
            readings.longitude = longitude
            readings.locationName = name
        }
        return readings
    }

    /// Saves the device shown as a profile named `name`; the added profile,
    /// nil when the name is taken or the device could not be read.
    @discardableResult
    func saveCurrentSettingsAsProfile(named name: String, in target: DeviceWorkspace? = nil) -> SettingsProfile? {
        guard let readings = currentProfileReadings(in: target) else {
            status.errorMessage = "Select a running Android device or simulator to save its settings."
            return nil
        }
        let profile = SettingsProfile.capturing(readings, named: name)
        guard let added = settingsProfiles.add(profile) else {
            status.errorMessage = "A profile named “\(name)” already exists."
            return nil
        }
        status.flash("Saved profile “\(added.name)”")
        return added
    }
}
