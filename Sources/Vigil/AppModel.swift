import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VigilCore
import VigilSync

enum DashboardSection: String, CaseIterable, Identifiable {
    case today, engine, trends, timetable, history, focus, blocking, devices, categories, agents, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .engine: return "Engine"
        case .trends: return "Trends"
        case .timetable: return "Timetable"
        case .devices: return "Devices"
        case .history: return "History"
        case .focus: return "Focus"
        case .blocking: return "Blocking"
        case .categories: return "Categories"
        case .agents: return "Agents (MCP)"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .today: return "sun.max"
        case .engine: return "point.3.connected.trianglepath.dotted"
        case .trends: return "chart.xyaxis.line"
        case .timetable: return "calendar"
        case .devices: return "ipad.and.iphone"
        case .history: return "chart.bar.xaxis"
        case .focus: return "timer"
        case .blocking: return "hand.raised"
        case .categories: return "tag"
        case .agents: return "point.3.connected.trianglepath.dotted"
        case .settings: return "gearshape"
        }
    }
}

/// Day / night look. `auto` uses Day from 07:00 to 19:00 and Night otherwise.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, day, night, auto
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Match macOS"
        case .day: return "Day"
        case .night: return "Night"
        case .auto: return "Auto (by time)"
        }
    }

    /// nil means follow macOS.
    func appearanceName(at date: Date = Date()) -> NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .day: return .aqua
        case .night: return .darkAqua
        case .auto:
            let hour = Calendar.current.component(.hour, from: date)
            return (7..<19).contains(hour) ? .aqua : .darkAqua
        }
    }
}

/// Ticks every two seconds; only the menu-bar countdown observes it.
final class Clock: ObservableObject {
    @Published var now = Date()
}

final class AppModel: ObservableObject {
    let clock = Clock()
    let store: VigilStore
    let browser: BrowserBridge
    let tracker: ActivityTracker
    let blocker: Blocker
    let census: TabCensus
    let notifier = Notifier()

    // Live state
    @Published var current: TrackerSnapshot?
    @Published var isIdle = false
    @Published var today: DaySummary
    /// Charts and forecasts for the Trends page and paired devices. Built off the main thread.
    @Published var trends: TrendsData?
    /// Objects, links and conclusions (the data engine). Built off the main thread.
    @Published var engine: EngineData?
    @Published var engineDays = 14
    /// Object open in the Engine inspector.
    @Published var inspected: String?
    @Published var focus: FocusSession?
    @Published var activeSchedule: BlockSchedule?
    @Published var blockingActive = false
    @Published var blockReason = ""
    /// Every open tab in every running supported browser (in memory only).
    @Published var openTabs: [OpenTab] = []

    // Configuration
    @Published var blocklist: [BlockItem] = []
    @Published var limits: [DailyLimit] = []
    @Published var schedules: [BlockSchedule] = []
    @Published var rules: [CategoryRule] = []
    /// Agent changes waiting for approval.
    @Published var proposals: [TimetableRevision] = []
    /// The time block running now, if any.
    @Published var activeTimeBlock: TimetableItem?
    /// Bumped whenever the timetable changes, so open views reload.
    @Published var timetableVersion = 0

    // Settings
    @Published var trackingPaused = false
    @Published var idleMinutes = 3
    @Published var recordTitles = true
    @Published var reportEnabled = true
    @Published var reportMinuteOfDay = 21 * 60
    @Published var closeTabsInstead = false
    @Published var retentionDays = 180
    @Published var storeFullURLs = false
    @Published var mcpReadOnly = false
    @Published var appearanceMode: AppearanceMode = .system { didSet { applyAppearance() } }
    @Published var accessibilityGranted = WindowInfo.isTrusted

    // Paired devices
    private(set) var host: HostServer?
    @Published var devices: [PairedDevice] = []
    @Published var onlineDevices: Set<String> = []
    @Published var pairing: PairingEvent?

    // Navigation
    @Published var section: DashboardSection = .today
    @Published var viewingDay: String = DayKey.today
    @Published var lastMessage: String?

