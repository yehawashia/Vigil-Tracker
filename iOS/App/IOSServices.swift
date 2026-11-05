import SwiftUI
import UIKit
import VigilCore
import VigilMobile
#if VIGIL_SCREEN_TIME
import DeviceActivity
import FamilyControls
import ManagedSettings
#endif

/// iOS implementations of the hooks VigilMobile needs. Screen Time parts compile only in the
/// full build (VIGIL_SCREEN_TIME), which needs the Family Controls capability (paid account).
final class IOSServices: PlatformServices {
    static let shared = IOSServices()

    var deviceName: String { UIDevice.current.name }
    var platform: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS" }
    var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
    }

    func collectUsage() -> [DeviceUsage] { SharedUsage.collect() }

    #if VIGIL_SCREEN_TIME
    private let store = ManagedSettingsStore()

    var canBlock: Bool { AuthorizationCenter.shared.authorizationStatus == .approved }

    /// Shields the user's picked apps and the Mac's blocklist domains while a focus session or time
    /// block is active; clears them otherwise. The monitor extension also clears them at `until`.
    func applyBlocking(domains: [String], until: Date?, reason: String?) {
        guard canBlock else { return }
        guard let until, until > Date() else {
            store.clearAllSettings()
            return
        }
        let picked = AppGroups.load().blockSelection
        store.shield.applications = picked.applicationTokens.isEmpty ? nil : picked.applicationTokens
        store.shield.applicationCategories = picked.categoryTokens.isEmpty ? nil : .specific(picked.categoryTokens)
        store.webContent.blockedByFilter = domains.isEmpty ? nil : .specific(Set(domains.prefix(50).map { WebDomain(domain: $0) }))
        // Safety net: lift the shield at `until` even if the app never runs again.
        let end = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: until)
        let start = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: Date())
        try? DeviceActivityCenter().startMonitoring(.focusWindow, during: DeviceActivitySchedule(intervalStart: start, intervalEnd: end, repeats: false))
    }

    func settingsView() -> AnyView? { AnyView(AppGroupsSettings()) }
    #else
    var canBlock: Bool { false }
    func applyBlocking(domains: [String], until: Date?, reason: String?) {}
    func settingsView() -> AnyView? { nil }
    #endif
}

#if VIGIL_SCREEN_TIME
extension DeviceActivityName {
    static let daily = DeviceActivityName("vigil.daily")
    static let focusWindow = DeviceActivityName("vigil.focus")
}

/// Named app groups ("Social", "Games"…) and the apps to shield during focus. Apple gives Vigil
/// opaque tokens, never app names, so groups carry the names you give them.
struct AppGroups: Codable {
    var groups: [String: FamilyActivitySelection] = [:]
    var blockSelection = FamilyActivitySelection()

    static func load() -> AppGroups {
        guard let data = SharedUsage.defaults?.data(forKey: "appGroups"),
              let g = try? JSONDecoder().decode(AppGroups.self, from: data) else { return AppGroups() }
        return g
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { SharedUsage.defaults?.set(data, forKey: "appGroups") }
        startMonitoring()
    }

    /// One daily schedule with an event every 15 minutes of use per group (up to 8 hours).
    func startMonitoring() {
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for (name, sel) in groups {
            for minutes in stride(from: 15, through: 480, by: 15) {
                events[DeviceActivityEvent.Name("g|\(name)|\(minutes)")] = DeviceActivityEvent(
                    applications: sel.applicationTokens, categories: sel.categoryTokens, webDomains: sel.webDomainTokens,
                    threshold: DateComponents(minute: minutes))
            }
        }
        let center = DeviceActivityCenter()
        center.stopMonitoring([.daily])
        guard !events.isEmpty else { return }
        try? center.startMonitoring(.daily, during: DeviceActivitySchedule(intervalStart: DateComponents(hour: 0, minute: 0),
                                                                          intervalEnd: DateComponents(hour: 23, minute: 59),
                                                                          repeats: true), events: events)
    }
}

struct AppGroupsSettings: View {
    @State private var groups = AppGroups.load()
    @State private var editing: String?
    @State private var newName = ""
    @State private var pickingBlock = false
    @State private var authorized = AuthorizationCenter.shared.authorizationStatus == .approved

    var body: some View {
        MCard("S", "Screen Time", note: authorized ? "on" : "off") {
            if !authorized {
                Text("Allow Screen Time so Vigil can shield apps during focus and measure app groups.").font(.callout)
                Button("Allow Screen Time") {
                    Task {
                        try? await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                        authorized = AuthorizationCenter.shared.authorizationStatus == .approved
                    }
                }.buttonStyle(.borderedProminent)
            } else {
                Button("Choose apps to block during focus (\(groups.blockSelection.applicationTokens.count))") { pickingBlock = true }
                Divider()
                Text("APP GROUPS · TIME IN 15-MINUTE STEPS").font(MTheme.label(9)).foregroundStyle(.secondary)
                ForEach(groups.groups.keys.sorted(), id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        Button("Edit") { editing = name }
                        Button(role: .destructive) { groups.groups[name] = nil; groups.save() } label: { Image(systemName: "trash") }
                    }
                }
                HStack {
                    TextField("New group (e.g. Social)", text: $newName)
                    Button("Add") {
                        let n = newName.trimmingCharacters(in: .whitespaces)
                        guard !n.isEmpty, n.count <= 40, !n.contains("|") else { return }
                        groups.groups[n] = FamilyActivitySelection(); newName = ""; editing = n
                    }
                }
            }
        }
        .familyActivityPicker(isPresented: $pickingBlock, selection: Binding(get: { groups.blockSelection }, set: { groups.blockSelection = $0; groups.save() }))
        .familyActivityPicker(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } }),
                              selection: Binding(get: { editing.flatMap { groups.groups[$0] } ?? FamilyActivitySelection() },
                                                 set: { if let e = editing { groups.groups[e] = $0; groups.save() } }))
    }
}
#endif
