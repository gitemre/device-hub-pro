import Foundation

/// The last display shapes each AVD reported, kept on disk so a stopped
/// AVD's hero can draw its screen with the device's own corners and cutout
/// instead of the skin's (often missing) `corner_radius`. Physical phones
/// are kept per model (`ro.product.model`), so a phone's next session and its
/// illustration start from its real corners before the read answers.
///
/// One JSON file per AVD name in `directory`, holding every display the AVD
/// listed (both panels of a foldable), so the hero can pick the one its skin
/// variant shows with `DisplayShape.matching(frame:in:)`; phone models go in
/// `physical/<model>.json`, a folder no AVD's file can be. The shapes are a
/// cache of what the device reports: losing them only costs the fallback
/// until the AVD next boots, so the default lives in the app's caches like
/// `AppIconStore`'s icons. Reads never throw — an absent, unreadable or
/// older-format file reads as no shapes.
public struct DisplayShapeStore: Sendable {
    /// The file format. A file with another version reads as empty and is
    /// replaced on the next `record`.
    public static let formatVersion = 1

    public let directory: URL

    public init(directory: URL = DisplayShapeStore.defaultDirectory()) {
        self.directory = directory
    }

    /// `~/Library/Caches/DeviceHubPro/displayshapes`, beside `AppIconStore`'s
    /// `appicons`.
    public static func defaultDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches
            .appendingPathComponent("DeviceHubPro", isDirectory: true)
            .appendingPathComponent("displayshapes", isDirectory: true)
    }

    /// The shapes last recorded for `avdName`, in dump order; empty when none
    /// were.
    public func shapes(forAvd avdName: String) -> [DisplayShape] {
        shapes(at: fileURL(forAvd: avdName))
    }

    /// Records `shapes` as `avdName`'s last known displays. An empty list is
    /// a failed read, not news, so it keeps what is stored; an unchanged
    /// list is not rewritten. Throws when the file cannot be written.
    public func record(_ shapes: [DisplayShape], forAvd avdName: String) throws {
        try record(shapes, at: fileURL(forAvd: avdName))
    }

    /// The shapes last recorded for phones of `model` (`ro.product.model`),
    /// in dump order; empty when none were, or for an empty model name.
    public func shapes(forPhysicalModel model: String) -> [DisplayShape] {
        guard let url = fileURL(forPhysicalModel: model) else { return [] }
        return shapes(at: url)
    }

    /// Records `shapes` as the last known displays of phones of `model`, by
    /// the rules of `record(_:forAvd:)`. An empty model name names no phone
    /// and records nothing. Throws when the file cannot be written.
    public func record(_ shapes: [DisplayShape], forPhysicalModel model: String) throws {
        guard let url = fileURL(forPhysicalModel: model) else { return }
        try record(shapes, at: url)
    }

    private func shapes(at url: URL) -> [DisplayShape] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.version == Self.formatVersion
        else { return [] }
        return file.displays
    }

    private func record(_ shapes: [DisplayShape], at url: URL) throws {
        guard !shapes.isEmpty, shapes != self.shapes(at: url) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(File(version: Self.formatVersion, displays: shapes))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    /// Forgets `avdName`'s shapes (the AVD was deleted).
    public func removeShapes(forAvd avdName: String) {
        try? FileManager.default.removeItem(at: fileURL(forAvd: avdName))
    }

    /// Moves `avdName`'s shapes to `newName` (the AVD was renamed). What
    /// `newName` held goes either way: it was a deleted AVD's, and a skin of
    /// another size can still match its panels, so it must not reach the
    /// renamed one. Read, removed and written again rather than moved, so a
    /// rename that only changes case (one file on a case-insensitive volume)
    /// keeps the shapes. Throws when the new file cannot be written.
    public func moveShapes(fromAvd avdName: String, toAvd newName: String) throws {
        guard avdName != newName else { return }
        let shapes = shapes(forAvd: avdName)
        removeShapes(forAvd: avdName)
        removeShapes(forAvd: newName)
        try record(shapes, forAvd: newName)
    }

    /// `<name>.json`. avdmanager only allows `[A-Za-z0-9._-]` in names, but a
    /// hand-made AVD can hold anything, so every other character is
    /// percent-encoded: a name can never leave `directory`.
    func fileURL(forAvd avdName: String) -> URL {
        directory.appendingPathComponent(Self.fileName(avdName), isDirectory: false)
    }

    /// `physical/<model>.json`, the model encoded like an AVD name. The
    /// folder's name has no `.json` suffix, so no AVD's file can be it or lie
    /// in it. Nil for an empty model.
    func fileURL(forPhysicalModel model: String) -> URL? {
        guard !model.isEmpty else { return nil }
        return directory
            .appendingPathComponent("physical", isDirectory: true)
            .appendingPathComponent(Self.fileName(model), isDirectory: false)
    }

    private static func fileName(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
        return encoded + ".json"
    }

    private struct File: Codable {
        var version: Int
        var displays: [DisplayShape]
    }
}
