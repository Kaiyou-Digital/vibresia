import Darwin
import Foundation
import Testing
@testable import VibresiaMCPShare

/// A client that outlives its server: real sockets, pipes and threads, as in `MCPShareTests`.
///
/// The server keeps nothing per session, so a client can start a new one and carry on; a request that was waiting for
/// an answer when the server went is answered with an error at once, because that answer is never coming.
@Suite("A client that outlives its server", .serialized)
struct MCPReconnectTests {
    // MARK: - Helpers

    private func scratchSocketPath() -> String {
        "/tmp/vmr-" + UUID().uuidString.prefix(8) + "/mcp.sock"
    }

    private func cleanUp(_ path: String) {
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    private func makePipe() -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        return (fds[0], fds[1])
    }

    private func write(_ text: String, to fd: Int32) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, bytes.count) }
    }

    private func send(_ message: [String: Any], to fd: Int32) throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        write(String(decoding: data, as: UTF8.self) + "\n", to: fd)
    }

    /// Reads up to `count` lines as JSON objects, waiting at most `timeout` seconds in all.
    private func readMessages(_ fd: Int32, count: Int, timeout: Double = 8) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        var pending = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while messages.count < count, Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 100) > 0 else { continue }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let got = read(fd, &buffer, buffer.count)
            if got <= 0 { break }
            pending.append(contentsOf: buffer[0..<got])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { messages.append(object) }
            }
        }
        return messages
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// A server that answers every request that has an id with `{"result": {"server": <tag>, "method": ...}}`, except
    /// `slow`, which it never answers (a request still being worked on when the server goes).
    private func startServer(_ path: String, tag: Int) throws -> MCPSocketServer {
        guard case .server(let server) = try MCPShare.claim(socketPath: path, idleSeconds: 30) else {
            throw TestFailure("expected to become the server")
        }
        server.onLine = { line, client in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let identifier = object["id"], let method = object["method"] as? String, method != "slow",
                  let data = try? JSONSerialization.data(withJSONObject: [
                      "jsonrpc": "2.0", "id": identifier, "result": ["server": tag, "method": method],
                  ]) else { return }
            client.send(String(decoding: data, as: UTF8.self))
        }
        server.start()
        return server
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Runs a proxy on its own thread between two pipes.
    private func startProxy(_ connection: MCPSocketConnection, reconnect: (() -> MCPSocketConnection?)?)
        -> (stdin: Int32, stdout: Int32, finished: DispatchSemaphore) {
        let input = makePipe(), output = makePipe()
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            MCPProxy.run(connection, input: input.read, output: output.write, reconnect: reconnect)
            close(output.write)
            finished.signal()
        }
        return (input.write, output.read, finished)
    }

    private func result(_ message: [String: Any]) -> (server: Int, method: String)? {
        guard let result = message["result"] as? [String: Any], let server = result["server"] as? Int,
              let method = result["method"] as? String else { return nil }
        return (server, method)
    }

    // MARK: - Carrying on

    @Test("A request after the server died is answered by a new one")
    func newServerAnswersAfterTheOldOneDied() throws {
        let path = scratchSocketPath()
        defer { cleanUp(path) }
        let first = try startServer(path, tag: 1)
        var second: MCPSocketServer?
        let restarts = Counter()
        let proxy = startProxy(try #require(MCPShare.connect(socketPath: path))) {
            restarts.increment()
            second = try? self.startServer(path, tag: 2) // what the app does: start a server and connect to it
            return MCPShare.waitForServer(socketPath: path, timeout: 5)
        }
        defer { second?.stop() }

        try send(["jsonrpc": "2.0", "id": 1, "method": "ping"], to: proxy.stdin)
        #expect(readMessages(proxy.stdout, count: 1).compactMap(result).first?.server == 1)

        first.stop() // the server dies
        try send(["jsonrpc": "2.0", "id": 2, "method": "ping"], to: proxy.stdin)
        let answered = readMessages(proxy.stdout, count: 1)
        #expect(answered.first?["id"] as? Int == 2)
        #expect(result(try #require(answered.first))?.server == 2, "answered by the new server: \(answered)")
        #expect(restarts.count == 1)
        close(proxy.stdin)
        #expect(proxy.finished.wait(timeout: .now() + 5) == .success)
    }

    @Test("A request still waiting when the server dies is answered with an error, ids kept as they were")
    func requestInFlightGetsAnError() throws {
        let path = scratchSocketPath()
        defer { cleanUp(path) }
        let first = try startServer(path, tag: 1)
        var second: MCPSocketServer?
        let proxy = startProxy(try #require(MCPShare.connect(socketPath: path))) {
            second = try? self.startServer(path, tag: 2)
            return MCPShare.waitForServer(socketPath: path, timeout: 5)
        }
        defer { second?.stop() }

        try send(["jsonrpc": "2.0", "id": 7, "method": "slow"], to: proxy.stdin)
        try send(["jsonrpc": "2.0", "id": "abc-1", "method": "slow"], to: proxy.stdin)
        Thread.sleep(forTimeInterval: 0.3) // both have reached the server, which will never answer
        first.stop()

        let errors = readMessages(proxy.stdout, count: 2)
        #expect(errors.count == 2, "both requests were answered: \(errors)")
        let byIdentifier = Dictionary(uniqueKeysWithValues: errors.compactMap { message -> (String, [String: Any])? in
            guard let error = message["error"] as? [String: Any] else { return nil }
            return ("\(message["id"] ?? "nil")", error)
        })
        #expect(byIdentifier["7"] != nil, "a number id came back as a number: \(errors)")
        #expect(byIdentifier["abc-1"] != nil, "a string id came back as a string: \(errors)")
        #expect(byIdentifier["7"]?["code"] as? Int == -32000)
        #expect((byIdentifier["7"]?["message"] as? String)?.contains("try it again") == true)
        close(proxy.stdin)
    }

    @Test("A notification, which expects no answer, never gets an error")
    func notificationsAreNotAnsweredWithErrors() throws {
        let path = scratchSocketPath()
        defer { cleanUp(path) }
        let first = try startServer(path, tag: 1)
        var second: MCPSocketServer?
        let proxy = startProxy(try #require(MCPShare.connect(socketPath: path))) {
            second = try? self.startServer(path, tag: 2)
            return MCPShare.waitForServer(socketPath: path, timeout: 5)
        }
        defer { second?.stop() }

        try send(["jsonrpc": "2.0", "method": "notifications/initialized"], to: proxy.stdin)
        Thread.sleep(forTimeInterval: 0.2)
        first.stop()
        try send(["jsonrpc": "2.0", "id": 1, "method": "ping"], to: proxy.stdin)
        let messages = readMessages(proxy.stdout, count: 2, timeout: 3)
        #expect(messages.count == 1, "only the ping is answered: \(messages)")
        #expect(messages.first?["error"] == nil)
        close(proxy.stdin)
    }

    @Test("A request that was answered is not given an error when the server dies later")
    func answeredRequestsAreNotErroredLater() throws {
        let path = scratchSocketPath()
        defer { cleanUp(path) }
        let first = try startServer(path, tag: 1)
        var second: MCPSocketServer?
        let proxy = startProxy(try #require(MCPShare.connect(socketPath: path))) {
            second = try? self.startServer(path, tag: 2)
            return MCPShare.waitForServer(socketPath: path, timeout: 5)
        }
        defer { second?.stop() }

        try send(["jsonrpc": "2.0", "id": 1, "method": "ping"], to: proxy.stdin)
        #expect(readMessages(proxy.stdout, count: 1).count == 1)
        first.stop()
        try send(["jsonrpc": "2.0", "id": 2, "method": "ping"], to: proxy.stdin)
        let later = readMessages(proxy.stdout, count: 2, timeout: 3)
        #expect(later.count == 1 && later.first?["id"] as? Int == 2, "nothing for request 1 but its answer: \(later)")
        close(proxy.stdin)
    }

    @Test("A request sent while the server is being restarted waits for the new one")
    func requestDuringRestartWaits() throws {
        let path = scratchSocketPath()
        defer { cleanUp(path) }
        let first = try startServer(path, tag: 1)
        var second: MCPSocketServer?
        let proxy = startProxy(try #require(MCPShare.connect(socketPath: path))) {
            Thread.sleep(forTimeInterval: 0.6) // a server that is slow to come up
            second = try? self.startServer(path, tag: 2)
            return MCPShare.waitForServer(socketPath: path, timeout: 5)
        }
        defer { second?.stop() }

        first.stop()
        // Let the client notice the loss: a request sent in the very instant the server goes is one it was waiting on,
        // and gets the error (`requestInFlightGetsAnError`); this one is sent while the new server is starting.
        Thread.sleep(forTimeInterval: 0.25)
        try send(["jsonrpc": "2.0", "id": 5, "method": "ping"], to: proxy.stdin)
        let answered = readMessages(proxy.stdout, count: 1)
        #expect(answered.first?["id"] as? Int == 5)
        #expect(answered.first.flatMap(result)?.server == 2, "waited for the new server rather than failing: \(answered)")
        close(proxy.stdin)
    }

    // MARK: - Leaving

    @Test("A client leaves if no server can be started")
    func givesUpWhenNoServerCanBeStarted() throws {
        let path = scratchSocketPath()
        defer { cleanUp(path) }
        let first = try startServer(path, tag: 1)
        let proxy = startProxy(try #require(MCPShare.connect(socketPath: path))) { nil }
        first.stop()
        #expect(proxy.finished.wait(timeout: .now() + 5) == .success, "it left rather than waiting for ever")
        close(proxy.stdin)
    }

    @Test("A client whose own input closed leaves without restarting anything")
    func inputClosingDoesNotRestartTheServer() throws {
        let path = scratchSocketPath()
        defer { cleanUp(path) }
        let server = try startServer(path, tag: 1)
        defer { server.stop() }
        let restarts = Counter()
        let proxy = startProxy(try #require(MCPShare.connect(socketPath: path))) {
            restarts.increment()
            return nil
        }
        try send(["jsonrpc": "2.0", "id": 1, "method": "ping"], to: proxy.stdin)
        #expect(readMessages(proxy.stdout, count: 1).count == 1)
        close(proxy.stdin)
        #expect(proxy.finished.wait(timeout: .now() + 5) == .success)
        #expect(restarts.count == 0, "ending normally is not a reason to restart the server")
    }
}
