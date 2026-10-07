import Foundation

/// The device-language helper: `devicehubpro-locales.dex`, built from
/// `LocaleHelper/DeviceHubProLocales.java` by `Scripts/build-locale-helper.sh`. The
/// shell user may push a configuration from Android 8.0 (API 26), so the helper
/// changes the whole system language list (extensions included), which no
/// shell command can: `settings put system system_locales` is only read at
/// boot, and `cmd locale set-device-locale` (API 36.1+) takes one listed
/// language. Each run pushes the dex under a fresh name, runs it through
/// `app_process` and deletes it in the same shell command.
public enum LocaleHelper {
    static let resourceName = "devicehubpro-locales"
    static let resourceExtension = "dex"
    static let className = "DeviceHubProLocales"
    static let deviceDirectory = "/data/local/tmp"

    /// The vendored dex inside the Kit bundle (`ResourceBundleLookup`).
    public static func bundledDexURL() throws -> URL {
        try bundledDexURL(resourceDirectory: Bundle.main.resourceURL, module: { Bundle.module })
    }

    static func bundledDexURL(resourceDirectory: URL?, module: () -> Bundle) throws -> URL {
        guard let url = ResourceBundleLookup.url(
            forResource: resourceName,
            withExtension: resourceExtension,
            bundleName: ResourceBundleLookup.kitBundleName,
            resourceDirectory: resourceDirectory,
            module: module
        ) else {
            throw LanguageTimeError.helperMissing
        }
        return url
    }

    /// A device path no other run shares, so two runs never delete each
    /// other's dex.
    static func devicePath(token: String = String(UUID().uuidString.prefix(8)).lowercased()) -> String {
        "\(deviceDirectory)/\(resourceName)-\(token).\(resourceExtension)"
    }

    /// The shell line that runs the helper and deletes it whatever happens,
    /// keeping the helper's exit status.
    static func runCommand(devicePath: String, arguments: [String]) -> String {
        let quoted = arguments.map(AdbClient.shellQuoted).joined(separator: " ")
        return "CLASSPATH=\(devicePath) app_process / \(className) \(quoted); "
            + "status=$?; rm -f \(devicePath); exit $status"
    }

    /// `set` arguments: every list the helper pushes, in order.
    static func setArguments(_ lists: [[DeviceLocale]]) -> [String] {
        ["set"] + lists.map(DeviceLocaleList.tags)
    }

    /// What a `get`, `set` or `repush` run printed: the list before (the first
    /// `current` line) and the list system_server reported after each push.
    public struct Output: Sendable, Equatable {
        public var current: [DeviceLocale]?
        public var applied: [[DeviceLocale]] = []

        /// The list in place when the helper finished.
        public var final: [DeviceLocale]? { applied.last ?? current }

        public static func parse(_ text: String) -> Output {
            var output = Output()
            for rawLine in text.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.hasPrefix("current "), output.current == nil {
                    output.current = DeviceLocaleList.parse(String(line.dropFirst("current ".count)))
                } else if line.hasPrefix("applied ") {
                    output.applied.append(DeviceLocaleList.parse(String(line.dropFirst("applied ".count))))
                }
            }
            return output
        }
    }
}

/// How the Language row writes a language list.
public struct DeviceLocaleWritePlan: Sendable, Equatable {
    public enum Route: Sendable, Equatable {
        /// `cmd locale set-device-locale <tag>` (API 36.1+, one listed language).
        case command(DeviceLocale)
        /// The helper, pushing each list in turn.
        case helper([[DeviceLocale]])
    }

    public let route: Route

