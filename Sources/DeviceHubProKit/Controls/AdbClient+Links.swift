import Foundation

/// The Links rows' adb calls: open a URI as an `ACTION_VIEW` intent, preview
/// which app takes it, and read or re-verify an app's App Links state. Each
/// call is one `adb shell` round trip; the device's own status travels in
/// the output (`LinkCommands.exitMarker`), never in adb's exit code.
extension AdbClient {
    /// One argument for the device shell that survives Foundation.Process.
    /// An all-ASCII argument goes through `shellQuoted`. Anything with a
    /// scalar ≥ U+0080 becomes `$'…'`: each UTF-8 byte outside printable
    /// ASCII 0x20–0x7E, and `'` and `\`, is written as a 3-digit octal escape
    /// (`\303\274`). Foundation.Process hands non-ASCII argv strings to the
    /// child decomposed (NFD; ü → u + U+0308), while an ASCII-only argv
    /// arrives unchanged. Octal, not `\x`: mksh reads `\x` greedily
    /// (`\xbcab` is one character). A shell without `$'…'` reads it as `$`
    /// plus a quoted string: a wrong URI, never an injection, since the word
    /// holds no raw `'`.
    public static func shellWord(_ argument: String) -> String {
        guard argument.unicodeScalars.contains(where: { $0.value >= 0x80 }) else {
            return shellQuoted(argument)
        }
        var word = "$'"
        word.reserveCapacity(argument.utf8.count * 4 + 3)
        for byte in argument.utf8 {
            if (0x20...0x7E).contains(byte), byte != 0x27, byte != 0x5C {
                word.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                word += "\\" + octalDigits(byte)
            }
        }
        word += "'"
        return word
    }

    private static func octalDigits(_ byte: UInt8) -> String {
        let digits = String(byte, radix: 8)
        return String(repeating: "0", count: 3 - digits.count) + digits
    }

    /// Opens `request` with `am start -W` and parses what Android reported
    /// (`apiLevel`, when known, lets the exit status cross-check the lines).
    /// adb's own failures (device gone, the 30 s bound) throw. A
    /// `ProcessRunnerError.timedOut` says only that no answer came: either
    /// adb could not reach the device, or `am` is still waiting for the
    /// launch (`-W` waits without a bound of its own:
    /// ActivityTaskSupervisor.waitActivityVisibleOrLaunched android-16.0.0_r1:
    /// 624–638).
    public func openLink(serial: String, _ request: LinkRequest, apiLevel: Int? = nil) async throws -> LinkLaunchResult {
        let output = try await shell(serial: serial, [LinkCommands.openScript(request)])
        return LinkLaunchResult.parse(output, request: request, apiLevel: apiLevel)
    }

    /// Which app `am start` would pick for `request`, and every app that can
    /// take it (API 24+; the API level alone before).
    public func linkPreview(serial: String, _ request: LinkRequest) async throws -> LinkPreview {
        let output = try await shell(serial: serial, [LinkCommands.previewScript(request)])
        return LinkPreview.parse(output)
    }

    /// Every package that reaches a command passes `validatePackageName`
    /// first: an empty one would make `get-app-links` print every package
    /// and `verify-app-links --re-verify` re-verify every package.
    static func validateLinkPackage(_ package: String) throws(LinkError) {
        do {
            try validatePackageName(package)
        } catch {
            throw .invalidPackage(package)
        }
    }
}
