import Foundation
import Network

/// Apple's peer-to-peer WiFi link shows up as its own interface — `awdl0`, or
/// `llw0` for the low-latency variant — while infrastructure WiFi is `en0`.
/// Both report `NWInterface.InterfaceType.wifi`, so the interface name is the
/// only thing that separates a direct link from one that goes via a router.
func isPeerToPeerWiFiInterface(_ name: String) -> Bool {
    let lowered = name.lowercased()
    return lowered.hasPrefix("awdl") || lowered.hasPrefix("llw")
}

extension NWConnection {
    /// The peer-to-peer WiFi interface this connection landed on, or nil when
    /// it runs over a local network, a cable or the USB loopback. Only
    /// meaningful once the connection is ready — before that there is no path.
    var peerToPeerWiFiInterfaceName: String? {
        guard let path = currentPath else { return nil }
        // Strongest signal: a peer-to-peer socket talks to an IPv6 link-local
        // address scoped to the peer-to-peer interface.
        if let remote = path.remoteEndpoint,
           case .hostPort(let host, _) = remote,
           case .ipv6(let address) = host,
           let name = address.interface?.name,
           isPeerToPeerWiFiInterface(name) {
            return name
        }
        // Fallback: the path offers exactly one interface and it is the
        // peer-to-peer one. Deliberately strict — `awdl0` is also listed
        // alongside `en0` while the device sits on a network, and that case is
        // infrastructure WiFi, not a direct link.
        if path.availableInterfaces.count == 1,
           let only = path.availableInterfaces.first,
           isPeerToPeerWiFiInterface(only.name) {
            return only.name
        }
        return nil
    }
}
