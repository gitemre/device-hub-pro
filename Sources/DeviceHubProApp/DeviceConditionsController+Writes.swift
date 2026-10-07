import Foundation
import DeviceHubProKit

/// The conditions writes. Each one holds the write fence, sends its
/// command, then reads the effect back (retrying while Android settles) and
/// reports what the device shows — a write the device did not take is an
/// error, never a silent success.
extension DeviceConditionsController {
    // MARK: - Data path

    /// Moves the traffic to mobile data (`svc wifi disable` + `svc data
    /// enable`), the only path the emulator shapes, remembering the radios
    /// for the AVD, for `resetNetworkConditions()` and `detach()`. Done when
    /// ConnectivityService's default network is the mobile one.
    func useMobileData() async {
        guard let adbClient, let serial = activeSerial, let snapshot = network else { return }
        let generation = currentGeneration
        beginWrite()
        defer { endWrite() }
        guard let instance = await identifyForWrite(serial: serial, generation: generation) else { return }
        rememberDataPath(SavedDataPath(wifiOn: snapshot.wifiOn, mobileData: snapshot.mobileData), avdName: instance.avdName)
        let progress = "Switching to mobile data…"
        status.showProgress(progress)
        // Only this write's own line: the outcome below replaces it, and
        // another operation's line is not this write's to clear.
        defer { status.clear(ifShowing: progress) }
        do {
            try await adbClient.setWifi(serial: serial, enabled: false)
            try await adbClient.setMobileData(serial: serial, enabled: true)
        } catch {
            if !error.isCancellation { errorMessage = "\(error)" }
            return
        }
        let settled = await settleNetwork(serial: serial, generation: generation, attempts: 40) {
            $0.connectivity.dataPath == .mobileData
        }
        guard isCurrent(serial: serial, generation: generation) else { return }
        if settled {
            flashStatus("Mobile data carries the traffic now")
        } else {
            errorMessage = "Mobile data did not become the active network within 20 s (\(network?.connectivity.dataPath?.label ?? "unknown")). Is airplane mode on?"
        }
    }

    // MARK: - Speed and latency

    /// The profile the rows show now: what the device reports, which falls
    /// back to the last request for rates no preset has.
    var currentShapingProfile: ShapingProfile {
        guard let reading = shaping else { return .neutral }
        let asked = activeSerial.flatMap { desiredShaping[$0] }
        return ShapingProfile(
            speed: reading.speed ?? asked?.speed ?? .full,
            latency: reading.latency,
            lossPercent: reading.lossPercent
        )
    }

    func setLatency(_ latency: ConnectionLatency) async {
        var profile = currentShapingProfile
        profile.latency = latency
        await applyShaping(profile)
    }

    func setSpeed(_ speed: NetworkSpeed) async {
        var profile = currentShapingProfile
        profile.speed = speed
        await applyShaping(profile)
    }

    /// Puts `profile` on the device with `tc netem` (`NetworkShaper`):
    /// roots adbd when it is not (`adb root` restarts it; Device Hub Pro unroots
    /// when conditions reset, unless the device was root already), applies,
    /// and shows what the device reports. `quiet` is the poll putting the
    /// shaping back on a moved data path.
    ///
    /// `expecting` names the device the profile was meant for (the poll's
    /// reapply): when another device is mirrored by the time this runs,
    /// nothing is applied, so A's profile never lands on B.
    func applyShaping(
        _ profile: ShapingProfile,
        quiet: Bool = false,
        expecting target: (serial: String, generation: UInt64)? = nil
    ) async {
        guard let adbClient, let serial = activeSerial else { return }
        let generation = currentGeneration
        if let target, target.serial != serial || target.generation != generation { return }
        let shaper = NetworkShaper(adb: adbClient)
        beginWrite()
        defer { endWrite() }
        guard let instance = await identifyForWrite(serial: serial, generation: generation) else { return }
        do {
            var restarted = false
            if !profile.isNeutral || shaping?.isShaping == true {
                // Recorded as soon as `adb root` was accepted, before the wait
                // for adbd: a wait that fails or is cut still leaves a root
                // Device Hub Pro gave, for the put-back to take away.
                let root = try await shaper.ensureRoot(serial: serial, willRestart: { [weak self] in
                    await self?.recordRootedByDeviceHubPro(true, serial: serial)
                })
                if root == .restartedAsRoot { restarted = true }
            }
            if !profile.isNeutral { markChanged(.shaping, serial: serial, instance: instance) }
            let readBack = try await shaper.apply(profile, serial: serial)
            if restarted { onAdbdRestarted?(serial) }
            guard isCurrent(serial: serial, generation: generation) else { return }
            shaping = readBack
            if profile.isNeutral {
                setDesiredShaping(nil, serial: serial)
                markRestored([.shaping], serial: serial)
                if rootedByDeviceHubPro.contains(serial) {
                    try await shaper.dropRoot(serial: serial)
                    recordRootedByDeviceHubPro(false, serial: serial)
                    onAdbdRestarted?(serial)
                }
            } else {
                setDesiredShaping(profile, serial: serial)
            }
            isEditingCustomLatency = false
            customLatencyError = nil
            guard !quiet else { return }
            if profile.isNeutral ? readBack.isShaping : !readBack.matches(profile) {
                errorMessage = "The device did not take the speed and latency: it reports \(readBack.netem.isEmpty ? "no shaping" : "other values")."
                return
            }
            flashStatus(Self.shapingMessage(profile))
        } catch {
            guard isCurrent(serial: serial, generation: generation) else { return }
            if !error.isCancellation { errorMessage = "\(error)" }
        }
    }

