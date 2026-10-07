import Foundation

/// Reads an AVD's `config.ini` for its hardware features.
public enum AvdConfig {
    /// All `key=value` pairs from the AVD's `config.ini`.
    public static func values(avdName: String, avdHome: URL? = nil) -> [String: String] {
        valuesFile(configURL(avdName: avdName, avdHome: avdHome))
    }

    /// Number of hinge sensors the AVD declares (0 for non-foldables).
    public static func hingeCount(avdName: String, avdHome: URL? = nil) -> Int {
        Int(values(avdName: avdName, avdHome: avdHome)["hw.sensor.hinge.count"] ?? "0") ?? 0
    }

    /// Whether the AVD has a resizable display, the one the console's
    /// `resize-display` presets switch: its `hw.resizable.configs` lists the
    /// sizes (`name-id-width-height-dpi` entries, per the SDK's
    /// `hardware-properties.ini`). The key is empty or missing on every other
    /// AVD; `hw.sensor.hinge.resizable.config`, which the emulator writes on
    /// every AVD, says nothing about resizability.
    public static func isResizable(avdName: String, avdHome: URL? = nil) -> Bool {
        let configs = values(avdName: avdName, avdHome: avdHome)["hw.resizable.configs"] ?? ""
        return !configs.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The name Device Manager shows, falling back to the AVD id.
    public static func displayName(avdName: String, avdHome: URL? = nil) -> String {
        let config = values(avdName: avdName, avdHome: avdHome)
        if let name = config["avd.ini.displayname"], !name.isEmpty { return name }
        if let id = config["AvdId"], !id.isEmpty { return id }
        return avdName
    }

    /// The device class the AVD's system image is built for, from its
    /// `config.ini` (`tag.id`, else the tag in `image.sysdir.1`), known
    /// before the VM answers adb.
    public static func formFactor(avdName: String, avdHome: URL? = nil) -> SystemImage.FormFactor {
        formFactor(values: values(avdName: avdName, avdHome: avdHome))
    }

    static func formFactor(values: [String: String]) -> SystemImage.FormFactor {
        if let tag = values["tag.id"], !tag.isEmpty { return SystemImage.formFactor(tag: tag) }
        // `system-images/android-36/google-tv/arm64-v8a/`: the tag is the third part.
        let parts = (values["image.sysdir.1"] ?? "").split(separator: "/").map(String.init)
        if parts.count >= 3 { return SystemImage.formFactor(tag: parts[2]) }
        return .handheld
    }

    /// The system-image target from `<avd>.ini` (`android-35`, `android-37.1`, …).
    public static func target(avdName: String, avdHome: URL? = nil) -> String? {
        let values = valuesFile(
            homeURL(avdHome: avdHome).appendingPathComponent("\(avdName).ini")
        )
        if let target = values["target"], !target.isEmpty { return target }
        return nil
    }

    /// The AVDs in the home whose `image.sysdir.1` is the system image
    /// `package` (`system-images;android-35;google_apis;arm64-v8a`), sorted:
    /// the AVDs that stop booting when that image is uninstalled.
    public static func avdNames(usingSystemImage package: String, avdHome: URL? = nil) -> [String] {
        let wanted = package.split(separator: ";").joined(separator: "/")
        let home = homeURL(avdHome: avdHome)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? [])
            .filter { $0.hasSuffix(".ini") }
            .map { String($0.dropLast(".ini".count)) }
        return names.filter { name in
            guard let sysdir = values(avdName: name, avdHome: avdHome)["image.sysdir.1"] else {
                return false
            }
            let trimmed = sysdir.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return trimmed == wanted
        }
        .sorted()
    }

