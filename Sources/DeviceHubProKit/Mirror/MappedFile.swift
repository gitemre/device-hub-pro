import Foundation
import Darwin

/// A file-backed mapping used as the emulator's MMAP frame-transport target.
///
/// The emulator writes raw pixel data into the mapped region; the client reads it
/// directly. The file holds the live device screen (typed passwords, one-time
/// codes), so it is private: created fresh (never reused, never through a
/// symlink) with mode 0600 inside a 0700 folder of the per-user temporary
/// directory, under an unpredictable name, and unlinked when the mapping is
/// released. A mapping holds a shared lock on its file for its lifetime, so
/// the files a crash or force-quit leaves behind — the only ones nobody
/// holds — are swept when the next frame file is made. Marked
/// `@unchecked Sendable` because it is read-only after setup.
final class MappedFile: @unchecked Sendable {
    let path: String
    let size: Int

    private let fd: Int32
    private let base: UnsafeMutableRawPointer

    /// A fresh frame file for one stream attempt, in `directory` (the private
    /// `devicehubpro-mirror` folder of the per-user temporary directory). Frame
    /// files no live mapping holds are removed from `directory` first.
    static func makePrivate(
        port: Int,
        display: UInt32,
        size: Int,
        directory: URL = defaultDirectory
    ) throws -> MappedFile {
        if directory == defaultDirectory {
            _ = legacyFilesSwept
        }
        try ensurePrivateDirectory(directory)
        sweepAbandonedFiles(in: directory)
        let name = "\(filePrefix)\(port)-\(display)-\(UUID().uuidString).raw"
        return try MappedFile(path: directory.appendingPathComponent(name).path, size: size)
    }

    private static let filePrefix = "mirror-"

    /// Removes the frame files in `directory` that no mapping holds: a live
    /// one, in this process or another running copy, keeps its shared lock,
    /// so the exclusive lock is only granted on a file its owner left behind
    /// by crashing or being force-quit.
    static func sweepAbandonedFiles(in directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(filePrefix) && name.hasSuffix(".raw") {
            let path = directory.appendingPathComponent(name).path
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK | O_NONBLOCK)
            guard fd >= 0 else { continue }
            unlink(path)
            close(fd)
        }
    }

    /// Earlier builds mapped a fixed `/tmp/devicehubpro-mirror-<port>-<display>.raw`:
    /// world-readable (0644), 64 MB, never removed, still holding the last
    /// mirrored screen. Removed once per process.
    private static let legacyFilesSwept: Void = sweepLegacyFiles(in: URL(fileURLWithPath: "/tmp"))

    /// Removes this user's regular files named like the old fixed frame
    /// files from `directory` (a symlink or another user's file is left).
    static func sweepLegacyFiles(in directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where isLegacyFrameFileName(name) {
            let path = directory.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == getuid()
            else { continue }
            unlink(path)
        }
    }

    /// `devicehubpro-mirror-<port>-<display>.raw`.
    private static func isLegacyFrameFileName(_ name: String) -> Bool {
        let prefix = "devicehubpro-mirror-", suffix = ".raw"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let fields = name.dropFirst(prefix.count).dropLast(suffix.count)
            .split(separator: "-", omittingEmptySubsequences: false)
        return fields.count == 2 && fields.allSatisfy { field in
            !field.isEmpty && field.allSatisfy { ("0"..."9").contains($0) }
        }
    }

    /// `$TMPDIR` is per user (0700) on macOS; the extra folder keeps the frame
    /// files together and out of other tools' way.
    static var defaultDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("devicehubpro-mirror", isDirectory: true)
    }

    /// Creates `path` exclusively (an existing file or a planted symlink at
    /// that name fails instead of being followed or reused) with mode 0600,
    /// taking its shared lock in the same step so a sweep can never see it
    /// unheld.
    init(path: String, size: Int) throws {
        self.path = path
        self.size = size

        let fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_SHLOCK, 0o600)
        guard fd >= 0 else { throw MirrorError.couldNotCreateSharedMemory(path) }
        guard ftruncate(fd, off_t(size)) == 0 else {
            close(fd)
            unlink(path)
            throw MirrorError.couldNotCreateSharedMemory(path)
        }
        let mapped = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0)
        guard let base = mapped, base != UnsafeMutableRawPointer(bitPattern: -1) else {
            close(fd)
            unlink(path)
            throw MirrorError.couldNotCreateSharedMemory(path)
        }
        self.fd = fd
        self.base = base
    }

    /// Copies the mapped pixels into owned storage. A zero-copy view would be
    /// mutated by the emulator while the renderer uploads it to a texture,
    /// which shows up as torn rows that stay on screen once the stream pauses;
    /// it would also outlive `munmap`.
    func data(offset: Int, count: Int) -> Data {
        Data(bytes: base.advanced(by: offset), count: count)
    }

    /// Unlinking removes only the name: an emulator that still has the file
    /// mapped keeps writing into its pages until the stream closes. Closing
    /// the descriptor releases the shared lock.
    deinit {
        munmap(base, size)
        unlink(path)
        close(fd)
    }

    /// Creates `directory` with mode 0700, or accepts an existing one only
    /// when it is a real directory owned by this user with no group/other
    /// access.
    private static func ensurePrivateDirectory(_ directory: URL) throws {
        let path = directory.path
        if mkdir(path, 0o700) != 0, errno != EEXIST {
            throw MirrorError.couldNotCreateSharedMemory(path)
        }
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0
        else {
            throw MirrorError.couldNotCreateSharedMemory(path)
        }
    }
}
