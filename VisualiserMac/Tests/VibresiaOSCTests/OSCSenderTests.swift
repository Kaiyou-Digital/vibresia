import Foundation
import Network
import Testing
@testable import VibresiaOSC

/// Packets sent over a real UDP socket on this Mac arrive as they were sent.
struct OSCSenderTests {
    /// Collects the datagrams a listener on a free local port receives.
    private final class Listener: @unchecked Sendable {
        private let queue = DispatchQueue(label: "vibresia.osc.test")
        private let lock = NSLock()
        private var received: [Data] = []
        private var listener: NWListener?
        private(set) var port: UInt16 = 0

        func start() throws {
            let parameters = NWParameters.udp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let created = try NWListener(using: parameters)
            created.newConnectionHandler = { [weak self] connection in
                connection.start(queue: self?.queue ?? .global())
                self?.receive(on: connection)
            }
            let ready = DispatchSemaphore(value: 0)
            created.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            created.start(queue: queue)
            _ = ready.wait(timeout: .now() + 5)
            port = created.port?.rawValue ?? 0
            listener = created
        }

        private func receive(on connection: NWConnection) {
            connection.receiveMessage { [weak self] data, _, _, error in
                if let data {
                    self?.lock.lock()
                    self?.received.append(data)
                    self?.lock.unlock()
                }
                if error == nil { self?.receive(on: connection) }
            }
        }

        var datagrams: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return received
        }

        func stop() { listener?.cancel() }
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        return condition()
    }

    @Test func packetsSentArriveIntactAndInOrder() throws {
        let listener = Listener()
        try listener.start()
        defer { listener.stop() }
        let sender = OSCSender(host: "127.0.0.1", port: listener.port)
        defer { sender.stop() }
        let first = OSCEncoder.message(OSCMessage("/vibresia/beat", [.float(0.5)]))
        let second = OSCEncoder.bundle([OSCMessage("/vibresia/bass", [.float(0.25)]), OSCMessage("/vibresia/genre", [.int(3)])])
        sender.send([first, second])
        #expect(waitUntil(5) { listener.datagrams.count >= 2 }, "both datagrams arrived")
        #expect(listener.datagrams.prefix(2).map { $0 } == [first, second])
    }

    @Test func sendingToNobodyIsHarmlessAndStoppingCanBeRepeated() {
        let sender = OSCSender(host: "127.0.0.1", port: 9) // the discard port: nothing listens
        sender.send([OSCEncoder.message(OSCMessage("/x", []))])
        sender.stop()
        sender.stop()
        sender.send([OSCEncoder.message(OSCMessage("/x", []))]) // after stopping: ignored, not a crash
    }

    @Test func aHostThatCannotBeFoundDoesNotCrash() {
        let sender = OSCSender(host: "no-such-host.invalid", port: 9420)
        sender.send([OSCEncoder.message(OSCMessage("/x", []))])
        sender.stop()
    }
}