    nonisolated static func shapingMessage(_ profile: ShapingProfile) -> String {
        if profile.isNeutral { return "Speed and latency off" }
        var parts: [String] = []
        if profile.speed != .full { parts.append("speed \(profile.speed.name)") }
        if profile.latency.isActive { parts.append("latency \(profile.latency.rangeLabel)") }
        return "Set " + parts.joined(separator: ", ")
    }

    /// Validates the custom fields (`1 <= min <= max`) and applies them.
    func applyCustomLatency() async {
        switch ConnectionLatency.custom(minimum: customLatencyMinimum, maximum: customLatencyMaximum) {
        case .success(let latency):
            customLatencyError = nil
            await setLatency(latency)
        case .failure(let error):
            customLatencyError = error.description
        }
    }

    /// Opens the custom editor, prefilled with the stored range.
    func beginCustomLatency() {
        let current = shaping?.latency ?? .off
        customLatencyMinimum = current == .off ? "" : "\(current.minimumMs)"
        customLatencyMaximum = current == .off ? "" : "\(current.maximumMs)"
        customLatencyError = nil
        isEditingCustomLatency = true
    }

    func setMobileDataMetered(_ metered: Bool) async {
        guard let adbClient, let serial = activeSerial else { return }
        guard network?.connectivity.cellularAgent != nil else { return }
        let generation = currentGeneration
        beginWrite()
        defer { endWrite() }
        guard let instance = await identifyForWrite(serial: serial, generation: generation) else { return }
        markChanged(.meter, serial: serial, instance: instance)
        do {
            try await adbClient.setEmulatorMobileDataMetered(serial: serial, metered: metered)
        } catch {
            if !error.isCancellation { errorMessage = "\(error)" }
            return
        }
        let settled = await settleNetwork(serial: serial, generation: generation, attempts: 20) {
            $0.connectivity.isMobileDataMetered == metered
        }
        guard isCurrent(serial: serial, generation: generation) else { return }
        if settled {
            if metered {
                markRestored([.meter], serial: serial)
            }
            flashStatus(metered ? "Mobile data is metered" : "Mobile data is temporarily not metered")
        } else {
            errorMessage = "The mobile network did not become \(metered ? "metered" : "temporarily not metered") within 10 s."
        }
    }

    // MARK: - Reset

