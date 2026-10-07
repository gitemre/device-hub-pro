import Foundation

// The answers of the Controls commands `DevicectlPhysicalClient` runs on a
// physical iPhone. Each was captured from CoreDevice 642.16 (JSON
// version 5, Xcode 27.0) against the dedicated test iPhone (an iPhone 12 on
// iOS 27.0); `Fixtures/ios27-device/` holds the scrubbed captures and
// `ApplePhysicalControlsTests` decodes them. The appearance, VoiceOver and
// orientation answers reuse `DevicectlAppearance`, `DevicectlVoiceOver` and
// `DevicectlOrientation`.

/// `devicectl device simulate location coordinate`: the coordinate the phone
/// now reports (until it is cleared).
public struct DevicectlLocationSimulation: Decodable, Sendable, Equatable {
    public let deviceIdentifier: String?
    public let latitude: Double
    public let longitude: Double
}

/// `devicectl device simulate location clear`.
public struct DevicectlLocationCleared: Decodable, Sendable, Equatable {
    public let deviceIdentifier: String?
    public let cleared: Bool
}

/// `devicectl device pasteboard copy`: how many items the pasteboard holds
/// now and their types (plain text is written as three text types).
public struct DevicectlPasteboardCopy: Decodable, Sendable, Equatable {
    public let deviceIdentifier: String?
    public let pasteboardName: String?
    public let itemCount: Int
    public let types: [String]
}

/// The JSON document of `devicectl device pasteboard paste`: the pasteboard's
/// text itself is the command's standard output, and this says what it was.
public struct DevicectlPasteboardPaste: Decodable, Sendable, Equatable {
    public let deviceIdentifier: String?
    public let pasteboardName: String?
    /// The text's size in bytes.
    public let contentSize: Int
    /// The pasteboard type that supplied it (`public.utf8-plain-text`).
    public let contentType: String
}
