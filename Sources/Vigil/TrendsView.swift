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
                    TodayForecastCard(t: t).frame(maxWidth: .infinity)
                    WeekForecastCard(t: t).frame(maxWidth: .infinity)
                }
                BarcodeCard(t: t)
                HStack(alignment: .top, spacing: 16) {
                    RhythmCard(t: t).frame(maxWidth: .infinity)
                    RangeCard(t: t).frame(maxWidth: .infinity)
                }
                HStack(alignment: .top, spacing: 16) {
                    ShareDotsCard(t: t).frame(maxWidth: .infinity)
                    RankRingCard(t: t).frame(maxWidth: .infinity)
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
    var title: String
    var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(subtitle).font(Theme.label(10)).foregroundStyle(.secondary)
        }
    }
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

    private var nowHour: Double { Forecaster.hourFraction(Date()) }

    var body: some View {
        Card {
            ChartTitle(title: "Today, projected", subtitle: "tracked so far · where you'll likely finish")
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
                    RuleMark(x: .value("Now", nowHour))
                        .foregroundStyle(Theme.hairline)
                        .annotation(position: .top, alignment: .leading) { Text("NOW").font(Theme.label(8.5)).foregroundStyle(.secondary) }
                }
                .chartXScale(domain: 0...24)
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

    var body: some View {
        Card {
            ChartTitle(title: "Next 7 days", subtitle: "last 2 weeks ● · forecast ○ with 80% band")
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
                    ForEach(t.week) { f in
                        RuleMark(x: .value("Day", f.day), yStart: .value("Low", hours(f.active.low)), yEnd: .value("High", hours(f.active.high)))
                            .foregroundStyle(Theme.accent.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 7, lineCap: .round))
                        PointMark(x: .value("Day", f.day), y: .value("Active", hours(f.active.expected)))
                            .symbol { Circle().strokeBorder(Theme.accent, lineWidth: 1.5).background(Circle().fill(Theme.cardBackground)).frame(width: 8, height: 8) }
                    }
                }
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

    var body: some View {
        let peaks = Set(t.days.sorted { $0.activeSeconds > $1.activeSeconds }.prefix(3).map(\.day))
        Card {
            HStack(alignment: .top) {
                ChartTitle(title: "Ninety days as a barcode", subtitle: "one line per day · dot = time tracked · filled = mostly productive")
                Spacer()
                Text("\(t.trackedDays) DAYS TRACKED").font(Theme.label(9.5)).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(t.days) { d in barcodeMarks(d, peak: peaks.contains(d.day)) }
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

    var body: some View {
        Card {
            ChartTitle(title: "Your daily rhythm", subtitle: "average productive minutes per hour · weekdays vs weekends")
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
            }
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

    /// Whole hours that cover every day's range.
    private var rangeDomain: ClosedRange<Double> {
        let lo = Double(((t.ranges.map(\.firstMinute).min() ?? 480) / 60))
        let hi = Double(min(24, (t.ranges.map(\.lastMinute).max() ?? 1320) / 60 + 1))
        return lo...max(lo + 1, hi)
    }

    var body: some View {
        Card {
            ChartTitle(title: "Daily active range", subtitle: "first to last activity · last 30 days")
            if t.ranges.isEmpty {
                EmptyHint(symbol: "clock", title: "No days yet", message: "Days with at least 5 minutes of activity appear here.")
            } else {
                Chart {
                    ForEach(t.ranges) { r in
                        RuleMark(x: .value("Day", r.day),
                                 yStart: .value("First", -Double(r.firstMinute) / 60), yEnd: .value("Last", -Double(r.lastMinute) / 60))
                            .foregroundStyle(r.day == DayKey.today ? Theme.accent : Theme.ink)
                            .lineStyle(StrokeStyle(lineWidth: 5, lineCap: .round))
                    }
                }
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

    private var counts: [(ActivityCategory, Int)] {
        let total = max(1, t.share.values.reduce(0, +))
        var c = ActivityCategory.allCases.map { ($0, Int((t.share[$0] ?? 0) / total * 100)) }
        let missing = 100 - c.map(\.1).reduce(0, +)
        if total > 1, missing > 0, let i = c.indices.max(by: { c[$0].1 < c[$1].1 }) { c[i].1 += missing }
        return c
    }

    var body: some View {
        Card {
            ChartTitle(title: "Where the week went", subtitle: "last 7 days · every dot = 1% of tracked time")
            HStack(alignment: .center, spacing: 28) {
                let dots = counts.flatMap { cat, n in Array(repeating: cat, count: n) }
                Canvas { ctx, size in
                    let cell = min(size.width, size.height) / 10
                    for i in 0..<100 {
                        let rect = CGRect(x: CGFloat(i % 10) * cell + cell * 0.15, y: CGFloat(i / 10) * cell + cell * 0.15,
                                          width: cell * 0.7, height: cell * 0.7)
                        let color: Color = i < dots.count ? dots[i].color : Theme.hairline
                        ctx.fill(Path(ellipseIn: rect), with: .color(color))
                    }
                }
                .frame(width: 170, height: 170)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(counts, id: \.0) { cat, n in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(cat.color).frame(width: 9, height: 9).padding(.top, 3)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(cat.label.uppercased()).font(Theme.label(9.5)).foregroundStyle(.secondary)
                                Text("\(n)%").font(.system(size: 22, weight: .light, design: .rounded)).monospacedDigit()
                            }
                        }
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

    var body: some View {
        Card {
            ChartTitle(title: "Ranked, last 7 days", subtitle: "top apps and sites · darker = more time")
            if t.top.isEmpty {
                EmptyHint(symbol: "circle.dashed", title: "Nothing yet", message: "Use your Mac for a while.")
            } else {
                HStack(spacing: 24) {
                    RankRing(items: t.top).frame(width: 170, height: 170)
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(t.top.prefix(8).enumerated()), id: \.offset) { i, item in
                            HStack(spacing: 8) {
                                Text(String(format: "%02d", i + 1)).font(Theme.label(9)).foregroundStyle(.secondary)
                                Circle().fill(item.category.color).frame(width: 6, height: 6)
                                Text(item.name).font(.system(size: 12)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(DurationText.short(item.seconds)).font(Theme.label(10)).foregroundStyle(.secondary)
                            }
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
                ctx.fill(p, with: .color(item.category == .distracting ? Theme.distracting.opacity(fade) : Theme.ink.opacity(fade)))
            }
        }
    }
}
