import Foundation

/// A point of a route, in degrees.
public struct GpsPoint: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// What the emulator is told at one tick: the position, the speed over the
/// ground (m/s) and the bearing of travel (degrees clockwise from north).
public struct GpsSample: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var speed: Double
    public var bearing: Double

    public init(latitude: Double, longitude: Double, speed: Double = 0, bearing: Double = 0) {
        self.latitude = latitude
        self.longitude = longitude
        self.speed = speed
        self.bearing = bearing
    }
}

/// A polyline walked at a constant speed. A route that `repeats` starts over
/// from its first point when it ends (a closed loop, or an out-and-back that
/// returns to where it began); one that does not stops on its last point.
public struct GpsRoute: Sendable, Equatable {
    public let points: [GpsPoint]
    /// Metres per second.
    public let speed: Double
    public let repeats: Bool

    /// Mean Earth radius for the great-circle distances (metres).
    static let earthRadius = 6_371_008.8
    /// Metres short of the end that still count as arrived (rounding).
    static let arrivalTolerance = 1e-3

    public init(points: [GpsPoint], speed: Double, repeats: Bool = false) {
        self.points = points
        self.speed = speed
        self.repeats = repeats
    }

    /// Whether the route can be walked: two points, a positive speed and a
    /// non-zero length.
    public var isWalkable: Bool { points.count >= 2 && speed > 0 && length > 0 }

    /// The length of the polyline in metres.
    public var length: Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + Self.distance($1.0, $1.1) }
    }

    /// The sample after walking `distance` metres from the start. Past the end
    /// a repeating route wraps around; another stays on its last point.
    public func sample(atDistance distance: Double) -> GpsSample {
        guard let first = points.first else { return GpsSample(latitude: 0, longitude: 0) }
        guard points.count >= 2, length > 0 else {
            return GpsSample(latitude: first.latitude, longitude: first.longitude)
        }
        let total = length
        let ended = !repeats && distance >= total - Self.arrivalTolerance
        var remaining: Double
        if ended {
            remaining = total
        } else if repeats {
            remaining = distance.truncatingRemainder(dividingBy: total)
            if remaining < 0 { remaining += total }
        } else {
            remaining = max(distance, 0)
        }
        for index in 0..<(points.count - 1) {
            let from = points[index]
            let to = points[index + 1]
            let leg = Self.distance(from, to)
            if remaining <= leg || index == points.count - 2 {
                let fraction = leg > 0 ? min(remaining / leg, 1) : 1
                return GpsSample(
                    latitude: from.latitude + (to.latitude - from.latitude) * fraction,
                    longitude: from.longitude + (to.longitude - from.longitude) * fraction,
                    speed: ended ? 0 : speed,
                    bearing: Self.bearing(from, to)
                )
            }
            remaining -= leg
        }
        let last = points[points.count - 1]
        return GpsSample(latitude: last.latitude, longitude: last.longitude)
    }

    /// Whether walking `distance` metres reaches the end of a route that does
    /// not repeat.
    public func isFinished(atDistance distance: Double) -> Bool {
        !repeats && distance >= length - Self.arrivalTolerance
    }

    /// Great-circle distance in metres (haversine).
    public static func distance(_ a: GpsPoint, _ b: GpsPoint) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let deltaLat = (b.latitude - a.latitude) * .pi / 180
        let deltaLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(deltaLat / 2) * sin(deltaLat / 2) + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial bearing from `a` to `b`, degrees clockwise from north.
    public static func bearing(_ a: GpsPoint, _ b: GpsPoint) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let deltaLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }
}

/// The three moving scenarios both Controls Location menus offer under
/// "Trips", by Apple's names (`simctl location list`).
///
/// A simulator runs Apple's own scenario of that name. An emulator has none,
/// so Device Hub Pro plays a route of its own: SOURCE-DERIVED from the names and the
/// speeds a tester expects (a run about 3 m/s, a bicycle ride about 6 m/s, a
/// freeway drive about 30 m/s), laid out around Apple Park in Cupertino, where
/// the simulator's own scenarios start. Apple's actual waypoints are not used.
public enum LocationScenario: String, CaseIterable, Identifiable, Sendable {
    case cityRun
    case cityBicycleRide
    case freewayDrive

