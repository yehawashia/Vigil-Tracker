import Charts
import SwiftUI
import VigilCore

/// Trends and predictions. All data comes precomputed in `model.trends` (built off the main thread),
/// so this view only lays out charts.
struct TrendsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Color.clear.frame(height: 0)
                .pageHeader("Trends", subtitle: "Where your time goes, your daily rhythm, and what's likely next.")
            if let t = model.trends {
                HStack(alignment: .top, spacing: 16) {
                    TodayForecastCard(t: t).frame(maxWidth: .infinity).crosshairs()
                    WeekForecastCard(t: t).frame(maxWidth: .infinity).crosshairs()
                }
                HeatmapCard(t: t).crosshairs()
                BarcodeCard(t: t).crosshairs()
                HStack(alignment: .top, spacing: 16) {
                    RhythmCard(t: t).frame(maxWidth: .infinity).crosshairs()
                    RangeCard(t: t).frame(maxWidth: .infinity).crosshairs()
                }
                HStack(alignment: .top, spacing: 16) {
                    ShareDotsCard(t: t).frame(maxWidth: .infinity).crosshairs()
                    RankRingCard(t: t).frame(maxWidth: .infinity).crosshairs()
                }
                if !t.notes.isEmpty {
                    Card("Findings") {
                        ForEach(t.notes, id: \.self) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Text("◆").font(Theme.label(9)).foregroundStyle(Theme.accent).padding(.top, 3)
                                Text(line).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            } else {
                Card { EmptyHint(symbol: "chart.xyaxis.line", title: "Crunching your data…", message: "This takes a moment the first time.") }
            }
        }
        .onAppear { model.refreshTrends(force: true) }
    }
}

// MARK: - Shared chart styling

private func hours(_ seconds: Double) -> Double { seconds / 3600 }

private struct ChartTitle: View {
    var number: String
    var title: String
    var subtitle: String
    var readout: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(number: number, title: title)
            HStack(alignment: .firstTextBaseline) {
                Text(subtitle).font(Theme.label(9.5)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Text(readout.map { "→ " + $0.uppercased() } ?? " ")
                    .font(Theme.label(9.5)).foregroundStyle(Theme.accent).lineLimit(1)
            }
        }
    }
}

/// Hover crosshair + click for Swift Charts (macOS 13 compatible).
private extension View {
    func hoverX<V: Plottable>(_ type: V.Type, onHover: @escaping (V?) -> Void, onTap: ((V) -> Void)? = nil) -> some View {
        chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            let origin = geo[proxy.plotAreaFrame].origin
                            onHover(proxy.value(atX: p.x - origin.x, as: V.self))
                        case .ended: onHover(nil)
                        }
                    }
                    .gesture(SpatialTapGesture().onEnded { v in
                        let origin = geo[proxy.plotAreaFrame].origin
                        if let val = proxy.value(atX: v.location.x - origin.x, as: V.self) { onTap?(val) }
                    })
            }
        }
    }
}

private func crosshairRule<V: Plottable>(_ value: V) -> some ChartContent {
    RuleMark(x: .value("Hover", value))
        .foregroundStyle(Theme.ink.opacity(0.5))
        .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
}

private extension View {
    func monoAxes() -> some View {
        self.chartXAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel().font(Theme.label(9))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel().font(Theme.label(9))
            }
        }
    }
}

private func shortDay(_ key: String, _ format: String = "EEE") -> String {
    guard let d = DayKey.date(from: key) else { return key }
    let f = DateFormatter(); f.dateFormat = format
    return f.string(from: d)
}

// MARK: - Today forecast

private struct TodayForecastCard: View {
    var t: TrendsData
    @State private var hoverHour: Double?

    private var readout: String? {
        guard let h = hoverHour else { return nil }
        let hour = max(0, min(24, h))
        if hour <= nowHour {
            return String(format: "%02d:00 · ", Int(hour)) + DurationText.short(t.todaySoFar[min(23, max(0, Int(hour) - 1))]) + " tracked"
        }
        guard let f = t.todayFinish else { return nil }
        let soFar = t.todaySoFar[min(23, Int(nowHour))]
        let frac = (hour - nowHour) / max(0.01, 24 - nowHour)
        return String(format: "%02d:00 · ~", Int(hour)) + DurationText.short(soFar + (f.expected - soFar) * frac) + " projected"
    }

