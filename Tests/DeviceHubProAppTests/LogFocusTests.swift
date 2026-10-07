import AppKit
import SwiftUI
import XCTest
@testable import DeviceHubProApp
import DeviceHubProKit

/// Log focus mode: the window layout it takes and gives back, the follow
/// state, the model's filters and selection, the log source seam and the
/// row geometry; and a render of the pane into PNGs for a look.
@MainActor
final class LogFocusTests: XCTestCase {
    private func entry(
        _ id: UInt64, level: LogcatLevel = .info, tag: String = "App", message: String = "hello",
        subsystem: String = ""
    ) -> LogcatEntry {
        LogcatEntry(
            id: id, timestamp: "10-01 12:34:56.\(String(format: "%03d", Int(id % 1000)))", pid: 4242, tid: 4243,
            level: level, tag: tag, message: message, subsystem: subsystem
        )
    }

    // MARK: - Layout

    func testEnteringHidesSidebarAndInspectorAndExitingRestoresThemExactly() {
        let window = WindowState()
        window.columnVisibility = .all
        window.showInspector = true
        window.inspectorTab = .controls
        var opens = 0
        window.openDiagnosticsLogcat = { opens += 1 }

        window.enterLogFocus()
        XCTAssertTrue(window.isLogFocus)
        XCTAssertEqual(window.columnVisibility, .detailOnly)
        XCTAssertFalse(window.showInspector)
        XCTAssertEqual(opens, 1, "entering opens the device's log")

        window.exitLogFocus()
        XCTAssertFalse(window.isLogFocus)
        XCTAssertEqual(window.columnVisibility, .all)
        XCTAssertTrue(window.showInspector)
    }

    func testExitingRestoresAHiddenSidebarAndHiddenInspectorToo() {
        let window = WindowState()
        window.columnVisibility = .detailOnly
        window.showInspector = false
        window.toggleLogFocus()
        XCTAssertTrue(window.isLogFocus)
        window.toggleLogFocus()
        XCTAssertEqual(window.columnVisibility, .detailOnly)
        XCTAssertFalse(window.showInspector)
    }

    func testEnteringTwiceKeepsTheFirstLayoutAndExitingWithoutEnteringIsANoOp() {
        let window = WindowState()
        window.exitLogFocus()
        XCTAssertEqual(window.columnVisibility, .all)
        window.showInspector = true
        window.enterLogFocus()
        window.enterLogFocus()
        window.exitLogFocus()
        XCTAssertTrue(window.showInspector, "the second enter must not save the focus layout")
        XCTAssertEqual(window.columnVisibility, .all)
    }

    func testTheSidebarAndInspectorCommandsLeaveFocusInsteadOfFightingIt() {
        let window = WindowState()
        window.enterLogFocus()
        window.toggleSidebarColumn()
        XCTAssertFalse(window.isLogFocus)
        XCTAssertEqual(window.columnVisibility, .all)

        window.enterLogFocus()
        window.selectInspectorTab(.diagnostics)
        XCTAssertFalse(window.isLogFocus)
        XCTAssertTrue(window.showInspector)

        window.enterLogFocus()
        window.toggleInspector()
        XCTAssertFalse(window.isLogFocus)
        XCTAssertTrue(window.showInspector)
    }

    func testTheSplitWidthStaysInsideTheColumn() {
        typealias Split = LogFocusSplit<EmptyView, EmptyView>
        XCTAssertEqual(Split.clampedStageWidth(380, total: 1400), 380)
        XCTAssertEqual(Split.clampedStageWidth(100, total: 1400), Split.minStage)
        XCTAssertEqual(Split.clampedStageWidth(2000, total: 1000), 1000 - Split.minLog)
        XCTAssertEqual(Split.clampedStageWidth(380, total: 500), Split.minStage, "the stage keeps its minimum")
    }

    // MARK: - Source seam

    func testTheLogSourceFollowsTheSelection() {
        let ready: (String) -> Bool = { $0 == "SIM-READY" }
        XCTAssertEqual(
            LogSource.resolve(selection: .device("emulator-5554"), liveSerial: "emulator-5554", simulatorIsReady: ready),
            .adb(serial: "emulator-5554")
        )
        XCTAssertEqual(
            LogSource.resolve(selection: .simulator("SIM-READY"), liveSerial: nil, simulatorIsReady: ready),
            .simulator(udid: "SIM-READY")
        )
        XCTAssertEqual(
            LogSource.resolve(selection: .simulator("SIM-BOOTING"), liveSerial: nil, simulatorIsReady: ready), .none
        )
        let phone = LogSource.resolve(selection: .physicalApple("UDID"), liveSerial: nil, simulatorIsReady: ready)
        XCTAssertEqual(phone, .physicalApple(udid: "UDID"))
        XCTAssertTrue(phone.streams, "a physical iPhone streams the console of a launched app")
        XCTAssertTrue(LogSource.adb(serial: "x").streams)
        XCTAssertEqual(LogSource.resolve(selection: nil, liveSerial: nil, simulatorIsReady: ready), .none)
    }

