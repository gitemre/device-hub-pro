import Foundation

/// A prerequisite the Pixel provisioning flow needs.
public enum PixelDependency: Sendable, Hashable {
    case platformTools
    case emulator
    case commandLineTools
    case java
    case systemImage
}

/// Which prerequisites are missing, in presentation order.
public enum PixelReadiness {
    public static func missing(
        hasAdb: Bool,
        hasEmulator: Bool,
        hasCommandLineTools: Bool,
        hasJava: Bool,
        hasUsableImage: Bool
    ) -> [PixelDependency] {
        var missing: [PixelDependency] = []
        if !hasAdb { missing.append(.platformTools) }
        if !hasEmulator { missing.append(.emulator) }
        if !hasCommandLineTools { missing.append(.commandLineTools) }
        if !hasJava { missing.append(.java) }
        if !hasUsableImage { missing.append(.systemImage) }
        return missing
    }
}
