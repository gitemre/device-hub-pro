extension Task where Success == Never, Failure == Never {
    /// Suspends the current task for `duration` on the continuous clock, like
    /// the standard library's `Task.sleep(for:)`. Throws `CancellationError`
    /// if the task is cancelled before the duration elapses.
    ///
    /// Works around a toolchain bug; see `docs/native-build-async-odr.md`.
    /// This non-generic overload wins overload resolution over the standard
    /// library's generic `sleep(for:tolerance:clock:)`, so every
    /// `Task.sleep(for:)` in this package lands here. The standard library's
    /// version is `@_alwaysEmitIntoClient`, so each module emits its own weak
    /// copy of the `Clock.sleep(for:)` specialization for `ContinuousClock`.
    /// The copy compiled at our deployment target (macOS 15 when this was
    /// found, 26 now) needs a 128-byte async context. The copies in the
    /// macOS 12 dependencies (grpc-swift-nio-transport,
    /// swift-service-lifecycle) need 112. The native build system merged the
    /// copies, and ld paired our body with a 112-byte function pointer, so
    /// every sleep overran the task allocator ("freed pointer was not the
    /// last allocation").
    /// `ContinuousClock.sleep(until:tolerance:)` is a real runtime function,
    /// so this package emits no copy at all.
    ///
    /// Bypassing this shim brings the crash back. Examples:
    /// `Task.sleep(for:tolerance:)`, `Task.sleep(for:clock:)`, and
    /// `ContinuousClock().sleep(for:)`. Check a native release build with
    /// `Scripts/check-async-odr.sh`.
    package static func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(until: .now + duration, tolerance: nil)
    }
}
