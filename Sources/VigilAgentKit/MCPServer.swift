import Foundation
import VigilCore

// Vigil's MCP tools, shared by the stdio server (vigil-mcp) and the app's live HTTP server.
// One MCPServer per connection: it knows which agent is calling and whether that agent is trusted.

public struct ToolError: Error { public let message: String; public init(message: String) { self.message = message } }
public typealias JSON = [String: Any]

public enum ToolResult {
    case text(String)
    case json(JSON)
}

extension Dictionary where Key == String, Value == Any {
    func str(_ key: String) -> String? {
        if let s = self[key] as? String { return s }
        if let n = self[key] as? NSNumber { return n.stringValue }
        return nil
    }
    func int(_ key: String) -> Int? {
        if let n = self[key] as? NSNumber { return n.intValue }
        if let s = self[key] as? String { return Int(s) }
        return nil
    }
    func bool(_ key: String) -> Bool? {
        if let b = self[key] as? Bool { return b }
        if let n = self[key] as? NSNumber { return n.boolValue }
        if let s = self[key] as? String { return ["true", "1", "yes"].contains(s.lowercased()) }
        return nil
    }
    func kind() throws -> TargetKind {
        guard let raw = str("kind")?.lowercased() else { throw ToolError(message: "Missing 'kind' (\"domain\" or \"app\")") }
        if raw == "website" || raw == "site" || raw == "url" { return .domain }
        guard let k = TargetKind(rawValue: raw) else { throw ToolError(message: "'kind' must be \"domain\" or \"app\"") }
        return k
    }
    func pattern() throws -> String {
        guard let p = str("pattern")?.trimmingCharacters(in: .whitespaces), !p.isEmpty else {
            throw ToolError(message: "Missing 'pattern' (a domain like youtube.com, or an app name / bundle ID)")
        }
        return p
    }
}

public final class MCPServer {
    /// Who the change history records, e.g. "agent" (stdio) or "agent:Claude Code" (live server).
    public let author: String
    /// Trusted agents' timetable changes apply immediately; others become proposals for the user to approve.
    public let trusted: Bool

    public init(store: VigilStore? = nil, author: String = "agent", trusted: Bool = false) {
        self.cachedStore = store
        self.author = author
        self.trusted = trusted
    }

