// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Vigil",
    platforms: [.macOS(.v13), .iOS(.v16)],
    targets: [
        // Shared storage, categorisation and reporting. Used by both the app and the MCP server.
        .target(
            name: "VigilCore",
            path: "Sources/VigilCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Pairing and local-network sync between the Mac host and iPhone/iPad. Shared with the iOS app.
        .target(
            name: "VigilSync",
            dependencies: ["VigilCore"],
            path: "Sources/VigilSync"
        ),
        // The menu-bar app: tracking, blocking, dashboard, daily reports, pairing host.
        .executableTarget(
            name: "Vigil",
            dependencies: ["VigilCore", "VigilSync"],
            path: "Sources/Vigil"
        ),
        // stdio MCP server that agents (Claude Desktop, Claude Code, etc.) launch.
        .executableTarget(
            name: "VigilMCP",
            dependencies: ["VigilCore"],
            path: "Sources/VigilMCP"
        ),
        .testTarget(
            name: "VigilCoreTests",
            dependencies: ["VigilCore", "VigilSync"],
            path: "Tests/VigilCoreTests"
        ),
    ]
)
