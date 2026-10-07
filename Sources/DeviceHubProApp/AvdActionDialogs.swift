import SwiftUI
import DeviceHubProKit

/// Transient presentation state for the AVD file actions. Owned by the app
/// scene so the sidebar context menu and the Device menu drive the same
/// dialogs; the actions themselves live on `AppModel`.
@MainActor
@Observable
final class AvdActionDialogs {
    enum Confirmation: Equatable {
        case delete(String)
        case wipeData(String)

        var avdName: String {
            switch self {
            case .delete(let name), .wipeData(let name): name
            }
        }
    }

    var confirmation: Confirmation?
    var renameAvdName: String?
    var renameDraft = ""

    func requestRename(_ avdName: String) {
        renameDraft = avdName
        renameAvdName = avdName
    }

    func requestDelete(_ avdName: String) {
        confirmation = .delete(avdName)
    }

    func requestWipeData(_ avdName: String) {
        confirmation = .wipeData(avdName)
    }
}

/// Presents `AvdActionDialogs`' confirmations as Device Hub-style alerts (the
/// simulator ones' look, `DHAlert.swift`) over the window that hosts it.
struct AvdActionDialogsHost: ViewModifier {
    @Environment(AppModel.self) private var model
    let dialogs: AvdActionDialogs

    func body(content: Content) -> some View {
        content.dhAlert(
            item: dialogs.confirmation,
            spec: { confirmation in
                // The name the sidebar shows ("Television (4K)"), not the AVD id
                // ("Television_4K") the files are named by.
                let shown = { (id: String) in model.catalog.avdCards.first { $0.name == id }?.displayName ?? id }
                switch confirmation {
                case .delete(let id):
                    let name = shown(id)
                    return DHAlertSpec(
                        title: "Remove \(name)?",
                        message: "Removing \(name) will move this emulator's files to the Trash.",
                        confirmTitle: "Remove",
                        style: .plain
                    )
                case .wipeData(let id):
                    let name = shown(id)
                    return DHAlertSpec(
                        title: "Reset content and settings on \(dhQuoted(name))?",
                        message: "User data and snapshots will be permanently deleted, and the next start will be clean. You can\u{2019}t undo this action.",
                        confirmTitle: "Reset",
                        cancelTitle: "Don\u{2019}t Reset",
                        style: .caution
                    )
                }
            },
            resolve: { confirmation, confirmed in
                dialogs.confirmation = nil
                guard confirmed else { return }
                switch confirmation {
                case .delete:
                    Task { await model.catalog.deleteAVD(confirmation.avdName) }
                case .wipeData:
                    Task { await model.catalog.wipeAVDData(confirmation.avdName) }
                }
            }
        )
    }
}
