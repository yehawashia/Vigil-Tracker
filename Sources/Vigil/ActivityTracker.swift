import AppKit
import ApplicationServices
import VigilCore

struct TrackerSnapshot: Equatable {
    var appName: String
    var bundleID: String?
    var pid: pid_t
    var windowTitle: String?
    var url: String?
    var domain: String?
    var category: ActivityCategory
    var since: Date
}

/// Event-driven activity tracker.
///
/// Latency: app switches (NSWorkspace) and window/tab/title changes (Accessibility observers)
/// trigger an immediate sample, so changes are picked up in ~0.1 s instead of waiting for the timer.
///
/// Cost: the 1 s heartbeat is cheap. It reuses the cached window title and browser URL and only
/// re-queries them when an event says something changed (with a slow fallback poll). The current
/// segment's end time is kept in memory and flushed to SQLite every few seconds, not every tick.
final class ActivityTracker {
    private let store: VigilStore
    private let browser: BrowserBridge

    var categorizer: Categorizer
    var idleThreshold: TimeInterval = 180
    var recordTitles = true
    var storeFullURLs = false
    var userPaused = false
    /// Called (on the main thread) when an Accessibility event says the focused window/title changed.
    var onFocusChange: (() -> Void)?

    private(set) var systemAway = false
    private(set) var isIdle = false
    private(set) var current: TrackerSnapshot?

    // Segment state
    private var currentID: Int64?
    private var currentKey: String?
    private var lastSample: Date?
    private var pendingEnd: Date?
    private var lastFlush = Date.distantPast

    // Cached expensive lookups
    private var cachedPID: pid_t = 0
    private var cachedTitle: String?
    private var cachedURL: String?
    private var lastDetailRefresh = Date.distantPast
    private var detailsDirty = true

    private var observers: [NSObjectProtocol] = []
    private var axObserver: AXObserver?
    private var axObservedPID: pid_t = 0

    /// Gaps longer than this start a new segment instead of extending the last one.
    private let continuity: TimeInterval = 10
    /// How often the in-memory segment end is written to disk.
    private let flushInterval: TimeInterval = 5
    /// Fallback re-read of title/URL when no event arrived (e.g. apps without AX title events).
    private let browserFallback: TimeInterval = 3
    private let titleFallback: TimeInterval = 5

