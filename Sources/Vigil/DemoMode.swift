import AppKit
import SwiftUI
import VigilCore
import VigilSync

/// `Vigil --demo-screenshots <dir>` renders the real UI against a throwaway database of
/// generated sample data and saves PNGs. Nothing from your own activity appears in them.
enum DemoScreenshots {
    static var requested: Bool { CommandLine.arguments.contains("--demo-screenshots") }

    static var outputDirectory: URL {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--demo-screenshots"), i + 1 < args.count {
            return URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("docs/screenshots")
    }

    static func makeModel() -> AppModel {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("vigil-demo-\(getpid()).sqlite").path
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        let model = AppModel(storePath: path, demo: true)
        do { try DemoData.seed(model.store) } catch { NSLog("[Vigil] demo seed failed: \(error)") }
        model.prepareDemo()
        return model
    }
}

extension AppModel {
    func prepareDemo() {
        reloadConfig()
        today = store.summary(day: DayKey.today)
        focus = store.activeFocusSession()
        activeSchedule = store.activeSchedule()
        blockingActive = true
        blockReason = focus.map { "Focus session: \($0.label ?? "Focus")" } ?? "Focus session"
        accessibilityGranted = true
        current = TrackerSnapshot(appName: "Safari", bundleID: "com.apple.Safari", pid: 0,
                                  windowTitle: "SwiftUI | Apple Developer Documentation",
                                  url: "https://developer.apple.com/documentation/swiftui",
                                  domain: "developer.apple.com", category: .productive,
                                  since: Date().addingTimeInterval(-540))
    }
}

/// Generates two weeks of plausible student/developer activity.
enum DemoData {
    private struct Block {
        let minute: Int          // start, minutes after midnight
        let length: Int          // minutes
        let app: String
        let bundle: String
        let domain: String?
        let title: String
    }

    private static let template: [Block] = [
        Block(minute: 8 * 60 + 40, length: 12, app: "Messages", bundle: "com.apple.MobileSMS", domain: nil, title: "Messages"),
        Block(minute: 8 * 60 + 52, length: 10, app: "Safari", bundle: "com.apple.Safari", domain: "bbc.co.uk", title: "BBC News"),
        Block(minute: 9 * 60 + 5, length: 48, app: "Xcode", bundle: "com.apple.dt.Xcode", domain: nil, title: "ActivityTracker.swift"),
        Block(minute: 9 * 60 + 55, length: 14, app: "Safari", bundle: "com.apple.Safari", domain: "github.com", title: "Pull requests · GitHub"),
        Block(minute: 10 * 60 + 9, length: 9, app: "Safari", bundle: "com.apple.Safari", domain: "youtube.com", title: "YouTube"),
        Block(minute: 10 * 60 + 18, length: 40, app: "Terminal", bundle: "com.apple.Terminal", domain: nil, title: "zsh — swift build"),
        Block(minute: 11 * 60, length: 22, app: "Safari", bundle: "com.apple.Safari", domain: "developer.apple.com", title: "SwiftUI | Apple Developer Documentation"),
        Block(minute: 11 * 60 + 22, length: 20, app: "Safari", bundle: "com.apple.Safari", domain: "stackoverflow.com", title: "How to observe window title changes - Stack Overflow"),
        Block(minute: 11 * 60 + 42, length: 16, app: "Safari", bundle: "com.apple.Safari", domain: "reddit.com", title: "r/programming"),
        Block(minute: 12 * 60 + 45, length: 18, app: "Safari", bundle: "com.apple.Safari", domain: "youtube.com", title: "YouTube"),
        Block(minute: 13 * 60 + 5, length: 42, app: "Notes", bundle: "com.apple.Notes", domain: nil, title: "Data Structures — lecture 6"),
        Block(minute: 13 * 60 + 47, length: 34, app: "Safari", bundle: "com.apple.Safari", domain: "leetcode.com", title: "Two Sum - LeetCode"),
        Block(minute: 14 * 60 + 21, length: 24, app: "Safari", bundle: "com.apple.Safari", domain: "claude.ai", title: "Claude"),
        Block(minute: 14 * 60 + 45, length: 14, app: "Safari", bundle: "com.apple.Safari", domain: "instagram.com", title: "Instagram"),
        Block(minute: 15 * 60, length: 50, app: "Safari", bundle: "com.apple.Safari", domain: "docs.python.org", title: "heapq — Heap queue algorithm"),
        Block(minute: 15 * 60 + 50, length: 18, app: "Messages", bundle: "com.apple.MobileSMS", domain: nil, title: "Messages"),
        Block(minute: 16 * 60 + 10, length: 38, app: "Safari", bundle: "com.apple.Safari", domain: "khanacademy.org", title: "Linear algebra | Khan Academy"),
        Block(minute: 18 * 60 + 30, length: 28, app: "Music", bundle: "com.apple.Music", domain: nil, title: "Music"),
        Block(minute: 19 * 60, length: 44, app: "Safari", bundle: "com.apple.Safari", domain: "netflix.com", title: "Netflix"),
        Block(minute: 19 * 60 + 45, length: 30, app: "Safari", bundle: "com.apple.Safari", domain: "wolframalpha.com", title: "Wolfram|Alpha"),
        Block(minute: 20 * 60 + 15, length: 20, app: "Safari", bundle: "com.apple.Safari", domain: "x.com", title: "Home / X"),
        Block(minute: 20 * 60 + 35, length: 26, app: "Preview", bundle: "com.apple.Preview", domain: nil, title: "Options, Futures and Other Derivatives.pdf"),
    ]

