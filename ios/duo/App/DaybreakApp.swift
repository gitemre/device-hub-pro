import SwiftUI

/// Daybreak, the iPhone Duo showcase: open the phone and the sun rises. The
/// hinge angle is the time of day, from night on the closed cover to noon
/// flat open, over one sky that re-flows around the fold.
///
/// Launch arguments: `--log-readings` writes every hinge callback, layout
/// change and phase change, and the frames delivered each second, to
/// `Documents/readings.jsonl`;
/// `--time-lapse-after <seconds>[,<seconds>…]` toggles the Time-Lapse at
/// those times after launch, as its button does.
@main
struct DaybreakApp: App {
    @State private var model = DayModel(arguments: ProcessInfo.processInfo.arguments)

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                // Light chrome and text over the sky, which is dark for
                // half the day.
                .preferredColorScheme(.dark)
        }
    }
}
