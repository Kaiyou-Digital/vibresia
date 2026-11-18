import Darwin
import Foundation

/// Lets every `Vibresia --mcp` on a Mac share one server.
///
/// A stdio MCP server is started once per client, so with several AI sessions open there were several copies of the
/// whole app, each holding about 150 MB for a process with no window. Here the first launch takes a lock and listens
/// on a Unix socket in the user's own folder; a launch that finds it connects and only copies its stdin and stdout to
/// the socket, which costs a few MB. The socket is not a network port, nothing outside this Mac can reach it, and
/// another user cannot connect to it (mode 0600).
///
/// Taking the lock and listening happen together, under one lock, so two launches at the same instant cannot both
/// become the server, and a launch that arrives a moment later always finds a server to connect to. A socket file
/// left behind by a server that died is replaced.
public enum MCPShare {
    public enum Claim {
        /// Nobody was serving; this process is now listening and must serve.
        case server(MCPSocketServer)
        /// A server was found; this process should copy its stdin and stdout to it (`MCPProxy.run`) and leave.
        case proxy(MCPSocketConnection)
    }

    public enum ClaimError: Error {
        /// A Unix socket's path is limited to 103 bytes; a longer one is refused rather than cut short.
        case pathTooLong
        case folder(Int32)
        case lock(Int32)
        case listen(Int32)
        case spawn(Int32)
    }

    /// Decides whether this launch serves or proxies. Throws if sharing is not possible (the caller then carries on
    /// as a stdio server of its own, as before).
    ///
    /// `startupGraceSeconds` is how long a server that nobody has connected to yet waits before it gives up, so a
    /// background server whose launcher died leaves nothing running.
    public static func claim(socketPath: String, idleSeconds: Double = 5, startupGraceSeconds: Double = 10) throws -> Claim {
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw ClaimError.pathTooLong
        }
        try makeFolder((socketPath as NSString).deletingLastPathComponent)

        let lockDescriptor = open(socketPath + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lockDescriptor >= 0 else { throw ClaimError.lock(errno) }
        defer { close(lockDescriptor) } // closing it releases the lock
        guard flock(lockDescriptor, LOCK_EX) == 0 else { throw ClaimError.lock(errno) }

        if let descriptor = connectSocket(socketPath) {
            return .proxy(MCPSocketConnection(descriptor: descriptor))
        }
        unlink(socketPath) // nobody answers, so any file here was left by a server that died
        return .server(MCPSocketServer(listening: try listenSocket(socketPath), socketPath: socketPath,
                                       idleSeconds: idleSeconds, startupGraceSeconds: startupGraceSeconds))
    }

    /// Connects to a server that is already running, without ever becoming one. Nil if nobody is serving.
    public static func connect(socketPath: String) -> MCPSocketConnection? {
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path),
              let descriptor = connectSocket(socketPath) else { return nil }
        return MCPSocketConnection(descriptor: descriptor)
    }

    /// Waits up to `timeout` seconds for a server to be there, as one that is still starting will be.
    public static func waitForServer(socketPath: String, timeout: Double) -> MCPSocketConnection? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let connection = connect(socketPath: socketPath) { return connection }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return connect(socketPath: socketPath)
    }

    /// Starts a program that no client owns: in a session of its own, so that killing the process that started it, or
    /// that process's group, does not take it down, and with stdin, stdout and stderr on /dev/null. Returns its pid.
    public static func spawnDetached(executable: String, arguments: [String]) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(0x0400)) // POSIX_SPAWN_SETSID

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        let arguments: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { arguments.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, arguments, environ)
        guard result == 0 else { throw ClaimError.spawn(result) }
        return pid
    }

    // MARK: - Sockets

    private static func makeFolder(_ folder: String) throws {
        // Created private; a folder that already exists (the app's own support folder) is left as it is, since the
        // socket is private on its own.
        if mkdir(folder, 0o700) != 0, errno != EEXIST {
            // A parent may be missing: create the whole path.
            do {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                throw ClaimError.folder(errno)
            }
        }
    }

    private static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.withCString { buffer.baseAddress!.copyMemory(from: $0, byteCount: path.utf8.count + 1) }
        }
        return address
    }

    private static func connectSocket(_ path: String) -> Int32? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var target = address(path)
        let connected = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(descriptor)
            return nil
        }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return descriptor
    }

    private static func listenSocket(_ path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ClaimError.listen(errno) }
        var target = address(path)
        let previous = umask(0o177) // so the socket is never visible to others, even for an instant
        let bound = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previous)
        guard bound == 0 else {
            let reason = errno
            close(descriptor)
            throw ClaimError.listen(reason)
        }
        chmod(path, 0o600)
        guard listen(descriptor, 32) == 0 else {
            let reason = errno
            close(descriptor)
            unlink(path)
            throw ClaimError.listen(reason)
        }
        return descriptor
    }
}

/// A connected socket, as a proxy holds it.
public final class MCPSocketConnection {
    let descriptor: Int32
    private let lock = NSLock()
    private var closed = false

    init(descriptor: Int32) { self.descriptor = descriptor }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(descriptor)
    }

    deinit { close() }
}

/// What a proxy does: copy stdin to the server and the server's replies to stdout.
public enum MCPProxy {
    /// Returns when the server has finished replying after stdin closed, or the server goes away. The caller exits.
    public static func run(_ connection: MCPSocketConnection, input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) {
        let descriptor = connection.descriptor
        // stdin to the server, on a thread of its own; when stdin ends, tell the server so it can finish and close.
        Thread.detachNewThread {
            copy(from: input, to: descriptor)
            shutdown(descriptor, SHUT_WR)
        }
        copy(from: descriptor, to: output)
        connection.close()
    }

    /// Copies until the source ends or the destination cannot be written.
    private static func copy(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(source, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { return }
            if !writeAll(destination, buffer, count: count) { return }
        }
    }
}

/// Writes every byte, or reports that it could not.
func writeAll(_ descriptor: Int32, _ bytes: [UInt8], count: Int) -> Bool {
    var offset = 0
    while offset < count {
        let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress! + offset, count - offset) }
        if written < 0, errno == EINTR { continue }
        if written <= 0 { return false }
        offset += written
    }
    return true
}