    private var timer: Timer?
    private var tickCount = 0
    private var lastFocusID: Int64?
    private var iconCache: [String: NSImage] = [:]
    private var observers: [NSObjectProtocol] = []
    private var napActivity: NSObjectProtocol?
    private var sigtermSource: DispatchSourceSignal?

    // Caches so the 1 s heartbeat does no database reads in the common case.
    private var lastDataVersion = 0
    private var pendingSessions: [FocusSession] = []
    private var timeBlocks: [TimetableItem] = []
    private var lastReportDay: String?
    private var lastMaintenanceDay: String?
    private var pendingTick: DispatchWorkItem?

    // Summaries are computed off the main thread on a separate read connection.
    private let summaryQueue = DispatchQueue(label: "dev.vigil.summary", qos: .utility)
    private var readerStore: VigilStore?
    private var summaryInFlight = false
    private var lastSummaryRefresh = Date.distantPast

    /// True for the sample-data instance used to render README screenshots.
    let demoMode: Bool

    init(storePath: String? = nil, demo: Bool = false) {
        self.demoMode = demo
        let store: VigilStore
        do {
            store = try storePath.map { try VigilStore(path: $0) } ?? VigilStore()
        } catch {
            // Fall back to a temporary database so the app still opens and can show the error.
            NSLog("[Vigil] Could not open database: \(error)")
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("vigil-fallback.sqlite")
            store = try! VigilStore(path: fallback.path)
        }
        let browser = BrowserBridge()
        self.store = store
        self.browser = browser
        self.tracker = ActivityTracker(store: store, browser: browser)
        self.blocker = Blocker(store: store, browser: browser)
        self.census = TabCensus(browser: browser)
        self.today = DaySummary.empty(day: DayKey.today)
        self.readerStore = try? storePath.map { try VigilStore(path: $0) } ?? VigilStore()
        loadSettings()
        reloadConfig()
        reloadFocusCache()
        lastReportDay = store.setting("last_report_day")
        lastDataVersion = store.dataVersion()
    }

    // MARK: - Lifecycle

