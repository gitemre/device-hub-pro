import SwiftUI

/// The Device Hub Pro verifier for iOS: one live row per Controls row it mirrors
/// (Shared/Registry.swift), observed through the APIs any app uses. It reads
/// and displays; it never changes a setting on the device.
@main
struct VerifierApp: App {
    @StateObject private var model = VerifierModel()

    var body: some Scene {
        WindowGroup {
            VerifierView(model: model)
                .onOpenURL { model.opened(link: $0) }
        }
    }
}
