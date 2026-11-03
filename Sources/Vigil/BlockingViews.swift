import AppKit
import SwiftUI
import VigilCore

// MARK: - Blocking

struct BlockingView: View {
    @EnvironmentObject var model: AppModel
    @State private var newKind: TargetKind = .domain
    @State private var newPattern = ""
    @State private var limitKind: TargetKind = .domain
    @State private var limitPattern = ""
    @State private var limitMinutes = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Color.clear.frame(height: 0)
                .pageHeader("Blocking", subtitle: "Your blocklist is enforced during focus sessions and schedules. Daily limits apply every day.")

            statusBanner

            Card("Blocklist") {
                HStack {
                    Picker("", selection: $newKind) {
                        ForEach(TargetKind.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    TextField(newKind == .domain ? "youtube.com" : "App name or bundle ID", text: $newPattern)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                    runningAppsMenu
                }
                let sites = model.blocklist.filter { $0.kind == .domain }
                let apps = model.blocklist.filter { $0.kind == .app }
                if model.blocklist.isEmpty {
                    EmptyHint(symbol: "hand.raised", title: "Nothing blocked", message: "Add sites like reddit.com or apps like Discord.")
                }
                if !sites.isEmpty {
                    Text("WEBSITES").font(.system(size: 10.5, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary).padding(.top, 4)
                    FlowChips(items: sites, symbol: { _ in "globe" }, label: { $0.pattern }, onRemove: model.removeBlock, disabled: model.isLocked)
                }
                if !apps.isEmpty {
                    Text("APPS").font(.system(size: 10.5, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary).padding(.top, 4)
                    FlowChips(items: apps, symbol: { _ in "app.fill" }, label: { appLabel($0.pattern) }, onRemove: model.removeBlock, disabled: model.isLocked)
                }
                Text("Subdomains are included: blocking youtube.com also blocks m.youtube.com and music.youtube.com.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Card("Daily limits") {
                Text("Once you've used something for this long today, Vigil blocks it until midnight, focus session or not.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Picker("", selection: $limitKind) {
                        ForEach(TargetKind.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    TextField(limitKind == .domain ? "instagram.com" : "App name or bundle ID", text: $limitPattern)
                        .textFieldStyle(.roundedBorder)
                    Stepper(value: $limitMinutes, in: 5...600, step: 5) { Text("\(limitMinutes) min/day").monospacedDigit() }
                    Button("Set limit") {
                        model.setLimit(kind: limitKind, pattern: limitPattern, minutes: limitMinutes)
                        limitPattern = ""
                    }
                    .disabled(limitPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(model.limits) { limit in
                    let used = model.store.secondsToday(kind: limit.kind, pattern: limit.pattern)
                    let fraction = min(1, used / Double(max(1, limit.minutes * 60)))
                    HStack(spacing: 12) {
                        Image(systemName: limit.kind == .domain ? "globe" : "app").foregroundStyle(.secondary)
                        Text(limit.kind == .app ? appLabel(limit.pattern) : limit.pattern).frame(width: 180, alignment: .leading)
                        MeterBar(value: fraction, tint: fraction >= 1 ? Theme.distracting : Theme.accent)
                        Text("\(Int(used / 60))/\(limit.minutes)m").monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                        Button(role: .destructive) { model.deleteLimit(limit) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .disabled(model.isLocked)
                    }
                    .padding(.vertical, 2)
                }
            }

            Card("How blocking works") {
                Toggle("Close blocked tabs instead of showing the block page", isOn: Binding(
                    get: { model.closeTabsInstead }, set: { model.closeTabsInstead = $0; model.saveSettings() }))
                VStack(alignment: .leading, spacing: 6) {
                    bullet("Websites are caught in Safari, Chrome, Arc, Brave, Edge, Vivaldi and Opera, in every open tab, within a few seconds.")
                    bullet("Blocked apps are quit as soon as they open.")
                    bullet("Locked sessions can't be stopped, the blocklist can't be edited and Vigil refuses to quit until the timer ends.")
                    bullet("Firefox can't be read via AppleScript, so add it as a blocked app during sessions if you use it to escape.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if model.blockingActive {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill").font(.title2).foregroundStyle(Theme.distracting)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.blockReason.isEmpty ? "Daily limits reached" : model.blockReason).font(.headline)
                    Text(model.isLocked ? "Locked. Changes that weaken blocking are disabled." : "Blocking is active right now.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.distracting.opacity(0.1)))
        }
    }

    private var runningAppsMenu: some View {
        Menu {
            ForEach(runningApps, id: \.self) { app in
                Button(app.name) { model.addBlock(kind: .app, pattern: app.bundleID) }
            }
        } label: {
            Label("Running app", systemImage: "plus.app")
        }
        .fixedSize()
    }

    private struct RunningApp: Hashable { let name: String; let bundleID: String }

    private var runningApps: [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.bundleIdentifier.map { RunningApp(name: app.localizedName ?? $0, bundleID: $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func appLabel(_ pattern: String) -> String {
        AppNames.displayName(for: pattern)
    }

    private func add() {
        let p = newPattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        model.addBlock(kind: newKind, pattern: p)
        newPattern = ""
    }
}

/// Removable chips laid out in rows.
struct FlowChips<Item: Identifiable>: View {
    var items: [Item]
    var symbol: (Item) -> String
    var label: (Item) -> String
    var onRemove: (Item) -> Void
    var disabled: Bool

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                HStack(spacing: 6) {
                    Image(systemName: symbol(item)).foregroundStyle(.secondary).font(.caption)
                    Text(label(item)).lineLimit(1).font(.system(size: 12.5))
                    Spacer(minLength: 4)
                    Button { onRemove(item) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.borderless)
                        .disabled(disabled)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
        }
    }
}

// MARK: - Categories

struct CategoriesView: View {
    @EnvironmentObject var model: AppModel
    @State private var kind: TargetKind = .domain
    @State private var pattern = ""
    @State private var category: ActivityCategory = .productive
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Color.clear.frame(height: 0)
                .pageHeader("Categories", subtitle: "Decide what counts as productive. This drives your score and daily report.")

            Card("Unsorted today") {
                let unsorted = unsortedItems
                if unsorted.isEmpty {
                    Text("Everything you used today has a category.").foregroundStyle(.secondary)
                }
                ForEach(unsorted) { entry in
                    let item = entry.item
                    let itemKind = entry.kind
                    HStack {
                        if itemKind == .app {
                            AppIcon(image: model.icon(bundleID: item.detail), size: 18)
                        } else {
                            AppIcon(image: nil, fallbackSymbol: "globe", size: 18)
                        }
                        Text(item.name)
                        Text(DurationText.short(item.seconds)).foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        ForEach(ActivityCategory.allCases) { c in
                            Button(c.label) {
                                model.setCategory(kind: itemKind, pattern: itemKind == .app ? (item.detail ?? item.name) : item.name, category: c)
                            }
                            .tint(c.color)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Card("Add a rule") {
                HStack {
                    Picker("", selection: $kind) { ForEach(TargetKind.allCases) { Text($0.label).tag($0) } }
                        .labelsHidden().frame(width: 110)
                    TextField(kind == .domain ? "example.com" : "Bundle ID or app name", text: $pattern)
                        .textFieldStyle(.roundedBorder)
                    Picker("", selection: $category) { ForEach(ActivityCategory.allCases) { Text($0.label).tag($0) } }
                        .labelsHidden().frame(width: 130)
                    Button("Save") {
                        model.setCategory(kind: kind, pattern: pattern, category: category)
                        pattern = ""
                    }
                    .disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Card("Rules", trailing: AnyView(TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 180))) {
                ForEach(ActivityCategory.allCases) { c in
                    let rules = model.rules.filter { $0.category == c && (filter.isEmpty || $0.pattern.localizedCaseInsensitiveContains(filter)) }
                    if !rules.isEmpty {
                        HStack {
                            CategoryPill(category: c)
                            Text("\(rules.count)").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.top, 6)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 6) {
                            ForEach(rules) { rule in
                                HStack(spacing: 6) {
                                    Image(systemName: rule.kind == .domain ? "globe" : "app.fill").font(.caption).foregroundStyle(.secondary)
                                    Text(rule.kind == .app ? AppNames.displayName(for: rule.pattern) : rule.pattern)
                                        .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                        .help(rule.pattern)
                                    Spacer(minLength: 2)
                                    Menu {
                                        ForEach(ActivityCategory.allCases) { other in
                                            Button(other.label) { model.setCategory(kind: rule.kind, pattern: rule.pattern, category: other) }
                                        }
                                        Divider()
                                        Button("Delete rule", role: .destructive) { model.deleteRule(rule) }
                                    } label: {
                                        Image(systemName: "ellipsis")
                                    }
                                    .menuStyle(.borderlessButton)
                                    .menuIndicator(.hidden)
                                    .fixedSize()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                            }
                        }
                    }
                }
            }
        }
    }

    struct UnsortedItem: Identifiable {
        let item: UsageItem
        let kind: TargetKind
        var id: String { kind.rawValue + item.name }
    }

    /// Today's apps and sites that no rule covers yet, biggest first.
    private var unsortedItems: [UnsortedItem] {
        let categorizer = Categorizer(rules: model.rules)
        let apps = model.today.topApps
            .filter { categorizer.category(forApp: $0.name, bundleID: $0.detail) == nil && !BrowserBridge.supported.keys.contains($0.detail ?? "") }
            .map { UnsortedItem(item: $0, kind: .app) }
        let sites = model.today.topDomains
            .filter { categorizer.category(forDomain: $0.name) == nil }
            .map { UnsortedItem(item: $0, kind: .domain) }
        return Array((apps + sites).sorted { $0.item.seconds > $1.item.seconds }.prefix(12))
    }
}
