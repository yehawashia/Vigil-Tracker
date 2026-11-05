# Vigil: notes for Claude Code

See **AGENTS.md** for installing, MCP tools and the code layout. Short version:

- Build: `swift build` (quick check), `./test.sh` (unit + loopback network tests), `./build.sh` (signed `build/Vigil.app`), `./build.sh --install` (install and run 24/7), `./build.sh --screenshots` (regenerate README images from sample data).
- Swift 5 language mode, macOS 13 deployment target. No macOS 14-only APIs (`@Observable`, two-parameter `onChange`, `ContentUnavailableView`).
- The app and `vigil-mcp` share `~/Library/Application Support/Vigil/vigil.sqlite` (WAL). The app reacts to MCP writes by polling `PRAGMA data_version` on each 1 s tick.
- Performance: the tick loop must not query SQLite in the common case. Use `pendingSessions`, `schedules` and the tracker's cached title and URL. Segment end times are flushed every 5 s.
- Security:
  - No internet code, ever. The only networking is `Sources/VigilSync`: local network only (no cellular, non-local addresses refused), paired devices only, TLS-PSK with a per-device key. Change it only with tests in `Tests/`.
  - Keep SQL parameterised.
  - Keep folders 0700 and database files 0600.
  - Sanitise URLs with `Categorizer.sanitize` before storing them.
  - Keep hardened-runtime signing in `build.sh`.
- Locked focus sessions must never be weakened, whether from the UI, over MCP or from a paired device.
- Agents only *propose* timetable changes (`status = 'proposed'`); never let MCP write timetable items directly.
- Timetable history is append-only. Revert by adding a revision, never by editing or deleting old ones.
- Swift 5 / macOS 13 / iOS 16. `Sources/VigilMobile` must keep compiling on macOS (guard UIKit with `#if canImport(UIKit)`).
- Architecture and security design: docs/ARCHITECTURE.md.