    init(store: VigilStore, browser: BrowserBridge) {
        self.store = store
        self.browser = browser
        self.categorizer = Categorizer(rules: store.rules())
    }

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        let away: [Notification.Name] = [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                                         NSWorkspace.sessionDidResignActiveNotification]
        let back: [Notification.Name] = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                                         NSWorkspace.sessionDidBecomeActiveNotification]
        for name in away {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.setAway(true) })
        }
        for name in back {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.setAway(false) })
        }
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.setAway(true)
        })
        observers.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.setAway(false)
        })
    }

    private func setAway(_ away: Bool) {
        systemAway = away
        if away { closeSegment() }
    }

    /// Marks cached title/URL stale so the next tick re-reads them.
    func invalidateDetails() {
        detailsDirty = true
    }

    static func secondsSinceLastInput() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    @discardableResult
    func tick(now: Date = Date()) -> TrackerSnapshot? {
        if userPaused || systemAway {
            closeSegment()
            current = nil
            return nil
        }

        let idleFor = ActivityTracker.secondsSinceLastInput()
        if idleFor >= idleThreshold {
            if !isIdle {
                closeSegment(trimTo: now.addingTimeInterval(-idleFor))
            }
            isIdle = true
            current = nil
            return nil
        }
        isIdle = false

        guard let app = NSWorkspace.shared.frontmostApplication else {
            closeSegment()
            current = nil
            return nil
        }

        let pid = app.processIdentifier
        let name = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
        let bundleID = app.bundleIdentifier
        let isBrowser = browser.isSupported(bundleID)

        if pid != cachedPID {
            cachedPID = pid
            detailsDirty = true
            observeFocus(pid: pid)
        }

        let sinceRefresh = now.timeIntervalSince(lastDetailRefresh)
        let fallback = isBrowser ? browserFallback : titleFallback
        if detailsDirty || sinceRefresh >= fallback {
            refreshDetails(app: app, bundleID: bundleID, isBrowser: isBrowser)
            lastDetailRefresh = now
            detailsDirty = false
        }

        var title = cachedTitle
        var url = cachedURL
        if let u = url, u.hasPrefix("data:text/html") {
            url = nil
            title = "Blocked by Vigil"
        }

        let domain = Categorizer.domain(from: url)
        let category = categorizer.category(appName: name, bundleID: bundleID, domain: domain)
        let storedTitle = recordTitles ? title : nil
        let key = [bundleID ?? name, domain ?? "", storedTitle ?? ""].joined(separator: "|")

        if key == currentKey, currentID != nil, let last = lastSample, now.timeIntervalSince(last) < continuity {
            pendingEnd = now
            if now.timeIntervalSince(lastFlush) >= flushInterval { flush() }
        } else {
            flush()
            let start: Date
            if let last = lastSample, now.timeIntervalSince(last) < continuity { start = last } else { start = now }
            let storedURL = Categorizer.sanitize(url: url, keepQuery: storeFullURLs)
            currentID = try? store.insertActivity(start: start, end: now, appName: name, bundleID: bundleID,
                                                  windowTitle: storedTitle, url: storedURL, domain: domain, category: category)
            currentKey = key
            pendingEnd = nil
            lastFlush = now
            current = TrackerSnapshot(appName: name, bundleID: bundleID, pid: pid,
                                      windowTitle: title, url: url, domain: domain, category: category, since: start)
        }
        lastSample = now
        if current?.windowTitle != title { current?.windowTitle = title }
        return current
    }

    private func refreshDetails(app: NSRunningApplication, bundleID: String?, isBrowser: Bool) {
        if isBrowser, let bundleID, let tab = browser.activeTab(bundleID: bundleID) {
            cachedURL = tab.url.isEmpty ? nil : tab.url
            cachedTitle = tab.title.isEmpty ? nil : tab.title
        } else {
            cachedURL = nil
            cachedTitle = (recordTitles || BrowserBridge.titleOnly.contains(bundleID ?? ""))
                ? WindowInfo.focusedWindowTitle(pid: app.processIdentifier) : nil
        }
    }

    /// Writes the in-memory end time of the current segment.
    func flush() {
        guard let id = currentID, let end = pendingEnd else { return }
        try? store.extendActivity(id: id, to: end)
        pendingEnd = nil
        lastFlush = Date()
    }

    func closeSegment(trimTo end: Date? = nil) {
        flush()
        if let end, let id = currentID {
            _ = try? store.db.run("UPDATE activity SET end = MAX(start, MIN(end, ?)) WHERE id = ?", [end, id])
        }
        currentID = nil
        currentKey = nil
        lastSample = nil
        detailsDirty = true
    }

    // MARK: - Accessibility observers (instant title / tab / window change detection)

    private func observeFocus(pid: pid_t) {
        if let old = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .commonModes)
            axObserver = nil
        }
        axObservedPID = 0
        guard AXIsProcessTrusted(), pid != ProcessInfo.processInfo.processIdentifier else { return }

        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<ActivityTracker>.fromOpaque(refcon).takeUnretainedValue()
            tracker.detailsDirty = true
            tracker.onFocusChange?()
        }
        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let notifications = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                             kAXTitleChangedNotification]
        for n in notifications {
            AXObserverAddNotification(observer, appElement, n as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObserver = observer
        axObservedPID = pid
    }
}

enum WindowInfo {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let window = windowRef as! AXUIElement
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String, !title.isEmpty else { return nil }
        return title
    }
}
