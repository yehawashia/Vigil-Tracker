# Vigil for AI agents

This guide is for AI agents (Claude Code, Claude Desktop, Cursor and other MCP clients) that need to **install Vigil for a user**, **connect to it** or **work on its code**.

Vigil is a macOS 13+ menu-bar app that tracks app, window and website usage locally, blocks distractions, and serves that data over MCP (stdio, JSON-RPC 2.0). It has no internet access; paired iPhones/iPads sync with it over the local network only (encrypted, per-device keys).

---

## 1. Install (on the user's Mac)

```bash
curl -fsSL https://raw.githubusercontent.com/yehawashia/Vigil-Tracker/main/install.sh | bash
```

- This clones the source to `~/.vigil/src`, builds it with Swift Package Manager, installs `~/Applications/Vigil.app` and registers the LaunchAgent `dev.vigil.Vigil` so it runs 24/7. Re-running it updates Vigil.
- If Apple's command line tools are missing, it opens the installer and exits. Ask the user to finish that, then run it again.
- Daily reports are saved as private text files in `~/Library/Application Support/Vigil/Reports/YYYY-MM-DD.txt`.
- **Only the user can grant permissions.** After installing, tell them to open the Vigil menu-bar icon → Dashboard → **Settings**, grant **Accessibility**, then click **Test open browsers** and allow the **Automation** prompts. Without these, Vigil tracks apps but not window titles or websites.
- To uninstall: `~/.vigil/src/uninstall.sh`. Add `--purge` to also delete the data.

Check that it's running:

```bash
launchctl list | grep dev.vigil.Vigil          # shows a PID while running
~/Applications/Vigil.app/Contents/MacOS/vigil-mcp --version
```

## 2. Connect over MCP

Two ways, same tools:

- **stdio** (below): the agent launches `vigil-mcp`. Timetable changes are always proposals.
- **Live server**: Vigil (running 24/7) serves MCP over HTTP at `http://127.0.0.1:47610/mcp`. The user adds the agent in **Vigil → Agents → Live server**, which shows a token once. Each agent can be marked **Trusted** (its timetable and task changes apply immediately) or not (changes wait for approval). Loopback only; requests with an `Origin` header or a foreign `Host` are refused.

```bash
claude mcp add --transport http --scope user vigil-live http://127.0.0.1:47610/mcp --header "Authorization: Bearer vgl_…"
```

The server binary is `~/Applications/Vigil.app/Contents/MacOS/vigil-mcp`.

**Claude Code**
```bash
claude mcp add --scope user vigil -- ~/Applications/Vigil.app/Contents/MacOS/vigil-mcp
```

**Claude Desktop / generic `mcpServers` config.** Use an absolute path, since `~` isn't expanded:
```json
{
  "mcpServers": {
    "vigil": {
      "command": "/Users/<user>/Applications/Vigil.app/Contents/MacOS/vigil-mcp",
      "env": { "VIGIL_MCP_READONLY": "0" }
    }
  }
}
```
The user can also click **Agents (MCP) → Add to Claude Desktop** in the app.

Set `VIGIL_MCP_READONLY=1`, or turn on *Read-only for agents* in the app, to hide every tool that changes something.

## 3. Tools

All dates accept `"today"`, `"yesterday"`, `"YYYY-MM-DD"` or `"-N"` (N days ago). Durations are returned in minutes, rounded to 0.1. Every result is JSON text, except `get_daily_report`, which returns Markdown.

