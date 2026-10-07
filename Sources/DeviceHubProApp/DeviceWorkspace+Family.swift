import DeviceHubProKit

extension DeviceWorkspace {
    /// The Controls family of the device the stage shows (nil with none): an
    /// Android device's from its running system (or, before that is read,
    /// its AVD's image), a simulator's from its runtime and device type.
    var deviceFamily: ControlsFamily? {
        guard let device = context.device else { return nil }
        if device.platform == .apple {
            if context.isPhysicalView { return .physicalApple }
            return services.simulators.entry(udid: device.id).map {
                ControlsFamily.simulator(platform: $0.platform, productFamily: $0.productFamily)
            }
        }
        guard let serial = device.adbSerial else { return nil }
        return .android(mirror.deviceFormFactor(serial))
    }

    /// Whether the shown Android device reports `feature` in `pm list
    /// features`: true until its Info is read (and for a read that listed
    /// nothing), so an item never vanishes on a guess. A Wear OS image reports
    /// no `android.hardware.fingerprint` (measured, Wear OS API 37 emulator).
    func androidDeviceHas(_ feature: String) -> Bool {
        guard let serial = context.serial,
              let info = services.inventory.deviceInfos[serial], !info.features.isEmpty
        else { return true }
        return info.features.contains(feature)
    }

    static let fingerprintFeature = "android.hardware.fingerprint"
    static let telephonyFeature = "android.hardware.telephony"
    static let accelerometerFeature = "android.hardware.sensor.accelerometer"
    static let leanbackOnlyFeature = "android.software.leanback_only"

    /// Whether the shown Android device's feature list has been read (a
    /// feature's absence means something only then).
    var androidHasReadFeatures: Bool {
        guard let serial = context.serial, let info = services.inventory.deviceInfos[serial] else { return false }
        return !info.features.isEmpty
    }

    /// Whether Rotate means anything for the shown device. A TV, a watch and
    /// a car keep their orientation (the Rotate button and menu rows are
    /// left out for them); an unknown device is offered it as before.
    var deviceRotates: Bool { deviceFamily?.rotates ?? true }

    /// The remote the stage offers under the device (a TV's), nil elsewhere.
    var remoteFamily: ControlsFamily? {
        guard let family = deviceFamily, family.hasRemote else { return nil }
        return family
    }
}