    private var nowHour: Double { Forecaster.hourFraction(Date()) }

    var body: some View {
        Card {
            ChartTitle(number: "01", title: "Today, projected", subtitle: "tracked so far · where you'll likely finish", readout: readout)
            if let f = t.todayFinish {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(DurationText.short(f.expected))
                        .font(.system(size: 40, weight: .light, design: .rounded)).monospacedDigit()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("likely \(DurationText.short(f.low))–\(DurationText.short(f.high))").font(Theme.label(10.5))
                        if let p = t.todayProductiveFinish {
                            Text("\(DurationText.short(p.expected)) productive").font(Theme.label(10.5)).foregroundStyle(Theme.accent)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                Chart {
                    ForEach(0..<min(24, Int(nowHour) + 1), id: \.self) { h in
                        LineMark(x: .value("Hour", Double(h + 1)), y: .value("Hours", hours(t.todaySoFar[h])))
                            .foregroundStyle(Theme.ink)
                            .interpolationMethod(.monotone)
                    }
                    let soFar = hours(t.todaySoFar[min(23, Int(nowHour))])
                    AreaMark(x: .value("Hour", nowHour), yStart: .value("Low", soFar), yEnd: .value("High", soFar))
                        .foregroundStyle(Theme.accent.opacity(0.18))
                    AreaMark(x: .value("Hour", 24.0), yStart: .value("Low", hours(f.low)), yEnd: .value("High", hours(f.high)))
                        .foregroundStyle(Theme.accent.opacity(0.18))
                    LineMark(x: .value("Hour", nowHour), y: .value("Proj", soFar), series: .value("s", "projection"))
                        .foregroundStyle(Theme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    LineMark(x: .value("Hour", 24.0), y: .value("Proj", hours(f.expected)), series: .value("s", "projection"))
                        .foregroundStyle(Theme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    PointMark(x: .value("Hour", 24.0), y: .value("Proj", hours(f.expected)))
                        .foregroundStyle(Theme.accent).symbolSize(40)
                    if let h = hoverHour { crosshairRule(h) }
                    RuleMark(x: .value("Now", nowHour))
                        .foregroundStyle(Theme.hairline)
                        .annotation(position: .top, alignment: .leading) { Text("NOW").font(Theme.label(8.5)).foregroundStyle(.secondary) }
                }
                .chartXScale(domain: 0...24)
                .hoverX(Double.self) { hoverHour = $0 }
                .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 24]) { v in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel { Text(String(format: "%02d", v.as(Int.self) ?? 0)).font(Theme.label(9)) }
                } }
                .chartYAxis { AxisMarks(position: .leading) { v in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel { Text("\(v.as(Double.self).map { Int($0) } ?? 0)h").font(Theme.label(9)) }
                } }
                .frame(height: 170)
            } else {
                EmptyHint(symbol: "sparkles", title: "Not enough history yet",
                          message: "After 3 tracked days Vigil predicts where today will end.")
            }
        }
    }
}

// MARK: - Next 7 days

private struct WeekForecastCard: View {
    var t: TrendsData
    @State private var hoverDay: String?

    private var readout: String? {
        guard let d = hoverDay else { return nil }
        if let f = t.week.first(where: { $0.day == d }) {
            return "\(shortDay(d, "EEE d")) · forecast \(DurationText.short(f.active.expected)) (\(DurationText.short(f.active.low))–\(DurationText.short(f.active.high)))"
        }
        if let s = t.days.first(where: { $0.day == d }) {
            return "\(shortDay(d, "EEE d")) · \(DurationText.short(s.activeSeconds)) · score \(s.score)"
        }
        return nil
    }

