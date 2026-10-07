import Foundation
import Synchronization

/// One tunnel lease per phone, shared by everyone who needs the CoreDevice
/// tunnel open (fast input and the native live view).
///
/// A lease only keeps the tunnel alive (`TunnelLeaseKeeper`: one resident
/// `devicectl device notification observe` child), so two holders gain nothing
/// from two children; measured live, the app ran two of them for one
/// phone, started the same second. The hub hands each consumer its own handle
/// onto a shared keeper: the keeper starts with the first handle and ends with
/// the last one released.
public final class SharedTunnelLeases: @unchecked Sendable {
    public static let shared = SharedTunnelLeases()

    private struct Entry {
        let lease: any FastInputLease
        var holders = 0
        var ready: Task<Void, any Error>?
        let token = UUID()
    }

    private let state = Mutex<[String: Entry]>([:])

    public init() {}

    /// A handle onto the phone's shared lease; `make` builds the keeper when
    /// no handle holds one yet.
    public func lease(
        for coreDeviceIdentifier: String,
        make: @escaping @Sendable () -> any FastInputLease
    ) -> any FastInputLease {
        Handle(hub: self, key: coreDeviceIdentifier, make: make)
    }

    /// How many handles hold the phone's lease now (for tests).
    public func holders(for coreDeviceIdentifier: String) -> Int {
        state.withLock { $0[coreDeviceIdentifier]?.holders ?? 0 }
    }

    fileprivate func acquire(_ key: String, make: () -> any FastInputLease) async throws {
        let (task, token) = state.withLock { entries -> (Task<Void, any Error>, UUID) in
            var entry = entries[key] ?? Entry(lease: make())
            entry.holders += 1
            if entry.ready == nil {
                let lease = entry.lease
                entry.ready = Task { try await lease.start() }
            }
            entries[key] = entry
            return (entry.ready!, entry.token)
        }
        do {
            try await task.value
        } catch {
            let ended = state.withLock { entries -> (any FastInputLease)? in
                guard var entry = entries[key], entry.token == token else { return nil }
                entry.ready = nil
                entry.holders -= 1
                if entry.holders <= 0 {
                    entries[key] = nil
                    return entry.lease
                }
                entries[key] = entry
                return nil
            }
            ended?.terminateNow()
            throw error
        }
    }

    /// Drops one holder; the lease it was, when it was the last.
    private func drop(_ key: String) -> (any FastInputLease)? {
        state.withLock { entries -> (any FastInputLease)? in
            guard var entry = entries[key] else { return nil }
            entry.holders -= 1
            if entry.holders <= 0 {
                entries[key] = nil
                return entry.lease
            }
            entries[key] = entry
            return nil
        }
    }

    fileprivate func release(_ key: String) async { await drop(key)?.stop() }
    fileprivate func releaseNow(_ key: String) { drop(key)?.terminateNow() }

    private final class Handle: FastInputLease, @unchecked Sendable {
        let hub: SharedTunnelLeases
        let key: String
        let make: @Sendable () -> any FastInputLease
        private let held = Mutex(false)

        init(hub: SharedTunnelLeases, key: String, make: @escaping @Sendable () -> any FastInputLease) {
            self.hub = hub
            self.key = key
            self.make = make
        }

        func start() async throws {
            guard held.withLock({ state -> Bool in
                if state { return false }
                state = true
                return true
            }) else { return }
            do {
                try await hub.acquire(key, make: make)
            } catch {
                held.withLock { $0 = false }
                throw error
            }
        }

        func stop() async {
            guard held.withLock({ state -> Bool in
                defer { state = false }
                return state
            }) else { return }
            await hub.release(key)
        }

        func terminateNow() {
            guard held.withLock({ state -> Bool in
                defer { state = false }
                return state
            }) else { return }
            hub.releaseNow(key)
        }
    }
}
