// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Vigil",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        // Used by the iPhone/iPad app in iOS/ (Xcode project generated from iOS/project.yml).
        .library(name: "VigilMobile", targets: ["VigilMobile"]),
        .executable(name: "Vigil", targets: ["Vigil"]),
        .executable(name: "VigilMCP", targets: ["VigilMCP"]),
    ],
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
        // On-device speech capture for "speak to schedule" (Mac, iPhone, iPad).
        .target(
            name: "VigilVoice",
            path: "Sources/VigilVoice"
        ),
        // The iPhone/iPad app's screens and sync engine. Platform-neutral so it type-checks on macOS too;
        // the iOS-only shell (camera, Screen Time, Safari extension) lives in iOS/.
        .target(
            name: "VigilMobile",
            dependencies: ["VigilCore", "VigilSync", "VigilVoice"],
            path: "Sources/VigilMobile"
        ),
        // MCP tools shared by vigil-mcp (stdio) and the app's live agent server (HTTP on 127.0.0.1).
        .target(
            name: "VigilAgentKit",
            dependencies: ["VigilCore"],
            path: "Sources/VigilAgentKit"
        ),
        // The menu-bar app: tracking, blocking, dashboard, daily reports, pairing host.
        .executableTarget(
            name: "Vigil",
            dependencies: ["VigilCore", "VigilSync", "VigilVoice", "VigilAgentKit"],
            path: "Sources/Vigil"
        ),
        // stdio MCP server that agents (Claude Desktop, Claude Code, etc.) launch.
        .executableTarget(
            name: "VigilMCP",
            dependencies: ["VigilCore", "VigilAgentKit"],
            path: "Sources/VigilMCP"
        ),
        .testTarget(
            name: "VigilCoreTests",
            dependencies: ["VigilCore", "VigilSync", "VigilAgentKit"],
            path: "Tests/VigilCoreTests"
        ),
    ]
)