    /// Small deterministic PRNG so screenshots look the same every run.
    private struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    static func seed(_ store: VigilStore, now: Date = Date()) throws {
        let cal = Calendar.current
        try store.setRule(kind: .app, pattern: "com.apple.MobileSMS", category: .neutral)
        try store.setRule(kind: .app, pattern: "com.apple.Music", category: .neutral)
        try store.setRule(kind: .domain, pattern: "bbc.co.uk", category: .neutral)
        let categorizer = Categorizer(rules: store.rules())
        let nowMinute = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)

        try store.db.transaction {
            for dayOffset in 0..<60 {
                guard let day = cal.date(byAdding: .day, value: -dayOffset, to: cal.startOfDay(for: now)) else { continue }
                var rng = LCG(state: UInt64(1000 + dayOffset * 7919))
                let weekend = cal.isDateInWeekend(day)
                for block in template {
                    let category = categorizer.category(appName: block.app, bundleID: block.bundle, domain: block.domain)
                    if rng.next() < (weekend && category == .productive ? 0.55 : 0.12) { continue }
                    let factor = weekend && category == .distracting ? 1.5 : 0.65 + rng.next() * 0.6
                    let length = max(3, Int(Double(block.length) * factor))
                    if dayOffset == 0 && nowMinute >= 10 * 60 && block.minute + length > nowMinute - 20 { continue }
                    // Split the block into a few segments, the way real tracking records it.
                    var cursor = block.minute
                    let end = block.minute + length
                    while cursor < end {
                        let piece = min(end - cursor, 4 + Int(rng.next() * 12))
                        let start = day.addingTimeInterval(Double(cursor) * 60)
                        let finish = start.addingTimeInterval(Double(piece) * 60 - 2)
                        let url = block.domain.map { "https://\($0)/" }
                        try store.insertActivity(start: start, end: finish, appName: block.app, bundleID: block.bundle,
                                                 windowTitle: block.title, url: url, domain: block.domain, category: category)
                        cursor += piece
                    }
                }
                // Focus sessions on weekdays.
                if !weekend {
                    for (startMinute, minutes, label) in [(9 * 60 + 5, 50, "Swift project"), (15 * 60, 50, "Python practice")] {
                        if dayOffset == 0 && startMinute + minutes > nowMinute - 20 { continue }
                        let start = day.addingTimeInterval(Double(startMinute) * 60)
                        try store.db.run("INSERT INTO focus_sessions(start, end, locked, label, created_by) VALUES (?, ?, 0, ?, 'app')",
                                         [start, start.addingTimeInterval(Double(minutes) * 60), label])
                    }
                }
                // Blocked attempts.
                let attempts = dayOffset == 0 ? 11 : 3 + Int(rng.next() * 12)
                for i in 0..<attempts {
                    let t = day.addingTimeInterval(Double(9 * 60 + i * 37) * 60)
                    if dayOffset == 0 && t > now { break }
                    let target = ["youtube.com", "reddit.com", "instagram.com", "x.com"][i % 4]
                    try store.db.run("INSERT INTO block_events(time, day, kind, target) VALUES (?, ?, 'domain', ?)",
                                     [t, DayKey.string(for: day), target])
                }
            }
            // A locked session in progress, started by an agent.
            try store.db.run("INSERT INTO focus_sessions(start, end, locked, label, created_by) VALUES (?, ?, 1, ?, 'mcp')",
                             [now.addingTimeInterval(-18 * 60), now.addingTimeInterval(32 * 60), "Algorithms coursework"])
        }

