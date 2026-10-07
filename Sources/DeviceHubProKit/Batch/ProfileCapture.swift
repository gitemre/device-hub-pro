import Foundation

/// What a device's controllers currently read, in plain values: the input of
/// "Save Current Settings as Profile…". A setting the device did not answer
/// (or the platform does not have) stays nil and is left out of the profile.
public struct ProfileReadings: Sendable, Equatable {
    /// nil when the device follows the system (Android's "System").
    public var dark: Bool?
    /// The text size as a scale against the default (1.0).
    public var textScale: Double?
    public var reduceMotion: Bool?
    public var increaseContrast: Bool?
    public var showBorders: Bool?
    public var screenReader: Bool?
    public var latitude: Double?
    public var longitude: Double?
    public var locationName: String?
    public var languageTag: String?
    public var timeFormat: TimeFormatSetting?
    /// A clean-status-bar override is in place.
    public var statusBarClean: Bool?

    public init(
        dark: Bool? = nil,
        textScale: Double? = nil,
        reduceMotion: Bool? = nil,
        increaseContrast: Bool? = nil,
        showBorders: Bool? = nil,
        screenReader: Bool? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        locationName: String? = nil,
        languageTag: String? = nil,
        timeFormat: TimeFormatSetting? = nil,
        statusBarClean: Bool? = nil
    ) {
        self.dark = dark
        self.textScale = textScale
        self.reduceMotion = reduceMotion
        self.increaseContrast = increaseContrast
        self.showBorders = showBorders
        self.screenReader = screenReader
        self.latitude = latitude
        self.longitude = longitude
        self.locationName = locationName
        self.languageTag = languageTag
        self.timeFormat = timeFormat
        self.statusBarClean = statusBarClean
    }
}

extension SettingsProfile {
    /// A user profile named `name` holding what `readings` say.
    public static func capturing(_ readings: ProfileReadings, named name: String) -> SettingsProfile {
        var profile = SettingsProfile(name: name)
        profile.appearance = readings.dark.map { $0 ? .dark : .light }
        profile.textSize = readings.textScale.map(BatchTextSize.nearest(toScale:))
        profile.reduceMotion = readings.reduceMotion
        profile.increaseContrast = readings.increaseContrast
        profile.showBorders = readings.showBorders
        profile.screenReader = readings.screenReader
        if let latitude = readings.latitude, let longitude = readings.longitude {
            profile.location = ProfileLocation(latitude: latitude, longitude: longitude, name: readings.locationName)
        }
        profile.language = readings.languageTag
        profile.timeFormat = readings.timeFormat.map(ProfileTimeFormat.init)
        if readings.statusBarClean == true { profile.statusBar = .clean }
        return profile
    }
}
