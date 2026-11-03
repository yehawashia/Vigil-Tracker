import Charts
import SwiftUI
import VigilCore

// MARK: - History

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var range = 7
    @State private var days: [DaySummary] = []
    @State private var topSites: [UsageItem] = []
    @State private var topApps: [UsageItem] = []

    private struct DayPoint: Identifiable {
        let day: String
        let label: String
        let category: String
        let hours: Double
        var id: String { day + category }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("History").font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("Trends across days").foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $range) {
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }

            HStack(spacing: 12) {
                let active = days.filter { $0.activeSeconds > 600 }
                let n = Double(max(1, active.count))
                StatTile(label: "Avg score", value: "\(active.isEmpty ? 0 : active.map(\.score).reduce(0, +) / active.count)")
                StatTile(label: "Avg productive", value: DurationText.short(active.map(\.productiveSeconds).reduce(0, +) / n), tint: Theme.productive)
                StatTile(label: "Avg distracting", value: DurationText.short(active.map(\.distractingSeconds).reduce(0, +) / n), tint: Theme.distracting)
                StatTile(label: "Days tracked", value: "\(active.count)/\(range)")
            }

            Card("Time per day") {
                Chart(points) { p in
                    BarMark(x: .value("Day", p.label), y: .value("Hours", p.hours))
                        .foregroundStyle(by: .value("Category", p.category))
                        .cornerRadius(3)
                }
                .chartForegroundStyleScale(["Productive": Theme.productive, "Neutral": Theme.neutral, "Distracting": Theme.distracting])
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))h") } }
                    }
                }
                .frame(height: 220)
            }

            Card("Productivity score") {
                Chart(days, id: \.day) { d in
                    LineMark(x: .value("Day", shortLabel(d.day)), y: .value("Score", d.score))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Theme.accent)
                    PointMark(x: .value("Day", shortLabel(d.day)), y: .value("Score", d.score))
                        .foregroundStyle(Theme.accent)
                }
                .chartYScale(domain: 0...100)
                .frame(height: 160)
            }

            HStack(alignment: .top, spacing: 16) {
                Card("Top websites (\(range) days)") {
                    let maxS = topSites.first?.seconds ?? 1
                    ForEach(topSites) { UsageRow(item: $0, kind: .domain, maxSeconds: maxS) }
                    if topSites.isEmpty { Text("No websites yet.").foregroundStyle(.secondary) }
                }
                Card("Top apps (\(range) days)") {
                    let maxS = topApps.first?.seconds ?? 1
                    ForEach(topApps) { UsageRow(item: $0, kind: .app, maxSeconds: maxS) }
                    if topApps.isEmpty { Text("No apps yet.").foregroundStyle(.secondary) }
                }
            }

            Card("Days") {
                ForEach(days.reversed(), id: \.day) { d in
                    Button {
                        model.viewingDay = d.day
                        model.section = .today
                    } label: {
                        HStack(spacing: 12) {
                            Text(longLabel(d.day)).frame(width: 150, alignment: .leading)
                            CategoryBar(productive: d.productiveSeconds, neutral: d.neutralSeconds,
                                        distracting: d.distractingSeconds, height: 7)
                            Text(DurationText.short(d.activeSeconds)).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .trailing)
                            Text(d.activeSeconds > 60 ? "\(d.score)" : "–").monospacedDigit().frame(width: 34, alignment: .trailing)
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: range) { _ in load() }
    }

    private var points: [DayPoint] {
        days.flatMap { d -> [DayPoint] in
            let label = shortLabel(d.day)
            return [DayPoint(day: d.day, label: label, category: "Productive", hours: d.productiveSeconds / 3600),
                    DayPoint(day: d.day, label: label, category: "Neutral", hours: d.neutralSeconds / 3600),
                    DayPoint(day: d.day, label: label, category: "Distracting", hours: d.distractingSeconds / 3600)]
        }
    }

    private func load() {
        days = model.store.history(days: range)
        let from = DayKey.offset(DayKey.today, days: -(range - 1))
        topSites = model.store.usage(fromDay: from, toDay: DayKey.today, groupBy: .domain, limit: 10)
        topApps = model.store.usage(fromDay: from, toDay: DayKey.today, groupBy: .app, limit: 10)
    }

    private func shortLabel(_ key: String) -> String {
        guard let d = DayKey.date(from: key) else { return key }
        let f = DateFormatter()
        f.dateFormat = range > 14 ? "d/M" : "EEE d"
        return f.string(from: d)
    }

    private func longLabel(_ key: String) -> String {
        guard let d = DayKey.date(from: key) else { return key }
        return d.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }
}

// MARK: - Focus

struct FocusView: View {
    @EnvironmentObject var model: AppModel
    @State private var minutes = 50
    @State private var label = ""
    @State private var locked = false
    @State private var recent: [FocusSession] = []

    // New schedule form
    @State private var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var startTime = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var endTime = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var scheduleLabel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Color.clear.frame(height: 0)
                .pageHeader("Focus", subtitle: "Block distractions for a set time, or on a schedule.")

            if let focus = model.focus {
                activeCard(focus)
            } else {
                startCard
            }

