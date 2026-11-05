# Security and privacy

Vigil records sensitive information: which apps you use, window titles and the websites you visit. It's designed so that information stays on your Mac.

## How data is handled

| | |
|---|---|
| **Network** | No internet: no telemetry, crash reporting, update checking or cloud sync. The only networking is optional sync with iPhones/iPads you pair: local network only (cellular disabled, non-local addresses refused), nothing listens until a device is paired, and every connection uses TLS with that device's own 256-bit key. Details and threat model: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#4-pairing-and-sync-security). |
| **Pairing** | QR codes are single-use and expire after 2 minutes; the device must prove it saw the code. PIN pairing shows a code derived from an X25519 exchange on both screens, which a man-in-the-middle can't match. Removing a device deletes its key and the data it sent. Device keys are stored in a `0600` file next to the database on the Mac, and in the Keychain (this device only) on iOS. |
| **Timetable** | Agents can only propose changes, which wait for your approval. Every change is kept in an append-only history and can be reverted. |
| **Storage** | A single SQLite database at `~/Library/Application Support/Vigil/vigil.sqlite`. The folder is `0700` and the database files are `0600`, so other user accounts can't read them. |
| **Deletion** | `PRAGMA secure_delete=ON` overwrites deleted rows. "Delete all activity" also runs `VACUUM`. Data older than the retention period (180 days by default) is deleted automatically. |
| **URLs** | Query strings, fragments and embedded credentials are removed before a URL is stored, unless you turn on "Store full web addresses". |
| **Signing** | Hardened runtime. The only entitlement is `com.apple.security.automation.apple-events`, used to read and redirect browser tabs. (macOS may ask for Local Network permission when you first pair a device.) |
| **Permissions** | Accessibility, for window titles, and Automation, per browser. Both are optional, and Vigil still tracks app usage without them. |
| **Agents (MCP)** | stdio only, with no sockets or ports. The server is started by, and answers only, the agent that launched it. You can make it read-only from the app or with `VIGIL_MCP_READONLY=1`. Locked focus sessions can't be weakened through MCP. |

**Agents and your data:** when an agent such as Claude calls a Vigil tool, the result becomes part of your conversation with that agent's AI provider. Only connect agents you trust, and use read-only mode if you just want reports.

## Building from source

`install.sh` clones this repository and builds it with Apple's toolchain on your machine. Nothing pre-compiled is downloaded, so you can review the code before running it.

## Reporting a vulnerability

Please use GitHub's **Report a vulnerability** button (Security tab → Advisories) rather than a public issue. Include steps to reproduce if you can.
