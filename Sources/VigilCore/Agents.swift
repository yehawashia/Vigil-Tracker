import CryptoKit
import Foundation

/// An AI agent allowed to use Vigil's live server. Vigil keeps only a SHA-256 hash of its token;
/// the token itself is shown once, when the agent is added.
public struct AgentToken: Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Trusted agents' timetable changes apply immediately; others are proposals for the user to approve.
    public var trusted: Bool
    public var created: Date
    public var lastUsed: Date?
}

extension VigilStore {
    static let agentsSchema = """
    CREATE TABLE IF NOT EXISTS agents (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        token_hash TEXT NOT NULL UNIQUE,
        trusted INTEGER NOT NULL DEFAULT 0,
        created REAL NOT NULL,
        last_used REAL
    );
    """

    static func hash(token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func agents() -> [AgentToken] {
        let rows = (try? db.query("SELECT * FROM agents ORDER BY created")) ?? []
        return rows.compactMap { r in
            guard let id = r.string("id"), let name = r.string("name") else { return nil }
            return AgentToken(id: id, name: name, trusted: r.bool("trusted"),
                              created: Date(timeIntervalSince1970: r.double("created") ?? 0),
                              lastUsed: r.double("last_used").map { Date(timeIntervalSince1970: $0) })
        }
    }

    /// Adds an agent and returns it with its token (the only time the token is available).
    public func createAgent(name: String) throws -> (agent: AgentToken, token: String) {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !clean.isEmpty else { throw TimetableError.invalid("Give the agent a name.") }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw TimetableError.invalid("No randomness.") }
        let token = "vgl_" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let agent = AgentToken(id: UUID().uuidString, name: clean, trusted: false, created: Date(), lastUsed: nil)
        try db.run("INSERT INTO agents(id, name, token_hash, trusted, created) VALUES (?, ?, ?, 0, ?)",
                   [agent.id, agent.name, VigilStore.hash(token: token), agent.created])
        return (agent, token)
    }

    /// The agent a bearer token belongs to (looked up by hash), or nil.
    public func agent(forToken token: String) -> AgentToken? {
        guard token.hasPrefix("vgl_"), token.count < 200 else { return nil }
        let id = (try? db.query("SELECT id FROM agents WHERE token_hash = ?", [VigilStore.hash(token: token)]))?.first?.string("id")
        return id.flatMap { id in agents().first { $0.id == id } }
    }

    public func setAgentTrusted(id: String, _ trusted: Bool) {
        _ = try? db.run("UPDATE agents SET trusted = ? WHERE id = ?", [trusted ? 1 : 0, id])
    }

    public func deleteAgent(id: String) {
        _ = try? db.run("DELETE FROM agents WHERE id = ?", [id])
    }

    public func touchAgent(id: String) {
        _ = try? db.run("UPDATE agents SET last_used = ? WHERE id = ?", [Date(), id])
    }
}