    /// The LCD size from `hw.lcd.width`/`hw.lcd.height`, if declared.
    public static func lcdSize(avdName: String, avdHome: URL? = nil) -> CGSize? {
        let config = values(avdName: avdName, avdHome: avdHome)
        guard
            let width = Double(config["hw.lcd.width"] ?? ""),
            let height = Double(config["hw.lcd.height"] ?? ""),
            width > 0, height > 0
        else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    /// The LCD density in dpi from `hw.lcd.density`, if declared: the
    /// density a stopped AVD's device body is sized with.
    public static func lcdDensity(avdName: String, avdHome: URL? = nil) -> Double? {
        guard let density = Double(values(avdName: avdName, avdHome: avdHome)["hw.lcd.density"] ?? ""),
              density.isFinite, density > 0
        else {
            return nil
        }
        return density
    }

    /// Writes the skin keys into an AVD's `config.ini` so a direct emulator
    /// launch renders the device frame the same way Device Hub Pro does. Existing
    /// `skin.*` keys are replaced, the rest of the file is preserved byte for
    /// byte; the new lines use the file's own line ending (CRLF stays CRLF).
    public static func setSkin(
        avdName: String,
        skinName: String,
        skinPath: String,
        avdHome: URL? = nil
    ) throws {
        let url = configURL(avdName: avdName, avdHome: avdHome)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let managed = ["skin.name", "skin.path", "skin.dynamic"]
        let lines = linesWithEndings(text)
        let newline = lines.first { !$0.ending.isEmpty }?.ending ?? "\n"
        var kept = lines.filter { line in
            guard let separator = line.body.firstIndex(of: "=") else { return true }
            let key = line.body[..<separator].trimmingCharacters(in: .whitespaces)
            return !managed.contains(key)
        }
        // The trailing (body "", ending "") piece of a terminated file is not
        // a line; an unterminated last line gets the file's ending.
        if kept.last?.body.isEmpty == true, kept.last?.ending.isEmpty == true {
            kept.removeLast()
        }
        if let last = kept.last, last.ending.isEmpty {
            kept[kept.count - 1].ending = newline
        }
        var updated = kept.map { $0.body + $0.ending }.joined()
        updated += "skin.name=\(skinName)\(newline)"
        updated += "skin.path=\(skinPath)\(newline)"
        updated += "skin.dynamic=yes\(newline)"
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The key behind the AVD's keyboard device (Android Studio's "Enable
    /// keyboard input"). The emulator's keys all go through that device:
    /// without it the frame's side buttons and typing fall back to adb
    /// (`EmulatorKeyRoute`).
    static let hardwareKeyboardKey = "hw.keyboard"

    /// Whether the AVD's `config.ini` turns its hardware keyboard on, as the
    /// emulator reads it (`EmulatorIni`); nil when the file cannot be read.
    /// A missing key, or a value the emulator does not take for a boolean,
    /// is off, the key's default (SOURCE-DERIVED: the SDK's
    /// `emulator/lib/hardware-properties.ini`, `hw.keyboard` `default = no`).
    public static func hardwareKeyboard(avdName: String, avdHome: URL? = nil) -> Bool? {
        let url = configURL(avdName: avdName, avdHome: avdHome)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        guard let value = EmulatorIni.value(of: hardwareKeyboardKey, in: text) else { return false }
        return EmulatorIni.boolean(value) ?? false
    }

    /// Turns the AVD's hardware keyboard on or off (`hw.keyboard=yes`/`no`)
    /// in its `config.ini`: every `hw.keyboard` line is rewritten in place
    /// (its leading whitespace kept; `hw.keyboard.lid` and
    /// `hw.keyboard.charmap` are other keys), or the key is appended in the
    /// file's own line ending when it is missing. Every other byte stays.
    /// Throws when the file cannot be read or written; never creates one.
    ///
    /// The emulator reads the key at launch only, so a running VM keeps the
    /// keyboard it started with. Its next start is a cold boot: the saved
    /// quick-boot snapshot has other hardware, which the emulator refuses
    /// ("different AVD configuration", measured on API 37 with emulator
    /// 36.6.11) before it saves a new one on exit; apps and data are kept.
    /// Every snapshot is checked against the hardware it was saved with
    /// (SOURCE-DERIVED: `platform/external/qemu` emu-master-dev,
    /// `android/android-emu/android/snapshot/Snapshot.cpp`
    /// `Snapshot::preload` and `checkValid`, `areHwConfigsEqual`), so the
    /// named snapshots saved before the change no longer load either.
    public static func setHardwareKeyboard(_ enabled: Bool, avdName: String, avdHome: URL? = nil) throws {
        try setValue(enabled ? "yes" : "no", forKey: hardwareKeyboardKey, avdName: avdName, avdHome: avdHome)
    }

    /// Whether a device profile id names a round screen (`wearos_large_round`,
    /// `wear_round_chin_320_290`, ...). Android Studio writes the profile's
    /// own round flag as `hw.lcd.circular=true`; avdmanager writes `false`
    /// for every device (measured on `wearos_large_round`, emulator 36.6.11).
    public static func isRoundProfile(deviceId: String) -> Bool {
        deviceId.lowercased().contains("round")
    }

    /// The `hw.initialOrientation` of an LCD: Android Studio gives the
    /// device's own default orientation, which is the one its LCD size is
    /// written in; avdmanager writes `portrait` for every device (a 1920x1080
    /// TV included), and the emulator then reports the physical model turned a
    /// quarter.
    public static func initialOrientation(lcdWidth: Double, lcdHeight: Double) -> String {
        lcdWidth > lcdHeight ? "landscape" : "portrait"
    }

    /// Like `initialOrientation(lcdWidth:lcdHeight:)`, for a device profile:
    /// a foldable (`pixel_9_pro_fold`, `pixel_10_pro_fold`, `pixel_fold`)
    /// is a landscape device whatever its inner LCD's sides (2076x2152 is
    /// taller than wide), and Android Studio writes `landscape` for it
    /// (the Pixel 9 Pro Fold AVD fixture). Written as `portrait` from the LCD
    /// size alone, the emulator turns the opened fold a quarter (physical
    /// model -90, display rotation 270, a 2152x2076 frame at rotation 3),
    /// where `landscape` keeps it upright (rotation 0, a 2076x2152 frame):
    /// measured on emulator 36.6.11, API 35, with the Pixel 10 Pro Fold.
    public static func initialOrientation(deviceId: String, lcdWidth: Double, lcdHeight: Double) -> String {
        if deviceId.lowercased().contains("fold") { return "landscape" }
        return initialOrientation(lcdWidth: lcdWidth, lcdHeight: lcdHeight)
    }

    /// Writes what avdmanager leaves out of a new AVD's `config.ini` and
    /// Android Studio writes: `hw.lcd.circular` for a round profile, the
    /// `hw.initialOrientation` the LCD size implies, and `AvdId` plus
    /// `avd.ini.displayname` when the name the user typed (`displayName`)
    /// differs from the AVD id (avdmanager takes no spaces).
    public static func completeDeviceKeys(
        avdName: String,
        deviceId: String,
        displayName: String?,
        avdHome: URL? = nil
    ) throws {
        if isRoundProfile(deviceId: deviceId) {
            try setValue("true", forKey: "hw.lcd.circular", avdName: avdName, avdHome: avdHome)
        }
        if let size = lcdSize(avdName: avdName, avdHome: avdHome) {
            try setValue(
                initialOrientation(deviceId: deviceId, lcdWidth: size.width, lcdHeight: size.height),
                forKey: "hw.initialOrientation", avdName: avdName, avdHome: avdHome
            )
        }
        if let displayName, !displayName.isEmpty, displayName != avdName {
            try setValue(avdName, forKey: "AvdId", avdName: avdName, avdHome: avdHome)
            try setValue(displayName, forKey: "avd.ini.displayname", avdName: avdName, avdHome: avdHome)
        }
    }

    /// Sets `key=value` in the AVD's `config.ini`, in place when the key is
    /// there (its leading whitespace kept), else appended in the file's own
    /// line ending; every other byte stays. Throws when the file cannot be
    /// read or written.
    public static func setValue(_ value: String, forKey key: String, avdName: String, avdHome: URL? = nil) throws {
        let url = configURL(avdName: avdName, avdHome: avdHome)
        let text = try String(contentsOf: url, encoding: .utf8)
        let line = "\(key)=\(value)"
        var lines = linesWithEndings(text)
        var found = false
        for index in lines.indices {
            let body = lines[index].body
            guard let separator = body.firstIndex(of: "="),
                  body[..<separator].trimmingCharacters(in: .whitespaces) == key
            else { continue }
            let leading = body.prefix(while: { $0 == " " || $0 == "\t" })
            lines[index].body = leading + line
            found = true
        }
        if !found {
            let newline = lines.first { !$0.ending.isEmpty }?.ending ?? "\n"
            // The trailing (body "", ending "") piece of a terminated file is
            // not a line; an unterminated last line gets the file's ending.
            if lines.last?.body.isEmpty == true, lines.last?.ending.isEmpty == true {
                lines.removeLast()
            }
            if let last = lines.last, last.ending.isEmpty {
                lines[lines.count - 1].ending = newline
            }
            lines.append((line, newline))
        }
        try lines.map { $0.body + $0.ending }.joined().write(to: url, atomically: true, encoding: .utf8)
    }

    /// Splits text into (body, terminator) pairs so any mix of LF/CRLF/CR
    /// and a missing final newline round-trips byte-for-byte. A plain split
    /// on `"\n"` cannot keep the terminators — and CRLF is a single Swift
    /// Character that never equals `"\n"`, so such a split leaves a CRLF file
    /// as one line. The walk steps whole characters (one index-after skips
    /// the entire `\r\n` pair). The last pair is the text after the final
    /// terminator (empty body and ending for a terminated file).
    static func linesWithEndings(_ text: String) -> [(body: String, ending: String)] {
        var out: [(body: String, ending: String)] = []
        var lineStart = text.startIndex
        var index = lineStart
        while index < text.endIndex {
            if text[index].isNewline {
                let next = text.index(after: index)
                out.append((String(text[lineStart..<index]), String(text[index..<next])))
                lineStart = next
                index = next
            } else {
                index = text.index(after: index)
            }
        }
        out.append((String(text[lineStart...]), ""))
        return out
    }

    private static func valuesFile(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }

        var values: [String: String] = [:]
        // Split on the newline property, not the "\n" character: CRLF is a
        // single Swift Character, so a lone-LF separator never cuts it and a
        // CRLF file would parse as one giant line.
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = line.firstIndex(of: "=") else { continue }
            values[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        return values
    }

    /// The AVD home directory: `avdHome` when given, otherwise the one the
    /// emulator and avdmanager use (see ``defaultHomeURL(environment:userHome:)``).
    public static func homeURL(avdHome: URL? = nil) -> URL {
        avdHome ?? defaultHomeURL()
    }

    /// The AVD home the emulator resolves, so Device Hub Pro's file operations act
    /// on the same AVDs `emulator -list-avds` lists: `$ANDROID_AVD_HOME`, then
    /// `$ANDROID_EMULATOR_HOME/avd`, `$ANDROID_USER_HOME/avd` and
    /// `$ANDROID_SDK_HOME/.android/avd` — the first that is an existing
    /// directory — else `~/.android/avd`.
    public static func defaultHomeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let overrides: [(key: String, suffix: String?)] = [
            ("ANDROID_AVD_HOME", nil),
            ("ANDROID_EMULATOR_HOME", "avd"),
            ("ANDROID_USER_HOME", "avd"),
            ("ANDROID_SDK_HOME", ".android/avd"),
        ]
        for override in overrides {
            guard let value = environment[override.key], !value.isEmpty else { continue }
            var candidate = URL(
                fileURLWithPath: (value as NSString).expandingTildeInPath,
                isDirectory: true
            )
            if let suffix = override.suffix {
                candidate.appendPathComponent(suffix, isDirectory: true)
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
        }
        return userHome.appendingPathComponent(".android/avd", isDirectory: true)
    }

    /// The AVD's content directory (`config.ini`, userdata, snapshots), read
    /// from its `<name>.ini` the way the emulator does: the absolute `path=`
    /// when that directory holds a `config.ini`, then `path.rel=` (relative to
    /// the AVD home's parent, the `.android` directory), else the default
    /// `<home>/<name>.avd`. AVDs created with `avdmanager create avd -p <dir>`
    /// live outside the home; the `config.ini` requirement keeps a malformed
    /// pointer from ever naming an unrelated directory.
    public static func contentDirectory(avdName: String, avdHome: URL? = nil) -> URL {
        let home = homeURL(avdHome: avdHome)
        let pointer = valuesFile(home.appendingPathComponent("\(avdName).ini"))
        var candidates: [URL] = []
        if let path = pointer["path"], path.hasPrefix("/") {
            candidates.append(URL(fileURLWithPath: path, isDirectory: true))
        }
        if let relative = pointer["path.rel"], !relative.isEmpty, !relative.hasPrefix("/") {
            candidates.append(
                home.deletingLastPathComponent().appendingPathComponent(relative, isDirectory: true)
            )
        }
        for candidate in candidates
        where FileManager.default.fileExists(atPath: candidate.appendingPathComponent("config.ini").path) {
            return candidate
        }
        return home.appendingPathComponent("\(avdName).avd", isDirectory: true)
    }

    /// The AVD's `config.ini` location (exposed for display repair).
    public static func configURL(avdName: String, avdHome: URL?) -> URL {
        contentDirectory(avdName: avdName, avdHome: avdHome)
            .appendingPathComponent("config.ini")
    }
}

/// An AVD's `config.ini` read the way the emulator reads it, for the keys
/// where Device Hub Pro must agree with the emulator (SOURCE-DERIVED:
/// `platform/external/qemu` emu-master-dev,
/// `android/android-emu-base/android/base/files/IniFile.cpp`, whose
/// `getBool` the hardware config uses for every `hw.*` boolean through
/// `iniFile_getBoolean`, `android/emu/avd/src/android/avd/hw-config.c`).
enum EmulatorIni {
    /// The value of `key`, from `IniFile::parseStream`: lines end at "\n";
    /// space, tab and "\r" around the key, the "=" and the value are
    /// skipped; a key starts with a letter or "_" and goes on with letters,
    /// digits, "_", "." and "-"; the value runs to a "\r" or the line's end,
    /// and a line with anything but space after it, or without a key and
    /// "=", counts for nothing (a "#" or ";" comment among them). A key
    /// given twice keeps its last value. Nil when no line sets it.
    static func value(of key: String, in text: String) -> String? {
        var value: String?
        for line in text.utf8.split(separator: UInt8(ascii: "\n")) {
            if let entry = entry(Array(line)), entry.key == key {
                value = entry.value
            }
        }
        return value
    }

    /// `IniFile::getBool`: true for a value that "yes", "true" or "1"
    /// begins with, false for one that "no", "false" or "0" begins with,
    /// ignoring ASCII case (`strncasecmp` over the value's own length, so
    /// "Y" and even an empty value are true); nil for anything else, which
    /// the emulator reads as the key's default.
    static func boolean(_ value: String) -> Bool? {
        let lowered = String(decoding: value.utf8.map { byte in
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
        }, as: UTF8.self)
        if ["yes", "true", "1"].contains(where: { $0.hasPrefix(lowered) }) { return true }
        if ["no", "false", "0"].contains(where: { $0.hasPrefix(lowered) }) { return false }
        return nil
    }

    private static func entry(_ line: [UInt8]) -> (key: String, value: String)? {
        func isSpace(_ byte: UInt8) -> Bool {
            byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\t")
        }
        func isKeyStart(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || byte == UInt8(ascii: "_")
        }
        func isKeyCharacter(_ byte: UInt8) -> Bool {
            isKeyStart(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-")
        }
        var index = line.startIndex
        func skip(while predicate: (UInt8) -> Bool) {
            while index < line.endIndex, predicate(line[index]) { index += 1 }
        }
        skip(while: isSpace)
        guard index < line.endIndex, isKeyStart(line[index]) else { return nil }
        let keyStart = index
        index += 1
        skip(while: isKeyCharacter)
        let key = line[keyStart..<index]
        skip(while: isSpace)
        guard index < line.endIndex, line[index] == UInt8(ascii: "=") else { return nil }
        index += 1
        skip(while: isSpace)
        let valueStart = index
        skip(while: { $0 != UInt8(ascii: "\r") })
        var valueEnd = index
        while valueEnd > valueStart, isSpace(line[valueEnd - 1]) { valueEnd -= 1 }
        skip(while: isSpace)
        guard index == line.endIndex else { return nil }
        return (String(decoding: key, as: UTF8.self), String(decoding: line[valueStart..<valueEnd], as: UTF8.self))
    }
}
