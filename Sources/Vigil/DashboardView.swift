import AppKit
import Charts
import SwiftUI
import VigilCore

struct DashboardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })) {
                Section {
                    ForEach([DashboardSection.today, .history, .focus]) { s in
                        Label(s.title, systemImage: s.symbol).tag(s)
                    }
                }
                Section("Control") {
                    ForEach([DashboardSection.blocking, .categories]) { s in
                        Label(s.title, systemImage: s.symbol).tag(s)
                    }
                }
                Section("Connect") {
                    ForEach([DashboardSection.agents, .settings]) { s in
                        Label(s.title, systemImage: s.symbol).tag(s)
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            ScrollView {
                Group {
                    switch model.section {
                    case .today: TodayView()
                    case .history: HistoryView()
                    case .focus: FocusView()
                    case .blocking: BlockingView()
                    case .categories: CategoriesView()
                    case .agents: AgentsView()
                    case .settings: SettingsView()
                    }
                }
                .padding(28)
                .frame(maxWidth: 1100, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(Theme.accent)
        .overlay(alignment: .bottom) { toast }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 8) {
                Circle()
                    .fill(model.trackingPaused ? Color.secondary : model.isIdle ? Theme.neutral : Theme.productive)
                    .frame(width: 8, height: 8)
                Text(model.trackingPaused ? "Paused" : model.isIdle ? "Idle" : "Tracking")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.blockingActive {
                    Image(systemName: "hand.raised.fill").foregroundStyle(Theme.distracting).font(.caption)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var toast: some View {
        if let message = model.lastMessage {
            HStack(spacing: 10) {
                Image(systemName: "info.circle")
                Text(message).font(.callout)
                Button {
                    model.lastMessage = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 18)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    if model.lastMessage == message { model.lastMessage = nil }
                }
            }
        }
    }
}

// MARK: - Today / Day detail

struct TodayView: View {
    @EnvironmentObject var model: AppModel
    @State private var summary: DaySummary?
    @State private var previous: DaySummary?
    @State private var records: [ActivityRecord] = []
    @State private var showReport = false
    @State private var showLog = false

    private var isToday: Bool { model.viewingDay == DayKey.today }
    private var s: DaySummary { isToday ? model.today : (summary ?? DaySummary.empty(day: model.viewingDay)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            dayHeader
            statRow
            Card("By hour", trailing: AnyView(legend)) { hourlyChart }
            HStack(alignment: .top, spacing: 16) {
                Card("Apps") {
                    if s.topApps.isEmpty {
                        EmptyHint(symbol: "macwindow", title: "No apps yet", message: "Use your Mac and they'll appear here.")
                    } else {
                        let maxS = s.topApps.first?.seconds ?? 1
                        ForEach(s.topApps) { UsageRow(item: $0, kind: .app, maxSeconds: maxS) }
                    }
                }
                Card("Websites") {
                    if s.topDomains.isEmpty {
                        EmptyHint(symbol: "globe", title: "No websites yet",
                                  message: "Safari, Chrome, Arc, Brave, Edge, Vivaldi and Opera are tracked once you allow Automation access.")
                    } else {
                        let maxS = s.topDomains.first?.seconds ?? 1
                        ForEach(s.topDomains) { UsageRow(item: $0, kind: .domain, maxSeconds: maxS) }
                    }
                }
            }
            Card("Insights") {
                ForEach(model.store.insights(for: s, previous: previous), id: \.self) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "sparkle").foregroundStyle(Theme.accent).font(.caption).padding(.top, 2)
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Card("Activity log", trailing: AnyView(
                Button(showLog ? "Hide" : "Show") { showLog.toggle(); if showLog { loadRecords() } }.buttonStyle(.link)
            )) {
                if showLog { activityLog } else {
                    Text("Every app, window and site, minute by minute.").foregroundStyle(.secondary).font(.callout)
                }
            }
        }
        .onAppear {
            load()
            if isToday { model.refreshSummary(force: true) }
        }
        .onChange(of: model.viewingDay) { _ in load() }
        .sheet(isPresented: $showReport) { ReportSheet(day: model.viewingDay) }
    }

    private func load() {
        if !isToday { summary = model.store.summary(day: model.viewingDay) }
        previous = model.store.summary(day: DayKey.offset(model.viewingDay, days: -1))
        if showLog { loadRecords() }
    }

    private func loadRecords() {
        records = model.store.activities(day: model.viewingDay).filter { $0.duration >= 15 }.reversed()
    }

    private var dayHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isToday ? "Today" : dayTitle(model.viewingDay))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(isToday ? dayTitle(model.viewingDay) : "Day detail").foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Button { model.viewingDay = DayKey.offset(model.viewingDay, days: -1) } label: { Image(systemName: "chevron.left") }
                Button("Today") { model.viewingDay = DayKey.today }.disabled(isToday)
                Button { model.viewingDay = DayKey.offset(model.viewingDay, days: 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(isToday)
            }
            .controlSize(.large)
            Button {
                showReport = true
            } label: {
                Label("Report", systemImage: "doc.text")
            }
            .controlSize(.large)
        }
    }

    private var statRow: some View {
        HStack(alignment: .top, spacing: 12) {
            HStack(spacing: 14) {
                ScoreRing(score: s.score, size: 58, lineWidth: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SCORE").font(.system(size: 10.5, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary)
                    if let p = previous, p.activeSeconds > 60, s.activeSeconds > 60 {
                        let d = s.score - p.score
                        Text(d == 0 ? "same as day before" : "\(d > 0 ? "▲" : "▼") \(abs(d)) vs day before")
                            .font(.caption)
                            .foregroundStyle(d >= 0 ? Theme.productive : Theme.distracting)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))

            StatTile(label: "Active", value: DurationText.short(s.activeSeconds),
                     footnote: s.firstActivity.map { "since \($0.formatted(date: .omitted, time: .shortened))" })
            StatTile(label: "Productive", value: DurationText.short(s.productiveSeconds), tint: Theme.productive)
            StatTile(label: "Distracting", value: DurationText.short(s.distractingSeconds), tint: Theme.distracting)
            StatTile(label: "Focus", value: "\(s.focusMinutes)m", footnote: "\(s.focusSessionsCompleted) completed")
            StatTile(label: "Blocked", value: "\(s.blockedAttempts)", footnote: "\(s.contextSwitches) app switches")
        }
    }

    private struct HourPoint: Identifiable {
        let hour: String
        let category: String
        let minutes: Double
        var id: String { hour + category }
    }

    private var hourlyChart: some View {
        let points: [HourPoint] = s.hourly.flatMap { b -> [HourPoint] in
            let h = String(format: "%02d", b.hour)
            return [HourPoint(hour: h, category: "Productive", minutes: b.productive / 60),
                    HourPoint(hour: h, category: "Neutral", minutes: b.neutral / 60),
                    HourPoint(hour: h, category: "Distracting", minutes: b.distracting / 60)]
        }
        return Chart(points) { p in
            BarMark(x: .value("Hour", p.hour), y: .value("Minutes", p.minutes))
                .foregroundStyle(by: .value("Category", p.category))
                .cornerRadius(3)
        }
        .chartForegroundStyleScale(["Productive": Theme.productive, "Neutral": Theme.neutral, "Distracting": Theme.distracting])
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: ["00", "03", "06", "09", "12", "15", "18", "21"]) { _ in
                AxisValueLabel()
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0.0, 15.0, 30.0, 45.0, 60.0]) { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))m") } }
            }
        }
        .chartYScale(domain: 0...60)
        .frame(height: 190)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(ActivityCategory.allCases) { c in
                HStack(spacing: 5) {
                    Circle().fill(c.color).frame(width: 7, height: 7)
                    Text(c.label).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var activityLog: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if records.isEmpty {
                Text("Nothing recorded.").foregroundStyle(.secondary)
            }
            ForEach(records.prefix(300)) { r in
                HStack(spacing: 10) {
                    Text("\(r.start.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                    AppIcon(image: model.icon(bundleID: r.bundleID), size: 16)
                    Text(r.domain ?? r.appName).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text(r.windowTitle ?? "").font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(DurationText.short(r.duration)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    Circle().fill(r.category.color).frame(width: 7, height: 7)
                }
                .padding(.vertical, 5)
                Divider().opacity(0.5)
            }
        }
    }

    private func dayTitle(_ key: String) -> String {
        guard let d = DayKey.date(from: key) else { return key }
        return d.formatted(date: .complete, time: .omitted)
    }
}

struct ReportSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var day: String
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Daily report").font(.title2.bold())
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Show file") {
                    if let url = model.store.saveReport(day: day) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                Text(text)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        }
        .padding(20)
        .frame(width: 640, height: 560)
        .onAppear { text = model.store.markdownReport(day: day) }
    }
}
