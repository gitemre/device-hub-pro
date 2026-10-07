import DeviceHubProKit

/// What the live stage draws around the mirrored screen (`MirrorStageContent`),
/// decided by `DeviceChromeResolver`.
enum DeviceChrome: Hashable {
    /// The AVD's SDK skin artwork (`FramedMirrorView`).
    case skin(ResolvedSkin)
    /// The concentric graphite body planned from what the device reports
    /// about its own screen (`VectorDeviceView`): skinless AVDs, physical
    /// phones, every Android device under `DHP_FORCE_VECTOR_CHROME`, and
    /// a simulator whose device type has no Apple chrome.
    case vector
    /// A simulator's Apple chrome, read at runtime from the user's Xcode
    /// (`AppleChromeDeviceView`).
    case appleChrome(AppleChromeFrame)
    /// The 8 pt thin bezel the stage drew before the vector body: an Apple
    /// device whose display is not known.
    case thinBezel
}

/// Picks the live stage's chrome for a device, the one place the main stage
/// (`LiveDetailView`) and the compact window (`CompactMirrorView`) decide it,
/// so the two cannot draw one session differently.
enum DeviceChromeResolver {
    /// - An Apple device gets its device type's Apple chrome when there is
    ///   one (`appleChrome`: DeviceKit names it and it could be read), else
    ///   the vector body when its display is known (`appleDisplayShapes`: a
    ///   simulator's device type declares it, so the live stage matches the
    ///   stopped page's hero), else the thin bezel.
    /// - `forceVector` (`DHP_FORCE_VECTOR_CHROME=1`) gives every Android
    ///   device the vector body, even one whose AVD has a skin, so the body
    ///   can be checked live on a skinned AVD.
    /// - An Android device whose adb serial is a running AVD with a skin gets
    ///   that skin.
    /// - Any other Android device (a skinless AVD, a phone) gets the vector
    ///   body. A physical Pixel showing its own SDK skin (Tier 2's deferred
    ///   J) would be a branch here, before this fallback.
    static func chrome(
        device: DeviceRef,
        avdCards: [AvdCard],
        forceVector: Bool,
        appleDisplayShapes: [DisplayShape] = [],
        appleChrome: AppleChromeFrame? = nil
    ) -> DeviceChrome {
        guard let serial = device.adbSerial else {
            if let appleChrome { return .appleChrome(appleChrome) }
            return appleDisplayShapes.isEmpty ? .thinBezel : .vector
        }
        if forceVector { return .vector }
        if let skin = avdCards.first(where: { $0.serial == serial })?.skin {
            return .skin(skin)
        }
        return .vector
    }

    /// The Apple chrome of the simulator `device` names, once its device
    /// type was read (`SimulatorInventory.loadDisplayShape(for:)`); nil for
    /// any other device.
    ///
    /// A physical iPhone's view (`physical`) is drawn in the chrome of the
    /// simulator device type that has its model identifier ("iPhone13,2"),
    /// read the same way; nil when Xcode ships no device type for it, and the
    /// stage then keeps the thin bezel.
    @MainActor
    static func appleChrome(
        for device: DeviceRef,
        simulators: SimulatorInventory,
        physical: ApplePhysicalInventory? = nil
    ) -> AppleChromeFrame? {
        guard device.platform == .apple else { return nil }
        if let entry = simulators.entry(udid: device.id) { return simulators.chromeFrame(for: entry) }
        if let phone = physical?.entry(udid: device.id) {
            return simulators.chromeFrame(forModelIdentifier: phone.device.productType)
        }
        return nil
    }
}
