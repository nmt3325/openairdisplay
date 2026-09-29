#!/usr/bin/env python3
"""Re-apply the AWDL (Apple peer-to-peer WiFi) fork work onto upstream v1.22.0.
Idempotent, anchored edits. Fails loudly if an anchor moved.
"""
import pathlib
import sys

ROOT = pathlib.Path("/data/work")
FORK = pathlib.Path("/data/fork-snapshot/openairdisplay-main")
fails = []


def edit(rel, old, new, count=1):
    p = ROOT / rel
    s = p.read_text()
    if new in s:
        print("  = already applied: " + rel)
        return
    n = s.count(old)
    if n != count:
        fails.append(rel + ": anchor matched " + str(n) + "x (want " + str(count) + "): " + repr(old.splitlines()[0][:70]))
        return
    p.write_text(s.replace(old, new, count))
    print("  + " + rel)


helper = r'''import Foundation
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
'''
hp = ROOT / "Shared/PeerToPeerWiFi.swift"
if hp.exists() and hp.read_text() == helper:
    print("  = already applied: Shared/PeerToPeerWiFi.swift")
else:
    hp.write_text(helper)
    print("  + Shared/PeerToPeerWiFi.swift (new)")

SR = "Shared/StreamReceiver.swift"

edit(SR, r"""    private var listener: NWListener?
    private var listenerHealthy = false
    private var connection: NWConnection?""", r"""    private var listener: NWListener?
    private var listenerHealthy = false
    /// A listener that exists but hasn't reached .ready yet. Without this,
    /// ensureListening() (fired by scenePhase .active on every cold launch)
    /// sees listenerHealthy == false and cancels the listener that is still
    /// coming up. The cancelled socket keeps the fixed port for a few seconds
    /// (allowLocalEndpointReuse is ignored here — FB8658821), so the immediate
    /// rebind fails with EADDRINUSE and the retry re-arms the same race
    /// forever. Peer-to-peer WiFi widened the window: AWDL bring-up delays
    /// .ready, which is why this only started showing up over p2p.
    private var listenerStarting = false
    /// Collapses overlapping restarts so only one rebind is ever in flight.
    private var restartPending = false
    /// Invalidates a scheduled rebind when the session is closed meanwhile.
    private var listenerGeneration = 0
    /// Grows after each failed bind so retries outlast the port hold.
    private var restartBackoff: TimeInterval = 0.5
    private var connection: NWConnection?""")

edit(SR, r"""            guard !self.listenerHealthy else { return }
            Log.info("listener not healthy — restarting")""", r"""            guard !self.listenerHealthy else { return }
            // Never tear down a listener that is still negotiating its way to
            // .ready — that is the cold-launch race, not a dead listener.
            guard !self.listenerStarting else {
                Log.info("listener still coming up — letting it finish")
                return
            }
            Log.info("listener not healthy — restarting")""")

edit(SR, r"""                self.listener?.cancel()
                self.listener = nil
                self.listenerHealthy = false
                self.stopCursorListener()""", r"""                self.listener?.stateUpdateHandler = nil
                self.listener?.newConnectionHandler = nil
                self.listener?.cancel()
                self.listener = nil
                self.listenerHealthy = false
                self.listenerStarting = false
                // Drop any rebind that was scheduled before we went dark.
                self.listenerGeneration &+= 1
                self.restartPending = false
                self.restartBackoff = 0.5
                self.stopCursorListener()""")

edit(SR, r"""    private func restartListener() {
        listener?.cancel()
        listener = nil
        listenerHealthy = false
        startListener()
    }""", r"""    /// Re-arm the listener. Cancelling does not free the fixed port in the
    /// same turn, so rebinding immediately fails with EADDRINUSE; wait for the
    /// cancel to land first and let only one rebind be in flight.
    private func restartListener(after delay: TimeInterval = 0) {
        guard !restartPending else { return }
        restartPending = true
        listenerHealthy = false
        listenerStarting = false
        if let old = listener {
            old.stateUpdateHandler = nil
            old.newConnectionHandler = nil
            old.cancel()
        }
        listener = nil
        listenerGeneration &+= 1
        let generation = listenerGeneration
        queue.asyncAfter(deadline: .now() + max(delay, 0.35)) { [weak self] in
            guard let self, generation == self.listenerGeneration else { return }
            self.restartPending = false
            self.startListener()
        }
    }

    /// Back off between rebind attempts. A cancelled listener holds the port
    /// for a few seconds, so retrying every second never lets it come free —
    /// each attempt cancels a fresh socket and restarts the hold. Doubling up
    /// to 8s outlasts it.
    private func scheduleListenerRetry() {
        let delay = restartBackoff
        restartBackoff = min(restartBackoff * 2, 8.0)
        Log.info("re-arming listener in \(delay)s")
        restartListener(after: delay)
    }""")

