import Foundation

/// A tool failure in words a tester can act on, with the raw tool output kept
/// apart so a view can offer it behind "Show Details". The tools' own text
/// (`sdkmanager --list failed with exit code 1 ... UnknownHostException`) is
/// never the sentence the user reads.
public struct PlainFailure: Equatable, Sendable {
    /// The sentence to show.
    public let summary: String
    /// The raw text behind it; nil when the summary already says everything
    /// (a short message that was plain to begin with).
    public let details: String?

    public init(summary: String, details: String? = nil) {
        self.summary = summary
        self.details = details
    }

    public static let offlineSummary =
        "Couldn\u{2019}t reach Google\u{2019}s servers. Check your internet connection and try again."
    public static let proxySummary =
        "A proxy or security software on this network is blocking the connection. "
        + "Check the proxy settings or try another network."
    public static let diskFullSummary =
        "There isn\u{2019}t enough free disk space. Free some space and try again."

    private static let offlineMarkers = [
        "unknownhostexception", "unable to resolve host", "nodename nor servname", "network is unreachable",
        "no route to host", "connection refused", "connect timed out", "unable to connect",
        "connection reset", "sockettimeoutexception", "connectexception", "internet connection appears to be offline",
        "could not finish", "timed out", "nsurlerrordomain error -1009", "nsurlerrordomain error -1001",
        "nsurlerrordomain error -1004", "temporary failure in name resolution", "failed to connect",
    ]
    private static let proxyMarkers = [
        "pkix", "sslhandshakeexception", "unable to find valid certification path", "certificate",
        "proxy", "tunnel connection failed", "407", "nsurlerrordomain error -1200", "nsurlerrordomain error -1202",
    ]
    private static let diskMarkers = [
        "no space left", "not enough space", "disk full", "insufficient disk space",
    ]

    /// Sorts a raw failure into a plain sentence. `fallback` is the sentence
    /// for a failure that matches nothing known (it names what was being
    /// done, for example "Couldn\u{2019}t load the list of system images."); the raw text goes
    /// behind it as the details.
    public static func make(_ raw: String, fallback: String) -> PlainFailure {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        func hit(_ markers: [String]) -> Bool { markers.contains { lower.contains($0) } }
        if lower.hasPrefix("no progress for") {
            return PlainFailure(summary: text)
        }
        // Proxy and certificate trouble also reads as a connection failure, so
        // it is tested first.
        if hit(proxyMarkers) { return PlainFailure(summary: proxySummary, details: text) }
        if hit(diskMarkers) { return PlainFailure(summary: diskFullSummary, details: text) }
        if hit(offlineMarkers) { return PlainFailure(summary: offlineSummary, details: text) }
        let oneLine = !text.contains("\n") && text.count <= 140
        let looksRaw = lower.contains("exit code") || lower.contains("sdkmanager") || lower.contains("avdmanager")
            || lower.contains("exception") || lower.contains("devicectl") || lower.contains("simctl")
        if text.isEmpty { return PlainFailure(summary: fallback) }
        if oneLine, !looksRaw { return PlainFailure(summary: text) }
        return PlainFailure(summary: fallback, details: text)
    }
}

/// Whether a download has the room it needs. sdkmanager's listing carries no
/// package size, so a system image is estimated at the typical size.
public enum DiskSpaceCheck {
    /// Room to leave free after the download (the archive is unpacked beside
    /// itself, and the emulator needs space for its own disks).
    public static let headroomBytes: Int64 = 2 * 1_000_000_000
    /// A typical system image download.
    public static let typicalImageBytes: Int64 = 1_500_000_000

    /// The free space needed to download an image of `imageBytes`.
    public static func requiredBytes(imageBytes: Int64 = typicalImageBytes) -> Int64 {
        imageBytes + headroomBytes
    }

    /// "1.5 GB" in the file-size style the rest of the app uses.
    public static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// The warning for a volume with `freeBytes` free, nil when there is
    /// enough room (or the free space is unknown).
    public static func warning(freeBytes: Int64?, imageBytes: Int64 = typicalImageBytes) -> String? {
        guard let freeBytes, freeBytes < requiredBytes(imageBytes: imageBytes) else { return nil }
        return "Only \(sizeText(freeBytes)) is free on this Mac. A system image needs about "
            + "\(sizeText(requiredBytes(imageBytes: imageBytes))) free (about \(sizeText(imageBytes)) "
            + "to download plus working room). Free some space first."
    }

    /// Whether the download cannot possibly fit: less than the image itself.
    public static func cannotFit(freeBytes: Int64?, imageBytes: Int64 = typicalImageBytes) -> Bool {
        guard let freeBytes else { return false }
        return freeBytes < imageBytes
    }

    /// Free space on the volume holding `url` (or its nearest existing
    /// parent), counting what macOS can reclaim; nil when it cannot be read.
    public static func freeBytes(at url: URL) -> Int64? {
        var candidate = url
        let manager = FileManager.default
        while !manager.fileExists(atPath: candidate.path), candidate.path != "/" {
            candidate.deleteLastPathComponent()
        }
        let values = try? candidate.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