    /// Picks the route. SystemUI's status-bar clock reads the new language on a
    /// background thread when the configuration changes and can miss it, keeping
    /// the previous language's time pattern until the next configuration change
    /// (seen on API 37: `PM 1:23` in Turkish order after tr-TR → en-US, fixed by
    /// the next change). So when the primary language changes, the helper first
    /// pushes a list that already has the new primary language and then the
    /// target: the second change reaches SystemUI with the new language settled.
    /// `cmd locale set-device-locale` cannot express that intermediate list, so it
    /// is used when the primary language stays (a list shortened to its first
    /// language) or when the helper cannot run.
    public static func plan(
        target: [DeviceLocale],
        current: [DeviceLocale]?,
        support: LanguageTimeSupport
    ) throws -> DeviceLocalePlanResult {
        guard let primary = target.first else { throw LanguageTimeError.emptyLanguageList }
        let primaryChanges = current?.first?.baseTag != primary.baseTag
        let commandFits = target.count == 1
            && primary.extensions.isEmpty
            && support.setDeviceLocaleCommand
            && isListed(primary, in: support.deviceLocales)

        if support.localeHelper {
            if commandFits && !primaryChanges {
                return DeviceLocalePlanResult(plan: DeviceLocaleWritePlan(route: .command(primary)), fallback: nil)
            }
            let lists = primaryChanges
                ? [settleList(for: target, previousPrimary: current?.first), target]
                : [target]
            let fallback = commandFits ? DeviceLocaleWritePlan(route: .command(primary)) : nil
            return DeviceLocalePlanResult(plan: DeviceLocaleWritePlan(route: .helper(lists)), fallback: fallback)
        }
        if commandFits {
            return DeviceLocalePlanResult(plan: DeviceLocaleWritePlan(route: .command(primary)), fallback: nil)
        }
        throw LanguageTimeError.languageListUnsupported
    }

    /// A list with `target`'s primary language that differs from `target`: the
    /// previous primary appended when `target` lacks it, else `target` without
    /// its last language.
    static func settleList(for target: [DeviceLocale], previousPrimary: DeviceLocale?) -> [DeviceLocale] {
        if let previousPrimary, !target.contains(where: { $0.baseTag == previousPrimary.baseTag }) {
            return target + [previousPrimary]
        }
        if target.count > 1 {
            return Array(target.dropLast())
        }
        let fallbackTag = target.first?.baseTag == "en-US" ? "en-GB" : "en-US"
        return target + [DeviceLocale(tag: fallbackTag)].compactMap { $0 }
    }

    static func isListed(_ locale: DeviceLocale, in supported: [DeviceLocale]) -> Bool {
        supported.isEmpty || supported.contains { $0.tag == locale.tag }
    }
}

/// A plan and the route to try when its helper cannot run.
public struct DeviceLocalePlanResult: Sendable, Equatable {
    public let plan: DeviceLocaleWritePlan
    public let fallback: DeviceLocaleWritePlan?
}

/// What a Language write did.
public struct DeviceLocaleWriteOutcome: Sendable, Equatable {
    /// The configuration's languages after the write (`am get-config`).
    public let applied: [DeviceLocale]
    /// Whether the settle push ran (the status-bar clock follows at once).
    public let settled: Bool
    /// Whether the write went through `cmd locale set-device-locale`.
    public let usedCommand: Bool
}

public enum LanguageTimeError: Error, Equatable, CustomStringConvertible {
    case helperMissing
    case emptyLanguageList
    case languageListUnsupported
    case unsupported(String)
    case invalidArgument(String)
    case unknownPackage(String)
    /// The command answered but the device does not show the change.
    case notApplied(String)

    public var description: String {
        switch self {
        case .helperMissing:
            return "The language helper (devicehubpro-locales.dex) is missing from the Device Hub Pro bundle."
        case .emptyLanguageList:
            return "Choose at least one language."
        case .languageListUnsupported:
            return "This device can't change its language list from adb (it needs Android 8.0 or newer)."
        case .unsupported(let what):
            return "\(what) can't be changed on this device from adb."
        case .invalidArgument(let what):
            return "\(what) is not valid."
        case .unknownPackage(let package):
            return "\(package) is not installed on the device."
        case .notApplied(let what):
            return "The device did not apply \(what)."
        }
    }
}
