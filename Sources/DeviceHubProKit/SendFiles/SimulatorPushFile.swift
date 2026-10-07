import Foundation

/// A `.apns` file dropped on a simulator (Simulator.app's old drag and drop of a
/// push payload, which Xcode 27's Device Hub no longer offers): a JSON push
/// payload checked the way `simctl push` checks it. The bundle identifier of the
/// app it goes to is the payload's top-level `Simulator Target Bundle` key (the
/// key `simctl help push` documents and Xcode's own `.apns` files carry); a file
/// without it needs the user to pick the app.
public struct SimulatorPushFile: Sendable, Equatable {
    /// The top-level key naming the target app (`simctl help push`).
    public static let targetBundleKey = "Simulator Target Bundle"
    /// The extension of a push payload file.
    public static let fileExtension = "apns"
    /// Files larger than this are refused before they are read (the payload
    /// itself is limited to `SimulatorPushPayload.maximumBytes`).
    static let readLimit = 1 << 20

    public let url: URL
    public let payload: SimulatorPushPayload
    /// The payload's target app, nil when the file does not name one.
    public let bundleIdentifier: String?

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unreadable(file: String, detail: String)
        case invalid(file: String, problem: SimulatorPushPayload.Problem)
        case badTarget(file: String, value: String)

        public var description: String {
            switch self {
            case .unreadable(let file, let detail): "“\(file)” could not be read: \(detail)"
            case .invalid(let file, let problem): "“\(file)” is not a push payload. \(problem)"
            case .badTarget(let file, let value):
                "“\(file)” names “\(value)” as its \"\(SimulatorPushFile.targetBundleKey)\", which is not a bundle identifier."
            }
        }
    }

    public static func isPushFile(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == fileExtension
    }

    /// Reads and checks `url`.
    public static func read(_ url: URL) throws -> SimulatorPushFile {
        let name = url.lastPathComponent
        let data: Data
        do {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= readLimit else {
                throw Failure.invalid(file: name, problem: .tooLarge(bytes: size))
            }
            data = try Data(contentsOf: url)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreadable(file: name, detail: (error as NSError).localizedDescription)
        }
        return try parse(data, name: name, url: url)
    }

    /// Checks the bytes of a payload file called `name`.
    public static func parse(_ data: Data, name: String, url: URL? = nil) throws -> SimulatorPushFile {
        guard let text = String(data: data, encoding: .utf8) else {
            throw Failure.invalid(file: name, problem: .notJSON("the file is not UTF-8 text"))
        }
        let payload: SimulatorPushPayload
        do {
            payload = try SimulatorPushPayload(text)
        } catch let problem as SimulatorPushPayload.Problem {
            throw Failure.invalid(file: name, problem: problem)
        }
        var bundle: String?
        if let object = try? JSONSerialization.jsonObject(with: payload.data) as? [String: Any],
           let value = object[targetBundleKey] {
            guard let text = value as? String,
                  (try? SimctlClient.validateBundleIdentifier(text)) != nil
            else {
                throw Failure.badTarget(file: name, value: "\(value)")
            }
            bundle = text
        }
        return SimulatorPushFile(url: url ?? URL(fileURLWithPath: "/" + name), payload: payload, bundleIdentifier: bundle)
    }
}

extension SimctlClient {
    /// `push <udid> <bundle> <file>`: sends a checked payload file to the app
    /// (the file-argument form of `push(udid:bundleIdentifier:payload:)`;
    /// simctl answers "Notification sent to '<bundle>'"). An explicit bundle
    /// identifier overrides the payload's `Simulator Target Bundle`.
    @discardableResult
    public func push(udid: String, bundleIdentifier: String, file: URL) async throws -> String {
        try Self.validateUDID(udid)
        try Self.validateBundleIdentifier(bundleIdentifier)
        try Self.validateFile(file, role: "push payload")
        let output = try await checked(["push", udid, bundleIdentifier, file.path])
        return output.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