    // MARK: - Follow

    func testFollowStopsWhenTheUserScrollsUpCountsNewLinesAndResumesAtTheBottom() {
        var follow = LogFollowState()
        XCTAssertTrue(follow.isFollowing)
        follow.entriesArrived(5)
        XCTAssertEqual(follow.unseenCount, 0, "following: nothing is unseen")

        follow.userScrolled(atBottom: false)
        XCTAssertFalse(follow.isFollowing)
        follow.entriesArrived(3)
        follow.entriesArrived(2)
        XCTAssertEqual(follow.unseenCount, 5)

        follow.userScrolled(atBottom: true)
        XCTAssertTrue(follow.isFollowing)
        XCTAssertEqual(follow.unseenCount, 0)

        follow.userScrolled(atBottom: false)
        follow.entriesArrived(4)
        follow.jumpToLatest()
        XCTAssertTrue(follow.isFollowing)
        XCTAssertEqual(follow.unseenCount, 0)
    }

    func testTheModelCountsUnseenLinesWhileScrolledUpAndJumpBumpsTheToken() {
        let model = LogFocusModel()
        model.ingest([entry(1), entry(2)])
        model.userScrolled(atBottom: false)
        model.ingest([entry(1), entry(2), entry(3), entry(4), entry(5)])
        XCTAssertEqual(model.follow.unseenCount, 3)
        let token = model.jumpToken
        model.jumpToLatest()
        XCTAssertTrue(model.follow.isFollowing)
        XCTAssertEqual(model.follow.unseenCount, 0)
        XCTAssertNotEqual(model.jumpToken, token)
    }

    // MARK: - Filters, selection

    func testLevelAndTextFiltersNarrowTheEntriesAndDropHiddenSelections() {
        let model = LogFocusModel()
        model.ingest([
            entry(1, level: .debug, message: "frame drawn"),
            entry(2, level: .warning, tag: "Net", message: "slow request to example.com"),
            entry(3, level: .error, tag: "Net", message: "timeout"),
            entry(4, level: .info, message: "button pressed"),
        ])
        XCTAssertEqual(model.entries.count, 4)
        model.selection = [1, 3]

        model.setFilter(level: .warning, search: "")
        XCTAssertEqual(model.entries.map(\.id), [2, 3])
        XCTAssertEqual(model.selection, [3], "a selected line the filter hides is dropped")

        model.setFilter(level: .debug, search: "BUTTON")
        XCTAssertEqual(model.entries.map(\.id), [4], "the search ignores case")

        model.setFilter(level: .debug, search: "net")
        XCTAssertEqual(model.entries.map(\.id), [2, 3], "the search matches the tag")
    }

    func testASimulatorSubsystemIsSearchedAndShownInTheDetail() {
        let model = LogFocusModel()
        let line = entry(7, tag: "SpringBoard", message: "launched", subsystem: "com.apple.UIKit")
        model.ingest([line])
        model.setFilter(level: .debug, search: "uikit")
        XCTAssertEqual(model.entries.count, 1)
        XCTAssertTrue(LogFocusModel.detailText(for: line).contains("com.apple.UIKit"))
        XCTAssertTrue(LogFocusModel.detailText(for: line).hasSuffix("\nlaunched"))
    }

    func testSelectedEntriesComeOldestFirstAndResetClearsEverything() {
        let model = LogFocusModel()
        model.ingest([entry(1), entry(2), entry(3)])
        model.selection = [3, 1]
        XCTAssertEqual(model.selectedEntries.map(\.id), [1, 3])
        model.reset()
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertTrue(model.follow.isFollowing)
    }

    func testTheRevisionOnlyMovesWhenWhatIsShownChanges() {
        let model = LogFocusModel()
        model.ingest([entry(1)])
        let revision = model.revision
        model.ingest([entry(1)])
        XCTAssertEqual(model.revision, revision, "the same snapshot again changes nothing")
        model.ingest([entry(1), entry(2)])
        XCTAssertNotEqual(model.revision, revision)
    }

    // MARK: - Row geometry

    func testWrappedLineCountBreaksByCharacterAndAtNewlines() {
        XCTAssertEqual(LogRowMetrics.wrappedLineCount(of: "", columns: 10), 1)
        XCTAssertEqual(LogRowMetrics.wrappedLineCount(of: String(repeating: "a", count: 10), columns: 10), 1)
        XCTAssertEqual(LogRowMetrics.wrappedLineCount(of: String(repeating: "a", count: 11), columns: 10), 2)
        XCTAssertEqual(LogRowMetrics.wrappedLineCount(of: "ab\ncd\n", columns: 10), 3)
        XCTAssertEqual(LogRowMetrics.wrappedLineCount(of: "x", columns: 0), 1)
    }

