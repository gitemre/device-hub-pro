// Stands in for the app's own modules, compiled at the app's deployment
// target (macOS 26.0). With -D WORKAROUND it gets the same shim as
// Sources/DeviceHubProKit/Internal/TaskSleep.swift.
import LibA

#if WORKAROUND
extension Task where Success == Never, Failure == Never {
    static func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(until: .now + duration, tolerance: nil)
    }
}
#endif

@main
struct Main {
    static func main() async throws {
        try await Task.sleep(for: .milliseconds(1))
        try await libASleep()
        print("ok: both sleeps returned")
    }
}
