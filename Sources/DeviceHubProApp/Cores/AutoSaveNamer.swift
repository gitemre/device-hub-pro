import Foundation

/// The free name an auto-saved recording is moved to: the clip's own file
/// name, else `<name>-2.mp4`, `<name>-3.mp4` and so on. The recorder never
/// overwrites, and neither does the auto-save.
///
/// `RecordingFinalizer` asks it with `FileManager.default.fileExists(atPath:)`
/// and moves the clip there.
enum AutoSaveNamer {
    /// The first destination in `directory` for which `fileExists` is false.
    static func destination(
        for clip: URL,
        in directory: URL,
        fileExists: (_ path: String) -> Bool
    ) -> URL {
        let base = clip.deletingPathExtension().lastPathComponent
        var destination = directory.appendingPathComponent(clip.lastPathComponent)
        var suffix = 2
        while fileExists(destination.path) {
            destination = directory.appendingPathComponent("\(base)-\(suffix).mp4")
            suffix += 1
        }
        return destination
    }
}
