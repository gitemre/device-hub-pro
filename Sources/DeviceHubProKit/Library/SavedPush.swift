import Foundation

/// A push payload kept in the library: a name, the app it targets and the
/// JSON as written.
public struct SavedPush: NamedLibraryItem {
    public var id: UUID
    public var name: String
    public var bundleIdentifier: String
    public var payload: String

    public init(id: UUID = UUID(), name: String, bundleIdentifier: String, payload: String) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.payload = payload
    }
}

/// The last push that went out, for Resend Last.
public struct SentPush: Codable, Sendable, Equatable {
    public var bundleIdentifier: String
    public var payload: String

    public init(bundleIdentifier: String, payload: String) {
        self.bundleIdentifier = bundleIdentifier
        self.payload = payload
    }
}

/// The templates that fill the push editor. Each is a complete payload that
/// `SimulatorPushPayload` accepts.
public struct PushTemplate: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let payload: String

    public static let builtIn: [PushTemplate] = [
        PushTemplate(id: "simple-alert", title: "Simple alert", payload: """
        {
          "aps": {
            "alert": "A test notification"
          }
        }
        """),
        PushTemplate(id: "title-subtitle-body", title: "Title, subtitle and body", payload: """
        {
          "aps": {
            "alert": {
              "title": "Device Hub Pro",
              "subtitle": "A subtitle",
              "body": "A test notification"
            }
          }
        }
        """),
        PushTemplate(id: "badge", title: "Badge", payload: """
        {
          "aps": {
            "badge": 3
          }
        }
        """),
        PushTemplate(id: "sound", title: "Alert with sound", payload: """
        {
          "aps": {
            "alert": {
              "title": "Device Hub Pro",
              "body": "A test notification"
            },
            "sound": "default"
          }
        }
        """),
        PushTemplate(id: "silent", title: "Silent (background)", payload: """
        {
          "aps": {
            "content-available": 1
          }
        }
        """),
        PushTemplate(id: "rich", title: "Rich (mutable content, category)", payload: """
        {
          "aps": {
            "alert": {
              "title": "Device Hub Pro",
              "body": "A test notification"
            },
            "mutable-content": 1,
            "category": "MY_CATEGORY"
          }
        }
        """),
    ]
}

/// Smart quotes and dashes turn a JSON editor's `"` into a curly quote and
/// break the payload. The editor switches the
/// substitutions off; `straightened` repairs text pasted with them.
public enum PushPayloadText {
    /// `text` with typographic quotes and dashes put back to ASCII.
    public static func straightened(_ text: String) -> String {
        var result = text
        let pairs = [("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{2018}", "'"), ("\u{2019}", "'"),
                     ("\u{2013}", "-"), ("\u{2014}", "-")]
        for (from, to) in pairs {
            result = result.replacingOccurrences(of: from, with: to)
        }
        return result
    }

    /// Why `text` cannot be sent, or nil when it can.
    public static func problem(in text: String) -> String? {
        do {
            _ = try SimulatorPushPayload(text)
            return nil
        } catch {
            return "\(error)"
        }
    }
}