edit(SR, r"""    private func startListener() {
        do {""", r"""    private func startListener() {
        guard listener == nil else { return }
        listenerStarting = true
        do {""")

edit(SR, r"""            params.serviceClass = .interactiveVideo
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)""", r"""            params.serviceClass = .interactiveVideo
            // Advertise and accept over Apple's peer-to-peer WiFi path as well
            // as a normal LAN, so no access point is required.
            params.includePeerToPeer = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)""")

edit(SR, r"""        } catch {
            setStatus("Listener failed: \(error.localizedDescription)")
            return
        }""", r"""        } catch {
            listenerStarting = false
            Log.info("listener could not be created: \(error)")
            setStatus("Listener failed — restarting…")
            scheduleListenerRetry()
            return
        }""")

edit(SR, r"""            case .ready:
                self.listenerHealthy = true
                self.setStatus("Listening on :\(self.port)")
            case .failed(let error):
                Log.info("listener failed: \(error) — restarting in 1s")
                self.listenerHealthy = false
                self.setStatus("Listener failed — restarting…")
                self.queue.asyncAfter(deadline: .now() + 1) { self.restartListener() }
            case .cancelled:
                self.listenerHealthy = false""", r"""            case .ready:
                self.listenerStarting = false
                self.listenerHealthy = true
                self.restartBackoff = 0.5
                self.setStatus("Listening on :\(self.port)")
            case .waiting(let error):
                // Transient: the interface (awdl0 on the peer-to-peer path)
                // isn't up yet. Network framework retries on its own, so
                // don't cancel — cancelling here is what strands the port.
                Log.info("listener waiting: \(error)")
            case .failed(let error):
                Log.info("listener failed: \(error)")
                self.listenerStarting = false
                self.listenerHealthy = false
                self.setStatus("Listener failed — restarting…")
                self.scheduleListenerRetry()
            case .cancelled:
                self.listenerStarting = false
                self.listenerHealthy = false""")

edit(SR, r"""        let onReady: () -> Void = { [weak self] in
            guard let self else { return }
            self.lastDataReceived = Date()
            self.setConnected(true)
            self.sendHello(on: conn)
        }""", r"""        let onReady: () -> Void = { [weak self] in
            guard let self else { return }
            self.lastDataReceived = Date()
            // USB was settled at accept time from the loopback address.
            // Separating a direct AWDL link from infrastructure WiFi needs the
            // connection's path, which does not exist until it is ready.
            if self.transport != "USB" {
                if let link = conn.peerToPeerWiFiInterfaceName {
                    self.transport = "AWDL"
                    Log.info("link: Apple peer-to-peer WiFi (\(link))")
                } else {
                    self.transport = "WiFi"
                    Log.info("link: local network")
                }
            }
            self.setConnected(true)
            self.sendHello(on: conn)
        }""")

MS = "Mac/MacSender.swift"

edit(MS, r"""    // Fired on every hello — carries the receiver's install id so the
    // controller can deduplicate USB/WiFi sessions to the same device.
    @MainActor var onHello: ((PhoneInfo) -> Void)?""", r"""    // Fired on every hello — carries the receiver's install id so the
    // controller can deduplicate USB/WiFi sessions to the same device.
    @MainActor var onHello: ((PhoneInfo) -> Void)?
    // Fired once a connection is live, naming the peer-to-peer WiFi interface
    // it landed on (`awdl0`), or nil when the link runs over a local network,
    // a cable or USB. Lets the UI say which path is carrying the session.
    @MainActor var onPeerToPeer: ((String?) -> Void)?""")

edit(MS, r"""        let params = NWParameters(tls: nil, tcp: options)
        let conn = NWConnection(to: endpoint, using: params)""", r"""        let params = NWParameters(tls: nil, tcp: options)
        // The Bonjour endpoint may live on Apple's peer-to-peer WiFi path when
        // there is no infrastructure network. Dialing the service endpoint (not
        // a resolved IP) is what lets Network.framework pick AWDL.
        params.includePeerToPeer = true
        let conn = NWConnection(to: endpoint, using: params)""")

