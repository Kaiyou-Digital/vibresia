import Foundation
import VibresiaMCPShare

/// How `Vibresia --mcp` shares one server between every client on a Mac (`VibresiaMCPShare` does the sockets).
///
/// Each client of a stdio MCP server starts its own copy of the app, and with several AI sessions open that was
/// several copies of 150 MB, each for a process with no window. Now there is one server, and every client is a
/// small proxy that copies its stdin and stdout to it, decided before the app has started, so a proxy costs a few MB.
///
/// The server is a process of its own (`--mcp --mcp-daemon`), started by the first client, in a session of its own:
/// no client owns it. A client's process can be closed, killed or its whole process group signalled when its session
/// ends, and the other sessions' servers do not go with it. It leaves a few seconds after the last client has gone.
enum MCPLaunch {
    /// How long the server stays after the last client has gone. Short, because a client that closes stdin usually
    /// waits for its process to exit before it carries on.
    static let idleSeconds = 3.0

    /// How long a launch waits for the server it started to be there.
    static let startTimeout = 15.0

    /// In the user's caches, not the support folder: it is a file the app can always make again, and making the
    /// support folder from here could get in the way of its migration from the old name (`SupportFolder`).
    static var socketPath: String {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vibresia", isDirectory: true)
            .appendingPathComponent("mcp.sock").path
    }

    /// Called first thing when the app is launched with `--mcp`, before AppKit or SwiftUI start.
    ///
    /// A client finds the server, starting it if need be, and then never returns: it proxies until its stdin closes.
    /// The server itself returns, to carry on starting as an app without a window. If sharing is not possible a client
    /// returns too, and serves its own client alone, as it always did.
    static func begin() {
        if CommandLine.arguments.contains("--mcp-daemon") {
            becomeTheServer()
        } else {
            becomeAClient()
        }
    }

    private static func becomeAClient() {
        if let connection = MCPShare.connect(socketPath: socketPath) { proxy(connection) }

        // Nobody is serving: start the server, in a session of its own, and wait for it. Two clients doing this at
        // the same instant start two, and the one that loses the lock leaves at once (`becomeTheServer`).
        guard let executable = Bundle.main.executablePath else { return }
        do {
            _ = try MCPShare.spawnDetached(executable: executable, arguments: ["--mcp", "--mcp-daemon"])
        } catch {
            NSLog("[MCP] could not start the shared server (\(error)); serving this client alone")
            return
        }
        if let connection = MCPShare.waitForServer(socketPath: socketPath, timeout: startTimeout) { proxy(connection) }
        NSLog("[MCP] the shared server did not come up; serving this client alone")
    }

    /// Serves until nobody has been connected for a while, then exits. Never returns.
    ///
    /// This is deliberately not the app: SwiftUI and AppKit never start here. A process that starts `NSApplication`
    /// registers with macOS as a running copy of Vibresia whatever its activation policy, so opening Vibresia
    /// reactivated the server instead of starting a window, and quitting it from the Dock ended every session's
    /// server (`.accessory` and `.prohibited` both did this). Run as a plain process it is not registered at all.
    private static func becomeTheServer() -> Never {
        do {
            switch try MCPShare.claim(socketPath: socketPath, idleSeconds: idleSeconds) {
            case .server(let server):
                serve(server)
                dispatchMain() // runs the main queue, where each request is handled; `onIdle` exits
            case .proxy(let connection):
                connection.close() // another server won the race; there is nothing for this one to do
                exit(0)
            }
        } catch {
            NSLog("[MCP] the shared server could not listen (\(error))")
            exit(1)
        }
    }

    private static func proxy(_ connection: MCPSocketConnection) -> Never {
        MCPProxy.run(connection)
        exit(0)
    }

    /// Serves every client of the shared server. Each has an `MCPServer` of its own so it gets only its own replies,
    /// and its requests are handled on the main thread, in order (the tools draw with OpenGL).
    static func serve(_ server: MCPSocketServer) {
        NSLog("[MCP] serving every client, on \(socketPath)")

        server.onLine = { line, client in
            DispatchQueue.main.async { handler(for: client).process(line) }
        }
        // Queued behind the requests already read, so a client that closes its input still gets every answer.
        server.onEnd = { client in
            DispatchQueue.main.async { client.close() }
        }
        // Nobody has been connected for a while, so leave rather than hold 150 MB for no one.
        server.onIdle = {
            DispatchQueue.main.async {
                server.stop() // removes the socket, so nothing stale is left behind
                exit(0)
            }
        }
        server.start()
    }

    /// The `MCPServer` that answers one client; made on first use, on the main thread.
    private static func handler(for client: MCPClient) -> MCPServer {
        if let existing = client.userInfo as? MCPServer { return existing }
        let created = MCPServer(emit: { client.send($0) })
        client.userInfo = created
        return created
    }
}
