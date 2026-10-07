import Foundation

/// Where the native live view of one iPhone connects (AGENTS.md, "Private APIs and kill switches"): the phone's CoreDevice tunnel
/// interface on this Mac and the two addresses at its ends. Nothing here is
/// ever logged, shown or stored.
public struct NativeMirrorEndpoint: Sendable, Equatable {
    public let coreDeviceIdentifier: String
    /// The tunnel interface (`utunN`).
    public let interface: String
    /// This Mac's address on the tunnel.
    public let hostAddress: String
    /// The phone's address on the tunnel (`connectionProperties.tunnelIPAddress`).
    public let deviceAddress: String
    public let productType: String

    public init(coreDeviceIdentifier: String, interface: String, hostAddress: String, deviceAddress: String, productType: String) {
        self.coreDeviceIdentifier = coreDeviceIdentifier
        self.interface = interface
        self.hostAddress = hostAddress
        self.deviceAddress = deviceAddress
        self.productType = productType
    }

    /// One IPv6 address of a host interface.
    public struct HostAddress: Sendable, Equatable {
        public let interface: String
        public let address: String

        public init(interface: String, address: String) {
            self.interface = interface
            self.address = address
        }
    }

    public enum ResolveError: Error, Equatable, CustomStringConvertible {
        case disabled
        case notAnIdentifier
        case noTunnelAddress
        case noHostInterface

        public var description: String {
            switch self {
            case .disabled: "The native live view is switched off."
            case .notAnIdentifier: "The device has no usable CoreDevice identifier."
            case .noTunnelAddress: "The iPhone's tunnel is not up."
            case .noHostInterface: "This Mac has no tunnel interface for the iPhone yet."
            }
        }
    }

    public static let disableVariable = "DHP_DISABLE_NATIVE_MIRROR"

    /// The kill switch: any non-empty value.
    public static func isDisabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !(environment[disableVariable] ?? "").isEmpty
    }

    /// Finds the host end of the phone's tunnel: a `utun` interface with an IPv6
    /// address in the same /64 as the phone's tunnel address (and not the phone's
    /// own address). Pure: the interfaces are handed in.
    public static func resolve(
        coreDeviceIdentifier: String,
        tunnelAddress: String?,
        productType: String?,
        interfaces: [HostAddress]
    ) throws -> NativeMirrorEndpoint {
        guard UUID(uuidString: coreDeviceIdentifier) != nil else { throw ResolveError.notAnIdentifier }
        guard let tunnelAddress, let device = bytes(of: tunnelAddress) else { throw ResolveError.noTunnelAddress }
        for candidate in interfaces where candidate.interface.hasPrefix("utun") {
            guard let host = bytes(of: candidate.address), host != device,
                  host[0..<8] == device[0..<8]
            else { continue }
            return NativeMirrorEndpoint(
                coreDeviceIdentifier: coreDeviceIdentifier,
                interface: candidate.interface,
                hostAddress: candidate.address,
                deviceAddress: tunnelAddress,
                productType: productType ?? ""
            )
        }
        throw ResolveError.noHostInterface
    }

    /// From a `device info details` read.
    public static func resolve(details: DevicectlDeviceDetails, interfaces: [HostAddress]) throws -> NativeMirrorEndpoint {
        try resolve(
            coreDeviceIdentifier: details.identifier,
            tunnelAddress: details.tunnelIPAddress,
            productType: details.productType,
            interfaces: interfaces
        )
    }

    private static func bytes(of address: String) -> [UInt8]? {
        // A scope suffix (`%utun4`) is not part of the address.
        let plain = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
        var value = in6_addr()
        guard inet_pton(AF_INET6, plain, &value) == 1 else { return nil }
        return withUnsafeBytes(of: &value) { Array($0) }
    }

    /// This Mac's IPv6 interface addresses (`getifaddrs`).
    public static func currentHostAddresses() -> [HostAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [HostAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var address = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { continue }
            result.append(HostAddress(interface: String(cString: entry.pointee.ifa_name), address: String(cString: buffer)))
        }
        return result
    }
}
