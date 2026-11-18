import Darwin
import Foundation
import Testing
@testable import VibresiaMCPShare

/// Every test here uses real sockets, real pipes and real threads, in a folder of its own: what could go wrong is
/// timing, locking and the operating system, which a stand-in would not reproduce.
@Suite("Sharing one MCP server", .serialized)
struct MCPShareTests {
    // MARK: - Helpers

    /// A short path (a Unix socket's path is limited to 104 bytes) in a folder that is removed afterwards.
    private func scratchSocketPath() -> String {
        let folder = "/tmp/vms-" + UUID().uuidString.prefix(8)
        return folder + "/mcp.sock"
    }

    private func cleanUp(_ path: String) {
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    /// A pipe: (read end, write end).
    private func makePipe() -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        return (fds[0], fds[1])
    }

    private func write(_ text: String, to fd: Int32) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, bytes.count) }
    }

    /// Reads `count` lines from `fd`, waiting at most `timeout` seconds in all.
    private func readLines(_ fd: Int32, count: Int, timeout: Double = 5) -> [String] {
        var lines: [String] = []
        var pending = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while lines.count < count, Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 100) > 0 else { continue }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let got = read(fd, &buffer, buffer.count)
            if got <= 0 { break }
            pending.append(contentsOf: buffer[0..<got])
            while let newline = pending.firstIndex(of: 0x0A) {
                lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        return lines
    }

    private func claimServer(_ path: String, idleSeconds: Double = 5) throws -> MCPSocketServer {
        guard case .server(let server) = try MCPShare.claim(socketPath: path, idleSeconds: idleSeconds) else {
            throw TestFailure("expected to become the server")
        }
        return server
    }

    private func claimProxyConnection(_ path: String) throws -> MCPSocketConnection {
        guard case .proxy(let connection) = try MCPShare.claim(socketPath: path) else {
            throw TestFailure("expected to find a server and become a proxy")
        }
        return connection
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Runs a proxy on its own thread between two pipes; returns the ends the test uses.
    private func startProxy(_ connection: MCPSocketConnection)
        -> (stdin: Int32, stdout: Int32, finished: DispatchSemaphore) {
        let input = makePipe(), output = makePipe()
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            MCPProxy.run(connection, input: input.read, output: output.write)
            close(output.write)
            finished.signal()
        }
        return (input.write, output.read, finished)
    }

    // MARK: - Who is the server

    @Test("The first launch becomes the server")
    func firstClaimIsTheServer() throws {
        let path = scratchSocketPath()
        defer { cleanUp(path) }
        let server = try claimServer(path)
        server.stop()
    }

    @Test("A later launch finds the server and becomes a proxy")
    func secondClaimIsAProxy() throws {
        let path = scratchSocketPath()
        defer { cleanUp(path) }
        let server = try claimServer(path)
        server.start()
        defer { server.stop() }

        let connection = try claimProxyConnection(path)
        connection.close()
    }

    @Test("A socket left behind by a server that died is replaced")
    func staleSocketIsReplaced() throws {
        let path = scratchSocketPath()
        defer { cleanUp(path) }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        // A socket file with nobody listening: bind, then close without removing the file.
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { source in
            withUnsafeMutableBytes(of: &address.sun_path) { $0.baseAddress!.copyMemory(from: source, byteCount: path.utf8.count + 1) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        close(stale)
        #expect(FileManager.default.fileExists(atPath: path), "the dead server left its socket file")

        let server = try claimServer(path)
        server.stop()
    }

    @Test("Many launches at the same instant give exactly one server")
    func simultaneousClaimsGiveOneServer() throws {
        for round in 0..<5 {
            let path = scratchSocketPath()
            defer { cleanUp(path) }
            let launches = 16
            let ready = DispatchSemaphore(value: 0)
            let go = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var servers: [MCPSocketServer] = []
            var proxies: [MCPSocketConnection] = []
            var failures: [String] = []
            let done = DispatchGroup()
            for _ in 0..<launches {
                done.enter()
                Thread.detachNewThread {
                    ready.signal()
                    go.wait()
                    do {
                        switch try MCPShare.claim(socketPath: path) {
                        case .server(let server):
                            server.start()
                            lock.lock(); servers.append(server); lock.unlock()
                        case .proxy(let connection):
                            lock.lock(); proxies.append(connection); lock.unlock()
                        }
                    } catch {
                        lock.lock(); failures.append("\(error)"); lock.unlock()
                    }
                    done.leave()
                }
            }
            for _ in 0..<launches { ready.wait() }
            for _ in 0..<launches { go.signal() }
            #expect(done.wait(timeout: .now() + 20) == .success, "round \(round): every launch finished")
            #expect(failures.isEmpty, "round \(round): \(failures)")
            #expect(servers.count == 1, "round \(round): \(servers.count) servers")
            #expect(proxies.count == launches - 1, "round \(round): \(proxies.count) proxies")
            proxies.forEach { $0.close() }
            servers.forEach { $0.stop() }
        }
    }

    @Test("Stopping the server also closes a client it had not got round to accepting")
    func stopClosesClientsStillQueued() throws {
        let path = scratchSocketPath()
        defer { cleanUp(path) }
        let server = try claimServer(path) // listening, but never started: nothing accepts
        let connection = try #require(MCPShare.connect(socketPath: path))
        defer { connection.close() }
        server.stop()

        var descriptor = pollfd(fd: connection.descriptor, events: Int16(POLLIN), revents: 0)
        #expect(poll(&descriptor, 1, 2000) > 0, "the client was told the server had gone")
        var byte: UInt8 = 0
        #expect(read(connection.descriptor, &byte, 1) <= 0, "as an end of input, not as data")
    }

    @Test("Stopping the server closes every client, even one that is just being accepted")
    func stopClosesAClientBeingAccepted() throws {
        for round in 0..<60 {
            let path = scratchSocketPath()
            defer { cleanUp(path) }
            let server = try claimServer(path)
            server.start()
            let connection = try #require(MCPShare.connect(socketPath: path))
            defer { connection.close() }
            Thread.sleep(forTimeInterval: Double(round % 6) * 0.02) // land the stop at different points of the accept loop
            server.stop()

            var descriptor = pollfd(fd: connection.descriptor, events: Int16(POLLIN), revents: 0)
            #expect(poll(&descriptor, 1, 2000) > 0, "round \(round): the client was told the server had gone")
        }
    }

    @Test("A server that leaves does not remove the socket of a newer one")
    func stopLeavesANewerServersSocketAlone() throws {
        let path = scratchSocketPath()
        defer { cleanUp(path) }
        let first = try claimServer(path)
        first.start()
        unlink(path) // the socket vanishes under a live server (a cache cleaner, say)
        let second = try claimServer(path) // nobody answers, so this one makes a socket of its own
        second.start()
        defer { second.stop() }

        first.stop() // the older one leaves
        let connection = MCPShare.connect(socketPath: path)
        #expect(connection != nil, "the newer server can still be reached")
        connection?.close()
    }

    @Test("The socket and its folder are private to the user")
    func socketIsPrivate() throws {
        let path = scratchSocketPath()
        defer { cleanUp(path) }
        let server = try claimServer(path)
        defer { server.stop() }

        var info = stat()
        #expect(stat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600, "socket mode \(String(info.st_mode & 0o777, radix: 8))")
        #expect(stat((path as NSString).deletingLastPathComponent, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700, "folder mode \(String(info.st_mode & 0o777, radix: 8))")
    }

    @Test("A path too long for a Unix socket is refused, not truncated")
    func longPathThrows() {
        let path = "/tmp/" + String(repeating: "x", count: 120) + "/mcp.sock"
        #expect(throws: MCPShare.ClaimError.self) { try MCPShare.claim(socketPath: path) }
    }

    // MARK: - Carrying messages

    @Test("A proxy carries lines to the server and the replies back, in order")
    func proxyCarriesLinesBothWays() throws {
        let path = scratchSocketPath()
        defer { cleanUp(path) }
        let server = try claimServer(path)
        server.onLine = { line, client in client.send("echo:" + line) }
        server.start()
        defer { server.stop() }

        let proxy = startProxy(try claimProxyConnection(path))
        for number in 0..<200 { write("line \(number)\n", to: proxy.stdin) }
        let replies = readLines(proxy.stdout, count: 200)
        #expect(replies == (0..<200).map { "echo:line \($0)" })
        close(proxy.stdin)
        #expect(proxy.finished.wait(timeout: .now() + 5) == .success, "the proxy leaves when its stdin closes")
    }

    @Test("Two clients each get only their own replies")
    func clientsAreIndependent() throws {
        let path = scratchSocketPath()
        defer { cleanUp(path) }
        let server = try claimServer(path)
        server.onLine = { line, client in client.send("echo:" + line) }
        server.start()
        defer { server.stop() }

        let first = startProxy(try claimProxyConnection(path))
        let second = startProxy(try claimProxyConnection(path))
        for number in 0..<50 {
            write("a\(number)\n", to: first.stdin)
            write("b\(number)\n", to: second.stdin)
        }
        #expect(readLines(first.stdout, count: 50) == (0..<50).map { "echo:a\($0)" })
        #expect(readLines(second.stdout, count: 50) == (0..<50).map { "echo:b\($0)" })
        close(first.stdin)
        close(second.stdin)
    }

    @Test("A client that closes its input still gets the replies still being worked on")
    func repliesFinishAfterInputCloses() throws {
        let path = scratchSocketPath()
        defer { cleanUp(path) }
        let server = try claimServer(path)
        // Replies come late, as a tool that draws a picture would; the end of the input is acted on after them.
        server.onLine = { line, client in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { client.send("echo:" + line) }
        }
        server.onEnd = { client in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { client.close() }
        }
        server.start()
        defer { server.stop() }

        let proxy = startProxy(try claimProxyConnection(path))
        for number in 0..<5 { write("slow \(number)\n", to: proxy.stdin) }
        close(proxy.stdin)
        // They are answered on a concurrent queue, so they may arrive in any order; that every one arrives is the point.
        #expect(readLines(proxy.stdout, count: 5).sorted() == (0..<5).map { "echo:slow \($0)" })
        #expect(proxy.finished.wait(timeout: .now() + 5) == .success)
    }

    @Test("The server's own stdin and stdout are a client like any other")
    func adoptedStdioIsAClient() throws {
        let path = scratchSocketPath()
        defer { cleanUp(path) }
        let server = try claimServer(path)
        server.onLine = { line, client in client.send("echo:" + line) }
        server.start()
        defer { server.stop() }

        let input = makePipe(), output = makePipe()
        _ = server.adopt(input: input.read, output: output.write)
        write("hello\n", to: input.write)
        #expect(readLines(output.read, count: 1) == ["echo:hello"])
        #expect(server.clientCount == 1)
        close(input.write)
    }

    // MARK: - Leaving

    @Test("The server leaves after nobody has been connected for the idle time, not before")
    func idleExit() throws {
        let path = scratchSocketPath()
        defer { cleanUp(path) }
        let server = try claimServer(path, idleSeconds: 0.4)
        server.onLine = { line, client in client.send("echo:" + line) }
        let idled = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var idleAt: Date?
        server.onIdle = { lock.lock(); idleAt = Date(); lock.unlock(); idled.signal() }
        server.start()
        defer { server.stop() }

        let proxy = startProxy(try claimProxyConnection(path))
        write("x\n", to: proxy.stdin)
        _ = readLines(proxy.stdout, count: 1)
        #expect(idled.wait(timeout: .now() + 0.6) == .timedOut, "not while a client is connected")

        let closedAt = Date()
        close(proxy.stdin)
        #expect(idled.wait(timeout: .now() + 3) == .success, "it leaves once nobody is connected")
        lock.lock(); let elapsed = idleAt!.timeIntervalSince(closedAt); lock.unlock()
        #expect(elapsed >= 0.35, "waited the idle time first: \(elapsed)")
    }

    @Test("A client arriving during the idle time cancels the exit")
    func newClientCancelsIdleExit() throws {
        let path = scratchSocketPath()
        defer { cleanUp(path) }
        let server = try claimServer(path, idleSeconds: 0.5)
        server.onLine = { line, client in client.send("echo:" + line) }
        let idled = DispatchSemaphore(value: 0)
        server.onIdle = { idled.signal() }
        server.start()
        defer { server.stop() }

        let first = startProxy(try claimProxyConnection(path))
        write("x\n", to: first.stdin)
        _ = readLines(first.stdout, count: 1)
        close(first.stdin)
        Thread.sleep(forTimeInterval: 0.2)
        let second = startProxy(try claimProxyConnection(path))
        write("y\n", to: second.stdin)
        #expect(readLines(second.stdout, count: 1) == ["echo:y"])
        #expect(idled.wait(timeout: .now() + 0.9) == .timedOut, "the second client kept the server alive")
        close(second.stdin)
    }

    // MARK: - A server of its own, that no client owns

    @Test("Connecting finds nothing when nobody is serving, and never becomes the server")
    func connectFindsNothingWhenNobodyServes() throws {
        let path = scratchSocketPath()
        defer { cleanUp(path) }
        #expect(MCPShare.connect(socketPath: path) == nil)
        #expect(!FileManager.default.fileExists(atPath: path), "looking must not leave a socket behind")
    }

    @Test("Connecting finds a server that is there")
    func connectFindsAServer() throws {
        let path = scratchSocketPath()
        defer { cleanUp(path) }
        let server = try claimServer(path)
        server.start()
        defer { server.stop() }
        let connection = try #require(MCPShare.connect(socketPath: path))
        connection.close()
    }

    @Test("Waiting returns the connection when a server appears, and gives up after the timeout")
    func waitForServer() throws {
        let path = scratchSocketPath()
        defer { cleanUp(path) }
        let started = Date()
        #expect(MCPShare.waitForServer(socketPath: path, timeout: 0.4) == nil)
        #expect(Date().timeIntervalSince(started) >= 0.4, "it waited the whole time")

        // A server that appears 0.3 s from now, as a background server does while it starts.
        let appeared = DispatchSemaphore(value: 0)
        var held: MCPSocketServer?
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.3)
            held = try? self.claimServer(path)
            held?.start()
            appeared.signal()
        }
        let connection = try #require(MCPShare.waitForServer(socketPath: path, timeout: 5))
        connection.close()
        appeared.wait()
        held?.stop()
    }

    @Test("A server nobody ever connects to leaves after the start-up grace, so a failed launch leaves nothing running")
    func startupGraceWithoutAnyClient() throws {
        let path = scratchSocketPath()
        defer { cleanUp(path) }
        guard case .server(let server) = try MCPShare.claim(socketPath: path, idleSeconds: 5, startupGraceSeconds: 0.4) else {
            throw TestFailure("expected to become the server")
        }
        let idled = DispatchSemaphore(value: 0)
        server.onIdle = { idled.signal() }
        let started = Date()
        server.start()
        defer { server.stop() }
        #expect(idled.wait(timeout: .now() + 3) == .success, "it left although nobody ever connected")
        #expect(Date().timeIntervalSince(started) >= 0.35, "after the grace, not at once")
    }

    @Test("A client connecting during the start-up grace keeps the server")
    func clientInTheGraceKeepsTheServer() throws {
        let path = scratchSocketPath()
        defer { cleanUp(path) }
        guard case .server(let server) = try MCPShare.claim(socketPath: path, idleSeconds: 5, startupGraceSeconds: 0.5) else {
            throw TestFailure("expected to become the server")
        }
        server.onLine = { line, client in client.send("echo:" + line) }
        let idled = DispatchSemaphore(value: 0)
        server.onIdle = { idled.signal() }
        server.start()
        defer { server.stop() }
        let proxy = startProxy(try claimProxyConnection(path))
        write("x\n", to: proxy.stdin)
        #expect(readLines(proxy.stdout, count: 1) == ["echo:x"])
        #expect(idled.wait(timeout: .now() + 1.0) == .timedOut, "the grace was over, but a client is connected")
        close(proxy.stdin)
    }

    @Test("A detached process runs in a session of its own, with its stdio on /dev/null")
    func spawnDetached() throws {
        let folder = "/tmp/vms-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let report = folder + "/report.txt"
        // It reports its own session id and what its stdin is (lsof), then ends.
        let script = "ps -o sess= -p $$ > '\(report)'; lsof -a -p $$ -d 0 -Fn >> '\(report)' 2>&1; exit 0"
        let pid = try MCPShare.spawnDetached(executable: "/bin/sh", arguments: ["-c", script])
        #expect(pid > 0)

        var text = ""
        for _ in 0..<50 {
            text = (try? String(contentsOfFile: report, encoding: .utf8)) ?? ""
            if text.contains("/dev/null") { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let session = Int32(text.split(separator: "\n").first?.trimmingCharacters(in: .whitespaces) ?? "")
        #expect(session != nil && session != getsid(0), "its own session, not ours: \(text)")
        #expect(text.contains("/dev/null"), "stdin is /dev/null: \(text)")
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }

    @Test("Starting a program that does not exist is reported, not ignored")
    func spawnDetachedFailure() {
        #expect(throws: MCPShare.ClaimError.self) {
            try MCPShare.spawnDetached(executable: "/nonexistent/vibresia", arguments: [])
        }
    }
}