| Tool | Arguments | Returns |
|---|---|---|
| `get_current_activity` | none | Frontmost app, window title, domain, category, focus state. `active: false` if the user is idle or away |
| `get_daily_summary` | `date?` | Score 0–100, minutes per category, top apps and sites, hourly breakdown, focus and blocking stats, insights |
| `get_daily_report` | `date?` | The day's report as Markdown |
| `get_usage` | `start_date?`, `end_date?`, `group_by?` (`app`\|`domain`\|`category`\|`day`), `limit?` | Totals over a date range |
| `get_history` | `days?` (1–90) | Score and category minutes for each day |
| `get_timeline` | `date?`, `min_seconds?`, `limit?` | Activity segments, most recent first |
| `search_activity` | `query`, `days?` | Segments matching an app name, title, URL or domain |
| `get_focus_status` | none | Active session (and whether it's locked), active schedule, daily limits reached |
| `start_focus_session` ✎ | `minutes` (1–480), `label?`, `locked?` | Starts a session or extends the current one |
| `stop_focus_session` ✎ | none | Ends an **unlocked** session |
| `get_blocklist` | none | Blocked sites and apps, daily limits with today's usage, schedules |
| `add_to_blocklist` ✎ | `kind` (`domain`\|`app`), `pattern` | Adds to the blocklist |
| `remove_from_blocklist` ✎ | `kind`, `pattern` | Removes from the blocklist. Refused during a locked session |
| `set_daily_limit` ✎ | `kind`, `pattern`, `minutes` (0 removes it) | Sets a per-day cap. During a locked session it can only be lowered |
| `get_timetable` | `start_date?`, `end_date?` | Scheduled items, open unscheduled `tasks`, and changes awaiting approval |
| `propose_timetable_change` ✎ | `op` (`add`\|`update`\|`delete`), `id?`, `title?`, `start?`, `end?`, `kind?` (`task`\|`block`\|`todo`), `estimate_minutes?`, `focus?`, `notes?`, `done?`, `reason?` | A proposal the user approves in Vigil, or applied immediately if the user marked this agent as trusted (the result says which). `todo` = unscheduled task (no times needed); schedule it with an update giving `kind`, `start`, `end` |
| `get_timetable_history` | `item_id?`, `limit?` | Every change: who made it (user, agent, device) and its status |
| `get_devices` | none | Paired iPhones/iPads, last seen, and today's reported time |
| `set_category` ✎ | `kind`, `pattern`, `category` (`productive`\|`neutral`\|`distracting`) | Recategorises a site or app and rescores the last 30 days |

✎ = changes something. These tools are hidden in read-only mode.

### Etiquette

- **Ask before `locked: true`.** A locked session can't be ended early by anyone, including you.
- A `domain` pattern covers its subdomains: `youtube.com` also blocks `m.youtube.com`. For `app`, use the bundle ID (`com.hnc.Discord`) or the app's name exactly as shown.
- For "how did I do?" questions, call `get_daily_summary`. For trends, use `get_history` and then `get_usage` grouped by `domain`.
- Vigil applies changes made over MCP within about a second (it checks SQLite's `data_version`).

### Smoke test

```bash
printf '%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_daily_summary","arguments":{"date":"today"}}}' \
 | ~/Applications/Vigil.app/Contents/MacOS/vigil-mcp
```

## 4. Working on the code

- `swift build` gives a fast compile check. `./test.sh` runs the tests (timetable rules, pairing crypto, real TLS-PSK handshakes, full pair/sync/revoke). `./build.sh` builds a signed `build/Vigil.app`. `./build.sh --install` reinstalls it. `./build.sh --screenshots` regenerates `docs/screenshots` from sample data.
- Layout:
  - `Sources/VigilCore` (SQLite store, categoriser, reports; shared)
  - `Sources/Vigil` (app: `AppModel` tick loop, `ActivityTracker`, `BrowserBridge`, `Blocker`, `TabCensus` (open/background tabs, memory only), `FocusDial`, SwiftUI views)
  - `Sources/VigilMCP/main.swift` (MCP server)
  - `Sources/VigilSync` (pairing + local sync; shared with iOS), `Sources/VigilMobile` (iPhone/iPad screens), `iOS/` (iOS shell, see iOS/README.md)
- Rules:
  - Keep Swift 5 language mode and macOS 13 as the minimum.
  - **No internet code.** Local-network sync lives only in `Sources/VigilSync` (see docs/ARCHITECTURE.md §4).
  - Agents only propose timetable changes; the user approves them.
  - Keep SQL parameterised.
  - Run URLs through `Categorizer.sanitize` before storing them.
  - Keep file permissions at 0700/0600.
  - Locked sessions must never be weakened.
  - The 1 s tick must not touch SQLite in the common case: use the in-memory caches and `dataVersion()`.
