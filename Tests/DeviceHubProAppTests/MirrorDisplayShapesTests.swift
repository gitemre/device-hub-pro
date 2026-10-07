import Observation
import XCTest
@testable import DeviceHubProKit
@testable import DeviceHubProApp

/// The device's display shapes on their way to the stage: read once per
/// mirror session (`MirrorViewState.loadDisplayShapes`), remembered for the
/// emulator's AVD or the phone's model (`DisplayShapeLibrary`, on a
/// `DisplayShapeStore`), and served to the live stage before the read
/// answers and to the heroes of a stopped AVD; and a phone's display
/// rotation, which turns the cutout the vector body draws on its posed
/// frames (`MirrorViewState.loadDisplayRotation`). The shapes are the API 37
/// Pixel 9 Pro Fold emulator's real
/// `dumpsys display` capture (`DeviceHubProKitTests/Fixtures/api37-emulator/
/// adb-core/shell-dumpsys-display.txt`): inner panel 2076x2152 (radius 85),
/// cover 1080x2424 (radius 115).
@MainActor
final class MirrorDisplayShapesTests: XCTestCase {
    private static let serial = "emulator-5554"
    /// A made-up AVD name: the context reads the named AVD's config.ini.
    private static let avd = "MirrorDisplayShapesTests_Fold"
    private static let inner = CGSize(width: 2076, height: 2152)
    private static let cover = CGSize(width: 1080, height: 2424)

    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("DeviceHubProKitTests/Fixtures/api37-emulator/adb-core/shell-dumpsys-display.txt")

    private static func fixtureShapes() throws -> [DisplayShape] {
        let text = try String(contentsOf: fixture, encoding: .utf8)
        let shapes = DisplayShape.parse(dumpsysDisplay: text)
        XCTAssertEqual(shapes.count, 2, "the fold lists its two panels")
        return shapes
    }