edit(MS, r"""            Task { @MainActor in self.onTransportPath?(wired) }""", r"""            Task { @MainActor in self.onTransportPath?(wired) }
            // awdl0 and en0 both report InterfaceType.wifi, so "WiFi" on its
            // own cannot say whether a router was involved — name the link.
            let peerToPeer = conn.peerToPeerWiFiInterfaceName
            Log.info(peerToPeer.map { "link: Apple peer-to-peer WiFi (\($0))" }
                ?? "link: local network or USB")
            Task { @MainActor in self.onPeerToPeer?(peerToPeer) }""")

MA = "Mac/OpenSidecarMacApp.swift"

edit(MA, r"""            return "wifi:unknown"
        }
    }
}""", r"""            return "wifi:unknown"
        }
    }

    /// True when Bonjour only ever saw this service over Apple's peer-to-peer
    /// WiFi link, i.e. no shared network is carrying it. Being visible on both
    /// paths still counts as a local network, because that is the one the dial
    /// will end up preferring.
    var isPeerToPeerOnly: Bool {
        guard case .wifi(let result) = self else { return false }
        let interfaces = result.interfaces
        return !interfaces.isEmpty
            && interfaces.allSatisfy { isPeerToPeerWiFiInterface($0.name) }
    }
}""")

edit(MA, r"""    @Published var wired = false

    var transportLabel: String { onUSB ? "USB" : wired ? "Cable" : "WiFi" }""", r"""    @Published var wired = false

    // Which WiFi link the live connection landed on: the interface name
    // ("awdl0") for Apple's peer-to-peer path, nil for a local network, a
    // cable or USB. Set by the sender the moment the connection is ready.
    @Published var peerToPeerInterface: String?

    /// "WiFi" on its own never said whether the two devices went through a
    /// router or straight to each other — name the actual link instead.
    var transportLabel: String {
        if onUSB { return "USB" }
        if wired { return "Cable" }
        return peerToPeerInterface != nil ? "AWDL (direct)" : "WiFi (LAN)"
    }""")

edit(MA, r"""        // TXT records carry the receiver's install id (new receivers).
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_opensidecar._tcp", domain: nil), using: .tcp)""", r"""        // Include Apple's peer-to-peer WiFi path so Bonjour discovery also
        // works when the Mac and receiver are not joined to an access point.
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        // TXT records carry the receiver's install id (new receivers).
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_opensidecar._tcp", domain: nil), using: params)""")

edit(MA, r"""        sender.onTransportPath = { [weak session] wired in
            session?.wired = wired
        }""", r"""        sender.onTransportPath = { [weak session] wired in
            session?.wired = wired
            if wired { session?.peerToPeerInterface = nil }   // a cable is no WiFi link
        }
        sender.onPeerToPeer = { [weak session] interfaceName in
            session?.peerToPeerInterface = interfaceName
            Log.info("link[\(id)]: \(interfaceName ?? "local network or USB")")
        }""")

edit(MA, r"""        var transportLabel: String {
            switch (usbTarget != nil, wifiTarget != nil) {
            case (true, true): return "USB · WiFi"
            case (true, false): return "USB"
            case (false, true): return "WiFi"
            default: return ""
            }
        }""", r"""        var transportLabel: String {
            // No session exists yet, so the discovery path is the only hint:
            // a service seen solely over awdl0 has no local network behind it.
            let wifiLabel = (wifiTarget?.isPeerToPeerOnly ?? false) ? "AWDL" : "WiFi"
            switch (usbTarget != nil, wifiTarget != nil) {
            case (true, true): return "USB · \(wifiLabel)"
            case (true, false): return "USB"
            case (false, true): return wifiLabel
            default: return ""
            }
        }""")


def section(text, heading):
    start = text.index(heading)
    nxt = text.index("\n## ", start + len(heading))
    return text[start:nxt + 1]


fork_readme = (FORK / "README.md").read_text()
about = section(fork_readme, "## About this fork")
awdl = section(fork_readme, "## Connecting without a local network")
awdl = awdl.replace("`iOS/PhoneReceiver.swift`", "`Shared/StreamReceiver.swift`")
awdl = awdl.replace("iOS/PhoneReceiver.swift", "Shared/StreamReceiver.swift")

rp = ROOT / "README.md"
r = rp.read_text()
if "## About this fork" in r:
    print("  = already applied: README.md")
elif "## Why OpenDisplay exists" not in r or "## Install" not in r:
    fails.append("README.md: expected headings missing")
else:
    r = r.replace("## Why OpenDisplay exists", about + "## Why OpenDisplay exists", 1)
    r = r.replace("## Install", awdl + "## Install", 1)
    rp.write_text(r)
    print("  + README.md (2 sections)")

if fails:
    print("\nFAILED ANCHORS:")
    for f in fails:
        print(" - " + f)
    sys.exit(1)
print("\nall edits applied")
