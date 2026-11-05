import AppKit
import SwiftUI
import VigilCore

// MARK: - Agents (MCP)

struct AgentsView: View {
    @EnvironmentObject var model: AppModel

    private var desktopJSON: String {
        """
        {
          "mcpServers": {
            "vigil": {
              "command": "\(model.mcpBinaryPath)"
            }
          }
        }
        """
    }

    private var claudeCodeCommand: String {
        "claude mcp add --scope user vigil -- \"\(model.mcpBinaryPath)\""
    }

    private let tools: [(String, String)] = [
        ("get_current_activity", "What you're doing right now: app, window, site, category"),
        ("get_daily_summary", "Score, time by category, top apps and sites for any day"),
        ("get_daily_report", "The full written daily report with insights"),
        ("get_usage", "Time per app, website, category or day over a date range"),
        ("get_history", "Day-by-day scores and totals for trend questions"),
        ("get_timeline", "Chronological activity segments for a day"),
        ("search_activity", "Find when you visited a site or used an app"),
        ("get_focus_status", "Active focus session, schedule and blocking state"),
        ("start_focus_session", "Start (or extend) a focus session, optionally locked"),
        ("stop_focus_session", "End an unlocked session early"),
        ("get_blocklist", "Blocked sites/apps, daily limits and schedules"),
        ("add_to_blocklist / remove_from_blocklist", "Edit the blocklist (removal refused while locked)"),
        ("set_daily_limit", "Cap minutes per day for a site or app"),
        ("set_category", "Mark a site or app productive, neutral or distracting"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Color.clear.frame(height: 0)
                .pageHeader("Agents (MCP)", subtitle: "Let Claude and other agents read your activity and run focus sessions for you.")

            Card("Access") {
                Toggle("Read-only for agents", isOn: Binding(
                    get: { model.mcpReadOnly }, set: { model.mcpReadOnly = $0; model.saveSettings() }))
                Text("When on, agents can read your stats but can't start sessions or change the blocklist, limits or categories.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("The MCP server runs locally and only answers the agent that launched it. It never connects to the internet. But anything an agent reads (for example today's top sites) goes to that agent's AI provider as part of your conversation, just like text you type.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LiveServerCard()

            Card("Claude Desktop") {
                Text("One click adds Vigil to Claude Desktop's config. Restart Claude afterwards.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button {
                        model.installInClaudeDesktop()
                    } label: {
                        Label("Add to Claude Desktop", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    copyButton(desktopJSON, title: "Copy JSON")
                }
                codeBlock(desktopJSON)
            }

            Card("Claude Code") {
                Text("Run this once in Terminal:").foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    codeBlock(claudeCodeCommand)
                    copyButton(claudeCodeCommand, title: "Copy")
                }
            }

            Card("Other MCP clients") {
                Text("Vigil speaks MCP over stdio. Point any client at this executable:").foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    codeBlock(model.mcpBinaryPath)
                    copyButton(model.mcpBinaryPath, title: "Copy")
                }
            }

            Card("Tools agents get") {
                ForEach(tools.indices, id: \.self) { i in
                    let name = tools[i].0
                    let detail = tools[i].1
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(name).font(.system(size: 12.5, design: .monospaced)).frame(width: 300, alignment: .leading)
                        Text(detail).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                }
                Text("Try asking: “How productive was I this week?”, “What distracted me most yesterday?”, “Start a locked 90-minute focus session for my algorithms coursework.”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func copyButton(_ text: String, title: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            model.lastMessage = "Copied"
        } label: {
            Label(title, systemImage: "doc.on.doc")
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmDelete = false
    @State private var browserStatus: [(String, String)] = []

    private var reportTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: model.reportMinuteOfDay / 60, minute: model.reportMinuteOfDay % 60,
                                      second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                model.reportMinuteOfDay = (c.hour ?? 21) * 60 + (c.minute ?? 0)
                model.saveSettings()
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Color.clear.frame(height: 0)
                .pageHeader("Settings", subtitle: "Everything stays on this Mac, in a local SQLite database.")

            Card("Permissions") {
                permissionRow(
                    title: "Accessibility",
                    detail: "Lets Vigil read window titles (document names, terminal tabs, Firefox pages).",
                    granted: model.accessibilityGranted,
                    action: {
                        WindowInfo.requestTrust()
                        model.openPrivacyPane("Privacy_Accessibility")
                    })
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Browser automation").font(.system(size: 13, weight: .semibold))
                            Text("Needed to see which website you're on and to block sites. macOS asks once per browser.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Test open browsers") { testBrowsers() }
                        Button("Open settings") { model.openPrivacyPane("Privacy_Automation") }
                    }
                    ForEach(browserStatus.indices, id: \.self) { i in
                        let name = browserStatus[i].0
                        let status = browserStatus[i].1
                        HStack {
                            Image(systemName: status == "OK" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(status == "OK" ? Theme.productive : Theme.distracting)
                            Text(name)
                            Text(status).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
                Divider()
                Text("Rebuilding the app changes its signature, so macOS may ask for these permissions again after an update.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Card("Appearance") {
                Picker("Look", selection: Binding(
                    get: { model.appearanceMode }, set: { model.appearanceMode = $0; model.saveSettings() })) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 460)
                Text("Day is light, Night is dark. Auto uses Day from 7am to 7pm and Night after that. The sun/moon button in the menu bar switches instantly.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Card("Tracking") {
                Toggle("Pause tracking", isOn: $model.trackingPaused)
                Toggle("Record window and tab titles", isOn: Binding(
                    get: { model.recordTitles }, set: { model.recordTitles = $0; model.saveSettings() }))
                Picker("Count me as idle after", selection: Binding(
                    get: { model.idleMinutes }, set: { model.idleMinutes = $0; model.saveSettings() })) {
                    ForEach([1, 2, 3, 5, 10, 15], id: \.self) { Text("\($0) min without input").tag($0) }
                }
                .frame(maxWidth: 360)
            }

            Card("Always on") {
                HStack(spacing: 12) {
                    Image(systemName: model.runsAlways ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
                        .font(.title2)
                        .foregroundStyle(model.runsAlways ? Theme.productive : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.runsAlways ? "Running 24/7" : "Not set to run 24/7").font(.system(size: 13, weight: .semibold))
                        Text(model.runsAlways
                             ? "Vigil starts at login and macOS restarts it within seconds if it stops or crashes. Quitting from the menu pauses it until your next login."
                             : "Make Vigil start at login and restart automatically if it's ever quit or crashes.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if model.runsAlways {
                        Button("Turn off") { model.disableAlwaysOn() }.disabled(model.isLocked)
                    } else {
                        Button("Keep running 24/7") { model.enableAlwaysOn() }.buttonStyle(.borderedProminent)
                    }
                }
            }

            Card("Daily update") {
                Toggle("Send a daily productivity report", isOn: Binding(
                    get: { model.reportEnabled }, set: { model.reportEnabled = $0; model.saveSettings() }))
                DatePicker("Send at", selection: reportTime, displayedComponents: .hourAndMinute)
                    .frame(maxWidth: 220)
                    .disabled(!model.reportEnabled)
                HStack {
                    Button("Send one now") { model.sendReportNow() }
                    Button("Open reports folder") { NSWorkspace.shared.open(VigilPaths.reportsDirectory) }
                }
                Text("Each report is also saved as a private text file (one per day), and agents can fetch them over MCP.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Card("Privacy") {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.shield.fill").font(.title2).foregroundStyle(Theme.productive)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Offline and private by design").font(.system(size: 13, weight: .semibold))
                        Text("Vigil has no network code: no accounts, no analytics, no cloud sync. It works the same with Wi-Fi off. Data lives in one database that only your user account can read (permissions 0600), and deleted rows are overwritten rather than left on disk.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
                Picker("Keep activity for", selection: Binding(
                    get: { model.retentionDays }, set: { model.retentionDays = $0; model.saveSettings() })) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("180 days").tag(180)
                    Text("1 year").tag(365)
                    Text("Forever").tag(0)
                }
                .frame(maxWidth: 320)
                Toggle("Store full web addresses (including ?search terms)", isOn: Binding(
                    get: { model.storeFullURLs }, set: { model.storeFullURLs = $0; model.saveSettings() }))
                Text("Off by default: Vigil keeps only the site and page path, because query strings often contain searches, emails or login tokens.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Card("Data") {
                HStack {
                    Button("Export reports as text (.txt)") { model.exportText(days: 30) }
                    Button("Export activity as CSV") { model.exportCSV(days: 30) }
                    Button("Show database in Finder") { model.revealDataFolder() }
                    Spacer()
                    Button("Delete all activity…", role: .destructive) { confirmDelete = true }
                        .disabled(model.isLocked)
                }
                Text(VigilPaths.databaseURL.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .confirmationDialog("Delete all tracked activity?", isPresented: $confirmDelete) {
            Button("Delete everything", role: .destructive) { model.deleteAllData() }
        } message: {
            Text("Your blocklist, rules and settings are kept. This can't be undone.")
        }
        .onAppear { model.accessibilityGranted = WindowInfo.isTrusted }
    }

    private func permissionRow(title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? Theme.productive : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Grant…", action: action) } else { Text("Granted").foregroundStyle(.secondary) }
        }
    }

    private func testBrowsers() {
        var results: [(String, String)] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, let info = BrowserBridge.supported[id] else { continue }
            _ = model.browser.activeTab(bundleID: id)
            results.append((info.name, model.browser.permissionDescription(bundleID: id)))
        }
        if results.isEmpty { results = [("No supported browser is open", "Open Safari or Chrome and try again")] }
        browserStatus = results
    }
}


// MARK: - Live server

/// Agents that connect to Vigil's local live server, each with its own token and trust switch.
struct LiveServerCard: View {
    @EnvironmentObject var model: AppModel
    @State private var newName = ""
    @State private var revealed: (name: String, token: String)?

    var body: some View {
        Card {
            SectionHeader(number: "L", title: "Live server", note: model.agents.isEmpty ? "off until you add an agent" : model.agentServerURL)
            Text("Agents connect over MCP at a local address on this Mac (no internet, refused from web pages). Each agent gets its own token. Trusted agents' timetable changes apply straight away; others wait for your approval. Everything is kept in history either way.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem = model.agentServerProblem { Text(problem).font(.caption).foregroundStyle(Theme.distracting) }

            ForEach(model.agents) { a in
                HStack(spacing: 12) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.name).font(.system(size: 13, weight: .medium))
                        Text(a.lastUsed.map { "USED " + $0.formatted(.relative(presentation: .named)).uppercased() } ?? "NOT USED YET")
                            .font(Theme.label(9)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Trusted", isOn: Binding(get: { a.trusted }, set: { model.setAgentTrusted(a, $0) }))
                        .toggleStyle(.switch).controlSize(.small)
                        .help("Trusted: its timetable and task changes apply immediately (you can undo them in History)")
                    Button("Remove", role: .destructive) { model.removeAgent(a) }.buttonStyle(.borderless)
                }
            }

            HStack {
                TextField("Agent name (e.g. Claude Code)", text: $newName).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Button("Add agent") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    if let token = model.addAgent(name: name) { revealed = (name, token); newName = "" }
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let r = revealed {
                let cmd = "claude mcp add --transport http --scope user vigil-live \(model.agentServerURL) --header \"Authorization: Bearer \(r.token)\""
                VStack(alignment: .leading, spacing: 6) {
                    Text("TOKEN FOR \(r.name.uppercased()) · SHOWN ONCE").font(Theme.label(9)).foregroundStyle(Theme.accent)
                    Text("Copy it now; Vigil only keeps a fingerprint of it. For Claude Code, run:").font(.caption).foregroundStyle(.secondary)
                    Text(cmd).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Theme.hairline.opacity(0.5))
                    HStack {
                        Button("Copy command") { copy(cmd) }
                        Button("Copy token only") { copy(r.token) }
                        Spacer()
                        Button("Done") { revealed = nil }
                    }
                }
                .padding(10)
                .overlay(Rectangle().strokeBorder(Theme.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
        }
        .crosshairs()
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        model.lastMessage = "Copied."
    }
}