    /// Speed and latency off, metered, and the Wi-Fi and mobile-data switches as they were
    /// before `useMobileData()` on this AVD. Each part is read back.
    func resetNetworkConditions() async {
        guard let adbClient, let serial = activeSerial else { return }
        let generation = currentGeneration
        beginWrite()
        defer { endWrite() }
        let progress = "Resetting conditions…"
        status.showProgress(progress)
        // Only this write's own line: the outcome below replaces it, and
        // another operation's line is not this write's to clear.
        defer { status.clear(ifShowing: progress) }
        // Which emulator this is: the records of another one are not put
        // back here (reading it drops a stale console record).
        let instance = await emulatorInstance(serial: serial, generation: generation)
        let conditions = ConsoleCondition.allCases
        let unroot = rootedByDeviceHubPro.contains(serial)
        let failed = await Self.putBack(conditions, serial: serial, adbClient: adbClient, unroot: unroot)
        if unroot, !failed.contains(where: { $0.condition == .shaping }) {
            recordRootedByDeviceHubPro(false, serial: serial)
            onAdbdRestarted?(serial)
        }
        if !failed.contains(where: { $0.condition == .shaping }) { setDesiredShaping(nil, serial: serial) }
        var failures = failed.map { "\($0.condition.label): \($0.error)" }
        markRestored(ConsoleCondition.allCases.filter { condition in !failed.contains { $0.condition == condition } }, serial: serial)
        let avdName = instance?.avdName ?? mirroredAvdName
        let saved = avdName.flatMap { savedDataPaths[$0] }
        if let avdName, let saved {
            do {
                try await adbClient.setMobileData(serial: serial, enabled: saved.mobileDataEnabled)
                try await adbClient.setWifi(serial: serial, enabled: saved.wifiEnabled)
                forgetDataPath(avdName: avdName)
            } catch {
                failures.append("data path: \(error)")
            }
        }

        // Read everything back.
        if let readBack = try? await NetworkShaper(adb: adbClient).read(serial: serial),
           isCurrent(serial: serial, generation: generation) {
            shaping = readBack
            if readBack.isShaping {
                failures.append("the device still shapes speed or latency")
            }
        }
        let expectedPath: DataPath? = saved.map { $0.wifiEnabled ? .wifi : ($0.mobileDataEnabled ? .mobileData : .noNetwork) }
        let settled = await settleNetwork(serial: serial, generation: generation, attempts: 40) { snapshot in
            (expectedPath == nil || snapshot.connectivity.dataPath == expectedPath)
                && snapshot.connectivity.isMobileDataMetered != false
        }
        guard isCurrent(serial: serial, generation: generation) else { return }
        if !settled {
            if let expectedPath, network?.connectivity.dataPath != expectedPath {
                failures.append("the data path is \(network?.connectivity.dataPath?.label ?? "unknown"), not \(expectedPath.label)")
            }
            if network?.connectivity.isMobileDataMetered == false {
                failures.append("mobile data is still temporarily not metered")
            }
        }
        if failures.isEmpty {
            flashStatus("Network conditions reset")
        } else {
            errorMessage = "Reset conditions did not finish: " + failures.joined(separator: "; ")
        }
    }

    // MARK: - App conditions

    /// Simulate low memory: sends the level `TrimMemoryLevel.forLowMemory`
    /// picks for the target's state, gated the way the activity manager
    /// gates it (on a fresh read), and reads the recorded level back.
    func simulateLowMemory() async {
        guard let adbClient, let serial = activeSerial, let package = targetPackage else { return }
        let generation = currentGeneration
        beginWrite()
        defer { endWrite() }
        let before = try? await adbClient.appConditions(serial: serial, package: package)
        guard isCurrent(serial: serial, generation: generation), package == targetPackage else { return }
        if let before { applyApp(before, package: package) }
        let api = before?.apiLevel ?? apiLevel
        let level = TrimMemoryLevel.forLowMemory(process: before?.runningProcess, apiLevel: api)
        let gate = TrimMemoryGate.evaluate(level, process: before?.runningProcess, apiLevel: api)
        if let reason = gate.reason {
            trimOutcome = reason
            return
        }
        do {
            try await adbClient.sendTrimMemory(serial: serial, package: package, level: level)
        } catch let error as AppConditionsError {
            trimOutcome = error.description
            return
        } catch {
            if !error.isCancellation { errorMessage = "\(error)" }
            return
        }
        let after = try? await adbClient.appConditions(serial: serial, package: package)
        guard isCurrent(serial: serial, generation: generation), package == targetPackage else { return }
        if let after { applyApp(after, package: package) }
        trimOutcome = Self.trimOutcome(level: level, after: after?.runningProcess)
    }

    nonisolated static func trimOutcome(level: TrimMemoryLevel, after process: AppProcessState?) -> String {
        guard let recorded = process?.trimMemoryLevel else {
            return "Sent \(level.label), but the process record is no longer readable."
        }
        guard recorded == level.rawValue else {
            return "Sent \(level.label), but the process records trim level \(recorded)."
        }
        if process?.isFrozen == true {
            return "Sent \(level.label): the process records level \(recorded). It is frozen, so it frees memory when the app resumes."
        }
        return "Sent \(level.label): the process records level \(recorded)."
    }