            Card("Block schedules") {
                Text("During these windows your blocklist is enforced automatically, like Freedom's recurring sessions.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(model.schedules) { s in
                    HStack {
                        Toggle("", isOn: Binding(get: { s.enabled }, set: { model.setSchedule(s, enabled: $0) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.label ?? "Scheduled block").font(.system(size: 13, weight: .medium))
                            Text("\(s.weekdaysText) · \(s.timeRangeText)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if s.isActive() {
                            Text("ACTIVE").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.distracting)
                        }
                        Button(role: .destructive) { model.deleteSchedule(s) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .disabled(s.isActive() && model.isLocked)
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
                newScheduleForm
            }

            Card("Recent sessions") {
                if recent.isEmpty {
                    Text("No sessions in the last week.").foregroundStyle(.secondary)
                }
                ForEach(recent) { s in
                    HStack {
                        Image(systemName: s.endedEarly != nil ? "xmark.circle" : (s.end > Date() ? "timer" : "checkmark.circle.fill"))
                            .foregroundStyle(s.endedEarly != nil ? Theme.distracting : Theme.productive)
                        Text(s.label ?? "Focus session")
                        if s.locked { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                        if s.createdBy == "mcp" {
                            Text("via agent").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(s.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                            .foregroundStyle(.secondary)
                        Text("\(Int(min(s.effectiveEnd, Date()).timeIntervalSince(s.start) / 60))/\(s.plannedMinutes)m")
                            .monospacedDigit()
                            .frame(width: 70, alignment: .trailing)
                    }
                    .font(.system(size: 13))
                    .padding(.vertical, 2)
                }
            }
        }
        .onAppear { recent = model.store.focusSessions(sinceDay: DayKey.offset(DayKey.today, days: -7)) }
        .onChange(of: model.focus) { _ in recent = model.store.focusSessions(sinceDay: DayKey.offset(DayKey.today, days: -7)) }
    }

    private func activeCard(_ focus: FocusSession) -> some View {
        Card {
            HStack(alignment: .center, spacing: 24) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let total = max(1, focus.end.timeIntervalSince(focus.start))
                    let done = min(1, max(0, context.date.timeIntervalSince(focus.start) / total))
                    ZStack {
                        Circle().stroke(Color.primary.opacity(0.08), lineWidth: 12)
                        Circle().trim(from: 0, to: done)
                            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 2) {
                            Text(DurationText.clock(focus.end.timeIntervalSince(context.date)))
                                .font(.system(size: 34, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            Text("remaining").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 170, height: 170)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(focus.label ?? "Focus session").font(.title2.bold())
                        if focus.locked { Image(systemName: "lock.fill").foregroundStyle(Theme.distracting) }
                    }
                    Text("Ends at \(focus.end.formatted(date: .omitted, time: .shortened)) · \(model.blocklist.count) items blocked")
                        .foregroundStyle(.secondary)
                    if focus.locked {
                        Text("This session is locked. It can't be stopped, the blocklist can't be edited, and Vigil can't be quit until it ends.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button("Add 15 min") { model.startFocus(minutes: Int(focus.remaining() / 60) + 15, locked: focus.locked, label: focus.label) }
                        if !focus.locked {
                            Button("End early", role: .destructive) { model.stopFocus() }
                        }
                    }
                    .controlSize(.large)
                    .padding(.top, 6)
                }
                Spacer()
            }
        }
    }

    private var startCard: some View {
        Card("New session") {
            HStack(spacing: 8) {
                ForEach([25, 50, 90, 120], id: \.self) { m in
                    Button("\(m) min") { minutes = m }
                        .buttonStyle(.bordered)
                        .tint(minutes == m ? Theme.accent : nil)
                }
                Stepper(value: $minutes, in: 5...480, step: 5) {
                    Text("\(minutes) minutes").monospacedDigit()
                }
                .padding(.leading, 12)
            }
            HStack(spacing: 12) {
                TextField("What are you working on? (optional)", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                Toggle(isOn: $locked) { Label("Lock session", systemImage: "lock") }
                    .help("Locked: can't be stopped early, blocklist can't be edited, Vigil can't be quit")
            }
            HStack {
                Button {
                    model.startFocus(minutes: minutes, locked: locked, label: label)
                    label = ""
                } label: {
                    Label("Start focus", systemImage: "play.fill").padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text("Blocks \(model.blocklist.filter { $0.kind == .domain }.count) sites and \(model.blocklist.filter { $0.kind == .app }.count) apps from your blocklist.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var newScheduleForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add schedule").font(.system(size: 13, weight: .semibold)).padding(.top, 6)
            HStack(spacing: 4) {
                ForEach(1...7, id: \.self) { day in
                    Toggle(["S", "M", "T", "W", "T", "F", "S"][day - 1], isOn: Binding(
                        get: { weekdays.contains(day) },
                        set: { if $0 { weekdays.insert(day) } else { weekdays.remove(day) } }))
                    .toggleStyle(.button)
                }
                DatePicker("From", selection: $startTime, displayedComponents: .hourAndMinute)
                    .padding(.leading, 12)
                DatePicker("to", selection: $endTime, displayedComponents: .hourAndMinute)
            }
            HStack {
                TextField("Label (e.g. Morning deep work)", text: $scheduleLabel)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                Button("Add schedule") {
                    let cal = Calendar.current
                    let s = cal.component(.hour, from: startTime) * 60 + cal.component(.minute, from: startTime)
                    let e = cal.component(.hour, from: endTime) * 60 + cal.component(.minute, from: endTime)
                    guard !weekdays.isEmpty, s != e else { return }
                    model.addSchedule(weekdays: Array(weekdays), start: s, end: e,
                                      label: scheduleLabel.isEmpty ? nil : scheduleLabel)
                    scheduleLabel = ""
                }
            }
        }
    }
}
