import CryptoKit
import Foundation

/// The digests the SDK repository (sha1) and Adoptium (sha256) publish, as
/// lower-case hex, computed over the file in chunks.
public enum FileChecksum {
    public enum Algorithm: String, Sendable {
        case sha1
        case sha256

        public init?(name: String) {
            switch name.lowercased() {
            case "sha1", "sha-1": self = .sha1
            case "sha256", "sha-256": self = .sha256
            default: return nil
            }
        }
    }

    public static func hexDigest(of file: URL, algorithm: Algorithm) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        switch algorithm {
        case .sha1:
            var hasher = Insecure.SHA1()
            try feed(handle) { hasher.update(data: $0) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        case .sha256:
            var hasher = SHA256()
            try feed(handle) { hasher.update(data: $0) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Whether `file` has exactly the published digest (case-insensitive).
    public static func matches(_ file: URL, algorithm: Algorithm, expected: String) -> Bool {
        guard let actual = try? hexDigest(of: file, algorithm: algorithm) else { return false }
        return actual.lowercased() == expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func feed(_ handle: FileHandle, _ body: (Data) -> Void) throws {
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            body(chunk)
        }
    }
}