    /// `am kill`: confirmed only when the pid is gone (the command exits 0
    /// when it left a foreground app alone), with the pid's exit record.
    func killProcess() async {
        guard let adbClient, let serial = activeSerial, let package = targetPackage else { return }
        let generation = currentGeneration
        beginWrite()
        defer { endWrite() }
        guard let before = try? await adbClient.appConditions(serial: serial, package: package),
              isCurrent(serial: serial, generation: generation), package == targetPackage
        else { return }
        applyApp(before, package: package)
        guard let pid = before.mainPid else {
            killOutcome = "\(package) is not running."
            return
        }
        do {
            try await adbClient.killBackgroundProcesses(serial: serial, package: package)
        } catch let error as AppConditionsError {
            killOutcome = error.description
            return
        } catch {
            if !error.isCancellation { errorMessage = "\(error)" }
            return
        }
        let after = await settleApp(serial: serial, package: package, generation: generation, attempts: 10) {
            !$0.pids.contains(pid)
        }
        guard isCurrent(serial: serial, generation: generation), package == targetPackage else { return }
        guard let after, !after.pids.contains(pid) else {
            killOutcome = "Still running. Only background apps can be killed this way: leave the app (Home), give Android a second, then try again."
            return
        }
        let record = await exitRecord(serial: serial, package: package, pid: pid, apiLevel: after.apiLevel)
        guard isCurrent(serial: serial, generation: generation), package == targetPackage else { return }
        killOutcome = Self.endedOutcome(verb: "Killed", pid: pid, record: record)
            + " Reopen it from Recents to test state restoration."
    }

    nonisolated static func endedOutcome(verb: String, pid: Int, record: ProcessExitRecord?) -> String {
        guard let record else { return "\(verb)." }
        return "\(verb). Android recorded \(record.summary)."
    }

    /// The exit record of `pid` (API 30+). AMS writes it as it handles the
    /// death, which can trail the pid leaving `pidof`, so an absent record
    /// is read again for up to a second.
    private func exitRecord(serial: String, package: String, pid: Int, apiLevel: Int?) async -> ProcessExitRecord? {
        guard let adbClient, (apiLevel ?? 0) >= ProcessExitRecord.minimumAPI else { return nil }
        var record: ProcessExitRecord?
        _ = await settleSetting(
            attempts: 5,
            delay: .milliseconds(200),
            attempt: {
                let records = (try? await adbClient.processExitRecords(serial: serial, package: package)) ?? []
                record = records.first { $0.pid == pid }
            },
            settled: { record != nil }
        )
        return record
    }

    // MARK: - Read-back loops

    /// One fresh network probe, kept while the device is still current.
    private func readNetwork(serial: String, generation: UInt64) async {
        guard let adbClient,
              let snapshot = try? await adbClient.networkConditions(serial: serial),
              isCurrent(serial: serial, generation: generation)
        else { return }
        network = snapshot
    }

    /// Re-reads the network probe until `done` holds (every 500 ms). A
    /// device change ends the loop at once: its reads would go to the
    /// device being left, holding the write fence (and the new device's
    /// rows) for up to 20 s. False then.
    private func settleNetwork(
        serial: String,
        generation: UInt64,
        attempts: Int,
        until done: @escaping (NetworkConditionsSnapshot) -> Bool
    ) async -> Bool {
        guard let adbClient else { return false }
        let finished = await settleSetting(
            attempts: attempts,
            delay: .milliseconds(500),
            attempt: {
                guard let snapshot = try? await adbClient.networkConditions(serial: serial),
                      isCurrent(serial: serial, generation: generation)
                else { return }
                network = snapshot
            },
            settled: {
                !isCurrent(serial: serial, generation: generation) || (network.map(done) ?? false)
            }
        )
        return finished && isCurrent(serial: serial, generation: generation)
    }

    /// Re-reads the app probe until `done` holds (every 300 ms), or until
    /// the device changes; returns the last reading.
    private func settleApp(
        serial: String,
        package: String,
        generation: UInt64,
        attempts: Int,
        until done: @escaping (AppConditionsSnapshot) -> Bool
    ) async -> AppConditionsSnapshot? {
        guard let adbClient else { return nil }
        var last: AppConditionsSnapshot?
        await settleSetting(
            attempts: attempts,
            delay: .milliseconds(300),
            attempt: {
                guard let snapshot = try? await adbClient.appConditions(serial: serial, package: package),
                      isCurrent(serial: serial, generation: generation)
                else { return }
                last = snapshot
                if package == targetPackage { applyApp(snapshot, package: package) }
            },
            settled: {
                !isCurrent(serial: serial, generation: generation) || (last.map(done) ?? false)
            }
        )
        return last
    }
}
