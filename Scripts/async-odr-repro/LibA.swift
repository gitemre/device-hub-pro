// Stands in for a package dependency compiled at its own, lower deployment
// target (grpc-swift-nio-transport and swift-service-lifecycle build at
// macOS 12.0). repro.sh compiles this file with -target arm64-apple-macosx12.0.

// Gives this object's __TEXT,__const 16-byte alignment (the SIMD constants
// are promoted into it), so the async function pointer of the Clock.sleep
// specialization below starts on a 16-byte boundary. ld prefers the more
// aligned of two weak copies, so it takes this pointer. In the app the
// alignment came from unrelated constants in Subchannel.swift.o.
public struct Table: Sendable {
    public var a: SIMD4<Float>
    public var b: SIMD4<Float>
    public var c: SIMD4<Float>
}

@inline(never)
public func table() -> Table {
    Table(a: SIMD4(1.5, 2.5, 3.5, 4.5), b: SIMD4(5.5, 6.5, 7.5, 8.5), c: SIMD4(9.5, 10.5, 11.5, 12.5))
}

// Moves the next async function pointer onto a 16-byte boundary.
public func libAYield() async {
    await Task.yield()
}

@available(macOS 13.0, *)
public func libASleep() async throws {
    try await Task.sleep(for: .milliseconds(1))
}