        try store.setLimit(kind: .domain, pattern: "instagram.com", minutes: 20)
        try store.setLimit(kind: .domain, pattern: "reddit.com", minutes: 30)
        try store.setLimit(kind: .domain, pattern: "youtube.com", minutes: 45)
        try store.addBlock(kind: .app, pattern: "com.hnc.Discord")
        try store.addBlock(kind: .app, pattern: "com.valvesoftware.steam")
        try store.addSchedule(weekdays: [2, 3, 4, 5, 6], startMinute: 9 * 60, endMinute: 12 * 60, label: "Morning deep work")
        try store.addSchedule(weekdays: [1, 2, 3, 4, 5, 6, 7], startMinute: 22 * 60 + 30, endMinute: 7 * 60, label: "Wind down")

        // A sample week in the timetable, and one change suggested by an agent.
        let week = Calendar.current.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
        let plan: [(Int, Double, Double, String, TimetableItem.Kind)] = [
            (0, 9, 11, "Algorithms lecture", .task), (0, 14, 16, "Problem set 4", .block),
            (1, 9.5, 12, "Deep work: thesis", .block), (1, 13, 14, "Gym", .task), (1, 16, 17.5, "Reading group", .task),
            (2, 10, 12, "Essay outline", .block), (2, 15, 16, "Office hours", .task),
            (3, 9, 10.5, "Statistics", .task), (3, 11, 13, "Deep work: thesis", .block), (3, 18, 19, "Call home", .task),
            (4, 10, 12.5, "Lab report", .block), (4, 14, 15, "Weekly review", .task),
            (5, 11, 12, "Run", .task),
        ]
        for (dayIndex, from, to, title, kind) in plan {
            let day = week.addingTimeInterval(Double(dayIndex) * 86400)
            let item = TimetableItem(title: title, start: day.addingTimeInterval(from * 3600), end: day.addingTimeInterval(to * 3600), kind: kind)
            try store.applyTimetableChange(.create, item: item, author: dayIndex == 3 ? "device:demo" : "mac")
        }
        let saturday = week.addingTimeInterval(5 * 86400)
        try store.proposeTimetableChange(.create, item: TimetableItem(title: "Exam revision", start: saturday.addingTimeInterval(14 * 3600),
                                                                     end: saturday.addingTimeInterval(16 * 3600), kind: .block),
                                         note: "Your statistics exam is on Monday and Saturday afternoon is free.")

        // A few unscheduled tasks for the task panel.
        for (title, minutes, focus) in [("Revise statistics chapter 4", 90, true), ("Email supervisor about draft", 15, false),
                                        ("Read Kahneman, chapters 3–5", 60, false)] {
            try store.applyTimetableChange(.create, item: TimetableItem(title: title, start: now, end: now, kind: .todo,
                                                                         estimate: minutes, wantsFocus: focus), author: "mac")
        }

        // Two sample paired devices with a little reported usage.
        let phone = PairedDevice(id: "demo-phone", name: "Sam's iPhone", model: "iPhone 16 Pro", platform: "iOS",
                                 pairedAt: now.addingTimeInterval(-9 * 86400), lastSeen: now.addingTimeInterval(-40), revoked: false)
        let pad = PairedDevice(id: "demo-ipad", name: "Sam's iPad", model: "iPad Air", platform: "iPadOS",
                               pairedAt: now.addingTimeInterval(-3 * 86400), lastSeen: now.addingTimeInterval(-3 * 3600), revoked: false)
        try store.addDevice(phone)
        try store.addDevice(pad)
        let today = DayKey.string(for: now)
        store.recordDeviceUsage(deviceID: phone.id, [
            DeviceUsage(day: today, kind: .domain, key: "wikipedia.org", seconds: 1260, precision: 1, category: .productive),
            DeviceUsage(day: today, kind: .appGroup, key: "Social", seconds: 2700, precision: 900, category: .distracting),
            DeviceUsage(day: today, kind: .domain, key: "youtube.com", seconds: 840, precision: 1, category: .distracting),
            DeviceUsage(day: today, kind: .focus, key: "focus", seconds: 1500, precision: 1, category: .productive),
        ])
    }
}

/// Opens windows with each screen, captures them, writes PNGs, then exits.
/// Each capture is checked (full resolution, not blank) and retried until the window has rendered.
final class ScreenshotRunner {
    private let model: AppModel
    private let outDir: URL
    private var window: NSWindow?
    private var steps: [(@escaping () -> Void) -> Void] = []

    init(model: AppModel) {
        self.model = model
        self.outDir = DemoScreenshots.outputDirectory
    }

