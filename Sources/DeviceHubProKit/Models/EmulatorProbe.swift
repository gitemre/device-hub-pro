import Foundation
import GRPCCore
import GRPCProtobuf

public struct EmulatorStatusInfo: Sendable {
    public let version: String
    public let booted: Bool
    public let uptimeMilliseconds: UInt64
}

/// Lightweight reachability check for an emulator's gRPC channel.
public enum EmulatorProbe {
    public static func status(port: Int, timeout: Duration = .seconds(1)) async -> EmulatorStatusInfo? {
        do {
            return try await EmulatorControl.withClient(port: port) { controller in
                var options = CallOptions.defaults
                options.timeout = timeout
                let status: Android_Emulation_Control_EmulatorStatus = try await controller.getStatus(
                    .init(),
                    options: options
                )
                return EmulatorStatusInfo(
                    version: status.version,
                    booted: status.booted,
                    uptimeMilliseconds: status.uptime
                )
            }
        } catch {
            return nil
        }
    }
}
