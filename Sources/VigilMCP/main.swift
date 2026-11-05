import Foundation
import VigilAgentKit
import VigilCore

// Vigil MCP server: newline-delimited JSON-RPC 2.0 over stdio.
// Agents launch this binary; it reads and writes the same SQLite database as the Vigil app.
// The tools themselves live in VigilAgentKit (shared with the app's live server).

let server = MCPServer()

func write(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
        server.log("failed to encode response")
        return
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

let arguments = CommandLine.arguments.dropFirst()
if arguments.first == "--report" {
    // Handy for testing: vigil-mcp --report [yesterday|YYYY-MM-DD]
    do { print(try server.store().markdownReport(day: DayKey.resolve(arguments.dropFirst().first))) } catch { print(error) }
    exit(0)
}
if arguments.first == "--version" {
    print("vigil-mcp \(MCPServer.version)")
    exit(0)
}

server.log("ready (database: \(VigilPaths.databaseURL.path))")
while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { continue }
    guard let data = trimmed.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) else {
        write(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"] as [String: Any]])
        continue
    }
    if let batch = json as? [[String: Any]] {
        for m in batch { if let r = server.handle(m) { write(r) } }
    } else if let message = json as? [String: Any] {
        if let r = server.handle(message) { write(r) }
    }
}