    // MARK: - Render

    /// Renders the focus layout (a stand-in phone, the log pane) at one
    /// appearance and wrap setting into `directory`, for a look.
    private func render(
        name: String, dark: Bool, wrap: Bool, selectRow: UInt64?, source: LogSource, into directory: URL
    ) async throws {
        let controller = LogcatController(adbClient: nil, status: StatusCenter(), picker: TestPicker())
        controller.logcatSerial = "emulator-5554"
        controller.logcatPackages = ["com.example.shop", "com.example.shop.debug", "com.example.mails"]
        controller.selectedLogcatPackage = "com.example.shop"
        controller.logcatStatusText = "com.example.shop"
        controller.logcatEntries = Self.sampleEntries()

        let focus = LogFocusModel()
        focus.wrap = wrap
        let tail = Self.sampleEntries()
        focus.ingest(tail)
        if let selectRow { focus.selection = [selectRow] }

        struct Host: View {
            let focus: LogFocusModel
            let controller: LogcatController
            let source: LogSource
            @FocusState var searchFocused: Bool
            var body: some View {
                HStack(spacing: 0) {
                    ZStack {
                        Color(nsColor: .textBackgroundColor)
                        RoundedRectangle(cornerRadius: 36, style: .continuous)
                            .fill(Color.primary.opacity(0.1))
                            .overlay(RoundedRectangle(cornerRadius: 36, style: .continuous).strokeBorder(Color.primary.opacity(0.35), lineWidth: 6))
                            .frame(width: 230, height: 480)
                    }
                    .frame(width: 380)
                    Divider()
                    LogFocusContent(focus: focus, logcat: controller, source: source, isSearchFocused: $searchFocused)
                }
            }
        }

        let size = CGSize(width: 1280, height: 640)
        let hosting = NSHostingView(rootView: Host(focus: focus, controller: controller, source: source))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderBack(nil)
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(60))
            hosting.layoutSubtreeIfNeeded()
        }
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
        window.orderOut(nil)
    }

    static func sampleEntries() -> [LogcatEntry] {
        let long = "okhttp3.internal.http2.StreamResetException: stream was reset: CANCEL at okhttp3.internal.http2.Http2Stream.checkOutNotClosed$okhttp(Http2Stream.kt:632) at okhttp3.internal.http2.Http2Stream\\$FramingSink.emitFrame(Http2Stream.kt:2) while requesting https://api.example.com/v2/cart/items?include=prices,promotions&locale=en-US"
        let rows: [(LogcatLevel, String, String)] = [
            (.debug, "ViewRootImpl", "ViewPostIme pointer 0"),
            (.info, "ShopApp", "Checkout button pressed, cart has 3 items"),
            (.debug, "CartRepository", "POST /v2/cart/checkout (body 212 bytes)"),
            (.warning, "OkHttp", "slow response: 1840 ms for POST https://api.example.com/v2/cart/checkout"),
            (.error, "CartRepository", long),
            (.info, "Choreographer", "Skipped 31 frames! The application may be doing too much work on its main thread."),
            (.verbose, "InputDispatcher", "channel 'a1b2c3 com.example.shop/.MainActivity' ~ Consumed move event"),
            (.fatal, "AndroidRuntime", "FATAL EXCEPTION: main"),
            (.error, "AndroidRuntime", "Process: com.example.shop, PID: 18342\njava.lang.IllegalStateException: Cart is empty\n\tat com.example.shop.CartViewModel.checkout(CartViewModel.kt:88)"),
        ]
        var result: [LogcatEntry] = []
        for index in 0..<60 {
            let row = rows[index % rows.count]
            result.append(LogcatEntry(
                id: UInt64(index + 1),
                timestamp: "10-01 12:34:\(String(format: "%02d", index / 3)).\(String(format: "%03d", (index * 137) % 1000))",
                pid: 18342, tid: 18342, level: row.0, tag: row.1, message: row.2
            ))
        }
        return result
    }

    /// Writes the PNGs the manual checks look at when
    /// `DHP_LOG_FOCUS_PNG_DIR` names a folder; always renders once, so a
    /// crash in the table or its cells fails the suite.
    func testRenderingThePane() async throws {
        let directory = ProcessInfo.processInfo.environment["DHP_LOG_FOCUS_PNG_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("log-focus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            if ProcessInfo.processInfo.environment["DHP_LOG_FOCUS_PNG_DIR"] == nil {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        try await render(name: "log-focus-light", dark: false, wrap: false, selectRow: 5, source: .adb(serial: "emulator-5554"), into: directory)
        try await render(name: "log-focus-dark-wrap", dark: true, wrap: true, selectRow: 9, source: .adb(serial: "emulator-5554"), into: directory)
        try await render(name: "log-focus-physical-iphone", dark: false, wrap: false, selectRow: nil, source: .physicalApple(udid: "X"), into: directory)
    }
}
