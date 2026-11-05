import Charts
import SwiftUI
import VigilCore
import VigilSync
import VigilVoice

private func short(_ s: Double) -> String { DurationText.short(s) }
private func dayLabel(_ key: String, _ format: String = "EEE d") -> String {
    guard let d = DayKey.date(from: key) else { return key }
    let f = DateFormatter(); f.dateFormat = format
    return f.string(from: d)
}

/// "No data yet" while the first sync hasn't happened.
private struct Waiting: View {
    @ObservedObject var state: DeviceState
    var body: some View {
        MCard {
            Text("Waiting for the first sync with \(state.hostName). Pull down to try now.").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Today

struct TodayScreen: View {
    @ObservedObject var state: DeviceState

    var body: some View {
        if let snap = state.snapshot {
            let s = snap.today
            if !snap.proposals.isEmpty { ProposalsCard(state: state, proposals: snap.proposals) }
            MCard("01", "Today on \(snap.hostName)") {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(s.score)").font(.system(size: 54, weight: .light, design: .rounded))
                    VStack(alignment: .leading) {
                        Text("SCORE").font(MTheme.label(9.5)).foregroundStyle(.secondary)
                        Text("\(short(s.activeSeconds)) active").font(.callout)
                    }
                }
                CategoryStrip(p: s.productiveSeconds, n: s.neutralSeconds, d: s.distractingSeconds)
                HStack {
                    stat("Productive", s.productiveSeconds, .productive)
                    stat("Neutral", s.neutralSeconds, .neutral)
                    stat("Distracting", s.distractingSeconds, .distracting)
                }
            }
            if let f = snap.trends?.todayFinish {
                MCard("02", "Where today is heading") {
                    Text("About \(short(f.expected)) by tonight").font(.title3)
                    Text("likely \(short(f.low))–\(short(f.high))").font(MTheme.label(10)).foregroundStyle(.secondary)
                }
            }
            MCard("03", "Top today") {
                let items = Array((s.topApps + s.topDomains).sorted { $0.seconds > $1.seconds }.prefix(8))
                if items.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                ForEach(items) { i in
                    HStack {
                        Circle().fill(MTheme.color(i.category)).frame(width: 7, height: 7)
                        Text(i.name).lineLimit(1)
                        Spacer()
                        Text(short(i.seconds)).font(MTheme.label(11)).foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Waiting(state: state)
        }
    }

    private func stat(_ label: String, _ v: Double, _ c: ActivityCategory) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(MTheme.label(8.5)).foregroundStyle(.secondary)
            Text(short(v)).font(.headline).foregroundStyle(MTheme.color(c))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CategoryStrip: View {
    var p: Double, n: Double, d: Double
    var body: some View {
        GeometryReader { g in
            let t = max(1, p + n + d)
            HStack(spacing: 2) {
                Capsule().fill(MTheme.productive).frame(width: g.size.width * p / t)
                Capsule().fill(MTheme.neutral).frame(width: g.size.width * n / t)
                Capsule().fill(MTheme.distracting).frame(width: g.size.width * d / t)
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Trends (touch and drag on a chart to read exact values)

struct TrendsScreen: View {
    @ObservedObject var state: DeviceState
    @State private var weekPick: String?
    @State private var hourPick: Int?

    var body: some View {
        if let t = state.snapshot?.trends {
            MCard("01", "Next 7 days", note: weekReadout(t)) {
                Chart {
                    ForEach(t.days.dropLast().suffix(7)) { d in
                        BarMark(x: .value("Day", dayLabel(d.day, "EEE")), y: .value("h", d.activeSeconds / 3600))
                            .foregroundStyle(MTheme.ink.opacity(weekPick == nil || weekPick == d.day ? 0.6 : 0.2))
                    }
                    ForEach(t.week) { f in
                        RuleMark(x: .value("Day", dayLabel(f.day, "EEE") + " "), yStart: .value("lo", f.active.low / 3600), yEnd: .value("hi", f.active.high / 3600))
                            .foregroundStyle(MTheme.accent.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 8, lineCap: .round))
                        PointMark(x: .value("Day", dayLabel(f.day, "EEE") + " "), y: .value("h", f.active.expected / 3600)).foregroundStyle(MTheme.accent)
                    }
                }
                .chartOverlay { proxy in pickOverlay(proxy) { (label: String) in
                    weekPick = (t.days.dropLast().suffix(7).map(\.day) + t.week.map(\.day)).first {
                        dayLabel($0, "EEE") == label || dayLabel($0, "EEE") + " " == label
                    }
                } }
                .frame(height: 190)
            }
            MCard("02", "Your daily rhythm", note: hourReadout(t)) {
                Chart {
                    ForEach(t.rhythm) { p in
                        AreaMark(x: .value("Hour", p.hour), y: .value("m", p.weekdayProductive))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(LinearGradient(colors: [MTheme.productive.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Hour", p.hour), y: .value("m", p.weekdayProductive), series: .value("s", "wd"))
                            .interpolationMethod(.catmullRom).foregroundStyle(MTheme.productive)
                        LineMark(x: .value("Hour", p.hour), y: .value("m", p.weekdayDistracting), series: .value("s", "dis"))
                            .interpolationMethod(.catmullRom).foregroundStyle(MTheme.distracting)
                    }
                    if let h = hourPick { RuleMark(x: .value("Hour", h)).foregroundStyle(MTheme.ink.opacity(0.4)) }
                }
                .chartOverlay { proxy in pickOverlay(proxy) { (h: Int) in hourPick = max(0, min(23, h)) } }
                .frame(height: 180)
            }
            MCard("03", "Where the week went") {
                DotMatrix(share: t.share)
            }
            MCard("04", "Hour × day", note: "last 4 weeks") {
                MiniHeatmap(terrain: t.terrain).frame(height: 200)
            }
            if !t.notes.isEmpty {
                MCard("05", "Findings") {
                    ForEach(t.notes, id: \.self) { Text("◆ " + $0).font(.callout) }
                }
            }
        } else {
            Waiting(state: state)
        }
    }

    private func weekReadout(_ t: TrendsData) -> String? {
        guard let d = weekPick else { return "touch to read" }
        if let f = t.week.first(where: { $0.day == d }) { return "\(dayLabel(d)) ~\(short(f.active.expected))" }
        return t.days.first { $0.day == d }.map { "\(dayLabel(d)) \(short($0.activeSeconds))" }
    }

    private func hourReadout(_ t: TrendsData) -> String? {
        guard let h = hourPick, let p = t.rhythm.first(where: { $0.hour == h }) else { return "touch to read" }
        return String(format: "%02d:00 %dm", h, Int(p.weekdayProductive))
    }

    private func pickOverlay<V: Plottable>(_ proxy: ChartProxy, _ pick: @escaping (V) -> Void) -> some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    let x = v.location.x - geo[proxy.plotAreaFrame].origin.x
                    if let val: V = proxy.value(atX: x) { pick(val); MHaptics.tick() }
                })
        }
    }
}

struct DotMatrix: View {
    var share: [ActivityCategory: Double]
    var body: some View {
        let total = max(1, share.values.reduce(0, +))
        let counts = ActivityCategory.allCases.map { ($0, Int(((share[$0] ?? 0) / total * 100).rounded())) }
        let dots = counts.flatMap { c, n in Array(repeating: c, count: n) }
        HStack(spacing: 20) {
            Canvas { ctx, size in
                let cell = min(size.width, size.height) / 10
                for i in 0..<100 {
                    let r = CGRect(x: CGFloat(i % 10) * cell + cell * 0.15, y: CGFloat(i / 10) * cell + cell * 0.15, width: cell * 0.7, height: cell * 0.7)
                    ctx.fill(Path(ellipseIn: r), with: .color(i < dots.count ? MTheme.color(dots[i]) : MTheme.hairline))
                }
            }
            .frame(width: 140, height: 140)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(counts, id: \.0) { c, n in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(c.label.uppercased()).font(MTheme.label(9)).foregroundStyle(.secondary)
                        Text("\(n)%").font(.title3.weight(.light)).foregroundStyle(MTheme.color(c))
                    }
                }
            }
        }
    }
}

struct MiniHeatmap: View {
    var terrain: [DayHours]
    var body: some View {
        Canvas { ctx, size in
            let rows = max(1, terrain.count)
            let cw = size.width / 24, ch = size.height / CGFloat(rows)
            let peak = max(60, terrain.flatMap(\.hours).map { $0.productive + $0.neutral + $0.distracting }.max() ?? 60)
            for (r, d) in terrain.enumerated() {
                for b in d.hours {
                    let total = b.productive + b.neutral + b.distracting
                    let rect = CGRect(x: CGFloat(b.hour) * cw + 0.5, y: CGFloat(r) * ch + 0.5, width: cw - 1, height: ch - 1)
                    let cat: ActivityCategory = b.distracting > b.productive ? .distracting : .productive
                    ctx.fill(Path(rect), with: .color(total > 0 ? MTheme.color(cat).opacity(0.15 + 0.85 * min(1, total / peak)) : MTheme.hairline))
                }
            }
        }
    }
}

// MARK: - Plan (timetable)

struct ProposalsCard: View {
    @ObservedObject var state: DeviceState
    var proposals: [TimetableRevision]
    var body: some View {
        MCard("!", "Your agent suggests", note: "\(proposals.count) waiting") {
            ForEach(proposals) { p in
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.summary).font(.callout.weight(.medium))
                    if let n = p.note { Text("“\(n)”").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button("Reject") { Task { await state.request(.decideProposal(id: p.id, approve: false)) } }.buttonStyle(.bordered)
                        Button("Approve") { Task { await state.request(.decideProposal(id: p.id, approve: true)) } }.buttonStyle(.borderedProminent)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct PlanScreen: View {
    @ObservedObject var state: DeviceState
    @State private var editing: TimetableEdit?
    @State private var showHistory = false

    var body: some View {
        if let snap = state.snapshot {
            if !snap.proposals.isEmpty { ProposalsCard(state: state, proposals: snap.proposals) }
            MobileTasks(state: state)
            Button {
                let start = Calendar.current.nextDate(after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? Date()
                editing = TimetableEdit(item: TimetableItem(title: "", start: start, end: start.addingTimeInterval(3600)), isNew: true)
            } label: { Label("Add to timetable", systemImage: "plus").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
            let upcoming = snap.timetable.filter { $0.end > Calendar.current.startOfDay(for: Date()) }
            let byDay = Dictionary(grouping: upcoming) { DayKey.string(for: $0.start) }
            ForEach(byDay.keys.sorted(), id: \.self) { day in
                MCard(nil, dayLabel(day, "EEEE d MMM")) {
                    ForEach(byDay[day]!.sorted { $0.start < $1.start }) { item in
                        Button { editing = TimetableEdit(item: item, isNew: false) } label: { row(item) }.buttonStyle(.plain)
                    }
                }
            }
            if upcoming.isEmpty { MCard { Text("Nothing planned. Add a task or a time block.").foregroundStyle(.secondary) } }
            DisclosureGroup("History", isExpanded: $showHistory) {
                ForEach(snap.history.prefix(30)) { r in
                    HStack {
                        Text(r.authorLabel.uppercased()).font(MTheme.label(8.5)).foregroundStyle(r.author == "agent" ? MTheme.accent : .secondary)
                        Text(r.summary).font(.caption).lineLimit(2)
                        Spacer()
                        if r.status == .applied {
                            Button("Revert") { Task { await state.request(.revert(revisionID: r.id)) } }.font(.caption)
                        } else {
                            Text(r.status.rawValue.uppercased()).font(MTheme.label(8.5)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
            .sheet(item: $editing) { edit in
                MobileEditor(item: edit.item, isNew: edit.isNew) { result in
                    editing = nil
                    Task {
                        switch result {
                        case .save(let i): await state.request(.editTimetable(op: edit.isNew ? .create : .update, item: i))
                        case .delete(let i): await state.request(.editTimetable(op: .delete, item: i))
                        case .cancel: break
                        }
                    }
                }
            }
        } else {
            Waiting(state: state)
        }
    }

    private func row(_ item: TimetableItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(item.kind == .block ? MTheme.accent : MTheme.ink.opacity(0.4)).frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).strikethrough(item.done)
                Text("\(item.start.formatted(date: .omitted, time: .shortened))–\(item.end.formatted(date: .omitted, time: .shortened))\(item.kind == .block ? " · blocks distractions" : "")")
                    .font(MTheme.label(9.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if item.isActive() { Text("NOW").font(MTheme.label(9)).foregroundStyle(MTheme.accent) }
        }
        .contentShape(Rectangle())
    }
}

enum MobileEditorResult { case save(TimetableItem), delete(TimetableItem), cancel }

struct MobileEditor: View {
    @State var item: TimetableItem
    var isNew: Bool
    var done: (MobileEditorResult) -> Void

    init(item: TimetableItem, isNew: Bool, done: @escaping (MobileEditorResult) -> Void) {
        _item = State(initialValue: item); self.isNew = isNew; self.done = done
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $item.title)
                DatePicker("Starts", selection: Binding(get: { item.start }, set: { let len = item.duration; item.start = $0; item.end = $0.addingTimeInterval(max(300, len)) }))
                DatePicker("Ends", selection: $item.end, in: item.start.addingTimeInterval(300)...)
                Toggle("Block distractions during this", isOn: Binding(get: { item.kind == .block }, set: { item.kind = $0 ? .block : .task }))
                if !isNew { Toggle("Done", isOn: $item.done) }
                TextField("Notes", text: Binding(get: { item.notes ?? "" }, set: { item.notes = $0 }), axis: .vertical)
                if !isNew {
                    Button("Delete", role: .destructive) { done(.delete(item)) }
                }
            }
            .navigationTitle(isNew ? "New item" : "Edit item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done(.cancel) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") { done(.save(item)) }.disabled(item.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Focus (dial)

struct FocusScreen: View {
    @ObservedObject var state: DeviceState
    @AppStorage("dialMinutes") private var minutes = 50
    @State private var locked = false
    @State private var confirmLock = false

    var body: some View {
        if let f = state.snapshot?.focus, f.end > Date() {
            MCard("01", f.label ?? "Focus session", note: f.locked ? "locked" : nil) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let total = max(1, f.end.timeIntervalSince(f.start))
                    let left = max(0, f.end.timeIntervalSince(ctx.date))
                    ZStack {
                        MobileDialTicks(fraction: left / total, tint: f.locked ? MTheme.distracting : MTheme.accent)
                        Text(DurationText.clock(left)).font(.system(size: 44, weight: .light, design: .rounded)).monospacedDigit()
                    }
                    .frame(width: 260, height: 260).frame(maxWidth: .infinity)
                }
                Text("Running on \(state.hostName) until \(f.end.formatted(date: .omitted, time: .shortened)). End it on the Mac.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else {
            MCard("01", "Focus", note: "drag the dial") {
                MobileDial(minutes: $minutes).frame(width: 280, height: 280).frame(maxWidth: .infinity)
                Toggle("Lock (can't be ended early)", isOn: $locked)
                Button {
                    if locked { confirmLock = true } else { Task { await state.request(.startFocus(minutes: minutes, locked: false, label: nil)) } }
                } label: { Label("Start \(minutes) min", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Text("Starts on \(state.hostName) and blocks your blocklist there\(state.services.canBlock ? " and here" : "").")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .confirmationDialog("Lock this session?", isPresented: $confirmLock) {
                Button("Start locked session") { Task { await state.request(.startFocus(minutes: minutes, locked: true, label: nil)) } }
            } message: { Text("A locked session can't be ended early by anyone, on any device.") }
        }
    }
}

struct MobileDialTicks: View {
    var fraction: Double
    var tint: Color
    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2, c = CGPoint(x: size.width / 2, y: size.height / 2)
            let lit = Int((fraction * 60).rounded())
            for i in 0..<60 {
                let a = Double(i) / 60 * 2 * .pi - .pi / 2
                let isLit = i < lit, head = lit > 0 && i == lit - 1
                let len: CGFloat = head ? r * 0.2 : isLit ? r * 0.13 : (i % 5 == 0 ? r * 0.09 : r * 0.06)
                var p = Path()
                p.move(to: CGPoint(x: c.x + CGFloat(cos(a)) * (r - 2 - len), y: c.y + CGFloat(sin(a)) * (r - 2 - len)))
                p.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * (r - 2), y: c.y + CGFloat(sin(a)) * (r - 2)))
                ctx.stroke(p, with: .color(head ? tint : isLit ? MTheme.ink.opacity(0.85) : MTheme.ink.opacity(0.18)),
                           style: StrokeStyle(lineWidth: head ? 3 : isLit ? 2 : 1.2, lineCap: .round))
            }
        }
    }
}

/// Touch-and-drag dial: 5–180 minutes in 5-minute steps, a haptic tick at each step.
struct MobileDial: View {
    @Binding var minutes: Int
    let maxMinutes = 180, step = 5

    var body: some View {
        GeometryReader { g in
            let size = min(g.size.width, g.size.height)
            ZStack {
                MobileDialTicks(fraction: Double(minutes) / Double(maxMinutes), tint: MTheme.accent)
                VStack(spacing: 0) {
                    Text("\(minutes)").font(.system(size: size * 0.24, weight: .light, design: .rounded)).monospacedDigit()
                    Text("MIN").font(MTheme.label(11)).foregroundStyle(.secondary)
                }
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in drag(to: v.location, size: size) })
            .accessibilityElement()
            .accessibilityLabel("Focus length")
            .accessibilityValue("\(minutes) minutes")
            .accessibilityAdjustableAction { d in
                minutes = min(maxMinutes, max(step, minutes + (d == .increment ? step : -step)))
            }
        }
    }

    /// Angle from 12 o'clock → minutes, snapped to 5; never wraps past the top.
    private func drag(to p: CGPoint, size: CGFloat) {
        let dx = Double(p.x - size / 2), dy = Double(p.y - size / 2)
        guard dx * dx + dy * dy > 100 else { return }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * Double.pi }
        let steps = (angle / (2 * Double.pi) * Double(maxMinutes) / Double(step)).rounded()
        var value = Int(steps) * step
        if minutes >= maxMinutes * 3 / 4 && value < maxMinutes / 4 { value = maxMinutes }
        if minutes <= maxMinutes / 4 && value > maxMinutes * 3 / 4 { value = step }
        let clamped = min(maxMinutes, max(step, value))
        if clamped != minutes {
            minutes = clamped
            MHaptics.tick()
        }
    }
}

// MARK: - Tasks + speak to schedule (iPhone / iPad)

struct MobileTasks: View {
    @ObservedObject var state: DeviceState
    @StateObject private var speech = SpeechCapture()
    @State private var draft = ""
    @State private var plan: VoicePlan?

    var body: some View {
        let todos = state.snapshot?.todos ?? []
        MCard("T", "Tasks", note: "\(todos.count) open") {
            HStack(spacing: 8) {
                TextField(speech.listening ? "Listening…" : "Add a task, or hold the mic", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(understand)
                Button { Task { await speech.toggle() } } label: {
                    Image(systemName: speech.listening ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(speech.listening ? MTheme.accent : MTheme.ink)
                }
                .accessibilityLabel(speech.listening ? "Stop listening" : "Speak a task")
            }
            if speech.listening { Text("LISTENING · ON-DEVICE").font(MTheme.label(9)).foregroundStyle(MTheme.accent) }
            if let p = speech.problem { Text(p).font(.caption).foregroundStyle(MTheme.distracting) }
            if let p = plan {
                MobilePlanPreview(plan: Binding(get: { p }, set: { plan = $0 })) { final in
                    Task { await state.request(.editTimetable(op: .create, item: final.item())) }
                    MHaptics.success()
                    plan = nil; draft = ""
                } onCancel: { plan = nil }
            }
            ForEach(todos) { t in
                HStack(spacing: 10) {
                    Button {
                        var done = t; done.done = true
                        Task { await state.request(.editTimetable(op: .update, item: done)) }
                    } label: { Image(systemName: "circle").foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.title)
                        HStack(spacing: 6) {
                            Text("\(t.estimate ?? 60) MIN").font(MTheme.label(9)).foregroundStyle(.secondary)
                            if t.wantsFocus == true { Text("FOCUS").font(MTheme.label(9)).foregroundStyle(MTheme.accent) }
                        }
                    }
                    Spacer()
                    Button("Next slot") {
                        let busy = state.snapshot?.timetable ?? []
                        let start = Scheduler.nextFreeSlot(minutes: t.estimate ?? 60, after: Date(), busy: busy)
                        Task { await state.request(.editTimetable(op: .update, item: t.scheduled(at: start))) }
                    }
                    .font(.caption).foregroundStyle(MTheme.accent)
                }
            }
        }
        .onChange(of: speech.listening) { listening in
            if !listening, !speech.transcript.isEmpty { draft = speech.transcript; understand() }
        }
        .onChange(of: speech.transcript) { text in if speech.listening { draft = text } }
    }

    private func understand() {
        plan = VoicePlanner.parse(draft)
        if plan == nil, !draft.trimmingCharacters(in: .whitespaces).isEmpty {
            state.message = "Couldn't find a task in that. Try “Gym tomorrow at 7”."
        }
    }
}

struct MobilePlanPreview: View {
    @Binding var plan: VoicePlan
    var onAdd: (VoicePlan) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("UNDERSTOOD").font(MTheme.label(9)).foregroundStyle(MTheme.accent)
            TextField("Title", text: $plan.title).textFieldStyle(.roundedBorder)
            if let start = plan.start {
                let end = plan.end ?? start.addingTimeInterval(Double(plan.minutes ?? 60) * 60)
                Text("\(start.formatted(.dateTime.weekday(.wide).day().month().hour().minute()))–\(end.formatted(date: .omitted, time: .shortened))")
                    .font(.callout)
            } else {
                Stepper("Takes about \(plan.minutes ?? 60) min", value: Binding(get: { plan.minutes ?? 60 }, set: { plan.minutes = $0 }), in: 15...480, step: 15)
                Text("No time heard: it goes to your tasks.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Block distractions during it", isOn: $plan.focus)
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button(plan.start == nil ? "Add task" : "Add to timetable") { onAdd(plan) }
                    .buttonStyle(.borderedProminent)
                    .disabled(plan.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(MTheme.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}
