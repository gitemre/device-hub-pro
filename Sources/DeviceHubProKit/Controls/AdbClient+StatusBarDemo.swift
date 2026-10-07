import Foundation

/// The Status bar rows' commands (SystemUI demo mode, `StatusBarDemo`). Every
/// write is read back before it returns: `am broadcast` answers `result=0` for
/// a command SystemUI ignored, and SystemUI takes the command after that
/// answer, so each write probes (`statusBarDemo(serial:)`) until SystemUI
/// reports it or the settle budget runs out, and throws `StatusBarDemoError`
/// then. Where SystemUI reports nothing (API 30 and older, a SystemUI without
/// the dumpable) one probe is taken and trusted.
///
/// `expectsController`: SystemUI reported `DemoModeController` earlier (the
/// caller knows; API 31+), so a probe without that section means it did not
/// answer: the probe is taken again within the settle budget, never read as
/// "nothing to check", and `systemUINotAnswering` is thrown when it stays
/// silent.
extension AdbClient {
    /// The rows' readings in one round trip.
    public func statusBarDemo(serial: String) async throws -> StatusBarDemoSnapshot {
        let output = try await shell(serial: serial, [StatusBarDemoSnapshot.probeScript])
        let snapshot = StatusBarDemoSnapshot.parse(output)
        guard snapshot.apiLevel != nil else {
            throw AdbError.commandFailed(
                arguments: ["-s", serial, "shell", "getprop", "ro.build.version.sdk"],
                exitCode: 0,
                message: "unreadable API level"
            )
        }
        return snapshot
    }

    /// A probe a write can act on: with `expectsController`, taken again
    /// until SystemUI's `DemoModeController` section is there.
    public func statusBarDemo(
        serial: String,
        expectsController: Bool,
        settle: StatusBarDemoSettle = .standard
    ) async throws -> StatusBarDemoSnapshot {
        let (snapshot, answered) = try await pollStatusBarDemo(
            serial: serial,
            settle: settle,
            expectsController: expectsController
        ) { _ in true }
        guard answered else { throw StatusBarDemoError.systemUINotAnswering }
        return snapshot
    }

    /// `settings put global sysui_demo_allowed 1`, then waits until SystemUI
    /// reports the gate open (the key itself where it reports nothing). A
    /// failing `settings` tool (exit 255, reason on stderr) is
    /// `settingRefused` with the reason's exception line; adb's own failures
    /// are rethrown unchanged.
    @discardableResult
    public func allowStatusBarDemo(
        serial: String,
        expectsController: Bool = false,
        settle: StatusBarDemoSettle = .standard
    ) async throws -> StatusBarDemoSnapshot {
        do {
            _ = try await shell(serial: serial, ["settings", "put", "global", StatusBarDemo.allowedKey, "1"])
        } catch AdbError.commandFailed(_, let exitCode, let message) where exitCode == 255 {
            throw StatusBarDemoError.settingRefused(StatusBarDemoError.refusalReason(standardError: message))
        }
        let (snapshot, settled) = try await pollStatusBarDemo(
            serial: serial,
            settle: settle,
            expectsController: expectsController
        ) {
            $0.controller.map(\.isAllowed) ?? $0.isAllowedKey
        }
        guard settled else {
            throw snapshot.answers(expectingController: expectsController)
                ? StatusBarDemoError.notAllowed
                : StatusBarDemoError.systemUINotAnswering
        }
        return snapshot
    }

    /// `sysui_tuner_demo_on` = 1 and `commands` in one script
    /// (`StatusBarDemoScript.enter`); read back until SystemUI reports demo
    /// mode and, on API 33+, the battery of the last battery command. The
    /// gate must be open (`allowStatusBarDemo`).
    @discardableResult
    public func enterStatusBarDemo(
        serial: String,
        commands: [DemoCommand],
        expectsController: Bool = false,
        settle: StatusBarDemoSettle = .standard
    ) async throws -> StatusBarDemoSnapshot {
        _ = try await shell(serial: serial, [StatusBarDemoScript.enter(commands)])
        return try await readBackStatusBarDemo(
            serial: serial,
            commands: commands,
            expectsController: expectsController,
            settle: settle,
            notInDemo: .notEntered
        )
    }

    /// `commands` while SystemUI is in demo mode; read back like `enter`.
    @discardableResult
    public func sendStatusBarDemo(
        serial: String,
        commands: [DemoCommand],
        expectsController: Bool = false,
        settle: StatusBarDemoSettle = .standard
    ) async throws -> StatusBarDemoSnapshot {
        _ = try await shell(serial: serial, [StatusBarDemoScript.send(commands)])
        return try await readBackStatusBarDemo(
            serial: serial,
            commands: commands,
            expectsController: expectsController,
            settle: settle,
            notInDemo: .notInDemoMode
        )
    }

