import Foundation
import SafariServices

/// Receives {"domain": "...", "seconds": n, "day": "YYYY-MM-DD"} batches from background.js and adds
/// them to the shared App Group. Only the site's domain is ever stored: no paths, titles or searches.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        if let entries = message?["usage"] as? [[String: Any]] {
            let d = UserDefaults(suiteName: "group.dev.vigil.mobile")
            for e in entries.prefix(200) {
                guard let domain = (e["domain"] as? String)?.lowercased(), domain.count <= 120,
                      domain.range(of: "^[a-z0-9.-]+$", options: .regularExpression) != nil,
                      let seconds = e["seconds"] as? Double, seconds > 0, seconds <= 3600,
                      let day = e["day"] as? String, day.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil
                else { continue }
                var all = d?.dictionary(forKey: "domains.\(day)") as? [String: Double] ?? [:]
                all[domain, default: 0] += seconds
                d?.set(all, forKey: "domains.\(day)")
            }
        }
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["ok": true]]
        context.completeRequest(returningItems: [response])
    }
}
