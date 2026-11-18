import Darwin
import Foundation

/// One connected client of the shared server: a proxy on a socket, or the server's own stdin and stdout.
public final class MCPClient {
    private let input: Int32
    private let output: Int32
    private let ownsDescriptors: Bool
    private let lock = NSLock()
    private var closed = false
    fileprivate weak var server: MCPSocketServer?

    /// Whatever the owner wants to keep with this client (for example the object that answers its requests).
    public var userInfo: AnyObject?

    init(input: Int32, output: Int32, ownsDescriptors: Bool, server: MCPSocketServer) {
        self.input = input
        self.output = output
        self.ownsDescriptors = ownsDescriptors
        self.server = server
    }

    /// Sends one line to this client. Safe from any thread; replies from different threads do not mix.
    public func send(_ text: String) {
        let bytes = Array((text + "\n").utf8)
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        _ = writeAll(output, bytes, count: bytes.count)
    }

    /// Ends this client. Safe to call more than once.
    public func close() {
        lock.lock()
        let wasOpen = !closed
        closed = true
        lock.unlock()
        guard wasOpen else { return }
        if ownsDescriptors {
            shutdown(output, SHUT_RDWR)
            Darwin.close(input)
        }
        server?.clientClosed(self)
    }

    /// Reads lines until the input ends, handing each to the server.
    fileprivate func readLines() {
        var pending: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(input, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[0..<newline], as: UTF8.self)
                pending.removeSubrange(0...newline)
                server?.deliver(line, from: self)
            }
        }
        if !pending.isEmpty { server?.deliver(String(decoding: pending, as: UTF8.self), from: self) }
        server?.ended(self)
    }
}

/// The shared server: accepts connections and hands every line to `onLine`.
///
/// It does not answer anything itself. The owner does, from `onLine`, by calling `send` on the client the line came
/// from, so each client gets only its own replies.
public final class MCPSocketServer {
    /// Called on the client's reading thread for every line. The owner may answer later, from any thread.
    public var onLine: ((String, MCPClient) -> Void)?
    /// Called when a client's input has ended. The owner closes the client once it has answered everything it was
    /// sent (it may have work still queued); with no handler the client is closed at once.
    public var onEnd: ((MCPClient) -> Void)?
    /// Called once nobody has been connected for the idle time. The owner leaves.
    public var onIdle: (() -> Void)?

    private let listeningDescriptor: Int32
    private let socketPath: String
    private let idleSeconds: Double
    private let startupGraceSeconds: Double
    private let lock = NSLock()
    private var clients: [ObjectIdentifier: MCPClient] = [:]
    private var idleWork: DispatchWorkItem?
    private var stopped = false
    private var accepting = false
    private let acceptFinished = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "vibresia.mcp.share")

    init(listening descriptor: Int32, socketPath: String, idleSeconds: Double, startupGraceSeconds: Double) {
        listeningDescriptor = descriptor
        self.socketPath = socketPath
        self.idleSeconds = idleSeconds
        self.startupGraceSeconds = startupGraceSeconds
    }

    public var clientCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return clients.count
    }

    /// Starts accepting connections.
    public func start() {
        // A client that went away must not end the process: a write to it just fails.
        signal(SIGPIPE, SIG_IGN)
        lock.lock()
        guard !accepting, !stopped else { lock.unlock(); return }
        accepting = true
        // Nobody has connected yet: if nobody ever does (whoever started this server has gone), leave after the grace.
        if clients.isEmpty { armIdle(after: startupGraceSeconds) }
        lock.unlock()
        Thread.detachNewThread { [self] in
            acceptLoop()
            acceptFinished.signal()
        }
    }

    /// Takes a pair of descriptors as a client, for the server's own stdin and stdout. They are not closed with it.
    @discardableResult
    public func adopt(input: Int32, output: Int32) -> MCPClient {
        register(MCPClient(input: input, output: output, ownsDescriptors: false, server: self))
    }

    /// Stops accepting, closes every client and removes the socket. Safe to call more than once.
    public func stop() {
        lock.lock()
        let wasAccepting = accepting
        let alreadyStopped = stopped
        stopped = true
        idleWork?.cancel()
        lock.unlock()
        guard !alreadyStopped else { return }
        if wasAccepting { _ = acceptFinished.wait(timeout: .now() + 1) }
        close(listeningDescriptor)
        unlink(socketPath)
        // Only now, once nothing is accepting: a client accepted while this waited would otherwise be missed and left
        // open, and its other end would wait for ever.
        lock.lock()
        let open = Array(clients.values)
        lock.unlock()
        open.forEach { $0.close() }
    }

    // MARK: - Inside

    private func acceptLoop() {
        while true {
            lock.lock()
            let done = stopped
            lock.unlock()
            if done { return }
            var descriptor = pollfd(fd: listeningDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100) // wakes often enough to notice `stop`
            if ready < 0, errno != EINTR { return }
            guard ready > 0 else { continue }
            let connection = accept(listeningDescriptor, nil, nil)
            if connection < 0 { continue }
            var on: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            register(MCPClient(input: connection, output: connection, ownsDescriptors: true, server: self))
        }
    }

    @discardableResult
    private func register(_ client: MCPClient) -> MCPClient {
        lock.lock()
        clients[ObjectIdentifier(client)] = client
        idleWork?.cancel()
        idleWork = nil
        lock.unlock()
        Thread.detachNewThread { client.readLines() }
        return client
    }

    fileprivate func deliver(_ line: String, from client: MCPClient) {
        onLine?(line, client)
    }

    fileprivate func ended(_ client: MCPClient) {
        if let onEnd { onEnd(client) } else { client.close() }
    }

    fileprivate func clientClosed(_ client: MCPClient) {
        lock.lock()
        clients.removeValue(forKey: ObjectIdentifier(client))
        let nobodyLeft = clients.isEmpty && !stopped
        if nobodyLeft { armIdle(after: idleSeconds) }
        lock.unlock()
    }

    /// Starts the countdown to `onIdle`. Called with the lock held.
    private func armIdle(after seconds: Double) {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.idleElapsed() }
        idleWork = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func idleElapsed() {
        lock.lock()
        let stillIdle = clients.isEmpty && !stopped
        lock.unlock()
        if stillIdle { onIdle?() }
    }
}
