import SwiftUI
import VigilCore

/// Week planner. Click an empty slot to add, click an item to edit. Time blocks switch blocking on.
/// Agent suggestions wait in "Awaiting approval"; every change is kept in History and can be reverted.
struct TimetableView: View {
    @EnvironmentObject var model: AppModel
    @State private var weekStart = TimetableView.startOfWeek(Date())
    @State private var items: [TimetableItem] = []
    @State private var history: [TimetableRevision] = []
    @State private var editing: TimetableEdit?

    static func startOfWeek(_ date: Date) -> Date {
        let cal = Calendar.current
        return cal.dateInterval(of: .weekOfYear, for: date)?.start ?? cal.startOfDay(for: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if !model.proposals.isEmpty { ProposalsCard() }
            Card {
                WeekGrid(weekStart: weekStart, items: items,
                         pending: model.proposals.compactMap { $0.op == .delete ? nil : $0.after },
                         onSelect: { editing = TimetableEdit(item: $0, isNew: false) },
                         onCreate: { start in
                             editing = TimetableEdit(item: TimetableItem(title: "", start: start, end: start.addingTimeInterval(3600)), isNew: true)
                         })
            }
            historyCard
        }
        .onAppear(perform: load)
        .onChange(of: weekStart) { _ in load() }
        .onChange(of: model.timetableVersion) { _ in load() }
        .sheet(item: $editing) { edit in
            TimetableEditor(item: edit.item, isNew: edit.isNew) { result in
                editing = nil
                switch result {
                case .save(let i): model.saveTimetableItem(i, isNew: edit.isNew)
                case .delete(let i): model.deleteTimetableItem(i)
                case .cancel: break
                }
            }
        }
    }

