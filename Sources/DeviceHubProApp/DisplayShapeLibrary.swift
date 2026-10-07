import Foundation
import Observation
import DeviceHubProKit

/// The display shapes each AVD and each phone model last reported, for the
/// views that draw a device's screen before or without a live read: the
/// stopped and booting heroes, and the live stage until the session's own
/// `dumpsys display` answers.
///
/// Backed by `DisplayShapeStore` (one JSON file per AVD, and per phone model
/// under `physical/`) and read from it once per name; `record`, `forget` and
/// `move` update the copy the views observe at once and change the files off
/// the main thread, one at a time in call order (a delete right after a
/// record must not be undone by the record's late write). Without a store
/// (tests, a hermetic model) the shapes live for the process only.
@MainActor
@Observable
final class DisplayShapeLibrary {
    @ObservationIgnored private let store: DisplayShapeStore?
    @ObservationIgnored private let diskQueue = DispatchQueue(label: "com.devicehubpro.display-shapes", qos: .utility)
    /// Shapes by AVD name, filled on first read: from the store, or empty
    /// when it has none (so a miss is not read from disk again).
    @ObservationIgnored private var shapesByAvd: [String: [DisplayShape]] = [:]
    /// Shapes by phone model, filled like `shapesByAvd`. Kept apart from
    /// it: a model and an AVD can share a name.
    @ObservationIgnored private var shapesByModel: [String: [DisplayShape]] = [:]
    /// Bumped by every change to an AVD's or a model's shapes. Reads
    /// observe it, not `shapesByAvd` or `shapesByModel`: filling those
    /// lazily inside a view body must not count as a change to what the
    /// body read.
    private var revision = 0

    init(store: DisplayShapeStore?) {
        self.store = store
    }

    /// `avdName`'s last known displays (both panels of a foldable), in dump
    /// order; empty when it never reported any.
    func shapes(forAvd avdName: String) -> [DisplayShape] {
        _ = revision
        if let known = shapesByAvd[avdName] { return known }
        let stored = store?.shapes(forAvd: avdName) ?? []
        shapesByAvd[avdName] = stored
        return stored
    }

    /// Remembers `shapes` as `avdName`'s. An empty list is a failed read
    /// and changes nothing, like the store.
    func record(_ shapes: [DisplayShape], forAvd avdName: String) {
        guard !shapes.isEmpty, shapesByAvd[avdName] != shapes else { return }
        shapesByAvd[avdName] = shapes
        revision &+= 1
        // A lost write only costs the skin fallback until the AVD's next
        // session, which records again.
        onDisk { try? $0.record(shapes, forAvd: avdName) }
    }

    /// The last known displays of phones of `model` (`adb devices -l`'s
    /// `model:`), in dump order; empty when none reported any, and for an
    /// empty model name.
    func shapes(forPhysicalModel model: String) -> [DisplayShape] {
        _ = revision
        guard !model.isEmpty else { return [] }
        if let known = shapesByModel[model] { return known }
        let stored = store?.shapes(forPhysicalModel: model) ?? []
        shapesByModel[model] = stored
        return stored
    }

    /// Remembers `shapes` as the displays of phones of `model`. An empty
    /// list is a failed read and changes nothing, like the store; an empty
    /// model names no phone.
    func record(_ shapes: [DisplayShape], forPhysicalModel model: String) {
        guard !shapes.isEmpty, !model.isEmpty, shapesByModel[model] != shapes else { return }
        shapesByModel[model] = shapes
        revision &+= 1
        // A lost write only costs the square corner until the phone's next
        // session, which records again.
        onDisk { try? $0.record(shapes, forPhysicalModel: model) }
    }

    /// Forgets `avdName`'s shapes: the AVD was deleted, and an AVD created
    /// later under its name must not draw the old device's screen corner
    /// (`DisplayShape.matching` takes a panel within 3% of the skin's
    /// aspect, which most phone panels are of one another).
    func forget(avdName: String) {
        if shapesByAvd[avdName]?.isEmpty == false { revision &+= 1 }
        shapesByAvd[avdName] = []
        onDisk { $0.removeShapes(forAvd: avdName) }
    }

    /// Moves `avdName`'s shapes to `newName`: the AVD was renamed. Whatever
    /// `newName` held (a deleted AVD's) goes.
    func move(fromAvd avdName: String, toAvd newName: String) {
        guard avdName != newName else { return }
        let moved = shapes(forAvd: avdName)
        if !moved.isEmpty || shapesByAvd[newName]?.isEmpty == false { revision &+= 1 }
        shapesByAvd[avdName] = []
        shapesByAvd[newName] = moved
        onDisk { try? $0.moveShapes(fromAvd: avdName, toAvd: newName) }
    }

    /// Waits until the file changes asked for so far are done (tests).
    func waitForPendingWrites() async {
        await withCheckedContinuation { continuation in
            diskQueue.async { continuation.resume() }
        }
    }

    private func onDisk(_ change: @escaping @Sendable (DisplayShapeStore) -> Void) {
        guard let store else { return }
        diskQueue.async { change(store) }
    }
}
