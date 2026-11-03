# Security and privacy

Vigil records sensitive information: which apps you use, window titles and the websites you visit. It's designed so that information stays on your Mac.

## How data is handled

| | |
|---|---|
| **Network** | None. The app and the MCP server contain no networking code. There's no telemetry, crash reporting, update checking or cloud sync. |
| **Storage** | A single SQLite database at `~/Library/Application Support/Vigil/vigil.sqlite`. The folder is `0700` and the database files are `0600`, so other user accounts can't read them. |
| **Deletion** | `PRAGMA secure_delete=ON` overwrites deleted rows. "Delete all activity" also runs `VACUUM`. Data older than the retention period (180 days by default) is deleted automatically. |
| **URLs** | Query strings, fragments and embedded credentials are removed before a URL is stored, unless you turn on "Store full web addresses". |
| **Signing** | Hardened runtime. The only entitlement is `com.apple.security.automation.apple-events`, used to read and redirect browser tabs. |
| **Permissions** | Accessibility, for window titles, and Automation, per browser. Both are optional, and Vigil still tracks app usage without them. |
| **Agents (MCP)** | stdio only, with no sockets or ports. The server is started by, and answers only, the agent that launched it. You can make it read-only from the app or with `VIGIL_MCP_READONLY=1`. Locked focus sessions can't be weakened through MCP. |

**Agents and your data:** when an agent such as Claude calls a Vigil tool, the result becomes part of your conversation with that agent's AI provider. Only connect agents you trust, and use read-only mode if you just want reports.

## Building from source

`install.sh` clones this repository and builds it with Apple's toolchain on your machine. Nothing pre-compiled is downloaded, so you can review the code before running it.

## Reporting a vulnerability

Please use GitHub's **Report a vulnerability** button (Security tab → Advisories) rather than a public issue. Include steps to reproduce if you can.
