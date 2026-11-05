import Foundation
import Network
import VigilCore

/// Vigil's live agent server: MCP over HTTP ("Streamable HTTP", JSON responses) on 127.0.0.1 only.
///
/// Security:
///  - Bound to the loopback interface; non-loopback peers are dropped.
///  - Every request needs `Authorization: Bearer <token>` for a registered agent (stored as a hash).
///  - Requests carrying an `Origin` header (i.e. from a web page) are refused, and the `Host` header
///    must be 127.0.0.1/localhost on this port, so a website can't reach it via DNS rebinding.
///  - Headers ≤ 16 KB, body ≤ 1 MB, 10 s to send a request; one request per connection.
public final class AgentHTTPServer {
    public static let defaultPort: UInt16 = 47610

    private let store: VigilStore
    private let queue = DispatchQueue(label: "dev.vigil.agent-server")
    private var listener: NWListener?
    public private(set) var port: UInt16 = 0
    /// Called on the main queue after an agent makes a request (for "last used" and live UI).
    public var onRequest: ((AgentToken) -> Void)?

    public init(storePath: String) throws {
        store = try VigilStore(path: storePath)
    }

    /// Starts listening on 127.0.0.1:`port` (0 = any free port, for tests). Throws if the port is taken.
    public func start(port: UInt16 = AgentHTTPServer.defaultPort) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        guard let p = l.port?.rawValue, p != 0 else { l.cancel(); throw ToolError(message: "Port \(port) is unavailable.") }
        listener = l
        self.port = p
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: Connection handling

    private func accept(_ c: NWConnection) {
        guard case let .hostPort(host, _) = c.endpoint, Self.isLoopback(host) else { c.cancel(); return }
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak c] in c?.cancel() }   // slow-loris guard
        read(c, buffer: Data())
    }

    static func isLoopback(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || (a.rawValue.prefix(12) == Data([0,0,0,0,0,0,0,0,0,0,0xff,0xff]) && a.rawValue.last.map { _ in a.rawValue[12] == 127 } == true)
        default: return false
        }
    }

    private func read(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if error != nil { c.cancel(); return }
            guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if buf.count > 16 * 1024 || done { self.respond(c, 431, ["error": "Request headers too large"]) } else { self.read(c, buffer: buf) }
                return
            }
            guard let head = String(data: buf[..<headerEnd.lowerBound], encoding: .utf8) else { self.respond(c, 400, ["error": "Bad request"]); return }
            let req = HTTPRequest(head)
            let length = Int(req.headers["content-length"] ?? "0") ?? -1
            guard length >= 0, length <= 1 << 20 else { self.respond(c, 413, ["error": "Body too large"]); return }
            let body = buf[headerEnd.upperBound...]
            if body.count < length {
                if done { self.respond(c, 400, ["error": "Truncated body"]) } else { self.read(c, buffer: buf) }
                return
            }
            self.handle(c, req, Data(body.prefix(length)))
        }
    }

    private func handle(_ c: NWConnection, _ req: HTTPRequest, _ body: Data) {
        // Browsers always send Origin on cross-site requests; agents don't. Refuse anything from a web page.
        if req.headers["origin"] != nil { return respond(c, 403, ["error": "Requests from web pages are not allowed"]) }
        let host = req.headers["host"] ?? ""
        guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)" || host == "[::1]:\(port)" else {
            return respond(c, 421, ["error": "Wrong host"])
        }
        guard req.path == "/mcp" || req.path.hasPrefix("/mcp?") else { return respond(c, 404, ["error": "Not found. Use POST /mcp"]) }
        guard req.method == "POST" else { return respond(c, 405, ["error": "Use POST"], extra: ["Allow": "POST"]) }
        guard let auth = req.headers["authorization"], auth.lowercased().hasPrefix("bearer "),
              let agent = store.agent(forToken: String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)) else {
            return respond(c, 401, ["error": "Missing or unknown token. Add this agent in Vigil → Agents."], extra: ["WWW-Authenticate": "Bearer"])
        }
        store.touchAgent(id: agent.id)
        DispatchQueue.main.async { self.onRequest?(agent) }

        guard let json = try? JSONSerialization.jsonObject(with: body) else {
            return respond(c, 400, ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"] as [String: Any]])
        }
        let server = MCPServer(store: store, author: "agent:\(agent.name)", trusted: agent.trusted)
        if let batch = json as? [[String: Any]] {
            let replies = batch.compactMap { server.handle($0) }
            replies.isEmpty ? respond(c, 202, nil) : respondRaw(c, 200, try? JSONSerialization.data(withJSONObject: replies))
        } else if let message = json as? [String: Any] {
            if let reply = server.handle(message) { respond(c, 200, reply) } else { respond(c, 202, nil) }
        } else {
            respond(c, 400, ["error": "Expected a JSON-RPC message"])
        }
    }

    private func respond(_ c: NWConnection, _ status: Int, _ object: Any?, extra: [String: String] = [:]) {
        respondRaw(c, status, object.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.withoutEscapingSlashes]) }, extra: extra)
    }

    private func respondRaw(_ c: NWConnection, _ status: Int, _ body: Data?, extra: [String: String] = [:]) {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                      405: "Method Not Allowed", 413: "Payload Too Large", 421: "Misdirected Request", 431: "Request Header Fields Too Large"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        if let body { head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n" } else { head += "Content-Length: 0\r\n" }
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        if let body { out.append(body) }
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}

struct HTTPRequest {
    var method = "", path = "", headers: [String: String] = [:]
    init(_ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        if parts.count >= 2 { method = String(parts[0]); path = String(parts[1]) }
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
    }
}
