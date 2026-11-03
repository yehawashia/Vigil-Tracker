// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Vigil",
    platforms: [.macOS(.v13)],
    targets: [
        // Shared storage, categorisation and reporting. Used by both the app and the MCP server.
        .target(
            name: "VigilCore",
            path: "Sources/VigilCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The menu-bar app: tracking, blocking, dashboard, daily reports.
        .executableTarget(
            name: "Vigil",
            dependencies: ["VigilCore"],
            path: "Sources/Vigil"
        ),
        // stdio MCP server that agents (Claude Desktop, Claude Code, etc.) launch.
        .executableTarget(
            name: "VigilMCP",
            dependencies: ["VigilCore"],
            path: "Sources/VigilMCP"
        ),
    ]
)
