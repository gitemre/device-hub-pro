import Foundation

/// Repairs AVDs whose `hw.lcd` size disagrees with their skin's display, so
/// the streamed framebuffer fills the skin window instead of letterboxing.
///
/// Some profiles ship an LCD size that matches no skin state (the gen-1 Pixel
/// Fold declares 2208x2092 — the cover's height — while its open skin is
/// 2208x1840). The emulator renders the LCD size, the skin window keeps its
/// own size, and the mirror must pillarbox. The repair is deliberately
/// conservative: it only fires when exactly one axis differs (a strong signal
/// it is the same display with one wrong axis), backs the config up first,
/// and never touches a running emulator — callers repair before boot.
public enum AvdDisplayRepair {
    /// An LCD/skin disagreement that the repair can fix.
    public struct Mismatch: Sendable, Equatable {
        public let lcd: CGSize
        public let skin: CGSize

        public init(lcd: CGSize, skin: CGSize) {
            self.lcd = lcd
            self.skin = skin
        }
    }

    public enum RepairResult: Sendable, Equatable {
        case repaired(from: CGSize, to: CGSize)
        case alreadyMatches
        case unsupported
        case failed
    }

    public static let backupFileName = "config.ini.devicehubpro-bak"

    private enum Analysis: Equatable {
        case matches
        case mismatch(Mismatch)
        case unsupported
    }

    private static func analyze(
        avdName: String,
        skin: ResolvedSkin?,
        avdHome: URL?
    ) -> Analysis {
        guard let lcd = AvdConfig.lcdSize(avdName: avdName, avdHome: avdHome),
              let display = skin?.preferredVariant?.layout?.preferred?.displaySize
        else {
            return .unsupported
        }
        let lcdSize = (width: Int(lcd.width), height: Int(lcd.height))
        let skinSize = (width: Int(display.width), height: Int(display.height))
        guard lcdSize.width > 0, lcdSize.height > 0,
              skinSize.width > 0, skinSize.height > 0
        else {
            return .unsupported
        }
        let widthOK = lcdSize.width == skinSize.width
        let heightOK = lcdSize.height == skinSize.height
        if widthOK, heightOK { return .matches }
        // Both axes differ: a different display, not a typo'd axis.
        guard widthOK != heightOK else { return .unsupported }
        return .mismatch(Mismatch(
            lcd: CGSize(width: lcdSize.width, height: lcdSize.height),
            skin: CGSize(width: skinSize.width, height: skinSize.height)
        ))
    }

    /// Read-only diagnosis. Returns the mismatch when the AVD's LCD differs
    /// from the skin's primary display in exactly one axis.
    public static func diagnose(
        avdName: String,
        skin: ResolvedSkin?,
        avdHome: URL? = nil
    ) -> Mismatch? {
        if case .mismatch(let mismatch) = analyze(avdName: avdName, skin: skin, avdHome: avdHome) {
            return mismatch
        }
        return nil
    }

    /// Backs `config.ini` up (keeping the first backup forever) and rewrites
    /// the differing LCD axis to the skin's size, preserving every other
    /// line, comments, blank lines and line endings byte-for-byte.
    public static func repair(
        avdName: String,
        skin: ResolvedSkin?,
        avdHome: URL? = nil
    ) -> RepairResult {
        guard case .mismatch(let mismatch) = analyze(avdName: avdName, skin: skin, avdHome: avdHome) else {
            return analyze(avdName: avdName, skin: skin, avdHome: avdHome) == .matches
                ? .alreadyMatches : .unsupported
        }

        let url = AvdConfig.configURL(avdName: avdName, avdHome: avdHome)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .failed
        }
        let target = CGSize(
            width: mismatch.lcd.width == mismatch.skin.width
                ? mismatch.lcd.width : mismatch.skin.width,
            height: mismatch.lcd.height == mismatch.skin.height
                ? mismatch.lcd.height : mismatch.skin.height
        )
        let repaired = AvdConfig.linesWithEndings(text).map { part -> String in
            var body = setValue(part.body, key: "hw.lcd.width", value: Int(target.width))
            body = setValue(body, key: "hw.lcd.height", value: Int(target.height))
            return body + part.ending
        }.joined()