    func start() {
        // A menu-bar tracker must keep ticking in the background: opt out of App Nap timer throttling
        // (idle system sleep is still allowed, so this doesn't keep the Mac awake).
        napActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Vigil tracks activity and enforces blocking continuously")

        // launchd / logout / pkill send SIGTERM: save the in-progress segment before exiting.
        signal(SIGTERM, SIG_IGN)
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler { [weak self] in
            self?.tracker.closeSegment()
            exit(0)
        }
        sigterm.resume()
        sigtermSource = sigterm

        applyAppearance()
        // Saved reports are private: tighten any written by older versions to 0600.
        let reports = VigilPaths.reportsDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: reports.path)) ?? [] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reports.appendingPathComponent(name).path)
        }
        notifier.onOpenDashboard = { [weak self] in self?.openDashboard() }
        notifier.setUp()
        blocker.onBlocked = { [weak self] target, reason in
            self?.notifier.send(title: "\(target) is blocked", body: reason, identifier: "block-\(target)")
        }
        tracker.onFocusChange = { [weak self] in self?.requestTick() }
        tracker.start()

        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.blocker.check(app: app)
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self.blocker.check(app: app)
            }
            self.tracker.invalidateDetails()
            self.tick()
        })

        // 1 s heartbeat. Most ticks only check idle time and compare cached state.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        startHost()
        catchUpMissedReport()
        tick()
        refreshSummary(force: true)
    }

    /// Coalesces bursts of Accessibility events (a tab switch fires several) into one sample ~30 ms later.
    func requestTick() {
        pendingTick?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.tick() }
        pendingTick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
    }

    private func tick() {
        let now = Date()
        clock.now = now
        tracker.userPaused = trackingPaused
        let snapshot = tracker.tick(now: now)
        if current != snapshot { current = snapshot }
        if isIdle != tracker.isIdle { isIdle = tracker.isIdle }
        tickCount += 1

        // Reload config only when another process (the MCP server) actually wrote something.
        let version = store.dataVersion()
        if version != lastDataVersion {
            lastDataVersion = version
            reloadConfig()
            reloadFocusCache()
        }
        if tickCount % 60 == 0 && appearanceMode == .auto { applyAppearance(now: now) }
        if tickCount % 10 == 0 {
            let trusted = WindowInfo.isTrusted
            if accessibilityGranted != trusted { accessibilityGranted = trusted }
        }

        let session = pendingSessions.first { $0.isActive(at: now) }
        let schedule = schedules.first { $0.isActive(at: now) }
        let block = timeBlocks.first { $0.isActive(at: now) }
        if activeTimeBlock != block { activeTimeBlock = block }
        handleFocusTransitions(session)
        if focus != session { focus = session }
        if activeSchedule != schedule { activeSchedule = schedule }

        blocker.closeTabsInstead = closeTabsInstead
        blocker.update(focus: session, timeBlock: block, schedule: schedule, now: now)
        blocker.enforce(snapshot: snapshot, now: now)
        if blockingActive != blocker.isBlockingActive { blockingActive = blocker.isBlockingActive }
        if blockReason != blocker.reason { blockReason = blocker.reason }

        if now.timeIntervalSince(lastSummaryRefresh) >= 30 { refreshSummary() }
        if !trackingPaused && !tracker.systemAway { refreshTabs(now: now) }
        checkDailyReport(now: now)
        runMaintenanceIfNeeded(now: now)
    }

    /// Once a day: drop data past the retention window, then tidy the database.
    private func runMaintenanceIfNeeded(now: Date) {
        let day = DayKey.string(for: now)
        guard lastMaintenanceDay != day else { return }
        lastMaintenanceDay = day
        tracker.flush()
        let removed = store.prune(olderThanDays: retentionDays)
        if removed > 5000 { store.compact() } else { store.maintenance() }
    }

    // MARK: - Paired devices (local network only; see docs/ARCHITECTURE.md §4)

    var hostID: String {
        if let id = store.setting("host_id") { return id }
        let id = Pairing.newID()
        store.setSetting("host_id", id)
        return id
    }

    var hostName: String { demoMode ? "Demo Mac" : (Host.current().localizedName ?? "Mac") }

    private func startHost() {
        guard !demoMode else { return }
        do {
            let server = try HostServer(hostID: hostID, hostName: hostName, storePath: VigilPaths.databaseURL.path,
                                        keyFile: DeviceKeyFile(url: VigilPaths.supportDirectory.appendingPathComponent("device-keys.json")))
            server.onPairingEvent = { [weak self] event in
                guard let self else { return }
                self.pairing = event
                if case .paired(let d) = event {
                    self.notifier.send(title: "\(d.name) is paired", body: "It syncs with this Mac over your local network.", identifier: "paired-\(d.id)")
                }
                self.reloadDevices()
            }
            server.onDevicesChanged = { [weak self] in self?.reloadDevices() }
            server.restartSync()
            host = server
        } catch {
            NSLog("[Vigil] Device sync unavailable: \(error)")
        }
        reloadDevices()
    }

    func reloadDevices() {
        let list = store.devices()
        if list != devices { devices = list }
        let online = host?.connectedDevices ?? []
        if online != onlineDevices { onlineDevices = online }
    }

    func openPairing(_ mode: PairingMode) { host?.openPairing(mode: mode) }
    func closePairing() { host?.closePairing(); pairing = nil }
    func confirmPairing(_ ok: Bool) { host?.confirmPairing(ok) }

    func revokeDevice(_ d: PairedDevice) {
        host?.revoke(deviceID: d.id)
        lastMessage = "\(d.name) was removed. It can't connect again unless you pair it."
        reloadDevices()
    }

    func deviceUsageToday(_ d: PairedDevice) -> [DeviceUsage] {
        store.deviceUsage(deviceID: d.id, sinceDay: DayKey.today)
    }

    // MARK: - Tabs

    /// Re-reads open tabs every 10 s (sooner with `force`). Publishes only when something changed.
    func refreshTabs(now: Date = Date(), force: Bool = false) {
        if demoMode {
            // Screenshots use made-up tabs, never the real browser's.
            if openTabs.isEmpty { openTabs = OpenTab.samples }
            return
        }
        if census.refresh(categorizer: tracker.categorizer, includeTitles: recordTitles, now: now, force: force) {
            openTabs = census.tabs
        }
    }

    func closeDistractingTabs() {
        let n = census.closeDistracting(categorizer: tracker.categorizer)
        lastMessage = n == 0 ? "No distracting tabs to close." : "Closed \(n) distracting tab\(n == 1 ? "" : "s")."
        refreshTabs(force: true)
    }

    func closeTab(_ tab: OpenTab) {
        census.close(tab)
        refreshTabs(force: true)
    }

    private func reloadFocusCache() {
        pendingSessions = store.pendingFocusSessions()
    }

    private func handleFocusTransitions(_ session: FocusSession?) {
        if let previous = lastFocusID, session?.id != previous {
            // The session we were watching is over. Was it completed or stopped?
            if let finished = store.focusSessions(sinceDay: DayKey.offset(DayKey.today, days: -1)).first(where: { $0.id == previous }),
               finished.endedEarly == nil {
                notifier.send(title: "Focus session complete",
                              body: "\(finished.plannedMinutes) minutes\(finished.label.map { " of \($0)" } ?? ""). Take a short break.",
                              sound: true)
            }
            reloadFocusCache()
        }
        lastFocusID = session?.id
    }

    /// Recomputes today's summary on a background queue and publishes it only if it changed.
    func refreshSummary(force: Bool = false) {
        if viewingDay > DayKey.today { viewingDay = DayKey.today }
        guard force || !summaryInFlight else { return }
        tracker.flush()
        lastSummaryRefresh = Date()
        summaryInFlight = true
        let day = DayKey.today
        let reader = readerStore ?? store
        let useMain = readerStore == nil
        let compute = { [weak self] in
            let summary = reader.summary(day: day)
            DispatchQueue.main.async {
                guard let self else { return }
                self.summaryInFlight = false
                if self.today != summary { self.today = summary }
            }
        }
        if useMain { compute() } else { summaryQueue.async(execute: compute) }
    }

    private var trendsInFlight = false
    private var engineInFlight = false

    /// Rebuilds the engine at most once a minute (or when forced), on the reader connection.
    func refreshEngine(force: Bool = false) {
        guard !engineInFlight else { return }
        if !force, let e = engine, e.days == engineDays, Date().timeIntervalSince(e.computedAt) < 60 { return }
        engineInFlight = true
        tracker.flush()
        let reader = readerStore ?? store
        let days = engineDays
        let work = { [weak self] in
            let data = reader.engine(days: days)
            DispatchQueue.main.async {
                guard let self else { return }
                self.engineInFlight = false
                if self.engine != data { self.engine = data }
            }
        }
        if readerStore == nil { work() } else { summaryQueue.async(execute: work) }
    }

    /// Rebuilds trends at most once a minute (or when forced, e.g. opening the page), on the reader connection.
    func refreshTrends(force: Bool = false) {
        guard !trendsInFlight else { return }
        if !force, let t = trends, Date().timeIntervalSince(t.computedAt) < 60 { return }
        if force, let t = trends, Date().timeIntervalSince(t.computedAt) < 5 { return }
        trendsInFlight = true
        tracker.flush()
        let reader = readerStore ?? store
        let work = { [weak self] in
            let data = reader.trends()
            DispatchQueue.main.async {
                guard let self else { return }
                self.trendsInFlight = false
                if self.trends != data { self.trends = data }
            }
        }
        if readerStore == nil { work() } else { summaryQueue.async(execute: work) }
    }

    func reloadConfig() {
        let newBlocklist = store.blocklist()
        let newLimits = store.limits()
        let newSchedules = store.schedules()
        let newRules = store.rules()
        if newBlocklist != blocklist || newLimits != limits { blocklist = newBlocklist; limits = newLimits; blocker.reload() }
        if newSchedules != schedules { schedules = newSchedules }
        if newRules != rules { rules = newRules; tracker.categorizer = Categorizer(rules: newRules) }
        reloadTimetable()
    }

    // MARK: - Timetable

    private func reloadTimetable() {
        let blocks = store.upcomingTimeBlocks()
        let pending = store.pendingProposals()
        if blocks != timeBlocks || pending != proposals {
            if pending.count > proposals.count, let newest = pending.last {
                notifier.send(title: "Your agent suggested a timetable change", body: newest.summary, identifier: "proposal-\(newest.id)")
            }
            timeBlocks = blocks
            proposals = pending
        }
        timetableVersion &+= 1
    }

    /// Your own edits on the Mac apply immediately and are recorded in history.
    func saveTimetableItem(_ item: TimetableItem, isNew: Bool) {
        do {
            try store.applyTimetableChange(isNew ? .create : .update, item: item, author: "mac")
        } catch {
            lastMessage = "\(error)"
        }
        reloadTimetable()
    }

    func deleteTimetableItem(_ item: TimetableItem) {
        try? store.applyTimetableChange(.delete, item: item, author: "mac")
        reloadTimetable()
    }

    func approve(_ proposal: TimetableRevision) {
        do { try store.approveProposal(id: proposal.id); lastMessage = "Approved: \(proposal.summary)" } catch { lastMessage = "\(error)" }
        reloadTimetable()
    }

    func reject(_ proposal: TimetableRevision) {
        store.rejectProposal(id: proposal.id)
        reloadTimetable()
    }

    func revert(_ revision: TimetableRevision) {
        do { try store.revert(revisionID: revision.id, author: "mac"); lastMessage = "Reverted." } catch { lastMessage = "\(error)" }
        reloadTimetable()
    }

    // MARK: - Settings

    private func loadSettings() {
        idleMinutes = store.setting("idle_minutes", default: 3)
        recordTitles = store.setting("record_titles", default: 1) == 1
        reportEnabled = store.setting("report_enabled", default: 1) == 1
        reportMinuteOfDay = store.setting("report_minute_of_day", default: 21 * 60)
        closeTabsInstead = store.setting("close_tabs", default: 0) == 1
        retentionDays = store.setting("retention_days", default: 180)
        storeFullURLs = store.setting("store_full_urls", default: 0) == 1
        mcpReadOnly = store.setting("mcp_readonly", default: 0) == 1
        appearanceMode = AppearanceMode(rawValue: store.setting("appearance") ?? "") ?? .system
        applySettings()
    }

    func saveSettings() {
        store.setSetting("idle_minutes", String(idleMinutes))
        store.setSetting("record_titles", recordTitles ? "1" : "0")
        store.setSetting("report_enabled", reportEnabled ? "1" : "0")
        store.setSetting("report_minute_of_day", String(reportMinuteOfDay))
        store.setSetting("close_tabs", closeTabsInstead ? "1" : "0")
        store.setSetting("retention_days", String(retentionDays))
        store.setSetting("store_full_urls", storeFullURLs ? "1" : "0")
        store.setSetting("mcp_readonly", mcpReadOnly ? "1" : "0")
        store.setSetting("appearance", appearanceMode.rawValue)
        applySettings()
    }

    private func applySettings() {
        tracker.idleThreshold = TimeInterval(max(1, idleMinutes) * 60)
        tracker.recordTitles = recordTitles
        tracker.storeFullURLs = storeFullURLs
    }

    // MARK: - Day / night

    private var appliedAppearance: NSAppearance.Name?? = .none

    /// Sets the whole app's look (dashboard, menu-bar panel and alerts). Only touches AppKit when it changes.
    func applyAppearance(now: Date = Date()) {
        guard !demoMode, let app = NSApp else { return }  // screenshots set their own per-window appearance
        let name = appearanceMode.appearanceName(at: now)
        if case .some(let applied) = appliedAppearance, applied == name { return }
        appliedAppearance = .some(name)
        app.appearance = name.flatMap { NSAppearance(named: $0) }
    }

    /// Menu-bar quick switch: flips between Day and Night.
    func toggleDayNight() {
        let isDarkNow = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        appearanceMode = isDarkNow ? .day : .night
        saveSettings()
    }

    // MARK: - Always-on background service (LaunchAgent)

    static let agentLabel = "dev.vigil.Vigil"
    static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    /// True when Vigil is installed as a LaunchAgent that starts at login and is restarted if it ever stops.
    var runsAlways: Bool { FileManager.default.fileExists(atPath: AppModel.agentURL.path) }

    /// Installs the LaunchAgent and hands over to it: this instance quits and launchd starts the managed one.
    func enableAlwaysOn() {
        let exe = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let plist: [String: Any] = [
            "Label": AppModel.agentLabel,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 5,
            "ProcessType": "Interactive",
        ]
        do {
            try FileManager.default.createDirectory(at: AppModel.agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: AppModel.agentURL, options: .atomic)
        } catch {
            lastMessage = "Couldn't install background service: \(error.localizedDescription)"
            return
        }
        // Bootstrap after we've exited so the single-instance check doesn't fight the new process.
        let uid = getuid()
        let script = "sleep 1; /bin/launchctl bootout gui/\(uid)/\(AppModel.agentLabel) 2>/dev/null; /bin/launchctl bootstrap gui/\(uid) '\(AppModel.agentURL.path)'"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try? p.run()
        tracker.closeSegment()
        exit(0)
    }

    /// Stops the always-on service. Vigil keeps running until you quit it.
    func disableAlwaysOn() {
        guard !isLocked else { lastMessage = "Not during a locked session."; return }
        try? FileManager.default.removeItem(at: AppModel.agentURL)
        objectWillChange.send()
        lastMessage = "Vigil will no longer restart automatically."
        // Unload last: if launchd manages this process, booting it out also ends this process.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())/\(AppModel.agentLabel)"]
        tracker.closeSegment()
        try? p.run()
    }

    /// Quit from the menu. Under the always-on service this pauses Vigil until the next login.
    func quit() {
        guard !isLocked else { return }
        tracker.closeSegment()
        if runsAlways {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["bootout", "gui/\(getuid())/\(AppModel.agentLabel)"]
            try? p.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
        } else {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Daily report

    private func checkDailyReport(now: Date) {
        guard reportEnabled else { return }
        let day = DayKey.string(for: now)
        guard lastReportDay != day else { return }
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        guard minute >= reportMinuteOfDay else { return }
        deliverReport(day: day, title: "Your day with Vigil")
    }

    /// If the Mac was asleep at report time, send yesterday's report on the next launch.
    private func catchUpMissedReport() {
        guard reportEnabled else { return }
        let yesterday = DayKey.offset(DayKey.today, days: -1)
        let last = store.setting("last_report_day") ?? ""
        guard last < yesterday, store.summary(day: yesterday).activeSeconds > 600 else { return }
        deliverReport(day: yesterday, title: "Yesterday with Vigil")
    }

    func deliverReport(day: String, title: String) {
        let summary = store.summary(day: day)
        store.saveReport(day: day)
        store.setSetting("last_report_day", day)
        lastReportDay = day
        notifier.send(title: title, body: store.notificationText(for: summary), identifier: "report-\(day)", sound: true)
    }

    func sendReportNow() {
        let day = DayKey.today
        let summary = store.summary(day: day)
        store.saveReport(day: day)
        notifier.send(title: "Productivity update", body: store.notificationText(for: summary), identifier: "report-now")
    }

    // MARK: - Focus

    func startFocus(minutes: Int, locked: Bool, label: String?) {
        let trimmed = label?.trimmingCharacters(in: .whitespaces)
        do {
            try store.startFocusSession(minutes: minutes, locked: locked,
                                        label: (trimmed?.isEmpty ?? true) ? nil : trimmed, createdBy: "app")
            notifier.send(title: "Focus session started",
                          body: "\(minutes) minutes\(locked ? ", locked" : ""). Your blocklist is active.",
                          identifier: "focus-start")
        } catch {
            lastMessage = "Couldn't start session: \(error)"
        }
        reloadFocusCache()
        tick()
    }

    func stopFocus() {
        switch store.stopFocusSession() {
        case .locked: lastMessage = "This session is locked. It ends at its scheduled time."
        case .stopped, .noSession: break
        }
        reloadFocusCache()
        tick()
    }

    var isLocked: Bool { focus?.locked == true }

    // MARK: - Blocklist / limits / schedules / rules

    func addBlock(kind: TargetKind, pattern: String) {
        try? store.addBlock(kind: kind, pattern: pattern)
        reloadConfig()
    }

    func removeBlock(_ item: BlockItem) {
        guard !isLocked else { lastMessage = "You can't remove items during a locked session."; return }
        try? store.removeBlock(kind: item.kind, pattern: item.pattern)
        reloadConfig()
    }

    func setLimit(kind: TargetKind, pattern: String, minutes: Int) {
        try? store.setLimit(kind: kind, pattern: pattern, minutes: minutes)
        reloadConfig()
    }

    func deleteLimit(_ limit: DailyLimit) {
        guard !isLocked else { lastMessage = "You can't remove limits during a locked session."; return }
        store.deleteLimit(id: limit.id)
        reloadConfig()
    }

    func addSchedule(weekdays: [Int], start: Int, end: Int, label: String?) {
        try? store.addSchedule(weekdays: weekdays, startMinute: start, endMinute: end, label: label)
        reloadConfig()
    }

    func setSchedule(_ schedule: BlockSchedule, enabled: Bool) {
        if !enabled && schedule.isActive() && isLocked { return }
        store.setScheduleEnabled(id: schedule.id, enabled: enabled)
        reloadConfig()
    }

    func deleteSchedule(_ schedule: BlockSchedule) {
        store.deleteSchedule(id: schedule.id)
        reloadConfig()
    }

    func setCategory(kind: TargetKind, pattern: String, category: ActivityCategory) {
        try? store.setRule(kind: kind, pattern: pattern, category: category)
        reloadConfig()
        refreshSummary()
    }

    func deleteRule(_ rule: CategoryRule) {
        store.deleteRule(id: rule.id)
        reloadConfig()
        refreshSummary()
    }

    // MARK: - Windows & helpers

    func openDashboard(_ section: DashboardSection? = nil) {
        if let section { self.section = section }
        DashboardWindowController.shared.show(model: self)
    }

    func icon(bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = image
        return image
    }

    var mcpBinaryPath: String {
        if demoMode { return "/Users/you/Applications/Vigil.app/Contents/MacOS/vigil-mcp" }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/vigil-mcp")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled.path }
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("VigilMCP")
        return sibling.path
    }

    /// Adds Vigil to Claude Desktop's MCP config, preserving anything already there.
    func installInClaudeDesktop() {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["vigil"] = ["command": mcpBinaryPath, "args": [String]()]
        root["mcpServers"] = servers
        do {
            try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: configURL, options: .atomic)
            lastMessage = "Added to Claude Desktop. Restart Claude to connect."
        } catch {
            lastMessage = "Couldn't write Claude config: \(error.localizedDescription)"
        }
    }

    func exportCSV(days: Int) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "vigil-activity.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let iso = ISO8601DateFormatter()
        func q(_ s: String?) -> String { "\"" + (s ?? "").replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var csv = "start,end,seconds,app,bundle_id,category,domain,url,window_title\n"
        for i in stride(from: days - 1, through: 0, by: -1) {
            for r in store.activities(day: DayKey.offset(DayKey.today, days: -i)) {
                csv += [iso.string(from: r.start), iso.string(from: r.end), String(Int(r.duration)), q(r.appName),
                        q(r.bundleID), r.category.rawValue, q(r.domain), q(r.url), q(r.windowTitle)].joined(separator: ",") + "\n"
            }
        }
        writePrivate(csv, to: url)
    }

    /// Exports the daily reports for the last `days` days as one plain-text file.
    func exportText(days: Int) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "vigil-report-\(DayKey.today).txt"
        panel.allowedContentTypes = [.plainText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var text = ""
        for i in 0..<days {
            let day = DayKey.offset(DayKey.today, days: -i)
            guard i == 0 || store.summary(day: day).activeSeconds >= 60 else { continue }
            text += store.markdownReport(day: day) + "\n\n"
        }
        writePrivate(text, to: url)
    }

    /// Writes a file only you can read (0600), wherever you chose to save it.
    private func writePrivate(_ text: String, to url: URL) {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            lastMessage = "Saved \(url.lastPathComponent)."
        } catch {
            lastMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    func deleteAllData() {
        tracker.closeSegment()
        store.deleteAllActivity()
        refreshSummary()
    }

    func revealDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([VigilPaths.databaseURL])
    }

    func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