    /// Ends demo mode and puts `original`'s keys back, from a fresh probe
    /// (`StatusBarDemoScript.restore(for:original:realignBattery:)`). When
    /// the script's broadcasts need the gate and it is off
    /// (`StatusBarDemoScript.needsGate`), the gate is opened and confirmed
    /// first, so they are not ignored; the script is still built from the
    /// probe before that, so it carries the put, and it closes that gate
    /// again even where `original` found it on
    /// (`StatusBarDemoOriginal.closingTheGate(as:)`: someone closed it
    /// since). If that gate does not take, the keys are put back (best
    /// effort) before the error is rethrown.
    ///
    /// Reads back until SystemUI is out of demo mode and the keys read as the
    /// put-back writes them (`StatusBarDemoOriginal.keysAreBack`), tries once
    /// more from the last probe, and throws `notExited` (still in demo mode)
    /// or `keysNotRestored` after that.
    @discardableResult
    public func exitStatusBarDemo(
        serial: String,
        original: StatusBarDemoOriginal,
        realignBattery: Bool = false,
        expectsController: Bool = false,
        settle: StatusBarDemoSettle = .standard
    ) async throws -> StatusBarDemoSnapshot {
        var before = try await statusBarDemo(serial: serial, expectsController: expectsController, settle: settle)
        // The keys this put-back leaves: `original`'s, with a gate it opened
        // itself closed again (kept for the second try).
        var target = original
        for _ in 0..<2 {
            if !before.answers(expectingController: expectsController) {
                // Never the no-report script for a SystemUI that went silent.
                before = try await statusBarDemo(serial: serial, expectsController: expectsController, settle: settle)
            }
            if StatusBarDemoScript.needsGate(for: before, realignBattery: realignBattery) {
                target = target.closingTheGate(as: before)
                do {
                    try await allowStatusBarDemo(serial: serial, expectsController: expectsController, settle: settle)
                } catch {
                    // Best effort: the keys go back (the gate as found, or
                    // closed again); the caller's record keeps the put-back
                    // for later.
                    _ = try? await shell(serial: serial, [StatusBarDemoScript.restoreKeys(original: target)])
                    throw error
                }
            }
            _ = try await shell(
                serial: serial,
                [StatusBarDemoScript.restore(for: before, original: target, realignBattery: realignBattery)]
            )
            let (after, settled) = try await pollStatusBarDemo(
                serial: serial,
                settle: settle,
                expectsController: expectsController
            ) {
                !$0.isInDemoMode && target.keysAreBack(in: $0)
            }
            if settled { return after }
            before = after
        }
        guard before.answers(expectingController: expectsController) else {
            throw StatusBarDemoError.systemUINotAnswering
        }
        throw before.isInDemoMode ? StatusBarDemoError.notExited : StatusBarDemoError.keysNotRestored
    }

    // MARK: - Read-back

    private func readBackStatusBarDemo(
        serial: String,
        commands: [DemoCommand],
        expectsController: Bool,
        settle: StatusBarDemoSettle,
        notInDemo: StatusBarDemoError
    ) async throws -> StatusBarDemoSnapshot {
        let battery = commands.last { $0.expectedBattery != nil }
        func batteryApplied(_ snapshot: StatusBarDemoSnapshot) -> Bool {
            guard let battery, (snapshot.apiLevel ?? 0) >= StatusBarDemo.batteryReadbackMinimumAPI,
                  let shown = snapshot.systemUIBattery
            else { return true }
            return battery.batteryApplied(shown)
        }
        let (snapshot, settled) = try await pollStatusBarDemo(
            serial: serial,
            settle: settle,
            expectsController: expectsController
        ) { snapshot in
            // Nothing to check where SystemUI never reports (a silent
            // SystemUI that did report is not settled: `expectsController`).
            guard let controller = snapshot.controller else { return true }
            return controller.isInDemoMode && batteryApplied(snapshot)
        }
        guard !settled else { return snapshot }
        guard snapshot.answers(expectingController: expectsController) else {
            throw StatusBarDemoError.systemUINotAnswering
        }
        if snapshot.controller?.isInDemoMode == false { throw notInDemo }
        if let battery, let expected = battery.expectedBattery, let shown = snapshot.systemUIBattery {
            throw StatusBarDemoError.batteryNotApplied(shown: shown, expected: expected)
        }
        throw notInDemo
    }

    /// Probes until `done` holds on a probe that answers
    /// (`StatusBarDemoSnapshot.answers(expectingController:)`), within
    /// `settle` (attempts, and no probe started past its limit); returns the
    /// last snapshot and whether it held. A failing probe throws.
    private func pollStatusBarDemo(
        serial: String,
        settle: StatusBarDemoSettle,
        expectsController: Bool,
        until done: (StatusBarDemoSnapshot) -> Bool
    ) async throws -> (StatusBarDemoSnapshot, Bool) {
        let clock = ContinuousClock()
        let deadline = settle.limit.map { clock.now.advanced(by: $0) }
        let attempts = max(settle.attempts, 1)
        func holds(_ snapshot: StatusBarDemoSnapshot) -> Bool {
            snapshot.answers(expectingController: expectsController) && done(snapshot)
        }
        var last = try await statusBarDemo(serial: serial)
        var index = 1
        while !holds(last) {
            guard index < attempts else { return (last, false) }
            if settle.delay > .zero {
                try await Task.sleep(for: settle.delay)
            }
            if let deadline, clock.now >= deadline { return (last, false) }
            last = try await statusBarDemo(serial: serial)
            index += 1
        }
        return (last, true)
    }
}
