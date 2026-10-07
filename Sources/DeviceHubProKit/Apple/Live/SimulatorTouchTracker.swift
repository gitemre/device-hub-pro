import Foundation

/// One stage contact after mapping: its id and phase, where it is on the
/// native panel, and the native edge a contact starting there begins at.
struct SimulatorContact: Sendable, Equatable {
    let id: Int32
    let phase: TouchCommand.Phase
    let point: SimulatorTouchPoint
    /// Only read on `.down`: the native edge the contact starts at.
    let edge: SimulatorTouchEdge
}

/// Turns stage contacts into dtuhidd digitizer events.
///
/// dtuhidd takes one contact, or two in one event that share a phase (they
/// go down, move and lift together). The tracker therefore follows at most
/// two fingers by id and drops a third:
///
/// - One finger: began, moved, ended, each tagged with the edge the finger
///   started at. The guest recognises the system edge gestures (Home, the
///   app switcher) from the tag on every event of the contact, not from the
///   coordinates (measured on iOS 27.0: the same swipe tagged only on
///   `began` did nothing).
/// - A second finger going down while one is down ends the one-finger touch
///   and begins a two-finger touch.
/// - Either finger of two lifting ends the two-finger touch; the finger left
///   down is ignored until it lifts, so a pinch never turns into a stray drag
///   or tap. So is any finger that goes down meanwhile.
///
/// Moves and ups of ids that are not followed are dropped, and a down for an
/// id already down counts as a move (as in `PhysicalPointerFilter`).
struct SimulatorTouchTracker: Sendable {
    private enum Mode: Sendable, Equatable {
        case idle
        case one(Int32)
        case two(Int32, Int32)
        /// Ids still down after a two-finger touch ended.
        case draining(Set<Int32>)
    }

    private var mode = Mode.idle
    private var points: [Int32: SimulatorTouchPoint] = [:]
    private var edges: [Int32: SimulatorTouchEdge] = [:]

    /// The fingers the tracker follows (a draining pinch's leftovers included).
    var downCount: Int {
        switch mode {
        case .idle: return 0
        case .one: return 1
        case .two: return 2
        case .draining(let ids): return ids.count
        }
    }

    mutating func reset() {
        mode = .idle
        points.removeAll()
        edges.removeAll()
    }

    private func follows(_ id: Int32) -> Bool {
        switch mode {
        case .one(let one): return one == id
        case .two(let first, let second): return first == id || second == id
        case .idle, .draining: return false
        }
    }

    /// The digitizer events for one input frame (all its contacts at once).
    mutating func accept(_ contacts: [SimulatorContact]) -> [SimulatorHIDEvent] {
        let followed: Int
        switch mode {
        case .idle, .draining: followed = 0
        case .one: followed = 1
        case .two: followed = 2
        }
        var newDowns: [Int32] = []
        var ups: Set<Int32> = []
        var moved = false

        for contact in contacts {
            let known = follows(contact.id) || newDowns.contains(contact.id)
            switch contact.phase {
            case .down:
                if known {
                    points[contact.id] = contact.point
                    moved = true
                } else if case .draining = mode {
                    continue
                } else if followed + newDowns.count < 2 {
                    newDowns.append(contact.id)
                    points[contact.id] = contact.point
                    edges[contact.id] = contact.edge
                }
            case .move:
                guard known else { continue }
                points[contact.id] = contact.point
                moved = true
            case .up:
                if known {
                    points[contact.id] = contact.point
                    ups.insert(contact.id)
                } else if case .draining(var ids) = mode {
                    ids.remove(contact.id)
                    mode = ids.isEmpty ? .idle : .draining(ids)
                }
            }
        }

        var events: [SimulatorHIDEvent] = []
        switch mode {
        case .idle:
            if newDowns.count == 1 {
                beginOne(newDowns[0], ups: ups, into: &events)
            } else if newDowns.count == 2 {
                beginTwo(newDowns[0], newDowns[1], ups: ups, into: &events)
            }
        case .one(let id):
            if let second = newDowns.first {
                events.append(single(id, .ended))
                if ups.contains(id) {
                    // The first finger lifted as the second went down.
                    forget(id)
                    mode = .idle
                    beginOne(second, ups: ups, into: &events)
                } else {
                    beginTwo(id, second, ups: ups, into: &events)
                }
            } else if ups.contains(id) {
                events.append(single(id, .ended))
                forget(id)
                mode = .idle
            } else if moved {
                events.append(single(id, .moved))
            }
        case .two(let first, let second):
            if !ups.isEmpty {
                events.append(pair(first, second, .ended))
                endTwo(first, second, ups: ups)
            } else if moved {
                events.append(pair(first, second, .moved))
            }
        case .draining:
            break
        }
        return events
    }

    private mutating func beginOne(_ id: Int32, ups: Set<Int32>, into events: inout [SimulatorHIDEvent]) {
        events.append(single(id, .began))
        if ups.contains(id) {
            events.append(single(id, .ended))
            forget(id)
            mode = .idle
        } else {
            mode = .one(id)
        }
    }

    private mutating func beginTwo(
        _ first: Int32,
        _ second: Int32,
        ups: Set<Int32>,
        into events: inout [SimulatorHIDEvent]
    ) {
        events.append(pair(first, second, .began))
        if ups.isEmpty {
            mode = .two(first, second)
        } else {
            events.append(pair(first, second, .ended))
            endTwo(first, second, ups: ups)
        }
    }

    private mutating func endTwo(_ first: Int32, _ second: Int32, ups: Set<Int32>) {
        let remaining = Set([first, second]).subtracting(ups)
        forget(first)
        forget(second)
        mode = remaining.isEmpty ? .idle : .draining(remaining)
    }

    private mutating func forget(_ id: Int32) {
        points[id] = nil
        edges[id] = nil
    }

    private func single(_ id: Int32, _ phase: SimulatorTouchPhase) -> SimulatorHIDEvent {
        let point = points[id] ?? SimulatorTouchPoint(x: 0.5, y: 0.5)
        let edge = edges[id] ?? .none
        return edge == .none
            ? .touch(x: point.x, y: point.y, phase: phase)
            : .edgeTouch(x: point.x, y: point.y, phase: phase, edge: edge)
    }

    private func pair(_ first: Int32, _ second: Int32, _ phase: SimulatorTouchPhase) -> SimulatorHIDEvent {
        .twoFingerTouch(
            first: points[first] ?? SimulatorTouchPoint(x: 0.5, y: 0.5),
            second: points[second] ?? SimulatorTouchPoint(x: 0.5, y: 0.5),
            phase: phase
        )
    }
}
