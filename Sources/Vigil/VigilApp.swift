import AppKit
import SwiftUI
import VigilCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel = DemoScreenshots.requested ? DemoScreenshots.makeModel() : AppModel()
    private var screenshotRunner: ScreenshotRunner?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if DemoScreenshots.requested {
            NSApp.setActivationPolicy(.accessory)
            let runner = ScreenshotRunner(model: model)
            screenshotRunner = runner
            runner.run()
            return
        }
        // Only one tracker at a time (login item + LaunchAgent + manual open could all start one).
        // The launchd-managed (always-on) instance wins; any other copy steps aside.
        if let id = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if !others.isEmpty {
                let managedByLaunchd = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == AppModel.agentLabel
                if managedByLaunchd {
                    others.forEach { $0.forceTerminate() }
                } else {
                    exit(0)
                }
            }
        }
        NSApp.setActivationPolicy(.accessory)
        model.start()
        if model.store.setting("onboarded") == nil {
            model.store.setSetting("onboarded", "1")
            model.openDashboard(.settings)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Cold Turkey style: a locked session can't be escaped by quitting.
        if model.isLocked {
            model.notifier.send(title: "Vigil is locked",
                                body: "Your focus session is locked until it ends.", identifier: "locked-quit")
            return .terminateCancel
        }
        model.tracker.closeSegment()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.tracker.flush()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.openDashboard()
        return true
    }
}

@main
struct VigilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(delegate.model)
        } label: {
            MenuBarLabel()
                .environmentObject(delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The text next to the menu-bar icon: focus countdown when a session runs, otherwise today's score.
struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        MenuBarLabelContent(clock: model.clock)
    }
}

private struct MenuBarLabelContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var clock: Clock

    var body: some View {
        if let focus = model.focus {
            Text("\(Image(systemName: focus.locked ? "lock.fill" : "timer")) \(DurationText.clock(focus.end.timeIntervalSince(clock.now)))")
                .monospacedDigit()
        } else if model.trackingPaused {
            Image(systemName: "pause.circle")
        } else if model.today.activeSeconds > 300 {
            Text("\(Image(systemName: model.blockingActive ? "hand.raised.fill" : "eye")) \(model.today.score)")
                .monospacedDigit()
        } else {
            Image(systemName: model.blockingActive ? "hand.raised.fill" : "eye")
        }
    }
}

/// Hosts the SwiftUI dashboard in a regular AppKit window so it can be opened from anywhere
/// (menu bar, notifications, Dock reopen) and so the app gets a Dock icon while it's open.
final class DashboardWindowController: NSObject, NSWindowDelegate {
    static let shared = DashboardWindowController()
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let root = DashboardView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 640)
            let hosting = NSHostingController(rootView: root)
            let w = NSWindow(contentViewController: hosting)
            w.title = "Vigil"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 1120, height: 760))
            w.center()
            w.setFrameAutosaveName("VigilDashboard")
            w.delegate = self
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
