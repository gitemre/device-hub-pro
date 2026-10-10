import Carbon
import Foundation

/// Settings ▸ Secure keyboard entry, as Device Hub offers it: while the Mac
/// keyboard is forwarded to a device view that has the keyboard focus, macOS
/// secure event input is on, so other apps cannot read the keys typed into
/// the device (passwords included).
///
/// macOS counts `EnableSecureEventInput` calls, so each view asks once and
/// gives it back once: secure input is on while any view holds it.
@MainActor
final class SecureKeyboardEntry {
    static let shared = SecureKeyboardEntry()

    private var holders: Set<ObjectIdentifier> = []
    private let enable: () -> Void
    private let disable: () -> Void

    init(enable: @escaping () -> Void = { _ = EnableSecureEventInput() },
         disable: @escaping () -> Void = { _ = DisableSecureEventInput() }) {
        self.enable = enable
        self.disable = disable
    }

    /// Whether any view holds secure input now.
    var isOn: Bool { !holders.isEmpty }

    /// `owner` wants secure input on (`wanted`) or no longer does.
    func set(_ wanted: Bool, for owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        if wanted {
            guard holders.insert(id).inserted else { return }
            if holders.count == 1 { enable() }
        } else {
            guard holders.remove(id) != nil else { return }
            if holders.isEmpty { disable() }
        }
    }
}