    public var id: String { rawValue }

    /// The name `simctl location list` and the menus use.
    public var name: String {
        switch self {
        case .cityRun: return "City Run"
        case .cityBicycleRide: return "City Bicycle Ride"
        case .freewayDrive: return "Freeway Drive"
        }
    }

    public init?(name: String) {
        guard let match = Self.allCases.first(where: { $0.name == name }) else { return nil }
        self = match
    }

    /// Metres per second.
    public var speed: Double {
        switch self {
        case .cityRun: return 3
        case .cityBicycleRide: return 6
        case .freewayDrive: return 30
        }
    }

    /// The route Device Hub Pro plays on an emulator. All three repeat until the
    /// location is changed: the runs are closed loops, the freeway an
    /// out-and-back.
    public var route: GpsRoute {
        switch self {
        case .cityRun:
            // About 1.9 km around the blocks west of Apple Park.
            return GpsRoute(points: Self.loop(south: 37.3349, west: -122.0090, north: 37.3389, east: -122.0030), speed: speed, repeats: true)
        case .cityBicycleRide:
            // About 6.2 km around Cupertino.
            return GpsRoute(points: Self.loop(south: 37.3200, west: -122.0300, north: 37.3320, east: -122.0100), speed: speed, repeats: true)
        case .freewayDrive:
            // About 16 km along the I-280 corridor toward Palo Alto and back.
            let start = GpsPoint(latitude: 37.3318, longitude: -122.0312)
            let middle = GpsPoint(latitude: 37.3790, longitude: -122.0900)
            let end = GpsPoint(latitude: 37.4300, longitude: -122.1700)
            return GpsRoute(points: [start, middle, end, middle, start], speed: speed, repeats: true)
        }
    }

    private static func loop(south: Double, west: Double, north: Double, east: Double) -> [GpsPoint] {
        [
            GpsPoint(latitude: south, longitude: west),
            GpsPoint(latitude: south, longitude: east),
            GpsPoint(latitude: north, longitude: east),
            GpsPoint(latitude: north, longitude: west),
            GpsPoint(latitude: south, longitude: west),
        ]
    }
}

/// Plays a `GpsRoute` into a sink once per interval (the emulator's GPS
/// samples at about 1 Hz). It runs until the surrounding task is cancelled,
/// the sink refuses a sample, or a route that does not repeat ends.
public enum GpsRoutePlayer {
    /// The sink takes one sample and answers whether the device accepted it.
    public typealias Sink = @Sendable (GpsSample) async -> Bool

    /// - Parameters:
    ///   - interval: seconds between samples (1 for the emulator).
    ///   - sleep: how the player waits between samples; tests make it instant.
    /// - Returns: why the player ended.
    @discardableResult
    public static func play(_ route: GpsRoute, interval: Double = 1, sink: Sink) async -> Ending {
        await play(route, interval: interval, sleep: { try await Task.sleep(for: $0) }, sink: sink)
    }

    @discardableResult
    public static func play(
        _ route: GpsRoute,
        interval: Double,
        sleep: @Sendable (Duration) async throws -> Void,
        sink: Sink
    ) async -> Ending {
        guard route.isWalkable else { return .notWalkable }
        var tick = 0
        while true {
            if Task.isCancelled { return .cancelled }
            let distance = route.speed * interval * Double(tick)
            guard await sink(route.sample(atDistance: distance)) else { return .refused }
            if route.isFinished(atDistance: distance) { return .finished }
            do {
                try await sleep(.milliseconds(Int(interval * 1000)))
            } catch {
                return .cancelled
            }
            tick += 1
        }
    }

    public enum Ending: Sendable, Equatable {
        case cancelled
        /// The sink answered no: the emulator is gone or refused the fix.
        case refused
        /// A route that does not repeat reached its last point.
        case finished
        case notWalkable
    }
}
