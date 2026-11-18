import Darwin
import Foundation

/// What a client does: copy its stdin to the server and the server's replies to its stdout, and carry on if the server
/// goes away.
///
/// The server keeps nothing per session, so when it dies the client can start a new one (`reconnect`) and go on with
/// the same session. A request that was waiting for an answer when the server went is answered with an error at once,
/// since its answer is never coming; one sent while the new server is starting waits for it. If no server can be
/// started the client leaves, as it always did.
public enum MCPProxy {
    /// Returns when stdin has closed and the server has finished replying, or when no server can be reached. The
    /// caller exits.
    ///
    /// `reconnect` is called, on a thread of its own, when the server goes away while stdin is still open. It should
    /// start a server if need be and return a connection to it, or nil to give up.
    public static func run(
        _ connection: MCPSocketConnection,
        input: Int32 = STDIN_FILENO,
        output: Int32 = STDOUT_FILENO,
        reconnect: (() -> MCPSocketConnection?)? = nil
    ) {
        MCPProxySession(connection: connection, input: input, output: output, reconnect: reconnect).run()
    }
}

/// The error a client is given for a request that was lost with the server it was sent to.
let lostRequestMessage = "Vibresia's server went away and was restarted, so this request was lost. Please try it again."

private final class MCPProxySession {
    private let input: Int32
    private let output: Int32
    private let reconnect: (() -> MCPSocketConnection?)?

    /// Guards everything below.
    private let state = NSCondition()
    /// The connection to the server; nil while a new one is being started.
    private var current: MCPSocketConnection?
    private var gaveUp = false
    private var inputClosed = false
    /// Requests sent and not yet answered: the id as the client wrote it, and the connection they were sent on.
    private var pending: [String: (id: Any, connection: MCPSocketConnection)] = [:]

    init(connection: MCPSocketConnection, input: Int32, output: Int32, reconnect: (() -> MCPSocketConnection?)?) {
        current = connection
        self.input = input
        self.output = output
        self.reconnect = reconnect
    }

    func run() {
        Thread.detachNewThread { [self] in pumpInput() }
        pumpServer()
        state.lock()
        let last = current
        current = nil
        state.unlock()
        last?.close()
    }

    // MARK: - Client to server

    private func pumpInput() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var carry: [UInt8] = []
        while true {
            let count = read(input, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            carry.append(contentsOf: buffer[0..<count])
            while let newline = carry.firstIndex(of: 0x0A) {
                let line = Array(carry[0...newline])
                carry.removeSubrange(0...newline)
                forward(line)
            }
        }
        if !carry.isEmpty { forward(carry + [0x0A]) }
        state.lock()
        inputClosed = true
        let connection = current
        state.broadcast()
        state.unlock()
        if let connection { shutdown(connection.descriptor, SHUT_WR) } // so the server can finish and close
    }

    /// Sends one line to the server, waiting for a new one if it is being restarted. Gives up quietly if there will
    /// never be one.
    private func forward(_ line: [UInt8]) {
        let request = requestID(in: line)
        var failed: MCPSocketConnection?
        while let connection = waitForConnection(after: failed) {
            if let request {
                state.lock()
                pending[request.key] = (request.id, connection)
                state.unlock()
            }
            if writeAll(connection.descriptor, line, count: line.count) { return }
            // The server went while this was being sent. If the loss has not been reported to the client yet, take the
            // request back and send it to the new server; if it has, the client has its error and must not get two.
            if let request {
                state.lock()
                let stillOurs = pending.removeValue(forKey: request.key) != nil
                state.unlock()
                if !stillOurs { return }
            }
            failed = connection
        }
    }

    /// The connection to send on: the current one, or the next one if `failed` is still current. Nil once given up.
    private func waitForConnection(after failed: MCPSocketConnection?) -> MCPSocketConnection? {
        state.lock()
        defer { state.unlock() }
        while true {
            if gaveUp { return nil }
            if let connection = current, connection !== failed { return connection }
            state.wait()
        }
    }

    // MARK: - Server to client

    private func pumpServer() {
        while true {
            state.lock()
            let connection = current
            state.unlock()
            guard let connection else { return }
            copyReplies(from: connection)

            state.lock()
            let leaving = inputClosed
            if current === connection { current = nil }
            state.unlock()
            failPending(on: connection)
            if leaving { return }

            guard let reconnect, let next = reconnect() else {
                giveUp()
                return
            }
            state.lock()
            if inputClosed {
                state.unlock()
                next.close()
                return
            }
            current = next
            state.broadcast()
            state.unlock()
        }
    }

    private func giveUp() {
        state.lock()
        gaveUp = true
        state.broadcast()
        state.unlock()
    }

    /// Passes the server's lines to the client until the server closes, noting which requests have been answered.
    private func copyReplies(from connection: MCPSocketConnection) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var carry: [UInt8] = []
        while true {
            let count = read(connection.descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { return }
            carry.append(contentsOf: buffer[0..<count])
            while let newline = carry.firstIndex(of: 0x0A) {
                let line = Array(carry[0...newline])
                carry.removeSubrange(0...newline)
                answered(line)
                if !writeAll(output, line, count: line.count) { return }
            }
        }
    }

    /// A reply from the server: that request no longer waits.
    private func answered(_ line: [UInt8]) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let identifier = object["id"], object["method"] == nil else { return }
        state.lock()
        pending.removeValue(forKey: Self.key(for: identifier))
        state.unlock()
    }

    /// Answers, with an error, every request that was sent to a server that has gone.
    private func failPending(on dead: MCPSocketConnection) {
        state.lock()
        let lost = pending.filter { $0.value.connection === dead }
        for key in lost.keys { pending.removeValue(forKey: key) }
        state.unlock()
        for (_, entry) in lost {
            let reply: [String: Any] = ["jsonrpc": "2.0", "id": entry.id,
                                        "error": ["code": -32000, "message": lostRequestMessage]]
            guard let data = try? JSONSerialization.data(withJSONObject: reply) else { continue }
            let line = Array(data) + [0x0A]
            _ = writeAll(output, line, count: line.count)
        }
    }

    // MARK: - Reading requests

    /// The id of a line that is a request (it has a method and an id), which will be answered; nil for a notification,
    /// a reply the client is giving, or anything that is not JSON.
    private func requestID(in line: [UInt8]) -> (key: String, id: Any)? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              object["method"] is String, let identifier = object["id"], !(identifier is NSNull) else { return nil }
        return (Self.key(for: identifier), identifier)
    }

    /// A number and a string that look alike are different ids.
    private static func key(for identifier: Any) -> String {
        if let text = identifier as? String { return "s:" + text }
        return "n:\(identifier)"
    }
}