    private func temporaryStore() throws -> DisplayShapeStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirrorDisplayShapesTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return DisplayShapeStore(directory: directory)
    }

    // MARK: - Reading once per session

    func testTwoViewsOfOneSessionReadOnce() async throws {
        let state = MirrorViewState()
        state.devicePixelSize = Self.inner
        let reader = ShapesReader(results: [try Self.fixtureShapes()])
        let read: @Sendable () async -> [DisplayShape] = { await reader.read() }

        let stage = Task { await state.loadDisplayShapes(reading: read) }
        let compact = Task { await state.loadDisplayShapes(reading: read) }
        try await waitFor { await reader.pending == 1 }
        await reader.releaseAll()
        await stage.value
        await compact.value

        let reads = await reader.reads
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(state.displayShapes.map(\.naturalSize), [Self.inner, Self.cover])
    }

    /// The first frame settling cancels the view's task; the read it started
    /// still lands, and the next request joins it.
    func testASupersededRequestLeavesItsReadToTheNextOne() async throws {
        let state = MirrorViewState()
        let reader = ShapesReader(results: [try Self.fixtureShapes()])
        let read: @Sendable () async -> [DisplayShape] = { await reader.read() }

        let first = Task { await state.loadDisplayShapes(reading: read) }
        try await waitFor { await reader.pending == 1 }
        first.cancel()
        state.devicePixelSize = Self.inner
        let second = Task { await state.loadDisplayShapes(reading: read) }
        await Task.yield()
        await reader.releaseAll()
        await first.value
        await second.value

        XCTAssertEqual(state.displayShapes.count, 2)
        let reads = await reader.reads
        XCTAssertEqual(reads, 1)
    }

    /// Folding switches the stream to the cover: the one read already lists
    /// it, so nothing is read again (the display metrics are, per screen).
    func testAFoldableSwitchingScreensDoesNotReadAgain() async throws {
        let state = MirrorViewState()
        state.devicePixelSize = Self.inner
        let reader = ShapesReader(results: [try Self.fixtureShapes()], gated: false)
        let read: @Sendable () async -> [DisplayShape] = { await reader.read() }
        await state.loadDisplayShapes(reading: read)

        state.devicePixelSize = Self.cover
        await state.loadDisplayShapes(reading: read)
        state.devicePixelSize = CGSize(width: 2152, height: 2076)
        await state.loadDisplayShapes(reading: read)

        let reads = await reader.reads
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(DisplayShape.matching(frame: Self.cover, in: state.displayShapes)?.maxCornerRadius, 115)
    }

    /// A frame no listed display fits (a resolution change) is read for
    /// again, once.
    func testAFrameNoDisplayFitsReadsAgainOnce() async throws {
        let state = MirrorViewState()
        state.devicePixelSize = Self.inner
        let shapes = try Self.fixtureShapes()
        let reader = ShapesReader(results: [shapes, shapes, shapes], gated: false)
        let read: @Sendable () async -> [DisplayShape] = { await reader.read() }
        await state.loadDisplayShapes(reading: read)

        state.devicePixelSize = CGSize(width: 1000, height: 1000)
        await state.loadDisplayShapes(reading: read)
        await state.loadDisplayShapes(reading: read)

        let reads = await reader.reads
        XCTAssertEqual(reads, 2, "the same answer would come back")
    }

    func testAFailedReadIsRetriedByTheNextRequest() async throws {
        let state = MirrorViewState()
        state.devicePixelSize = Self.inner
        let reader = ShapesReader(results: [[], try Self.fixtureShapes()], gated: false)
        let read: @Sendable () async -> [DisplayShape] = { await reader.read() }

        await state.loadDisplayShapes(reading: read)
        XCTAssertTrue(state.displayShapes.isEmpty)
        await state.loadDisplayShapes(reading: read)

        XCTAssertEqual(state.displayShapes.count, 2)
    }

    // MARK: - The controller: adb, the AVD, the store

    private func makeController(
        avdName: String?,
        store: DisplayShapeStore?
    ) throws -> (MirrorController, ActiveDeviceContext, StubAdb) {
        let adb = try makeStubAdb(arms: """
          "-s \(Self.serial) shell dumpsys display")
            cat '\(Self.fixture.path)' ;;
        """)
        let context = ActiveDeviceContext()
        context.serial = Self.serial
        context.avdName = avdName
        let mirror = MirrorController(
            adbClient: adb.client,
            context: context,
            status: StatusCenter(),
            perfLog: nil,
            displayShapes: DisplayShapeLibrary(store: store)
        )
        return (mirror, context, adb)
    }

    /// The session's `dumpsys display` fills the state and is remembered
    /// for the AVD, on disk: a later library over the same store (the next
    /// launch) finds it.
    func testAnEmulatorsShapesAreReadAndRememberedForItsAvd() async throws {
        let store = try temporaryStore()
        let (mirror, _, adb) = try makeController(avdName: Self.avd, store: store)
        mirror.mirrorViewState.devicePixelSize = Self.inner

        await mirror.loadDisplayShapes(for: mirror.mirrorViewState)

        XCTAssertEqual(adb.calls(containing: "dumpsys display").count, 1)
        XCTAssertEqual(mirror.mirrorViewState.displayShapes, try Self.fixtureShapes())
        XCTAssertEqual(mirror.displayShapes.shapes(forAvd: Self.avd), try Self.fixtureShapes())
        await waitUntil("the store holds the shapes") { !store.shapes(forAvd: Self.avd).isEmpty }
        XCTAssertEqual(DisplayShapeLibrary(store: store).shapes(forAvd: Self.avd), try Self.fixtureShapes())
    }

    /// The console names the AVD after the session starts: shapes read
    /// before are recorded once it does, through `AppModel`'s hub.
    func testShapesReadBeforeTheAvdIsKnownAreRecordedWhenItIs() async throws {
        let adb = try makeStubAdb(arms: """
          "-s \(Self.serial) shell dumpsys display")
            cat '\(Self.fixture.path)' ;;
        """)
        let model = AppModel.testing(adb: adb.client)
        model.context.serial = Self.serial
        let state = model.mirror.mirrorViewState
        state.devicePixelSize = Self.inner

        await model.mirror.loadDisplayShapes(for: state)
        XCTAssertEqual(state.displayShapes.count, 2)
        XCTAssertTrue(model.mirror.displayShapes.shapes(forAvd: Self.avd).isEmpty, "no AVD to record for yet")

        model.applyActiveAvdName(Self.avd, serial: Self.serial, generation: model.mirrorSessionGeneration)

        XCTAssertEqual(model.mirror.displayShapes.shapes(forAvd: Self.avd), try Self.fixtureShapes())
    }

    /// A phone whose model the device list does not name has no name to
    /// keep its shapes under: they serve its session only. Nothing is
    /// written under any name (the writes are waited for: they run off the
    /// main thread), and the library holds nothing for the serial.
    func testAPhoneOfAnUnknownModelRemembersNothing() async throws {
        let store = try temporaryStore()
        let (mirror, _, _) = try makePhysicalController(model: nil, store: store)
        mirror.mirrorViewState.devicePixelSize = Self.inner

        await mirror.loadDisplayShapes(for: mirror.mirrorViewState)
        await mirror.displayShapes.waitForPendingWrites()

        XCTAssertEqual(mirror.liveDisplayShapes.count, 2)
        // The directory is only ever created by a record.
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        XCTAssertTrue(mirror.displayShapes.shapes(forAvd: Self.phoneSerial).isEmpty)
    }

    // MARK: - Phones: per model

    /// Stands in for a phone's adb serial: a placeholder, no device's.
    private static let phoneSerial = "0A1B2C3D4E5F"
    /// Stands in for `adb devices -l`'s `model:` of the phone.
    private static let phoneModel = "MirrorDisplayShapesTests_Model"

    /// A controller mirroring a phone (`FakePhysicalSession`) whose model
    /// the device list names as `model`, with a stub adb answering its
    /// `dumpsys display` with the fixture.
    private func makePhysicalController(
        model: String?,
        store: DisplayShapeStore?,
        serial: String = MirrorDisplayShapesTests.phoneSerial
    ) throws -> (MirrorController, ActiveDeviceContext, StubAdb) {
        let adb = try makeStubAdb(arms: """
          "-s \(serial) shell dumpsys display")
            cat '\(Self.fixture.path)' ;;
        """)
        let context = ActiveDeviceContext()
        context.serial = serial
        let mirror = MirrorController(
            adbClient: adb.client,
            context: context,
            status: StatusCenter(),
            perfLog: nil,
            displayShapes: DisplayShapeLibrary(store: store)
        )
        mirror.session = FakePhysicalSession(serial: serial)
        mirror.physicalModel = { asked in asked == serial ? model : nil }
        return (mirror, context, adb)
    }

    /// A phone's shapes are remembered for its model, on disk: its next
    /// session (a later library over the same store) finds them, under the
    /// model and not under any AVD name.
    func testAPhysicalSessionsShapesAreRememberedForItsModel() async throws {
        let store = try temporaryStore()
        let (mirror, _, adb) = try makePhysicalController(model: Self.phoneModel, store: store)
        mirror.mirrorViewState.devicePixelSize = Self.inner

        await mirror.loadDisplayShapes(for: mirror.mirrorViewState)

        XCTAssertEqual(adb.calls(containing: "dumpsys display").count, 1)
        let shapes = try Self.fixtureShapes()
        XCTAssertEqual(mirror.displayShapes.shapes(forPhysicalModel: Self.phoneModel), shapes)
        await mirror.displayShapes.waitForPendingWrites()
        XCTAssertEqual(store.shapes(forPhysicalModel: Self.phoneModel), shapes)
        XCTAssertEqual(DisplayShapeLibrary(store: store).shapes(forPhysicalModel: Self.phoneModel), shapes)
        XCTAssertTrue(store.shapes(forAvd: Self.phoneModel).isEmpty, "a model is not an AVD")
    }

    /// Until the phone's own read answers, the stage draws with what a phone
    /// of its model last reported; then with the read.
    func testTheLiveStageUsesThePhoneModelsStoredShapesUntilTheReadAnswers() async throws {
        let store = try temporaryStore()
        let stored = try Self.fixtureShapes()
        try store.record(stored, forPhysicalModel: Self.phoneModel)
        let (mirror, _, _) = try makePhysicalController(model: Self.phoneModel, store: store)

        XCTAssertEqual(mirror.liveDisplayShapes, stored, "before the read")

        var edited = stored
        edited[0].topLeft = DisplayShape.RoundedCorner(radius: 90, centerX: 90, centerY: 90)
        mirror.mirrorViewState.devicePixelSize = Self.inner
        let read = edited
        await mirror.mirrorViewState.loadDisplayShapes { read }

        XCTAssertEqual(mirror.liveDisplayShapes, edited, "the session's read wins")
    }

    /// An emulator forced through the physical transport
    /// (`DHP_FORCE_PHYSICAL`, the live stand-in for a phone) records
    /// its shapes under its AVD and its model, as the live check expects,
    /// but never draws with the model's: every AVD on its system image
    /// shares that model name, and the entry can hold another AVD's panels.
    /// Before its own read it has only its AVD's stored shapes, here none.
    func testAForcedEmulatorRecordsUnderItsModelButDrawsWithItsAvdsShapesOnly() async throws {
        let store = try temporaryStore()
        let foreign = try Self.fixtureShapes()
        try store.record(foreign, forPhysicalModel: Self.phoneModel)
        let (mirror, context, _) = try makePhysicalController(
            model: Self.phoneModel,
            store: store,
            serial: Self.serial
        )
        XCTAssertTrue(mirror.liveDisplayShapes.isEmpty, "not the model's, before the AVD is named")
        context.avdName = Self.avd
        XCTAssertTrue(mirror.liveDisplayShapes.isEmpty, "not the model's, with the AVD named and nothing stored")

        mirror.mirrorViewState.devicePixelSize = Self.inner
        await mirror.loadDisplayShapes(for: mirror.mirrorViewState)
        await mirror.displayShapes.waitForPendingWrites()
        XCTAssertEqual(store.shapes(forAvd: Self.avd), foreign)
        XCTAssertEqual(store.shapes(forPhysicalModel: Self.phoneModel), foreign, "recorded for the live check")
    }

    /// An emulator's session is not a phone's: its shapes are its AVD's
    /// only, even when the device list names a model for its serial.
    func testAnEmulatorSessionRecordsNoModel() async throws {
        let store = try temporaryStore()
        let (mirror, _, _) = try makeController(avdName: Self.avd, store: store)
        mirror.session = FakeMirrorSession()
        mirror.physicalModel = { _ in Self.phoneModel }
        mirror.mirrorViewState.devicePixelSize = Self.inner

        await mirror.loadDisplayShapes(for: mirror.mirrorViewState)
        await mirror.displayShapes.waitForPendingWrites()

        XCTAssertEqual(store.shapes(forAvd: Self.avd), try Self.fixtureShapes())
        XCTAssertTrue(store.shapes(forPhysicalModel: Self.phoneModel).isEmpty)
    }

    /// The model reads a phone's model from its device list (`adb devices
    /// -l`'s `model:`), the name the gallery's illustrations will look the
    /// shapes up by.
    func testTheModelNamesAPhonesModelFromItsDeviceList() {
        let model = AppModel.testing()
        model.inventory.devices = [AndroidDevice.online(Self.phoneSerial, model: Self.phoneModel)]
        XCTAssertEqual(model.mirror.physicalModel(Self.phoneSerial), Self.phoneModel)
        XCTAssertNil(model.mirror.physicalModel("emulator-5554"), "not in the list")
    }

    func testTheLibraryKeepsModelsApartFromAvds() throws {
        let library = DisplayShapeLibrary(store: nil)
        library.record(try Self.fixtureShapes(), forPhysicalModel: "Shared")
        XCTAssertEqual(library.shapes(forPhysicalModel: "Shared").count, 2)
        XCTAssertTrue(library.shapes(forAvd: "Shared").isEmpty)
        library.record([], forPhysicalModel: "Shared")
        XCTAssertEqual(library.shapes(forPhysicalModel: "Shared").count, 2, "an empty read keeps what was known")
        library.record(try Self.fixtureShapes(), forPhysicalModel: "")
        XCTAssertTrue(library.shapes(forPhysicalModel: "").isEmpty, "an empty model names no phone")
    }

    // MARK: - The display rotation

    /// Only a phone's posed frames need the display rotation: an emulator
    /// session never reads it; a phone's reads it once its frame settles
    /// (the fixture's `mCurrentOrientation=0`).
    func testTheDisplayRotationIsReadForPhysicalSessionsOnly() async throws {
        let (emulator, _, emulatorAdb) = try makeController(avdName: Self.avd, store: nil)
        emulator.session = FakeMirrorSession()
        emulator.mirrorViewState.devicePixelSize = Self.inner
        await emulator.loadDisplayRotation(for: emulator.mirrorViewState)
        XCTAssertTrue(emulatorAdb.calls(containing: "dumpsys").isEmpty)
        XCTAssertNil(emulator.mirrorViewState.displayRotation)

        let (phone, _, phoneAdb) = try makePhysicalController(model: Self.phoneModel, store: nil)
        await phone.loadDisplayRotation(for: phone.mirrorViewState)
        XCTAssertTrue(phoneAdb.calls(containing: "dumpsys").isEmpty, "no frame has settled yet")
        phone.mirrorViewState.devicePixelSize = Self.inner
        await phone.loadDisplayRotation(for: phone.mirrorViewState)
        XCTAssertEqual(phoneAdb.calls(containing: "dumpsys display").count, 1)
        XCTAssertEqual(phone.mirrorViewState.displayRotation, 0)

        // A stale state (the user moved on) reads nothing.
        await phone.loadDisplayRotation(for: MirrorViewState())
        XCTAssertEqual(phoneAdb.calls(containing: "dumpsys display").count, 1)
    }

    /// The rotation is read again only when the frame turns between
    /// portrait and landscape: another frame of the same orientation (a
    /// resolution change) keeps it.
    func testTheDisplayRotationIsReadAgainOnlyWhenTheFrameTurns() async throws {
        let (phone, _, adb) = try makePhysicalController(model: Self.phoneModel, store: nil)
        let state = phone.mirrorViewState
        func reads() -> Int { adb.calls(containing: "dumpsys display").count }

        state.devicePixelSize = Self.cover
        await phone.loadDisplayRotation(for: state)
        XCTAssertEqual(reads(), 1)
        await phone.loadDisplayRotation(for: state)
        state.devicePixelSize = CGSize(width: 720, height: 1616)
        await phone.loadDisplayRotation(for: state)
        XCTAssertEqual(reads(), 1, "still portrait")

        state.devicePixelSize = CGSize(width: Self.cover.height, height: Self.cover.width)
        await phone.loadDisplayRotation(for: state)
        XCTAssertEqual(reads(), 2, "turned to landscape")
        await phone.loadDisplayRotation(for: state)
        XCTAssertEqual(reads(), 2)

        state.devicePixelSize = Self.cover
        await phone.loadDisplayRotation(for: state)
        XCTAssertEqual(reads(), 3, "back to portrait")
    }

    /// A failed read leaves the rotation unknown and the next request reads
    /// again; two views of one session then read once, and the answer is
    /// kept as a quarter turn.
    func testTheRotationReadIsRetriedJoinedAndNormalized() async throws {
        let state = MirrorViewState()
        state.devicePixelSize = Self.inner
        let failing = RotationReader(results: [nil], gated: false)
        await state.loadDisplayRotation { await failing.read() }
        XCTAssertNil(state.displayRotation, "a failed read")

        let reader = RotationReader(results: [5])
        let stage = Task { await state.loadDisplayRotation { await reader.read() } }
        try await waitFor { await reader.pending == 1 }
        let compact = Task { await state.loadDisplayRotation { await reader.read() } }
        await Task.yield()
        await reader.releaseAll()
        await stage.value
        await compact.value

        let reads = await reader.reads
        XCTAssertEqual(reads, 1, "the compact window joined the stage's read")
        XCTAssertEqual(state.displayRotation, 1, "5 quarter turns is ROTATION_90")
    }

    /// A phone turned straight from landscape to reverse landscape keeps its
    /// frame's size (scrcpy does not re-frame), so a plain request keeps
    /// ROTATION_90, and so does a refresh while the last read is fresh (a
    /// second view's watch); a refresh once the read is old enough asks
    /// again and finds ROTATION_270. Finding the same turn again changes
    /// nothing a view tracks, so the watch does not redraw the stage.
    func testARefreshFindsATurnThatKeepsTheFramesSize() async throws {
        let state = MirrorViewState()
        state.devicePixelSize = CGSize(width: Self.cover.height, height: Self.cover.width)
        let reader = RotationReader(results: [1, 3, 3], gated: false)
        let read: @Sendable () async -> Int? = { await reader.read() }
        await state.loadDisplayRotation(reading: read)
        XCTAssertEqual(state.displayRotation, 1)

        await state.loadDisplayRotation(reading: read)
        await state.loadDisplayRotation(refreshingAfter: .seconds(3600), reading: read)
        var reads = await reader.reads
        XCTAssertEqual(reads, 1, "a plain request and a fresh read's refresh read nothing")
        XCTAssertEqual(state.displayRotation, 1)

        await state.loadDisplayRotation(refreshingAfter: .zero, reading: read)
        reads = await reader.reads
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(state.displayRotation, 3, "the refresh finds the turn")

        let changed = Flag()
        withObservationTracking {
            _ = state.displayRotation
        } onChange: {
            changed.set()
        }
        await state.loadDisplayRotation(refreshingAfter: .zero, reading: read)
        reads = await reader.reads
        XCTAssertEqual(reads, 3)
        XCTAssertFalse(changed.isSet, "the same turn again")
    }

    /// The vector body's watch on a phone: after the first read, the
    /// rotation is read again at every interval while the frame shows a
    /// panel with a cutout (the fold's cover), and never while it shows none
    /// (a frame no panel fits, generated input); cancelling the watch ends the reads. The
    /// stub answers every read with the fixture (`mCurrentOrientation=0`):
    /// the test counts reads, and `testARefreshFindsATurnThatKeepsTheFramesSize`
    /// what a read that finds a turn does.
    func testThePhonesWatchRereadsTheRotationWhileItsPanelHasACutout() async throws {
        let (phone, _, adb) = try makePhysicalController(model: Self.phoneModel, store: nil)
        phone.displayRotationRefreshInterval = .milliseconds(20)
        let state = phone.mirrorViewState
        func reads() -> Int { adb.calls(containing: "dumpsys display").count }
        let shapes = try Self.fixtureShapes()
        await state.loadDisplayShapes { shapes }

        // No panel has a 1:3 screen: nothing for the rotation to turn.
        state.devicePixelSize = CGSize(width: 1000, height: 3000)
        let watch = Task { await phone.watchDisplayRotation(for: state) }
        try await waitFor { reads() == 1 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(reads(), 1, "ten intervals without a cutout to turn")

        // The frame shows the cover, which reports its hole: read again at
        // every interval (the watch outlives the frame change).
        state.devicePixelSize = Self.cover
        try await waitFor { reads() >= 4 }

        watch.cancel()
        await watch.value
        let stopped = reads()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reads(), stopped, "no read after the watch ends")
        XCTAssertEqual(state.displayRotation, 0)
    }

    /// The watch ends by itself when its session does, and never starts for
    /// an emulator, whose frames carry their rotation.
    func testTheWatchIsAPhoneSessionsOnly() async throws {
        let (emulator, _, emulatorAdb) = try makeController(avdName: Self.avd, store: nil)
        emulator.session = FakeMirrorSession()
        emulator.displayRotationRefreshInterval = .milliseconds(20)
        emulator.mirrorViewState.devicePixelSize = Self.cover
        await emulator.watchDisplayRotation(for: emulator.mirrorViewState)
        XCTAssertTrue(emulatorAdb.calls(containing: "dumpsys").isEmpty)

        let (phone, _, _) = try makePhysicalController(model: Self.phoneModel, store: nil)
        phone.displayRotationRefreshInterval = .milliseconds(20)
        phone.mirrorViewState.devicePixelSize = Self.cover
        let watch = Task { await phone.watchDisplayRotation(for: phone.mirrorViewState) }
        try await waitFor { phone.mirrorViewState.displayRotation == 0 }
        phone.session = FakeMirrorSession()
        let ended = Flag()
        Task {
            await watch.value
            ended.set()
        }
        try await waitFor { ended.isSet }
    }

    /// The vector body's `.task(id:)` starts the watch once per landscape ⟷
    /// portrait flip of the settled frame (`VectorDeviceView.RotationWatch`):
    /// a phone the mirror finds already turned never flips again for the
    /// rest of that session, so this one call is its only watch. If
    /// `context.serial` is still catching up from `beginMirrorSession` at
    /// that moment (set fractionally after the session and its state are),
    /// the watch must wait for it rather than give up for good — nothing
    /// else calls it again until the device actually turns, which this
    /// session never does. T2-CUTOUT, Tier 2 live check 6.
    func testAPhoneFoundAlreadyTurnedStillGetsItsRotationEvenIfTheSerialArrivesLate() async throws {
        let (phone, context, adb) = try makePhysicalController(model: Self.phoneModel, store: nil)
        context.serial = nil
        phone.displayRotationRefreshInterval = .milliseconds(20)
        let state = phone.mirrorViewState
        // Landscape from the very first frame: no later flip will start the
        // watch again.
        state.devicePixelSize = CGSize(width: Self.cover.height, height: Self.cover.width)

        let watch = Task { await phone.watchDisplayRotation(for: state) }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(state.displayRotation, "the serial is not known yet")
        XCTAssertTrue(adb.calls(containing: "dumpsys display").isEmpty, "nothing to read without a serial")

        context.serial = Self.phoneSerial
        try await waitFor { state.displayRotation != nil }
        XCTAssertEqual(state.displayRotation, 0, "the fixture's mCurrentOrientation")

        watch.cancel()
        await watch.value
    }

    /// Until the session's own read answers, the stage draws with what the
    /// AVD last reported; then with the read.
    func testTheLiveStageUsesTheAvdsStoredShapesUntilTheReadAnswers() async throws {
        let store = try temporaryStore()
        let stored = try Self.fixtureShapes()
        try store.record(stored, forAvd: Self.avd)
        let (mirror, _, _) = try makeController(avdName: Self.avd, store: store)

        XCTAssertEqual(mirror.liveDisplayShapes, stored, "before the read")

        var edited = stored
        edited[0].topLeft = DisplayShape.RoundedCorner(radius: 90, centerX: 90, centerY: 90)
        let reader = ShapesReader(results: [edited], gated: false)
        mirror.mirrorViewState.devicePixelSize = Self.inner
        await mirror.mirrorViewState.loadDisplayShapes { await reader.read() }

        XCTAssertEqual(mirror.liveDisplayShapes, edited, "the session's read wins")
    }

    /// A read for another session's state (the user moved on) lands nowhere.
    func testAStaleStateReadsNothing() async throws {
        let (mirror, _, adb) = try makeController(avdName: Self.avd, store: nil)
        let stale = MirrorViewState()

        await mirror.loadDisplayShapes(for: stale)

        XCTAssertTrue(stale.displayShapes.isEmpty)
        XCTAssertTrue(adb.calls(containing: "dumpsys").isEmpty)
    }

    // MARK: - The library

    func testTheLibraryKeepsShapesInMemoryWithoutAStore() throws {
        let library = DisplayShapeLibrary(store: nil)
        XCTAssertTrue(library.shapes(forAvd: Self.avd).isEmpty)
        library.record(try Self.fixtureShapes(), forAvd: Self.avd)
        XCTAssertEqual(library.shapes(forAvd: Self.avd).count, 2)
        XCTAssertTrue(library.shapes(forAvd: "Other").isEmpty)
    }

    /// An empty list is a failed read: it keeps what was known.
    func testAnEmptyRecordKeepsTheKnownShapes() throws {
        let library = DisplayShapeLibrary(store: nil)
        library.record(try Self.fixtureShapes(), forAvd: Self.avd)
        library.record([], forAvd: Self.avd)
        XCTAssertEqual(library.shapes(forAvd: Self.avd).count, 2)
    }

    /// A deleted AVD's shapes go, in memory and on disk: an AVD created
    /// later under its name starts from the skin, not the old device.
    func testADeletedAvdsShapesAreForgotten() async throws {
        let store = try temporaryStore()
        let library = DisplayShapeLibrary(store: store)
        library.record(try Self.fixtureShapes(), forAvd: Self.avd)

        library.forget(avdName: Self.avd)

        XCTAssertTrue(library.shapes(forAvd: Self.avd).isEmpty)
        await library.waitForPendingWrites()
        XCTAssertTrue(store.shapes(forAvd: Self.avd).isEmpty, "the record's write did not outlive the delete")
        XCTAssertTrue(DisplayShapeLibrary(store: store).shapes(forAvd: Self.avd).isEmpty)
    }

    /// A renamed AVD takes its shapes along; the old name keeps none, and
    /// what the new name held (a deleted AVD's) goes.
    func testARenamedAvdsShapesFollowIt() async throws {
        let store = try temporaryStore()
        let shapes = try Self.fixtureShapes()
        var other = shapes
        other[0].topLeft = DisplayShape.RoundedCorner(radius: 40, centerX: 40, centerY: 40)
        try store.record(other, forAvd: "Renamed_Fold")
        let library = DisplayShapeLibrary(store: store)
        library.record(shapes, forAvd: Self.avd)

        library.move(fromAvd: Self.avd, toAvd: "Renamed_Fold")

        XCTAssertEqual(library.shapes(forAvd: "Renamed_Fold"), shapes)
        XCTAssertTrue(library.shapes(forAvd: Self.avd).isEmpty)
        await library.waitForPendingWrites()
        XCTAssertEqual(store.shapes(forAvd: "Renamed_Fold"), shapes)
        XCTAssertTrue(store.shapes(forAvd: Self.avd).isEmpty)
    }

    /// The gallery's delete and rename reach the library the stage reads.
    func testTheCatalogSharesTheMirrorsLibrary() {
        let model = AppModel.testing()
        XCTAssertTrue(model.catalog.displayShapes === model.mirror.displayShapes)
    }

    /// The library is the app's: two mirrors over one
    /// library agree, so a shape one window's session recorded draws the
    /// hero in another window.
    func testTwoMirrorsOverOneLibraryAgree() throws {
        let library = DisplayShapeLibrary(store: nil)
        let status = StatusCenter()
        let first = MirrorController(adbClient: nil, context: ActiveDeviceContext(), status: status, perfLog: nil, displayShapes: library)
        let second = MirrorController(adbClient: nil, context: ActiveDeviceContext(), status: status, perfLog: nil, displayShapes: library)
        let shapes = try Self.fixtureShapes()

        first.displayShapes.record(shapes, forAvd: Self.avd)

        XCTAssertEqual(second.displayShapes.shapes(forAvd: Self.avd), shapes)
        let model = AppModel.testing()
        XCTAssertTrue(model.mirror.displayShapes === model.displayShapes)
    }

    // MARK: - Helpers

    private func waitFor(timeout: TimeInterval = 5, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition not met within \(timeout) s")
    }
}

