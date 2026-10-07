import Foundation

/// The emulator's gRPC endpoint as published in its discovery file.
public struct EmulatorGRPCInfo: Sendable {
    public let port: Int
    public let token: String?
}

/// Resolves the gRPC endpoint of a running emulator from its discovery file.
///
/// Emulators started by Android Studio's Device Manager enable JWT auth and do
/// not expose `-grpc` on the command line, so the port and token must be read
/// from the discovery file that `adb emu avd discoverypath` points at. The
/// token is registered with the control channel so every later call carries it.
public enum EmulatorDiscovery {
    public static func grpcInfo(serial: String, adbClient: AdbClient) async -> EmulatorGRPCInfo? {
        guard
            let output = try? await adbClient.emuCommand(serial: serial, ["avd", "discoverypath"]),
            let path = AdbParsing.discoveryPath(from: output),
            let text = try? String(contentsOfFile: path, encoding: .utf8)
        else {
            return nil
        }

        let discovery = AdbParsing.emulatorDiscovery(from: text)
        guard let port = discovery.port else { return nil }

        EmulatorControl.registerToken(discovery.token, forPort: port)
        return EmulatorGRPCInfo(port: port, token: discovery.token)
    }
}
