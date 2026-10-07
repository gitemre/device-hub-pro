import SwiftUI
import DeviceHubProKit

/// The emulator's Custom Location… sheet: the shared sheet
/// (`CustomLocationSheet`) over `LocationController`. Opening it starts from
/// the emulator's current fix.
struct AndroidCustomLocationSheet: View {
    @Environment(DeviceWorkspace.self) private var workspace

    var body: some View {
        let location = workspace.location
        CustomLocationSheet(
            title: "Custom Location",
            initialLatitude: location.locationLatText,
            initialLongitude: location.locationLngText,
            onCoordinate: { latitude, longitude in
                await location.choose(.coordinate(latitude: latitude, longitude: longitude))
            },
            onRoute: { from, to, speed in
                await location.choose(.route(from: from, to: to, speed: speed))
            }
        )
    }
}
