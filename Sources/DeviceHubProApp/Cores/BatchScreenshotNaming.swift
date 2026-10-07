import Foundation
import DeviceHubProKit

/// Screenshot All Selected's names: one folder per batch, one PNG per device
/// in it, named after the device.
enum BatchScreenshotNaming {
    /// The folder the save panel suggests: `devicehubpro-screenshots-20260926-214012`,
    /// the single screenshot's `devicehubpro-<yyyyMMdd-HHmmss>` form.
    static func folderName(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "devicehubpro-screenshots-\(formatter.string(from: date))"
    }

    /// Each target's file name (by `BatchTarget.id`), in the targets' order:
    /// the device's name with "/" and ":" as "-" (a name is one path
    /// component, and Finder shows ":" as "/"), " 2", " 3"… after a name an
    /// earlier target took (two simulators of one model), then ".png".
    static func fileNames(for targets: [BatchTarget]) -> [String: String] {
        var names: [String: String] = [:]
        var taken: Set<String> = []
        for target in targets {
            let base = sanitized(target.name)
            var candidate = base
            var suffix = 2
            while taken.contains(candidate.lowercased()) {
                candidate = "\(base) \(suffix)"
                suffix += 1
            }
            taken.insert(candidate.lowercased())
            names[target.id] = candidate + ".png"
        }
        return names
    }

    private static func sanitized(_ name: String) -> String {
        let replaced = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading dot would hide the file.
        let visible = replaced.hasPrefix(".") ? "-" + String(replaced.dropFirst()) : replaced
        return visible.isEmpty ? "Device" : visible
    }
}
