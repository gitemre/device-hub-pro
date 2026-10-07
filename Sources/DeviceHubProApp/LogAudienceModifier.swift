import SwiftUI

/// Tells the `LogcatController` that this view shows the log while it is on
/// screen in a visible window, so the adb child and the polls stop when no
/// view does (see `LogcatController.setLogShown`).
private struct LogAudienceModifier: ViewModifier {
    let logcat: LogcatController
    let isWindowVisible: Bool
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: isWindowVisible, initial: true) { _, visible in
                logcat.setLogShown(id, visible)
            }
            .onDisappear { logcat.setLogShown(id, false) }
    }
}

extension View {
    func logAudience(_ logcat: LogcatController, isWindowVisible: Bool) -> some View {
        modifier(LogAudienceModifier(logcat: logcat, isWindowVisible: isWindowVisible))
    }
}