    public static let version = "1.1.0"
    var serverVersion: String { MCPServer.version }
    let supportedProtocols = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]

    public func log(_ message: String) {
        FileHandle.standardError.write(Data(("[vigil-mcp] " + message + "\n").utf8))
    }


    func nn(_ value: Any?) -> Any { value ?? NSNull() }
    /// Minutes rounded to one decimal. NSDecimalNumber serialises as "12.5", not "12.500000000000002".
    func minutes(_ seconds: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.1f", seconds / 60))
    }

    let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()
    func ts(_ date: Date?) -> Any { date.map { iso.string(from: $0) } ?? NSNull() }






    // MARK: - Store

    var cachedStore: VigilStore?
    public func store() throws -> VigilStore {
        if let cachedStore { return cachedStore }
        do {
            let s = try VigilStore()
            cachedStore = s
            return s
        } catch {
            throw ToolError(message: "Could not open the Vigil database at \(VigilPaths.databaseURL.path): \(error)")
        }
    }

    // MARK: - Serialisers

    func usageJSON(_ items: [UsageItem]) -> [[String: Any]] {
        items.map { ["name": $0.name, "minutes": minutes($0.seconds), "time": DurationText.short($0.seconds),
                     "category": $0.category.rawValue] }
    }

    func summaryJSON(_ s: DaySummary) -> [String: Any] {
        [
            "date": s.day,
            "productivity_score": s.score,
            "score_explanation": "0–100: productive time counts fully, neutral half, distracting zero.",
            "active_minutes": minutes(s.activeSeconds),
            "active_time": DurationText.short(s.activeSeconds),
            "productive_minutes": minutes(s.productiveSeconds),
            "neutral_minutes": minutes(s.neutralSeconds),
            "distracting_minutes": minutes(s.distractingSeconds),
            "first_activity": ts(s.firstActivity),
            "last_activity": ts(s.lastActivity),
            "focus_sessions_completed": s.focusSessionsCompleted,
            "focus_minutes": s.focusMinutes,
            "blocked_attempts": s.blockedAttempts,
            "app_switches": s.contextSwitches,
            "top_apps": usageJSON(s.topApps),
            "top_websites": usageJSON(s.topDomains),
            "hourly_minutes": s.hourly.filter { $0.productive + $0.neutral + $0.distracting > 0 }.map { b -> JSON in
                ["hour": b.hour, "productive": minutes(b.productive), "neutral": minutes(b.neutral),
                 "distracting": minutes(b.distracting)]
            },
        ]
    }

    func recordJSON(_ r: ActivityRecord) -> [String: Any] {
        [
            "start": ts(r.start), "end": ts(r.end), "minutes": minutes(r.duration),
            "app": r.appName, "bundle_id": nn(r.bundleID), "window_title": nn(r.windowTitle),
            "url": nn(r.url), "domain": nn(r.domain), "category": r.category.rawValue,
        ]
    }

    func sessionJSON(_ f: FocusSession) -> [String: Any] {
        [
            "id": f.id, "label": nn(f.label), "start": ts(f.start), "end": ts(f.end), "locked": f.locked,
            "remaining_minutes": minutes(f.remaining()), "ended_early": ts(f.endedEarly), "created_by": nn(f.createdBy),
        ]
    }

    func focusStatus(_ st: VigilStore) -> [String: Any] {
        let focus = st.activeFocusSession()
        let schedule = st.activeSchedule()
        let exceeded = st.limits().filter { st.secondsToday(kind: $0.kind, pattern: $0.pattern) >= Double($0.minutes * 60) }
        return [
            "focus_session": nn(focus.map(sessionJSON)),
            "active_schedule": nn(schedule.map { sc -> JSON in ["label": nn(sc.label), "days": sc.weekdaysText, "time": sc.timeRangeText] }),
            "blocking_active": focus != nil || schedule != nil || !exceeded.isEmpty,
            "limits_reached": exceeded.map { l -> JSON in ["kind": l.kind.rawValue, "pattern": l.pattern, "minutes": l.minutes] },
        ]
    }

    // MARK: - Argument helpers


    // MARK: - Tool definitions

    let dateProp: [String: Any] = ["type": "string", "description": "\"today\", \"yesterday\", \"YYYY-MM-DD\", or \"-N\" for N days ago. Defaults to today."]
    let kindProp: [String: Any] = ["type": "string", "enum": ["domain", "app"], "description": "\"domain\" for a website, \"app\" for a Mac application"]
    let patternProp: [String: Any] = ["type": "string", "description": "Domain (e.g. youtube.com, subdomains included) or app name / bundle ID (e.g. Discord or com.hnc.Discord)"]

    func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = [], readOnly: Bool = true) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required] as JSON,
            "annotations": ["readOnlyHint": readOnly, "openWorldHint": false],
        ]
    }

    lazy var tools: [[String: Any]] = [
        tool("get_current_activity", "What the user is doing on their Mac right now: frontmost app, window title, website, category, and focus status."),
        tool("get_daily_summary", "Productivity summary for one day: score (0–100), time per category, top apps, top websites, hourly breakdown, focus sessions and blocked attempts.",
             ["date": dateProp]),
        tool("get_daily_report", "The written daily report (Markdown) with stats, insights and top apps/sites. Good for sharing or a quick overview.",
             ["date": dateProp]),
        tool("get_usage", "Total time grouped by app, website (domain), category or day across a date range.",
             ["start_date": dateProp, "end_date": dateProp,
              "group_by": ["type": "string", "enum": ["app", "domain", "category", "day"], "description": "Defaults to domain"] as JSON,
              "limit": ["type": "integer", "description": "Max rows, default 20"]]),
        tool("get_history", "Day-by-day productivity scores and time per category for the last N days, for spotting trends.",
             ["days": ["type": "integer", "description": "Number of days including today, default 7, max 90"]]),
        tool("get_timeline", "Chronological activity segments for one day (app, window title, URL, duration).",
             ["date": dateProp,
              "min_seconds": ["type": "integer", "description": "Skip segments shorter than this, default 60"],
              "limit": ["type": "integer", "description": "Max segments, default 150 (most recent first)"]]),
        tool("search_activity", "Search recent activity by app name, window title, URL or domain.",
             ["query": ["type": "string", "description": "Text to search for"],
              "days": ["type": "integer", "description": "How many days back, default 7"]], required: ["query"]),
        tool("get_focus_status", "Whether a focus session or block schedule is running, whether it is locked, and which daily limits have been reached."),
        tool("start_focus_session", "Start a focus session that blocks everything on the blocklist. If one is running it is extended. Locked sessions cannot be stopped early, and Vigil refuses to quit until they end. Confirm with the user before locking.",
             ["minutes": ["type": "integer", "description": "Length in minutes (1–480)"],
              "label": ["type": "string", "description": "What the user is working on"],
              "locked": ["type": "boolean", "description": "Prevent stopping early. Default false"]],
             required: ["minutes"], readOnly: false),
        tool("stop_focus_session", "End the current focus session early. Refused if the session is locked.", readOnly: false),
        tool("get_blocklist", "The blocklist (sites and apps), daily limits with today's usage, and recurring block schedules."),
        tool("add_to_blocklist", "Add a website or app to the blocklist (enforced during focus sessions and schedules).",
             ["kind": kindProp, "pattern": patternProp], required: ["kind", "pattern"], readOnly: false),
        tool("remove_from_blocklist", "Remove a website or app from the blocklist. Refused during a locked session.",
             ["kind": kindProp, "pattern": patternProp], required: ["kind", "pattern"], readOnly: false),
        tool("set_daily_limit", "Limit a website or app to N minutes per day; after that it's blocked until midnight. minutes = 0 removes the limit. Loosening is refused during a locked session.",
             ["kind": kindProp, "pattern": patternProp, "minutes": ["type": "integer", "description": "Minutes per day, 0 to remove"]],
             required: ["kind", "pattern", "minutes"], readOnly: false),
        tool("set_category", "Mark a website or app as productive, neutral or distracting. Re-scores the last 30 days.",
             ["kind": kindProp, "pattern": patternProp,
              "category": ["type": "string", "enum": ["productive", "neutral", "distracting"]] as JSON],
             required: ["kind", "pattern", "category"], readOnly: false),
        tool("get_timetable", "The user's timetable (tasks and time blocks) between two dates, plus any changes still waiting for the user's approval. Time blocks turn on blocking while they run.",
             ["start_date": dateProp, "end_date": ["type": "string", "description": "Same formats as start_date. Defaults to 7 days after start_date."] as JSON]),
        tool("propose_timetable_change", "Propose adding, changing or removing a timetable item. Unless the user has marked this agent as trusted, nothing changes until they approve it in Vigil (on their Mac or a paired iPhone/iPad); the result says whether it was applied or is waiting. Times are local, as \"YYYY-MM-DD HH:MM\" or ISO 8601.",
             ["op": ["type": "string", "enum": ["add", "update", "delete"]] as JSON,
              "id": ["type": "string", "description": "Item id (from get_timetable). Required for update and delete."] as JSON,
              "title": ["type": "string", "description": "Required for add"] as JSON,
              "start": ["type": "string", "description": "Start time. Required for add"] as JSON,
              "end": ["type": "string", "description": "End time. Required for add"] as JSON,
              "kind": ["type": "string", "enum": ["task", "block", "todo"], "description": "\"block\" turns blocking on during the item; \"todo\" is an unscheduled task for the task panel (no start/end needed). To schedule a todo, update it with kind task/block and a start and end. Default task"] as JSON,
              "estimate_minutes": ["type": "integer", "description": "For todos: how long it should take"] as JSON,
              "focus": ["type": "boolean", "description": "For todos: block distractions when it gets scheduled"] as JSON,
              "notes": ["type": "string"] as JSON,
              "done": ["type": "boolean"] as JSON,
              "reason": ["type": "string", "description": "One sentence shown to the user when they approve or reject"] as JSON],
             required: ["op"], readOnly: false),
        tool("get_timetable_history", "Version history of the timetable: every change, who made it (user, agent or a paired device) and whether it was applied, proposed or rejected.",
             ["item_id": ["type": "string", "description": "Only this item's history"] as JSON,
              "limit": ["type": "integer", "description": "Default 50"] as JSON]),
        tool("get_devices", "iPhones and iPads paired with this Mac, when each was last seen, and the time they reported today (Safari websites to the second; app groups in 15-minute steps)."),
    ]

    // MARK: - Timetable helpers

    let localFormats: [DateFormatter] = ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"].map {
        let f = DateFormatter(); f.dateFormat = $0; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; return f
    }

    func parseTime(_ text: String?, field: String) throws -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let d = ISO8601DateFormatter().date(from: text) { return d }
        for f in localFormats { if let d = f.date(from: text) { return d } }
        throw ToolError(message: "'\(field)' must look like \"2026-11-06 14:30\" (local time) or ISO 8601")
    }

    func itemJSON(_ i: TimetableItem) -> JSON {
        ["id": i.id, "title": i.title, "notes": nn(i.notes), "start": ts(i.start), "end": ts(i.end),
         "kind": i.kind.rawValue, "done": i.done, "minutes": i.kind == .todo ? nn(i.estimate) : Int(i.duration / 60),
         "focus": nn(i.wantsFocus)]
    }

    func revisionJSON(_ r: TimetableRevision) -> JSON {
        ["revision": r.id, "item_id": r.itemID, "op": r.op.rawValue, "status": r.status.rawValue,
         "author": r.author, "summary": r.summary, "note": nn(r.note), "time": ts(r.time)]
    }

    // MARK: - Tool handlers

    let writeTools: Set<String> = ["start_focus_session", "stop_focus_session", "add_to_blocklist",
                                    "remove_from_blocklist", "set_daily_limit", "set_category", "propose_timetable_change"]

    /// Read-only if VIGIL_MCP_READONLY=1 is set in the agent's config, or "Read-only for agents" is on in the app.
    func isReadOnly() -> Bool {
        if ProcessInfo.processInfo.environment["VIGIL_MCP_READONLY"] == "1" { return true }
        return (try? store())?.setting("mcp_readonly") == "1"
    }

    /// Returns either a JSON-able object (serialised as pretty JSON) or a String (sent as-is).
    func callTool(_ name: String, _ args: [String: Any]) throws -> ToolResult {
        let st = try store()
        if writeTools.contains(name) && isReadOnly() {
            throw ToolError(message: "Vigil is in read-only mode for agents. The user can change this in Vigil → Agents (MCP).")
        }
        switch name {
        case "get_current_activity":
            var out: [String: Any] = [:]
            if let r = st.currentActivity() {
                out["active"] = true
                out["activity"] = recordJSON(r)
            } else {
                out["active"] = false
                let last = st.recentActivities(limit: 1).first
                out["message"] = "No activity in the last 15 seconds. The user is idle or away, tracking is paused, or the Vigil app isn't running."
                out["last_seen"] = ts(last?.end)
            }
            out["focus"] = focusStatus(st)
            out["today"] = ["score": st.summary(day: DayKey.today).score]
            return .json(out)

        case "get_daily_summary":
            let day = DayKey.resolve(args.str("date"))
            let s = st.summary(day: day)
            var out = summaryJSON(s)
            out["insights"] = st.insights(for: s, previous: st.summary(day: DayKey.offset(day, days: -1)))
            return .json(out)

        case "get_daily_report":
            let day = DayKey.resolve(args.str("date"))
            st.saveReport(day: day)
            return .text(st.markdownReport(day: day))

        case "get_usage":
            let end = DayKey.resolve(args.str("end_date"))
            let start = args.str("start_date").map { DayKey.resolve($0) } ?? DayKey.offset(end, days: -6)
            let group = VigilStore.GroupBy(rawValue: (args.str("group_by") ?? "domain").lowercased()) ?? .domain
            let limit = min(200, max(1, args.int("limit") ?? 20))
            let items = st.usage(fromDay: min(start, end), toDay: max(start, end), groupBy: group, limit: limit)
            return .json(["start_date": min(start, end), "end_date": max(start, end), "group_by": group.rawValue,
                    "total_minutes": minutes(items.reduce(0) { $0 + $1.seconds }), "items": usageJSON(items)])

        case "get_history":
            let days = min(90, max(1, args.int("days") ?? 7))
            let history = st.history(days: days)
            let tracked = history.filter { $0.activeSeconds > 600 }
            return .json([
                "days": history.map { d -> JSON in
                    ["date": d.day, "score": d.score, "active_minutes": minutes(d.activeSeconds),
                     "productive_minutes": minutes(d.productiveSeconds),
                     "neutral_minutes": minutes(d.neutralSeconds),
                     "distracting_minutes": minutes(d.distractingSeconds)]
                },
                "average_score": tracked.isEmpty ? 0 : tracked.map(\.score).reduce(0, +) / tracked.count,
                "days_tracked": tracked.count,
            ])

        case "get_timeline":
            let day = DayKey.resolve(args.str("date"))
            let minSeconds = Double(args.int("min_seconds") ?? 60)
            let limit = min(1000, max(1, args.int("limit") ?? 150))
            let records = st.activities(day: day).filter { $0.duration >= minSeconds }
            return .json(["date": day, "segments": records.suffix(limit).reversed().map(recordJSON),
                          "total_segments": records.count])

        case "search_activity":
            guard let q = args.str("query"), !q.isEmpty else { throw ToolError(message: "Missing 'query'") }
            let days = min(365, max(1, args.int("days") ?? 7))
            let results = st.searchActivities(query: q, sinceDay: DayKey.offset(DayKey.today, days: -(days - 1)))
            return .json(["query": q, "matches": results.count, "total_minutes": minutes(results.reduce(0) { $0 + $1.duration }),
                          "results": results.map(recordJSON)])

        case "get_focus_status":
            return .json(focusStatus(st))

        case "start_focus_session":
            guard let m = args.int("minutes"), m >= 1, m <= 480 else { throw ToolError(message: "'minutes' must be between 1 and 480") }
            let session = try st.startFocusSession(minutes: m, locked: args.bool("locked") ?? false,
                                                   label: args.str("label"), createdBy: "mcp")
            return .json(["started": true, "session": sessionJSON(session),
                          "blocking": st.blocklist().map { "\($0.kind.rawValue):\($0.pattern)" },
                          "note": "The Vigil app enforces the blocklist within a few seconds."])

        case "stop_focus_session":
            switch st.stopFocusSession() {
            case .stopped: return .json(["stopped": true])
            case .locked:
                let endText = st.activeFocusSession().map { iso.string(from: $0.end) } ?? "its scheduled time"
                throw ToolError(message: "The current session is locked and can't be stopped early. It ends at \(endText).")
            case .noSession: return .json(["stopped": false, "message": "No focus session is running."])
            }

        case "get_blocklist":
            let items = st.blocklist()
            return .json([
                "websites": items.filter { $0.kind == .domain }.map(\.pattern),
                "apps": items.filter { $0.kind == .app }.map(\.pattern),
                "daily_limits": st.limits().map { l -> JSON in
                    ["kind": l.kind.rawValue, "pattern": l.pattern, "minutes_per_day": l.minutes,
                     "used_today_minutes": minutes(st.secondsToday(kind: l.kind, pattern: l.pattern))]
                },
                "schedules": st.schedules().map { sc -> JSON in
                    ["label": nn(sc.label), "days": sc.weekdaysText, "time": sc.timeRangeText, "enabled": sc.enabled]
                },
            ])

        case "add_to_blocklist":
            let k = try args.kind()
            let p = try args.pattern()
            try st.addBlock(kind: k, pattern: p)
            return .json(["added": true, "kind": k.rawValue, "pattern": p])

        case "remove_from_blocklist":
            let k = try args.kind()
            let p = try args.pattern()
            if st.activeFocusSession()?.locked == true {
                throw ToolError(message: "A locked focus session is running, so the blocklist can't be loosened until it ends.")
            }
            try st.removeBlock(kind: k, pattern: p)
            return .json(["removed": true, "kind": k.rawValue, "pattern": p])

        case "set_daily_limit":
            let k = try args.kind()
            let p = try args.pattern()
            guard let m = args.int("minutes"), m >= 0 else { throw ToolError(message: "'minutes' must be 0 or more") }
            if st.activeFocusSession()?.locked == true {
                let normalized = k == .domain ? Categorizer.normalizeDomainPattern(p) : p
                let existing = st.limits().first { $0.kind == k && $0.pattern.lowercased() == normalized.lowercased() }
                if let existing, m == 0 || m > existing.minutes {
                    throw ToolError(message: "A locked focus session is running, so limits can only be tightened until it ends.")
                }
            }
            try st.setLimit(kind: k, pattern: p, minutes: m)
            if m == 0 { return .json(["removed": true, "pattern": p]) }
            return .json(["set": true, "pattern": p, "minutes_per_day": m])

        case "set_category":
            let k = try args.kind()
            let p = try args.pattern()
            guard let c = ActivityCategory(rawValue: args.str("category")?.lowercased() ?? "") else {
                throw ToolError(message: "'category' must be productive, neutral or distracting")
            }
            try st.setRule(kind: k, pattern: p, category: c)
            return .json(["set": true, "kind": k.rawValue, "pattern": p, "category": c.rawValue])

        case "get_timetable":
            let startDay = DayKey.resolve(args.str("start_date"))
            let endDay = args.str("end_date").map { DayKey.resolve($0) } ?? DayKey.offset(startDay, days: 7)
            guard let from = DayKey.date(from: startDay), let toStart = DayKey.date(from: endDay), toStart >= from else {
                throw ToolError(message: "Invalid date range")
            }
            let to = toStart.addingTimeInterval(86400)
            guard to.timeIntervalSince(from) <= 92 * 86400 else { throw ToolError(message: "Ask for at most 92 days at a time") }
            return .json(["from": startDay, "to": endDay,
                          "items": st.timetable(from: from, to: to).map(itemJSON),
                          "tasks": st.todos().map(itemJSON),
                          "awaiting_approval": st.pendingProposals().map(revisionJSON)])

        case "propose_timetable_change":
            let op = args.str("op")?.lowercased() ?? ""
            let reason = args.str("reason")
            switch op {
            case "add":
                let kind = TimetableItem.Kind(rawValue: args.str("kind") ?? "task") ?? .task
                guard let title = args.str("title") else { throw ToolError(message: "'add' needs a title") }
                let item: TimetableItem
                if kind == .todo {
                    item = TimetableItem(title: title, notes: args.str("notes"), start: Date(), end: Date(), kind: .todo,
                                         estimate: args.int("estimate_minutes").map { max(5, min(1440, $0)) }, wantsFocus: args.bool("focus"))
                } else {
                    guard let start = try parseTime(args.str("start"), field: "start"), let end = try parseTime(args.str("end"), field: "end") else {
                        throw ToolError(message: "'add' needs start and end (or kind \"todo\" for an unscheduled task)")
                    }
                    item = TimetableItem(title: title, notes: args.str("notes"), start: start, end: end, kind: kind)
                }
                return try submit(.create, item, reason: reason, st: st)
            case "update", "delete":
                guard let id = args.str("id"), var item = st.timetableItem(id: id) else {
                    throw ToolError(message: "Unknown 'id'. Call get_timetable to find item ids.")
                }
                if op == "update" {
                    if let t = args.str("title") { item.title = t }
                    if let n = args.str("notes") { item.notes = n }
                    if let s = try parseTime(args.str("start"), field: "start") { item.start = s }
                    if let e = try parseTime(args.str("end"), field: "end") { item.end = e }
                    if let k = args.str("kind") {
                        guard let kind = TimetableItem.Kind(rawValue: k) else { throw ToolError(message: "'kind' must be task or block") }
                        item.kind = kind
                    }
                    if let d = args.bool("done") { item.done = d }
                    if let m = args.int("estimate_minutes") { item.estimate = max(5, min(1440, m)) }
                    if let f = args.bool("focus") { item.wantsFocus = f }
                }
                return try submit(op == "update" ? .update : .delete, item, reason: reason, st: st)
            default:
                throw ToolError(message: "'op' must be add, update or delete")
            }

        case "get_timetable_history":
            let limit = min(500, max(1, args.int("limit") ?? 50))
            return .json(["history": st.timetableHistory(itemID: args.str("item_id"), limit: limit).map(revisionJSON)])

        case "get_devices":
            let today = DayKey.today
            return .json(["devices": st.devices().map { d -> JSON in
                let usage = st.deviceUsage(deviceID: d.id, sinceDay: today)
                return ["id": d.id, "name": d.name, "model": nn(d.model), "platform": nn(d.platform),
                        "paired_at": ts(d.pairedAt), "last_seen": ts(d.lastSeen), "online": d.isOnline(),
                        "today": usage.prefix(20).map { u -> JSON in
                            ["kind": u.kind.rawValue, "name": u.key, "minutes": minutes(u.seconds),
                             "approximate": u.precision > 60] }]
            }])

        default:
            throw ToolError(message: "Unknown tool: \(name)")
        }
    }


    /// Trusted agents' changes apply now (and can be undone from history); others wait for approval.
    func submit(_ op: TimetableRevision.Op, _ item: TimetableItem, reason: String?, st: VigilStore) throws -> ToolResult {
        do {
            if trusted {
                let rev = try st.applyTimetableChange(op, item: item, author: author)
                return .json(["applied": true, "revision": rev, "item": itemJSON(item),
                              "note": "Applied: the user has marked this agent as trusted. It's recorded in Vigil's history and can be undone there."])
            }
            let rev = try st.proposeTimetableChange(op, item: item, author: author, note: reason)
            return .json(["proposed": true, "revision": rev, "item": itemJSON(item),
                          "note": "Waiting for the user's approval in Vigil. Nothing has changed yet."])
        } catch let e as TimetableError { throw ToolError(message: e.description) }
    }

    public func handle(_ message: [String: Any]) -> [String: Any]? {
        var response: [String: Any]?
        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]

        func reply(_ result: JSON) {
            guard let id else { return }
            response = ["jsonrpc": "2.0", "id": id, "result": result]
        }
        func fail(_ code: Int, _ text: String) {
            guard let id else { return }
            response = ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text] as JSON]
        }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? "2025-06-18"
            reply([
                "protocolVersion": supportedProtocols.contains(requested) ? requested : "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "vigil", "title": "Vigil activity tracker", "version": serverVersion],
                "instructions": """
                Vigil tracks the user's Mac activity locally (apps, window titles, websites, idle time) and enforces a \
                Freedom/Cold Turkey style blocklist. Use get_daily_summary or get_daily_report for "how productive was I" \
                questions, get_usage/get_history for trends, and start_focus_session to help the user concentrate. \
                Ask before starting a locked session: locked sessions cannot be ended early.
                """,
            ])
        case "notifications/initialized", "notifications/cancelled":
            break
        case "ping":
            reply([String: Any]())
        case "tools/list":
            let readOnly = isReadOnly()
            reply(["tools": readOnly ? tools.filter { !writeTools.contains($0["name"] as? String ?? "") } : tools])
        case "tools/call":
            guard let name = params["name"] as? String else { fail(-32602, "Missing tool name"); return response }
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text: String
                switch try callTool(name, args) {
                case .text(let s):
                    text = s
                case .json(let object):
                    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                       let s = String(data: data, encoding: .utf8) {
                        text = s
                    } else {
                        text = String(describing: object)
                    }
                }
                reply(["content": [["type": "text", "text": text]], "isError": false])
            } catch let e as ToolError {
                reply(["content": [["type": "text", "text": e.message]], "isError": true])
            } catch {
                reply(["content": [["type": "text", "text": "Error: \(error)"]], "isError": true])
            }
        case "resources/list":
            reply(["resources": [Any]()])
        case "resources/templates/list":
            reply(["resourceTemplates": [Any]()])
        case "prompts/list":
            reply(["prompts": [Any]()])
        default:
            if id != nil { fail(-32601, "Method not found: \(method)") }
        }
        return response
    }

}