        let backupURL = url.deletingLastPathComponent().appendingPathComponent(backupFileName)
        let manager = FileManager.default
        if !manager.fileExists(atPath: backupURL.path) {
            guard (try? manager.copyItem(at: url, to: backupURL)) != nil else {
                return .failed
            }
        }
        do {
            try repaired.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return .failed
        }
        return .repaired(from: mismatch.lcd, to: target)
    }

    /// Whether `repair` has backed this AVD's config up (the UI offers
    /// "Restore original display" only then).
    public static func hasBackup(avdName: String, avdHome: URL? = nil) -> Bool {
        let url = AvdConfig.configURL(avdName: avdName, avdHome: avdHome)
        return FileManager.default.fileExists(
            atPath: url.deletingLastPathComponent().appendingPathComponent(backupFileName).path
        )
    }

    /// Undoes the repair surgically: puts back only the `hw.lcd.width` and
    /// `hw.lcd.height` values the backup holds — the keys `repair` rewrites —
    /// and leaves every other line of the current config (edits made since
    /// the backup included) byte for byte. Returns false when there is no
    /// backup, it has no LCD keys, or the config cannot be rewritten. The
    /// backup is kept.
    @discardableResult
    public static func restoreDisplaySize(avdName: String, avdHome: URL? = nil) -> Bool {
        let url = AvdConfig.configURL(avdName: avdName, avdHome: avdHome)
        let backupURL = url.deletingLastPathComponent().appendingPathComponent(backupFileName)
        guard let backup = try? String(contentsOf: backupURL, encoding: .utf8),
              let current = try? String(contentsOf: url, encoding: .utf8)
        else {
            return false
        }
        var original: [String: Int] = [:]
        for line in AvdConfig.linesWithEndings(backup) {
            let stripped = line.body.trimmingCharacters(in: .whitespaces)
            for key in ["hw.lcd.width", "hw.lcd.height"] where stripped.hasPrefix(key + "=") {
                original[key] = Int(stripped.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces))
            }
        }
        guard let width = original["hw.lcd.width"], let height = original["hw.lcd.height"] else {
            return false
        }
        let restored = AvdConfig.linesWithEndings(current).map { part -> String in
            var body = setValue(part.body, key: "hw.lcd.width", value: width)
            body = setValue(body, key: "hw.lcd.height", value: height)
            return body + part.ending
        }.joined()
        do {
            try restored.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Restores the whole backup taken by `repair`, reverting any config edit
    /// made since (prefer ``restoreDisplaySize(avdName:avdHome:)``). Returns
    /// false when no backup exists. The backup is kept, so a later repair
    /// still restores the original file.
    @discardableResult
    public static func restoreBackup(avdName: String, avdHome: URL? = nil) -> Bool {
        let url = AvdConfig.configURL(avdName: avdName, avdHome: avdHome)
        let backupURL = url.deletingLastPathComponent().appendingPathComponent(backupFileName)
        let manager = FileManager.default
        guard manager.fileExists(atPath: backupURL.path) else { return false }
        do {
            if manager.fileExists(atPath: url.path) {
                try manager.removeItem(at: url)
            }
            try manager.copyItem(at: backupURL, to: url)
            return true
        } catch {
            return false
        }
    }

    /// Rewrites one `key=value` line, preserving leading whitespace.
    /// Non-matching lines pass through untouched.
    private static func setValue(_ line: String, key: String, value: Int) -> String {
        let stripped = line.trimmingCharacters(in: .whitespaces)
        guard stripped.hasPrefix(key + "=") else { return line }
        let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
        return "\(leading)\(key)=\(value)"
    }
}
