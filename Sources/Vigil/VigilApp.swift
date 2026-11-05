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
        if let focus = model.focus {
            // Only the countdown needs a per-second redraw; everything else updates when its data changes.
            FocusCountdownLabel(focus: focus, clock: model.clock)
        } else if model.trackingPaused {
            Image(systemName: "pause.circle")
        } else if model.today.activeSeconds > 300 {
            Text("\(model.blockingActive ? Image(systemName: "hand.raised.fill") : Image(nsImage: LogoGlyph.menuBar)) \(model.today.score)")
                .monospacedDigit()
        } else {
            if model.blockingActive { Image(systemName: "hand.raised.fill") } else { Image(nsImage: LogoGlyph.menuBar) }
        }
    }
}

private struct FocusCountdownLabel: View {
    var focus: FocusSession
    @ObservedObject var clock: Clock

    var body: some View {
        Text("\(Image(systemName: focus.locked ? "lock.fill" : "timer")) \(DurationText.clock(focus.end.timeIntervalSince(clock.now)))")
            .monospacedDigit()
    }
}

/// Hosts the SwiftUI dashboard in a regular AppKit window so it can be opened from anywhere
/// (menu bar, notifications, Dock reopen) and so the app gets a Dock icon while it's open.
final class DashboardWindowController: NSObject, NSWindowDelegate {
    static let shared = DashboardWindowController()
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible == true }

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

/// Vigil's logo simplified for the menu bar: six funnel-shaped petals with elliptical rims, drawn as
/// thin lines. A template image, so macOS tints it for light and dark menu bars.
enum LogoGlyph {
    static let menuBar: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let vector = NSImage(size: size, flipped: false) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY)
            NSColor.black.setStroke()
            for k in 0..<6 {
                let a = CGFloat(k) * .pi / 3
                let dir = CGPoint(x: cos(a), y: sin(a)), perp = CGPoint(x: -sin(a), y: cos(a))
                let inner: CGFloat = 1.1, outer: CGFloat = 7.6, waist: CGFloat = 0.45, mouth: CGFloat = 2.3
                func pt(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
                    CGPoint(x: c.x + dir.x * along + perp.x * across, y: c.y + dir.y * along + perp.y * across)
                }
                // Funnel sides, curving outward like the drawing.
                let sides = NSBezierPath()
                for side: CGFloat in [-1, 1] {
                    sides.move(to: pt(inner, side * waist))
                    sides.curve(to: pt(outer, side * mouth), controlPoint1: pt(outer * 0.6, side * waist * 1.2),
                                controlPoint2: pt(outer * 0.85, side * mouth * 0.7))
                }
                sides.lineWidth = 1.0
                sides.stroke()
                // Elliptical rim at the mouth.
                let rim = NSBezierPath(ovalIn: NSRect(x: -0.9, y: -mouth, width: 1.8, height: mouth * 2))
                var t = AffineTransform(translationByX: pt(outer, 0).x, byY: pt(outer, 0).y)
                t.rotate(byRadians: a)
                rim.transform(using: t)
                rim.lineWidth = 0.9
                rim.stroke()
            }
            return true
        }
        // Rasterise once: a drawing-handler image is redrawn on every menu-bar layout pass.
        let image = NSImage(size: size)
        for scale in [1, 2] {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            vector.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        image.accessibilityDescription = "Vigil"
        return image
    }()
}
