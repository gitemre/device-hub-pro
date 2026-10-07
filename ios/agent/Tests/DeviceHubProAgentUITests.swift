import XCTest

// One long-running test that serves the agent API until POST /stop (or a watchdog).
//
// Environment (xcodebuild passes TEST_RUNNER_<NAME> to the runner as <NAME>):
//   DHP_BIND         device-side tunnel address to bind to (required)
//   DHP_TOKEN        per-launch secret, at least 32 characters (required)
//   DHP_PORT         TCP port (default 8765)
//   DHP_MAX_SECONDS  watchdog, default 3600
//   DHP_IDLE_SECONDS stop after this long with no authorized request, default 90 (0 = off)
final class DeviceHubProAgentUITests: XCTestCase {
    func testServe() throws {
        continueAfterFailure = true
        let env = ProcessInfo.processInfo.environment
        guard let bind = env["DHP_BIND"], !bind.isEmpty else {
            XCTFail("AGENT_FATAL DHP_BIND is not set; refusing to listen"); return
        }
        guard let token = env["DHP_TOKEN"], token.count >= 32 else {
            XCTFail("AGENT_FATAL DHP_TOKEN is missing or shorter than 32 characters"); return
        }
        let port = UInt16(env["DHP_PORT"] ?? "") ?? 8765
        let maxSeconds = Double(env["DHP_MAX_SECONDS"] ?? "") ?? 3600
        let idleSeconds = Double(env["DHP_IDLE_SECONDS"] ?? "") ?? 90
        // Only authorized requests reach the handler (the server checks the token first).
        var lastRequest = Date()

        let server: AgentServer
        do {
            server = try AgentServer(bind: bind, port: port, token: token)
            server.handler = { req, respond in lastRequest = Date(); respond(AgentActions.handle(req)); lastRequest = Date() }
            try server.start()
        } catch {
            // Never fall back to another address.
            XCTFail("AGENT_FATAL cannot listen on the tunnel address: \(error)")
            return
        }
        AgentActions.startedAt = Date()
        print("AGENT_READY port=\(port) interface=\(server.interfaceName) pinnedInterface=\(server.pinnedInterface)")

        let deadline = Date(timeIntervalSinceNow: maxSeconds)
        var idled = false
        while !AgentActions.stopRequested && Date() < deadline {
            if idleSeconds > 0, Date().timeIntervalSince(lastRequest) > idleSeconds { idled = true; break }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        // Let the /stop response leave before the process goes away.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        server.stop()
        print("AGENT_STOPPED reason=\(AgentActions.stopRequested ? "stop" : idled ? "idle" : "watchdog")")
    }
}