    var body: some View {
        Card {
            ChartTitle(number: "02", title: "Next 7 days", subtitle: "last 2 weeks ● · forecast ○ with 80% band", readout: readout)
            if t.week.isEmpty {
                EmptyHint(symbol: "calendar", title: "Needs a week of data",
                          message: "Weekly forecasts start after 7 tracked days (\(t.trackedDays) so far).")
            } else {
                Chart {
                    ForEach(t.days.dropLast().suffix(14)) { d in
                        RuleMark(x: .value("Day", d.day), yStart: .value("0", 0), yEnd: .value("Active", hours(d.activeSeconds)))
                            .foregroundStyle(Theme.ink.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 1))
                        PointMark(x: .value("Day", d.day), y: .value("Active", hours(d.activeSeconds)))
                            .foregroundStyle(Theme.ink).symbolSize(28)
                    }
                    if let d = hoverDay { crosshairRule(d) }
                    ForEach(t.week) { f in
                        RuleMark(x: .value("Day", f.day), yStart: .value("Low", hours(f.active.low)), yEnd: .value("High", hours(f.active.high)))
                            .foregroundStyle(Theme.accent.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 7, lineCap: .round))
                        PointMark(x: .value("Day", f.day), y: .value("Active", hours(f.active.expected)))
                            .symbol { Circle().strokeBorder(Theme.accent, lineWidth: 1.5).background(Circle().fill(Theme.cardBackground)).frame(width: 8, height: 8) }
                    }
                }
                .hoverX(String.self) { hoverDay = $0 }
                .chartXAxis { AxisMarks(values: (t.days.dropLast().suffix(14).map(\.day) + t.week.map(\.day)).enumerated().filter { $0.offset % 3 == 0 }.map(\.element)) { v in
                    AxisValueLabel { Text(shortDay(v.as(String.self) ?? "", "d MMM").uppercased()).font(Theme.label(8.5)) }
                } }
                .chartYAxis { AxisMarks(position: .leading) { v in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel { Text("\(v.as(Double.self).map { Int($0) } ?? 0)h").font(Theme.label(9)) }
                } }
                .frame(height: 200)
                HStack(spacing: 14) {
                    ForEach(t.week.prefix(7)) { f in
                        VStack(spacing: 1) {
                            Text(shortDay(f.day).uppercased()).font(Theme.label(8.5)).foregroundStyle(.secondary)
                            Text(DurationText.short(f.active.expected)).font(.system(size: 11, weight: .medium)).monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 90-day barcode

private struct BarcodeCard: View {
    var t: TrendsData
    @EnvironmentObject var model: AppModel
    @State private var hoverDay: String?

    private var readout: String? {
        guard let d = hoverDay, let s = t.days.first(where: { $0.day == d }) else { return nil }
        guard s.activeSeconds >= 60 else { return "\(shortDay(d, "EEE d MMM")) · nothing tracked" }
        let pct = Int((s.productiveSeconds / s.activeSeconds * 100).rounded())
        return "\(shortDay(d, "EEE d MMM")) · \(DurationText.short(s.activeSeconds)) · \(pct)% productive · click to open"
    }

    var body: some View {
        let peaks = Set(t.days.sorted { $0.activeSeconds > $1.activeSeconds }.prefix(3).map(\.day))
        Card {
            HStack(alignment: .top) {
                ChartTitle(number: "04", title: "Ninety days as a barcode",
                           subtitle: "one line per day · dot = time tracked · filled = mostly productive · \(t.trackedDays) days tracked",
                           readout: readout)
            }
            Chart {
                ForEach(t.days) { d in barcodeMarks(d, peak: peaks.contains(d.day)) }
                if let d = hoverDay { crosshairRule(d) }
            }
            .hoverX(String.self, onHover: { hoverDay = $0 }) { day in
                model.viewingDay = day
                model.section = .today
            }
            .chartYScale(domain: 0...max(14, (t.days.map { hours($0.activeSeconds) }.max() ?? 0) + 1.5))
            .chartXAxis { AxisMarks(values: t.days.map(\.day).filter { $0.hasSuffix("-01") }) { v in
                AxisValueLabel { Text(shortDay(v.as(String.self) ?? "", "MMM").uppercased()).font(Theme.label(9)) }
            } }
            .chartYAxis(.hidden)
            .frame(height: 170)
        }
    }
}

extension BarcodeCard {
    @ChartContentBuilder
    func barcodeMarks(_ d: DaySummary, peak: Bool) -> some ChartContent {
        RuleMark(x: .value("Day", d.day), yStart: .value("0", 0), yEnd: .value("Top", 14))
            .foregroundStyle(Theme.hairline).lineStyle(StrokeStyle(lineWidth: 0.6))
        if d.activeSeconds >= 60 {
            RuleMark(x: .value("Day", d.day), yStart: .value("0", 0), yEnd: .value("Active", hours(d.activeSeconds)))
                .foregroundStyle(Theme.ink.opacity(0.55)).lineStyle(StrokeStyle(lineWidth: 1))
            PointMark(x: .value("Day", d.day), y: .value("Active", hours(d.activeSeconds)))
                .symbol { BarcodeDot(d: d, size: peak ? 8 : 5) }
                .annotation(position: .top, spacing: 3) {
                    if peak { Text(DurationText.short(d.activeSeconds)).font(Theme.label(8.5)).foregroundStyle(.secondary) }
                }
        }
    }
}

/// Filled dot = mostly productive; hollow = not; coral/orange = more distracting than productive.
private struct BarcodeDot: View {
    var d: DaySummary
    var size: CGFloat
    var body: some View {
        let tint = d.distractingSeconds > d.productiveSeconds ? Theme.distracting : Theme.ink
        if d.productiveSeconds >= d.activeSeconds / 2 {
            Circle().fill(tint).frame(width: size, height: size)
        } else {
            Circle().strokeBorder(tint, lineWidth: 1.3).background(Circle().fill(Theme.cardBackground)).frame(width: size + 1, height: size + 1)
        }
    }
}

// MARK: - Rhythm

private struct RhythmCard: View {
    var t: TrendsData
    @State private var hoverHour: Double?

    private var readout: String? {
        guard let h = hoverHour, let p = t.rhythm.first(where: { $0.hour == Int(h.rounded()) }) else { return nil }
        return String(format: "%02d:00 · weekday %dm · weekend %dm · distracting %dm", p.hour,
                      Int(p.weekdayProductive.rounded()), Int(p.weekendProductive.rounded()), Int(p.weekdayDistracting.rounded()))
    }

    var body: some View {
        Card {
            ChartTitle(number: "05", title: "Your daily rhythm", subtitle: "avg productive minutes per hour", readout: readout)
            Chart {
                ForEach(t.rhythm) { p in
                    AreaMark(x: .value("Hour", p.hour), y: .value("Min", p.weekdayProductive), series: .value("S", "Weekdays"))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(LinearGradient(colors: [Theme.productive.opacity(0.28), Theme.productive.opacity(0)],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Hour", p.hour), y: .value("Min", p.weekdayProductive), series: .value("S", "Weekdays"))
                        .interpolationMethod(.catmullRom).foregroundStyle(Theme.productive).lineStyle(StrokeStyle(lineWidth: 1.6))
                    LineMark(x: .value("Hour", p.hour), y: .value("Min", p.weekendProductive), series: .value("S", "Weekends"))
                        .interpolationMethod(.catmullRom).foregroundStyle(Theme.series2).lineStyle(StrokeStyle(lineWidth: 1.6, dash: [5, 3]))
                    LineMark(x: .value("Hour", p.hour), y: .value("Min", p.weekdayDistracting), series: .value("S", "Distracting"))
                        .interpolationMethod(.catmullRom).foregroundStyle(Theme.distracting.opacity(0.8)).lineStyle(StrokeStyle(lineWidth: 1))
                }
                if let h = hoverHour {
                    crosshairRule(h.rounded())
                    if let p = t.rhythm.first(where: { $0.hour == Int(h.rounded()) }) {
                        PointMark(x: .value("Hour", p.hour), y: .value("Min", p.weekdayProductive)).foregroundStyle(Theme.productive).symbolSize(30)
                        PointMark(x: .value("Hour", p.hour), y: .value("Min", p.weekendProductive)).foregroundStyle(Theme.series2).symbolSize(30)
                    }
                }
            }
            .hoverX(Double.self) { hoverHour = $0 }
            .chartXScale(domain: 0...23)
            .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) { v in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel { Text(String(format: "%02d:00", v.as(Int.self) ?? 0)).font(Theme.label(9)) }
            } }
            .chartYAxis { AxisMarks(position: .leading) { v in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel { Text("\(v.as(Double.self).map { Int($0) } ?? 0)m").font(Theme.label(9)) }
            } }
            .frame(height: 190)
            HStack(spacing: 14) {
                legend("Weekdays", Theme.productive, dashed: false)
                legend("Weekends", Theme.series2, dashed: true)
                legend("Distracting", Theme.distracting, dashed: false)
            }
        }
    }

    private func legend(_ text: String, _ color: Color, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 14, height: dashed ? 1.5 : 2.5)
            Text(text.uppercased()).font(Theme.label(9)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Daily range

private struct RangeCard: View {
    var t: TrendsData
    @State private var hoverDay: String?

    private var readout: String? {
        guard let d = hoverDay, let r = t.ranges.first(where: { $0.day == d }) else { return nil }
        return String(format: "%@ · %02d:%02d – %02d:%02d", shortDay(d, "EEE d"), r.firstMinute / 60, r.firstMinute % 60,
                      r.lastMinute / 60, r.lastMinute % 60)
    }

    /// Whole hours that cover every day's range.
    private var rangeDomain: ClosedRange<Double> {
        let lo = Double(((t.ranges.map(\.firstMinute).min() ?? 480) / 60))
        let hi = Double(min(24, (t.ranges.map(\.lastMinute).max() ?? 1320) / 60 + 1))
        return lo...max(lo + 1, hi)
    }

    var body: some View {
        Card {
            ChartTitle(number: "06", title: "Daily active range", subtitle: "first to last activity · last 30 days", readout: readout)
            if t.ranges.isEmpty {
                EmptyHint(symbol: "clock", title: "No days yet", message: "Days with at least 5 minutes of activity appear here.")
            } else {
                Chart {
                    ForEach(t.ranges) { r in
                        RuleMark(x: .value("Day", r.day),
                                 yStart: .value("First", -Double(r.firstMinute) / 60), yEnd: .value("Last", -Double(r.lastMinute) / 60))
                            .foregroundStyle(r.day == DayKey.today || r.day == hoverDay ? Theme.accent : Theme.ink)
                            .lineStyle(StrokeStyle(lineWidth: 5, lineCap: .round))
                    }
                }
                .hoverX(String.self) { hoverDay = $0 }
                // Plotted as negative hours so the morning sits at the top.
                .chartYScale(domain: -rangeDomain.upperBound ... -rangeDomain.lowerBound)
                .chartXAxis { AxisMarks(values: t.ranges.map(\.day).enumerated().filter { $0.offset % 7 == 0 }.map(\.element)) { v in
                    AxisValueLabel { Text(shortDay(v.as(String.self) ?? "", "d MMM").uppercased()).font(Theme.label(8.5)) }
                } }
                .chartYAxis { AxisMarks(position: .leading) { v in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel { Text(String(format: "%02d:00", v.as(Double.self).map { Int(-$0) } ?? 0)).font(Theme.label(9)) }
                } }
                .frame(height: 210)
            }
        }
    }
}

// MARK: - 100-dot share

private struct ShareDotsCard: View {
    var t: TrendsData
    @State private var focus: ActivityCategory?

    private var counts: [(ActivityCategory, Int)] {
        let total = max(1, t.share.values.reduce(0, +))
        var c = ActivityCategory.allCases.map { ($0, Int((t.share[$0] ?? 0) / total * 100)) }
        let missing = 100 - c.map(\.1).reduce(0, +)
        if total > 1, missing > 0, let i = c.indices.max(by: { c[$0].1 < c[$1].1 }) { c[i].1 += missing }
        return c
    }

    var body: some View {
        Card {
            ChartTitle(number: "07", title: "Where the week went", subtitle: "last 7 days · every dot = 1% of tracked time",
                       readout: focus.map { c in "\(c.label) · \(DurationText.short(t.share[c] ?? 0))" })
            HStack(alignment: .center, spacing: 28) {
                let dots = counts.flatMap { cat, n in Array(repeating: cat, count: n) }
                Canvas { ctx, size in
                    let cell = min(size.width, size.height) / 10
                    for i in 0..<100 {
                        let rect = CGRect(x: CGFloat(i % 10) * cell + cell * 0.15, y: CGFloat(i / 10) * cell + cell * 0.15,
                                          width: cell * 0.7, height: cell * 0.7)
                        let color: Color = i < dots.count ? dots[i].color : Theme.hairline
                        let dim = focus != nil && (i >= dots.count || dots[i] != focus)
                        ctx.fill(Path(ellipseIn: dim ? rect.insetBy(dx: rect.width * 0.25, dy: rect.height * 0.25) : rect),
                                 with: .color(dim ? color.opacity(0.25) : color))
                    }
                }
                .frame(width: 170, height: 170)
                .onContinuousHover { phase in
                    if case .active(let p) = phase {
                        let i = Int(p.y / 17) * 10 + Int(p.x / 17)
                        focus = (0..<dots.count).contains(i) ? dots[i] : nil
                    } else { focus = nil }
                }
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(counts, id: \.0) { cat, n in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(cat.color).frame(width: 9, height: 9).padding(.top, 3)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(cat.label.uppercased()).font(Theme.label(9.5)).foregroundStyle(.secondary)
                                Text("\(n)%").font(.system(size: 22, weight: .light, design: .rounded)).monospacedDigit()
                            }
                        }
                        .opacity(focus == nil || focus == cat ? 1 : 0.35)
                        .onHover { focus = $0 ? cat : nil }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Ranked ring

private struct RankRingCard: View {
    var t: TrendsData
    @State private var focus: Int?

    var body: some View {
        Card {
            ChartTitle(number: "08", title: "Ranked, last 7 days", subtitle: "top apps and sites · darker = more time",
                       readout: focus.flatMap { i in i < t.top.count ? "\(t.top[i].name) · \(DurationText.short(t.top[i].seconds))" : nil })
            if t.top.isEmpty {
                EmptyHint(symbol: "circle.dashed", title: "Nothing yet", message: "Use your Mac for a while.")
            } else {
                HStack(spacing: 24) {
                    RankRing(items: t.top, focus: $focus).frame(width: 170, height: 170)
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(t.top.prefix(8).enumerated()), id: \.offset) { i, item in
                            HStack(spacing: 8) {
                                Text(String(format: "%02d", i + 1)).font(Theme.label(9)).foregroundStyle(.secondary)
                                Circle().fill(item.category.color).frame(width: 6, height: 6)
                                Text(item.name).font(.system(size: 12)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(DurationText.short(item.seconds)).font(Theme.label(10)).foregroundStyle(.secondary)
                            }
                            .opacity(focus == nil || focus == i ? 1 : 0.35)
                            .onHover { focus = $0 ? i : nil }
                        }
                    }
                }
            }
        }
    }
}

/// Segmented ring, largest first, fading from ink to paper (macOS 13 has no SectorMark, so it's drawn by hand).
private struct RankRing: View {
    var items: [UsageItem]
    @Binding var focus: Int?

    /// Which segment is under a point (by angle, within the ring's radius band).
    private func index(at p: CGPoint, size: CGSize) -> Int? {
        let dx = p.x - size.width / 2, dy = p.y - size.height / 2
        let r = sqrt(dx * dx + dy * dy), outer = min(size.width, size.height) / 2
        guard r <= outer, r >= outer * 0.45 else { return nil }
        var a = atan2(Double(dy), Double(dx)) + .pi / 2
        if a < 0 { a += 2 * .pi }
        let total = max(1, items.reduce(0) { $0 + $1.seconds })
        var acc = 0.0
        for (i, item) in items.enumerated() {
            acc += item.seconds / total * 2 * .pi
            if a <= acc { return i }
        }
        return nil
    }

    var body: some View {
        Canvas { ctx, size in
            let total = max(1, items.reduce(0) { $0 + $1.seconds })
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = min(size.width, size.height) / 2, inner = outer * 0.52
            let gap = 0.025
            var angle = -Double.pi / 2
            for (i, item) in items.enumerated() {
                let sweep = item.seconds / total * 2 * .pi
                let start = angle + gap / 2, end = angle + max(gap, sweep) - gap / 2
                angle += sweep
                guard end > start else { continue }
                var p = Path()
                p.addArc(center: center, radius: outer, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
                p.addArc(center: center, radius: inner, startAngle: .radians(end), endAngle: .radians(start), clockwise: true)
                p.closeSubpath()
                let fade = 1 - Double(i) / Double(max(1, items.count)) * 0.8
                let dimmed = focus != nil && focus != i
                ctx.fill(p, with: .color((item.category == .distracting ? Theme.distracting : Theme.ink).opacity(dimmed ? fade * 0.25 : fade)))
                if focus == i { ctx.stroke(p, with: .color(Theme.accent), lineWidth: 1.5) }
            }
        }
        .overlay(GeometryReader { geo in
            Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                if case .active(let pt) = phase { focus = index(at: pt, size: geo.size) } else { focus = nil }
            }
        })
    }
}