/// A `dumpsys display` read the test answers: each call takes the next
/// result; gated calls wait until `releaseAll`.
private actor ShapesReader {
    private var results: [[DisplayShape]]
    private let gated: Bool
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var reads = 0

    init(results: [[DisplayShape]], gated: Bool = true) {
        self.results = results
        self.gated = gated
    }

    var pending: Int { waiting.count }

    func read() async -> [DisplayShape] {
        reads += 1
        let result = results.isEmpty ? [] : results.removeFirst()
        if gated {
            await withCheckedContinuation { waiting.append($0) }
        }
        return result
    }

    func releaseAll() {
        let released = waiting
        waiting = []
        released.forEach { $0.resume() }
    }
}

/// A display-rotation read the test answers, like `ShapesReader`: each call
/// takes the next result (nil is a failed read); gated calls wait until
/// `releaseAll`.
private actor RotationReader {
    private var results: [Int?]
    private let gated: Bool
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var reads = 0

    init(results: [Int?], gated: Bool = true) {
        self.results = results
        self.gated = gated
    }

    var pending: Int { waiting.count }

    func read() async -> Int? {
        reads += 1
        let result = results.isEmpty ? nil : results.removeFirst()
        if gated {
            await withCheckedContinuation { waiting.append($0) }
        }
        return result
    }

    func releaseAll() {
        let released = waiting
        waiting = []
        released.forEach { $0.resume() }
    }
}

/// Set once by an observation's `onChange` or a task, from anywhere.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    var isSet: Bool { lock.withLock { fired } }

    func set() {
        lock.withLock { fired = true }
    }
}
