import Foundation
import Network

/// Sends packets to one UDP address. UDP has no connection to lose: with nobody listening a packet is simply gone, so sending is never
/// an error and never blocks the caller.
public final class OSCSender {
    private let queue = DispatchQueue(label: "vibresia.osc.send", qos: .userInitiated)
    private let lock = NSLock()
    private var connection: NWConnection?

    /// A sender to `host` (an address or a name) on `port`. A port of 0 or a host that cannot be found makes a sender that sends nothing.
    public init(host: String, port: UInt16) {
        guard let port = NWEndpoint.Port(rawValue: port), port.rawValue != 0 else { return }
        let created = NWConnection(host: NWEndpoint.Host(host), port: port, using: .udp)
        created.start(queue: queue)
        connection = created
    }

    deinit { stop() }

    /// Sends each packet as a datagram of its own, in order. Ignored once stopped.
    public func send(_ packets: [Data]) {
        lock.lock()
        let current = connection
        lock.unlock()
        for packet in packets { current?.send(content: packet, completion: .contentProcessed { _ in }) }
    }

    /// Stops sending. Safe to call more than once.
    public func stop() {
        lock.lock()
        let current = connection
        connection = nil
        lock.unlock()
        current?.cancel()
    }
}