    private func load() {
        items = model.store.timetable(from: weekStart, to: weekStart.addingTimeInterval(7 * 86400))
        history = model.store.timetableHistory(limit: 40)
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Timetable").font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Plan your week. Time blocks turn blocking on while they run.").foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Button { weekStart = weekStart.addingTimeInterval(-7 * 86400) } label: { Image(systemName: "chevron.left") }
                Button("This week") { weekStart = TimetableView.startOfWeek(Date()) }
                    .disabled(weekStart == TimetableView.startOfWeek(Date()))
                Button { weekStart = weekStart.addingTimeInterval(7 * 86400) } label: { Image(systemName: "chevron.right") }
                Button {
                    let start = Calendar.current.nextDate(after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? Date()
                    editing = TimetableEdit(item: TimetableItem(title: "", start: start, end: start.addingTimeInterval(3600)), isNew: true)
                } label: { Label("New", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
    }

    private var historyCard: some View {
        Card("History") {
            if history.isEmpty {
                Text("Every change you, your agent or a paired device makes appears here, and can be undone.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(history) { r in
                HStack(spacing: 10) {
                    Text(r.time.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                        .font(Theme.label(10)).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                    AuthorChip(author: r.author)
                    Text(r.summary).font(.system(size: 12.5)).lineLimit(1)
                    Spacer()
                    if r.status != .applied {
                        Text(r.status.rawValue.uppercased()).font(Theme.label(9))
                            .foregroundStyle(r.status == .rejected ? Theme.distracting : Theme.accent)
                    } else {
                        Button("Revert") { model.revert(r) }.buttonStyle(.plain).font(.caption).foregroundStyle(Theme.accent)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }
}

struct AuthorChip: View {
    var author: String
    var body: some View {
        let label = author == "mac" ? "MAC" : author == "agent" ? "AGENT" : "DEVICE"
        Text(label)
            .font(Theme.label(8.5))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().strokeBorder(author == "agent" ? Theme.accent : Theme.hairline))
            .foregroundStyle(author == "agent" ? Theme.accent : .secondary)
    }
}

/// Agent suggestions. Nothing changes until you press Approve.
struct ProposalsCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card("Awaiting your approval", trailing: AnyView(Text("\(model.proposals.count)").font(Theme.label(11)).foregroundStyle(Theme.accent))) {
            ForEach(model.proposals) { p in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.accent).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.summary).font(.system(size: 13, weight: .medium))
                        if let note = p.note, !note.isEmpty {
                            Text("“\(note)”").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Suggested by your agent · \(p.time.formatted(date: .omitted, time: .shortened))")
                            .font(Theme.label(9)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reject") { model.reject(p) }
                    Button("Approve") { model.approve(p) }.buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Week grid

private struct WeekGrid: View {
    var weekStart: Date
    var items: [TimetableItem]
    /// Agent suggestions, drawn as dashed outlines until approved.
    var pending: [TimetableItem] = []
    var onSelect: (TimetableItem) -> Void
    var onCreate: (Date) -> Void

    private let hourHeight: CGFloat = 40
    private let gutter: CGFloat = 46

    /// Shows 07:00–23:00, widened to fit anything earlier or later.
    private var hourRange: ClosedRange<Int> {
        let cal = Calendar.current
        let lo = items.map { cal.component(.hour, from: $0.start) }.min() ?? 7
        let hi = items.map { min(24, cal.component(.hour, from: $0.end) + (cal.component(.minute, from: $0.end) > 0 ? 1 : 0)) }.max() ?? 23
        return min(7, lo)...max(23, hi)
    }

    var body: some View {
        let range = hourRange
        let hours = CGFloat(range.upperBound - range.lowerBound)
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                Color.clear.frame(width: gutter, height: 1)
                ForEach(0..<7, id: \.self) { d in
                    let day = weekStart.addingTimeInterval(Double(d) * 86400)
                    let isToday = Calendar.current.isDateInToday(day)
                    VStack(spacing: 0) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased()).font(Theme.label(9.5))
                        Text(day.formatted(.dateTime.day())).font(.system(size: 17, weight: isToday ? .semibold : .light, design: .rounded))
                    }
                    .foregroundStyle(isToday ? Theme.accent : .secondary)
                    .frame(maxWidth: .infinity)
                }
            }
            GeometryReader { geo in
                let colWidth = (geo.size.width - gutter) / 7
                ZStack(alignment: .topLeading) {
                    // Hour lines and labels.
                    ForEach(Array(range), id: \.self) { h in
                        let y = CGFloat(h - range.lowerBound) * hourHeight
                        Path { p in p.move(to: CGPoint(x: gutter, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y)) }
                            .stroke(Theme.hairline, lineWidth: 0.6)
                        Text(String(format: "%02d:00", h)).font(Theme.label(9)).foregroundStyle(.secondary)
                            .position(x: gutter / 2 - 2, y: y)
                    }
                    // Click empty space to add an item at that half hour.
                    Color.clear.contentShape(Rectangle())
                        .frame(width: geo.size.width - gutter, height: hours * hourHeight)
                        .offset(x: gutter)
                        .gesture(SpatialTapGesture().onEnded { value in
                            let col = max(0, min(6, Int(value.location.x / colWidth)))
                            let minutes = Int((value.location.y / hourHeight * 60 / 30).rounded(.down)) * 30
                            let day = Calendar.current.date(byAdding: .day, value: col, to: weekStart) ?? weekStart
                            onCreate(day.addingTimeInterval(Double(range.lowerBound * 60 + minutes) * 60))
                        })
                    // Items.
                    ForEach(items) { item in
                        if let frame = frame(for: item, colWidth: colWidth, range: range) {
                            ItemChip(item: item).frame(width: frame.width, height: frame.height)
                                .offset(x: frame.minX, y: frame.minY)
                                .onTapGesture { onSelect(item) }
                        }
                    }
                    ForEach(pending) { item in
                        if let frame = frame(for: item, colWidth: colWidth, range: range) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                                .overlay(alignment: .topLeading) {
                                    Text("SUGGESTED · \(item.title)").font(Theme.label(8.5)).foregroundStyle(Theme.accent).padding(5).lineLimit(2)
                                }
                                .frame(width: frame.width, height: frame.height)
                                .offset(x: frame.minX, y: frame.minY)
                                .allowsHitTesting(false)
                        }
                    }
                    // Now line.
                    if let x = nowColumn(colWidth: colWidth) {
                        let y = nowY(range: range)
                        Rectangle().fill(Theme.distracting).frame(width: colWidth, height: 1.5).offset(x: x, y: y)
                        Circle().fill(Theme.distracting).frame(width: 7, height: 7).offset(x: x - 3, y: y - 2.75)
                    }
                }
            }
            .frame(height: hours * hourHeight)
        }
    }

    private func frame(for item: TimetableItem, colWidth: CGFloat, range: ClosedRange<Int>) -> CGRect? {
        let cal = Calendar.current
        guard let col = cal.dateComponents([.day], from: weekStart, to: cal.startOfDay(for: item.start)).day, (0..<7).contains(col) else { return nil }
        let dayStart = cal.startOfDay(for: item.start)
        let top = item.start.timeIntervalSince(dayStart) / 3600 - Double(range.lowerBound)
        let bottom = min(Double(range.upperBound - range.lowerBound), item.end.timeIntervalSince(dayStart) / 3600 - Double(range.lowerBound))
        return CGRect(x: gutter + CGFloat(col) * colWidth + 2, y: CGFloat(top) * hourHeight + 1,
                      width: colWidth - 4, height: max(18, CGFloat(bottom - top) * hourHeight - 2))
    }

    private func nowColumn(colWidth: CGFloat) -> CGFloat? {
        let cal = Calendar.current
        guard let col = cal.dateComponents([.day], from: weekStart, to: cal.startOfDay(for: Date())).day, (0..<7).contains(col) else { return nil }
        return gutter + CGFloat(col) * colWidth
    }

    private func nowY(range: ClosedRange<Int>) -> CGFloat {
        CGFloat(Forecaster.hourFraction(Date()) - Double(range.lowerBound)) * hourHeight
    }
}

private struct ItemChip: View {
    var item: TimetableItem

    var body: some View {
        let block = item.kind == .block
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if block { Image(systemName: "hand.raised.fill").font(.system(size: 8)) }
                Text(item.title).font(.system(size: 11, weight: .semibold)).lineLimit(2).strikethrough(item.done)
            }
            Text("\(item.start.formatted(date: .omitted, time: .shortened))–\(item.end.formatted(date: .omitted, time: .shortened))")
                .font(Theme.label(8.5)).opacity(0.8)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(block ? Theme.onAccent : Theme.ink)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(block ? Theme.accent : Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(block ? Color.clear : Theme.ink.opacity(0.5), lineWidth: 1))
        .opacity(item.done ? 0.55 : 1)
        .help(item.kind == .block ? "Time block: your blocklist is on while this runs" : "Task")
        .contentShape(Rectangle())
    }
}

// MARK: - Editor

enum EditorResult { case save(TimetableItem), delete(TimetableItem), cancel }

struct TimetableEditor: View {
    @State var item: TimetableItem
    var isNew: Bool
    var done: (EditorResult) -> Void

    init(item: TimetableItem, isNew: Bool, done: @escaping (EditorResult) -> Void) {
        _item = State(initialValue: item)
        self.isNew = isNew
        self.done = done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New item" : "Edit item").font(.title3.bold())
            TextField("Title", text: $item.title).textFieldStyle(.roundedBorder)
            DatePicker("Starts", selection: Binding(get: { item.start }, set: { new in
                let length = item.duration
                item.start = new
                item.end = new.addingTimeInterval(max(300, length))
            }))
            DatePicker("Ends", selection: $item.end, in: item.start.addingTimeInterval(300)...)
            Toggle(isOn: Binding(get: { item.kind == .block }, set: { item.kind = $0 ? .block : .task })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Block distractions during this")
                    Text("Turns your blocklist on for the whole time block.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !isNew { Toggle("Done", isOn: $item.done) }
            TextField("Notes (optional)", text: Binding(get: { item.notes ?? "" }, set: { item.notes = $0 }), axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...5)
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) { done(.delete(item)) }
                }
                Spacer()
                Button("Cancel") { done(.cancel) }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { done(.save(item)) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(item.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}
