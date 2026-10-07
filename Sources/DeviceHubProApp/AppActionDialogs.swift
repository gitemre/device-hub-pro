import SwiftUI

/// Transient presentation state for the Apps inspector's destructive row
/// actions. Owned by the app scene so the context menu presents the same
/// dialogs as any future menu entry; the actions themselves live on
/// `AppModel` (the `AvdActionDialogs` pattern).
@MainActor
@Observable
final class AppActionDialogs {
    enum Confirmation: Equatable {
        case clearData(package: String, name: String)
        case uninstall(package: String, name: String)
    }

    var confirmation: Confirmation?

    func requestClearData(package: String, name: String) {
        confirmation = .clearData(package: package, name: name)
    }

    func requestUninstall(package: String, name: String) {
        confirmation = .uninstall(package: package, name: name)
    }
}