    func run() {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let sections: [(DashboardSection, String)] = [
            (.today, "today"), (.engine, "engine"), (.trends, "trends"), (.timetable, "timetable"), (.devices, "devices"), (.history, "history"), (.focus, "focus"),
            (.blocking, "blocking"), (.categories, "categories"), (.agents, "agents"),
        ]
        for (section, name) in sections {
            steps.append { [unowned self] done in self.showDashboard(section: section, dark: true); done() }
            steps.append { [unowned self] done in self.capture(name: "\(name)-dark", attempt: 1, done: done) }
        }
        steps.append { [unowned self] done in self.showDashboard(section: .today, dark: false); done() }
        steps.append { [unowned self] done in self.capture(name: "today-light", attempt: 1, done: done) }
        steps.append { [unowned self] done in self.showDashboard(section: .engine, dark: false); done() }
        steps.append { [unowned self] done in self.capture(name: "engine-light", attempt: 1, done: done) }
        steps.append { [unowned self] done in self.showDashboard(section: .trends, dark: false); done() }
        steps.append { [unowned self] done in self.capture(name: "trends-light", attempt: 1, done: done) }
        steps.append { [unowned self] done in self.showMenu(dark: true); done() }
        steps.append { [unowned self] done in self.capture(name: "menu-dark", attempt: 1, done: done) }
        steps.append { [unowned self] done in self.showMenu(dark: false); done() }
        steps.append { [unowned self] done in self.capture(name: "menu-light", attempt: 1, done: done) }
        steps.append { [unowned self] _ in
            print("Saved screenshots to \(self.outDir.path)")
            exit(0)
        }
        next()
    }

    private func next() {
        guard !steps.isEmpty else { return }
        let step = steps.removeFirst()
        step { [weak self] in
            // Give SwiftUI and Charts time to lay out and finish animating before the next step.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { self?.next() }
        }
    }

    private func showDashboard(section: DashboardSection, dark: Bool) {
        window?.orderOut(nil)
        model.section = section
        model.viewingDay = DayKey.today
        if section == .devices {
            // A made-up pairing code (no real secret: demo mode never opens a listener).
            model.reloadDevices()
            model.onlineDevices = ["demo-phone"]
            model.pairing = .open(mode: .qr, qrURL: "vigil://pair?v=1&h=demo&n=Demo%20Mac&k=AAAAAAAAAAAAAAAAAAAAAA&s=demo", expires: Date().addingTimeInterval(97))
        }
        // Trends is a long page: capture all of it.
        let height: CGFloat = section == .engine ? 1500 : section == .trends ? 2140 : section == .timetable ? 1180 : section == .history ? 1560 : 820
        let root = DashboardView()
            .environmentObject(model)
            .frame(width: 1280, height: height)
        let w = NSWindow(contentViewController: NSHostingController(rootView: root))
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.title = "Vigil"
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.setContentSize(NSSize(width: 1280, height: height))
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.center()
        w.orderFrontRegardless()
        window = w
    }

    private func showMenu(dark: Bool) {
        window?.orderOut(nil)
        let root = MenuBarView()
            .environmentObject(model)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        let w = NSWindow(contentViewController: NSHostingController(rootView: root))
        w.styleMask = [.borderless]
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.center()
        w.orderFrontRegardless()
        window = w
    }

    private func grab(_ window: NSWindow) -> CGImage? {
        if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                               [.boundsIgnoreFraming, .bestResolution]) {
            return image
        }
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    /// Full size and not a single flat colour.
    private func looksRendered(_ image: CGImage, window: NSWindow) -> Bool {
        let expected = Int(window.frame.width * window.backingScaleFactor * 0.95)
        guard image.width >= expected else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        var colours = Set<String>()
        for gx in 1...19 {
            for gy in 1...19 {
                let x = image.width * gx / 20, y = image.height * gy / 20
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    colours.insert(String(format: "%.2f-%.2f-%.2f", c.redComponent, c.greenComponent, c.blueComponent))
                }
            }
        }
        return colours.count >= 3
    }

    private func capture(name: String, attempt: Int, done: @escaping () -> Void) {
        guard let window else { done(); return }
        guard let image = grab(window), looksRendered(image, window: window) else {
            if attempt < 6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.capture(name: name, attempt: attempt + 1, done: done)
                }
            } else {
                print("Could not capture \(name) after \(attempt) attempts")
                done()
            }
            return
        }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { done(); return }
        let url = outDir.appendingPathComponent("\(name).png")
        do {
            try png.write(to: url)
            print("  \(url.lastPathComponent)\(attempt > 1 ? " (attempt \(attempt))" : "")")
        } catch {
            print("Could not write \(url.path): \(error)")
        }
        done()
    }
}
