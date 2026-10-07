import XCTest
@testable import DeviceHubProApp
@testable import DeviceHubProKit

/// `StatusBarDemoRecordStore` on its own: two workspaces'
/// stores share one `UserDefaults`, each keeping its own `records` dict
/// alive across calls — the scenario `StatusBarDemoController` puts it in.
/// `save` must diff per key against what this store itself last knew,
/// never touch a key it never saw, and never resurrect or overwrite a key
/// another store just changed.
@MainActor
final class StatusBarDemoRecordStoreTests: XCTestCase {
    private let original = StatusBarDemoOriginal(allowedRaw: "0", onRaw: "0", wasInDemoMode: false)

    private func record() -> StatusBarDemoRecord {
        StatusBarDemoRecord(original)
    }

    /// A delete in store A survives a later, unrelated save in store B: B
    /// never learned about A's key, so its own (stale, pre-delete) copy in
    /// its local `records` dict must not resurrect it.
    func testADeleteInOneStoreSurvivesAnUnrelatedSaveInAnother() {
        let defaults = UserDefaults.scratch()
        let storeA = StatusBarDemoRecordStore(defaults: defaults)
        let storeB = StatusBarDemoRecordStore(defaults: defaults)

        storeA.save(["avd-a": record()])
        // B loads before A's delete: its own `records` (like a real
        // controller's) would carry A's key along, unread and unchanged.
        var recordsB = storeB.load()
        XCTAssertEqual(recordsB, ["avd-a": record()])

        storeA.save([:])
        XCTAssertNil(storeA.load()["avd-a"], "A's own delete took effect")

        // B saves something of its own, still unaware A's key is gone.
        recordsB["serial-b"] = record()
        storeB.save(recordsB)

        XCTAssertNil(storeA.load()["avd-a"], "B's save must not resurrect A's own delete")
        XCTAssertEqual(storeB.load()["serial-b"], record(), "B's own key is still there")
    }

    /// An update in store A survives store B's save: B's local `records`
    /// still carries A's key at the value B last loaded, so B's save must
    /// leave it alone rather than overwrite A's fresher value.
    func testAnUpdateInOneStoreSurvivesAnotherStoresSave() {
        let defaults = UserDefaults.scratch()
        let storeA = StatusBarDemoRecordStore(defaults: defaults)
        let storeB = StatusBarDemoRecordStore(defaults: defaults)

        storeA.save(["avd-a": record()])
        var recordsB = storeB.load()
        XCTAssertEqual(recordsB["avd-a"], record())

        // A updates its own key after B loaded.
        var updated = record()
        updated.demoModeEnded = true
        storeA.save(["avd-a": updated])

        // B saves an unrelated addition, unaware of A's update — its local
        // copy of A's key is the stale one from its own load.
        recordsB["serial-b"] = record()
        storeB.save(recordsB)

        XCTAssertEqual(storeA.load()["avd-a"], updated, "B's save must not overwrite A's own update")
        XCTAssertEqual(storeB.load()["serial-b"], record())
    }

    /// Baseline: a single store's own delete and update both take effect —
    /// the fix must not weaken ordinary single-window behavior.
    func testASingleStoresOwnDeleteAndUpdateStillTakeEffect() {
        let defaults = UserDefaults.scratch()
        let store = StatusBarDemoRecordStore(defaults: defaults)

        store.save(["avd-a": record(), "serial-b": record()])
        XCTAssertEqual(store.load().keys.sorted(), ["avd-a", "serial-b"])

        var updated = record()
        updated.demoModeEnded = true
        store.save(["avd-a": updated])
        let after = store.load()
        XCTAssertEqual(after, ["avd-a": updated], "the store's own removal and update both landed")
    }
}
