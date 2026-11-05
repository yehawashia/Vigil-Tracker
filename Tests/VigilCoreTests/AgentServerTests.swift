import Foundation
import Testing
@testable import VigilAgentKit
@testable import VigilCore

/// Real HTTP requests against the live agent server on 127.0.0.1.
@Suite(.serialized) struct AgentServerTests {
    struct Env { let server: AgentHTTPServer; let store: VigilStore; let token: String; let agentID: String }

    func env() throws -> Env {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("vigil-agent-\(UUID().uuidString).sqlite").path
        let store = try VigilStore(path: path)
        let (agent, token) = try store.createAgent(name: "Test Agent")
        let server = try AgentHTTPServer(storePath: path)
        try server.start(port: 0)
        return Env(server: server, store: store, token: token, agentID: agent.id)
    }

    func post(_ e: Env, _ body: Any, token: String?, headers: [String: String] = [:], host: String? = nil) async throws -> (Int, [String: Any]?) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(e.server.port)/mcp")!)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let host { req.setValue(host, forHTTPHeaderField: "Host") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, try? JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    let list: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]
    func add(_ title: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": ["name": "propose_timetable_change", "arguments": ["op": "add", "kind": "todo", "title": title]]]
    }

    @Test func rejectsMissingAndWrongTokens() async throws {
        let e = try env(); defer { e.server.stop() }
        #expect(try await post(e, list, token: nil).0 == 401)
        #expect(try await post(e, list, token: "vgl_not-a-real-token").0 == 401)
        #expect(try await post(e, list, token: e.token).0 == 200)
    }

    @Test func rejectsWebPagesAndRebinding() async throws {
        let e = try env(); defer { e.server.stop() }
        #expect(try await post(e, list, token: e.token, headers: ["Origin": "https://evil.example"]).0 == 403)
        #expect(try await post(e, list, token: e.token, host: "evil.example:\(e.server.port)").0 == 421)
    }

    @Test func untrustedAgentOnlyProposes() async throws {
        let e = try env(); defer { e.server.stop() }
        let (status, reply) = try await post(e, add("From untrusted"), token: e.token)
        #expect(status == 200)
        #expect(e.store.todos().isEmpty)
        #expect(e.store.pendingProposals().first?.author == "agent:Test Agent")
        #expect(((reply?["result"] as? [String: Any])?["isError"] as? Bool) == false)
        #expect(e.store.agents().first?.lastUsed != nil)
    }

    @Test func trustedAgentApplies() async throws {
        let e = try env(); defer { e.server.stop() }
        e.store.setAgentTrusted(id: e.agentID, true)
        _ = try await post(e, add("From trusted"), token: e.token)
        #expect(e.store.todos().map(\.title) == ["From trusted"])
        #expect(e.store.timetableHistory().first?.author == "agent:Test Agent")
        #expect(e.store.timetableHistory().first?.status == .applied)
    }

    @Test func deletedAgentLosesAccess() async throws {
        let e = try env(); defer { e.server.stop() }
        e.store.deleteAgent(id: e.agentID)
        #expect(try await post(e, list, token: e.token).0 == 401)
    }

    @Test func notificationsGet202() async throws {
        let e = try env(); defer { e.server.stop() }
        #expect(try await post(e, ["jsonrpc": "2.0", "method": "notifications/initialized"], token: e.token).0 == 202)
    }
}
