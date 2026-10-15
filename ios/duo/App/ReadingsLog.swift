import Foundation
import os

/// Appends one JSON object per line to `Documents/readings.jsonl` and to the
/// unified log (subsystem com.devicehubpro.duo, category readings), so a
/// test on the Mac can follow a fold from either side:
///
///     simctl get_app_container <UDID> com.devicehubpro.duo data   # + /Documents/readings.jsonl
///
/// The app keeps one only when launched with `--log-readings`
/// (`build.sh --install <UDID> --launch -- --log-readings`).
///
/// Every line carries `t` (ISO 8601, UTC, milliseconds), `up` (milliseconds
/// since launch, for rates) and `kind`; the other keys belong to the kind.
/// Lines from earlier launches stay: each launch starts with `app.launch`.
@MainActor
final class ReadingsLog {
    private let handle: FileHandle?
    private let logger = Logger(subsystem: "com.devicehubpro.duo", category: "readings")
    private let launchedAt = ProcessInfo.processInfo.systemUptime
    /// The last payload written per dedupe key, so a layout pass that
    /// changes nothing writes nothing.
    private var lastPayload: [String: Data] = [:]
    private let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    let url: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = documents.appendingPathComponent("readings.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    /// Milliseconds since launch.
    var uptime: Double {
        ((ProcessInfo.processInfo.systemUptime - launchedAt) * 1000).rounded()
    }

    /// Writes `values` under `kind`. With `dedupe`, a payload identical to
    /// the last one written for the same key is dropped.
    func record(_ kind: String, _ values: [String: Any], dedupeKey: String? = nil) {
        if let key = dedupeKey {
            let payload = (try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])) ?? Data()
            if lastPayload[key] == payload { return }
            lastPayload[key] = payload
        }
        var line = values
        line["kind"] = kind
        line["t"] = Date().formatted(timestampStyle)
        line["up"] = uptime
        guard JSONSerialization.isValidJSONObject(line),
              var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes])
        else {
            logger.error("unencodable reading \(kind, privacy: .public)")
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        logger.info("\(text, privacy: .public)")
        data.append(0x0A)
        try? handle?.write(contentsOf: data)
    }
}

// JSON helpers: numbers rounded to a tenth (written as decimals, so 71.1
// stays 71.1 rather than 71.099999999999994), nil as null.
func jsonNumber(_ value: Double, places: Int = 1) -> Any {
    guard value.isFinite else { return NSNull() }
    return NSDecimalNumber(string: String(format: "%.\(places)f", locale: Locale(identifier: "en_US_POSIX"), value))
}

func jsonRect(_ rect: CGRect) -> [Any] {
    [rect.minX, rect.minY, rect.width, rect.height].map { jsonNumber($0) }
}

func jsonSize(_ size: CGSize) -> [Any] {
    [size.width, size.height].map { jsonNumber($0) }
}

/// Top, leading/left, bottom, trailing/right.
func jsonInsets(_ top: CGFloat, _ leading: CGFloat, _ bottom: CGFloat, _ trailing: CGFloat) -> [Any] {
    [top, leading, bottom, trailing].map { jsonNumber($0) }
}
