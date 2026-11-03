import AppKit
import UserNotifications

/// Thin wrapper around UserNotifications. Notifications need a real .app bundle,
/// so this is a no-op when run with `swift run`.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpenDashboard: (() -> Void)?

    private var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func setUp() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func send(title: String, body: String, identifier: String = UUID().uuidString, sound: Bool = false) {
        guard available else {
            NSLog("[Vigil] %@ — %@", title, body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { self.onOpenDashboard?() }
        completionHandler()
    }
}
