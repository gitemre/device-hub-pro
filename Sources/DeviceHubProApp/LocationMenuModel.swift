import Foundation
import DeviceHubProKit

/// The one Location menu both Controls panels show (Android emulators and iOS
/// simulators), so a tester finds the same items in the same order: None, the
/// fourteen places, a "Trips" section with the moving scenarios, and Custom
/// Location…. The platforms differ only in how an item is carried out (an
/// emulator gets Device Hub Pro's own route player over gRPC `setGps`; a simulator
/// runs `simctl location`). A physical iPhone keeps its own subset.
enum LocationMenuEntry: Equatable, Identifiable {
    case none
    case separator(String)
    case place(AppleLocationPlace)
    case header(String)
    case trip(LocationScenario)
    case custom

    var id: String {
        switch self {
        case .none: "none"
        case .separator(let id): "separator.\(id)"
        case .place(let place): "place.\(place.name)"
        case .header(let title): "header.\(title)"
        case .trip(let trip): "trip.\(trip.rawValue)"
        case .custom: "custom"
        }
    }

    /// The text of an item; nil for a separator.
    var title: String? {
        switch self {
        case .none: LocationMenuModel.noneTitle
        case .separator: nil
        case .place(let place): place.name
        case .header(let title): title
        case .trip(let trip): trip.name
        case .custom: LocationMenuModel.customTitle
        }
    }
}

enum LocationMenuModel {
    static let noneTitle = "None"
    static let tripsHeader = "Trips"
    static let customTitle = "Custom Location…"

    /// The entries in display order. `trips` are the scenarios the device can
    /// run (a simulator lists what `simctl location list` names; an emulator
    /// runs all of them).
    static func entries(trips: [LocationScenario] = LocationScenario.allCases) -> [LocationMenuEntry] {
        var entries: [LocationMenuEntry] = [.none, .separator("places")]
        entries += AppleLocationPlaces.all.map(LocationMenuEntry.place)
        if !trips.isEmpty {
            entries.append(.separator("trips"))
            entries.append(.header(tripsHeader))
            entries += trips.map(LocationMenuEntry.trip)
        }
        entries += [.separator("custom"), .custom]
        return entries
    }

    /// The scenarios a simulator's `simctl location list` names, in the shared
    /// order and by the shared names (its other scenario, "Apple", is not a
    /// trip).
    static func trips(named names: [String]) -> [LocationScenario] {
        LocationScenario.allCases.filter { names.contains($0.name) }
    }
}
