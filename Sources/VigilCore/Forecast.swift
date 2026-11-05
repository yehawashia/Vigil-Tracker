import Foundation

// MARK: - Trend data

extension DaySummary: Identifiable {
    public var id: String { day }
}

/// First and last activity on a day, as minutes after midnight.
public struct DayRange: Codable, Hashable, Identifiable {
    public var day: String
    public var firstMinute: Int
    public var lastMinute: Int
    public var id: String { day }
}

/// Average minutes per hour of the day, for weekdays and weekends.
public struct RhythmPoint: Codable, Hashable, Identifiable {
    public var hour: Int
    public var weekdayProductive: Double
    public var weekdayDistracting: Double
    public var weekendProductive: Double
    public var weekendDistracting: Double
    public var id: Int { hour }
}

/// One day's 24 hourly buckets (for the 3D terrain and heatmap).
public struct DayHours: Codable, Hashable, Identifiable {
    public var day: String
    public var hours: [HourBucket]
    public var id: String { day }
}

/// A predicted value with an uncertainty band (all in seconds).
public struct Projection: Codable, Hashable {
    public var expected: Double
    public var low: Double
    public var high: Double
    public init(expected: Double, low: Double, high: Double) {
        self.expected = expected; self.low = low; self.high = high
    }
}

public struct DayForecast: Codable, Hashable, Identifiable {
    public var day: String
    public var active: Projection
    public var productive: Projection
    public var id: String { day }
}

/// Everything the Trends page and paired devices draw. Computed off the main thread.
public struct TrendsData: Codable, Hashable {
    public var days: [DaySummary]                 // last 90 days, oldest first (no hourly detail)
    public var ranges: [DayRange]                 // last 30 days with activity
    public var rhythm: [RhythmPoint]              // 24 points
    public var todaySoFar: [Double]               // cumulative active seconds at the end of each hour, 0…23
    public var todayFinish: Projection?           // end-of-day active time
    public var todayProductiveFinish: Projection?
    public var week: [DayForecast]                // next 7 days
    public var share: [ActivityCategory: Double]  // last 7 days
    public var top: [UsageItem]                   // last 7 days, apps and sites
    public var notes: [String]                    // plain-language findings
    public var terrain: [DayHours] = []           // last 28 days, oldest first
    public var computedAt: Date

    /// Days with any tracked activity. Forecasts need about a week.
    public var trackedDays: Int { days.filter { $0.activeSeconds >= 60 }.count }
}

extension VigilStore {
    /// Active, productive and distracting seconds per day and hour since `sinceDay`.
    /// Segments are attributed to the hour they started in; they are short, so this is accurate to a minute or two.
    func hourlyByDay(sinceDay: String) -> [String: [HourBucket]] {
        let rows = (try? db.query("""
            SELECT day, CAST(strftime('%H', start, 'unixepoch', 'localtime') AS INTEGER) AS hour,
                   category, SUM(end - start) AS seconds
            FROM activity WHERE day >= ? GROUP BY day, hour, category
            """, [sinceDay])) ?? []
        var out: [String: [HourBucket]] = [:]
        for row in rows {
            guard let day = row.string("day"), let hour = row.int("hour"), (0..<24).contains(hour) else { continue }
            var buckets = out[day] ?? (0..<24).map { HourBucket(hour: $0, productive: 0, neutral: 0, distracting: 0) }
            let seconds = row.double("seconds") ?? 0
            switch ActivityCategory(rawValue: row.string("category") ?? "") ?? .neutral {
            case .productive: buckets[hour].productive += seconds
            case .neutral: buckets[hour].neutral += seconds
            case .distracting: buckets[hour].distracting += seconds
            }
            out[day] = buckets
        }
        return out
    }

    func dayRanges(sinceDay: String) -> [DayRange] {
        let rows = (try? db.query("""
            SELECT day, MIN(start) AS first, MAX(end) AS last FROM activity
            WHERE day >= ? GROUP BY day HAVING SUM(end - start) >= 300 ORDER BY day
            """, [sinceDay])) ?? []
        let cal = Calendar.current
        func minute(_ t: Double) -> Int {
            let c = cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: t))
            return (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }
        return rows.compactMap { row in
            guard let day = row.string("day"), let f = row.double("first"), let l = row.double("last") else { return nil }
            // A day that runs past midnight is shown as ending at midnight.
            let last = DayKey.string(for: Date(timeIntervalSince1970: l)) == day ? minute(l) : 24 * 60
            return DayRange(day: day, firstMinute: minute(f), lastMinute: max(minute(f), last))
        }
    }

    /// Builds all trend charts and forecasts. Five grouped queries; safe to call on a background connection.
    public func trends(now: Date = Date()) -> TrendsData {
        let today = DayKey.string(for: now)
        let days = history(days: 90, endingOn: today)
        let hourly = hourlyByDay(sinceDay: DayKey.offset(today, days: -56))
        let ranges = dayRanges(sinceDay: DayKey.offset(today, days: -29))
        let weekStart = DayKey.offset(today, days: -6)
        let apps = usage(fromDay: weekStart, toDay: today, groupBy: .app, limit: 8)
        let sites = usage(fromDay: weekStart, toDay: today, groupBy: .domain, limit: 8)
        let top = Array((apps + sites).sorted { $0.seconds > $1.seconds }.prefix(12))

        let lastWeek = days.suffix(7)
        let share: [ActivityCategory: Double] = [
            .productive: lastWeek.reduce(0) { $0 + $1.productiveSeconds },
            .neutral: lastWeek.reduce(0) { $0 + $1.neutralSeconds },
            .distracting: lastWeek.reduce(0) { $0 + $1.distractingSeconds },
        ]

        let rhythm = Forecaster.rhythm(hourly: hourly, excluding: today)
        let todayBuckets = hourly[today] ?? []
        let cumulative = Forecaster.cumulative(todayBuckets)
        let hourFraction = Forecaster.hourFraction(now)
        let finish = Forecaster.finish(today: today, hourly: hourly, hourFraction: hourFraction, productiveOnly: false)
        let productiveFinish = Forecaster.finish(today: today, hourly: hourly, hourFraction: hourFraction, productiveOnly: true)
        let past = days.filter { $0.day < today }
        let week = Forecaster.nextDays(7, after: today, history: past)

        var data = TrendsData(days: days, ranges: ranges, rhythm: rhythm, todaySoFar: cumulative,
                              todayFinish: finish, todayProductiveFinish: productiveFinish, week: week,
                              share: share, top: top, notes: [], computedAt: now)
        data.notes = Forecaster.notes(for: data)
        data.terrain = (0..<28).map { i in
            let day = DayKey.offset(today, days: i - 27)
            return DayHours(day: day, hours: hourly[day] ?? (0..<24).map { HourBucket(hour: $0, productive: 0, neutral: 0, distracting: 0) })
        }
        return data
    }
}

// MARK: - Forecasting (pure functions, no I/O)

public enum Forecaster {
    /// Hours elapsed today, e.g. 14.5 at 2:30 pm.
    public static func hourFraction(_ date: Date) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 + Double(c.second ?? 0) / 3600
    }

    public static func cumulative(_ buckets: [HourBucket]) -> [Double] {
        var running = 0.0
        return (0..<24).map { h in
            if h < buckets.count { running += buckets[h].productive + buckets[h].neutral + buckets[h].distracting }
            return running
        }
    }

    /// Seconds recorded before `hour` (fractional) in a day's buckets.
    static func done(_ buckets: [HourBucket], before hour: Double, productiveOnly: Bool) -> Double {
        var total = 0.0
        for b in buckets {
            let value = productiveOnly ? b.productive : b.productive + b.neutral + b.distracting
            let h = Double(b.hour)
            if h + 1 <= hour { total += value } else if h < hour { total += value * (hour - h) }
        }
        return total
    }

    /// End-of-day projection: today so far plus what you usually do after this time on this weekday.
    /// Uses up to 8 same-weekday days; falls back to the last 14 days if fewer than 3 exist.
    public static func finish(today: String, hourly: [String: [HourBucket]], hourFraction: Double,
                              productiveOnly: Bool) -> Projection? {
        let todayBuckets = hourly[today] ?? []
        let soFar = done(todayBuckets, before: 24, productiveOnly: productiveOnly)
        let weekday = DayKey.date(from: today).map { Calendar.current.component(.weekday, from: $0) }
        let pastDays = hourly.keys.filter { $0 < today }.sorted(by: >)
        let active = pastDays.filter { day in done(hourly[day] ?? [], before: 24, productiveOnly: false) >= 1800 }
        var sample = active.filter { day in
            DayKey.date(from: day).map { Calendar.current.component(.weekday, from: $0) } == weekday
        }.prefix(8).map { $0 }
        if sample.count < 3 { sample = Array(active.prefix(14)) }
        guard sample.count >= 3 else { return nil }
        let remaining = sample.map { day -> Double in
            let b = hourly[day] ?? []
            return max(0, done(b, before: 24, productiveOnly: productiveOnly) - done(b, before: hourFraction, productiveOnly: productiveOnly))
        }.sorted()
        return Projection(expected: soFar + quantile(remaining, 0.5),
                          low: soFar + quantile(remaining, 0.25),
                          high: soFar + quantile(remaining, 0.75))
    }

    /// Weekday-seasonal Holt smoothing over the last 8 weeks, with an 80% band from in-sample errors.
    public static func nextDays(_ count: Int, after today: String, history: [DaySummary]) -> [DayForecast] {
        let recent = Array(history.suffix(56))
        guard recent.filter({ $0.activeSeconds >= 60 }).count >= 7 else { return [] }
        func series(_ value: (DaySummary) -> Double) -> (forecast: [Projection], ok: Bool) {
            let values = recent.map(value)
            let weekdays = recent.map { DayKey.date(from: $0.day).map { Calendar.current.component(.weekday, from: $0) } ?? 1 }
            let overall = max(1, values.reduce(0, +) / Double(values.count))
            var factor: [Int: Double] = [:]
            for wd in 1...7 {
                let v = zip(values, weekdays).filter { $0.1 == wd }.map(\.0)
                factor[wd] = v.isEmpty ? 1 : max(0.05, (v.reduce(0, +) / Double(v.count)) / overall)
            }
            let deseason = zip(values, weekdays).map { $0 / (factor[$1] ?? 1) }
            let alpha = 0.3, beta = 0.1
            var level = deseason.first ?? 0
            var trend = 0.0
            var errors: [Double] = []
            for (i, y) in deseason.enumerated() where i > 0 {
                let predicted = level + trend
                errors.append(y - predicted)
                let newLevel = alpha * y + (1 - alpha) * (level + trend)
                trend = beta * (newLevel - level) + (1 - beta) * trend
                level = newLevel
            }
            let sigma = sqrt(errors.map { $0 * $0 }.reduce(0, +) / Double(max(1, errors.count)))
            let out = (1...count).map { k -> Projection in
                let day = DayKey.offset(today, days: k)
                let wd = DayKey.date(from: day).map { Calendar.current.component(.weekday, from: $0) } ?? 1
                let f = factor[wd] ?? 1
                let mid = max(0, (level + trend * Double(k)) * f)
                let spread = 1.28 * sigma * f * sqrt(Double(k))
                return Projection(expected: mid, low: max(0, mid - spread), high: mid + spread)
            }
            return (out, true)
        }
        let active = series { $0.activeSeconds }.forecast
        let productive = series { $0.productiveSeconds }.forecast
        return (0..<count).map { i in
            DayForecast(day: DayKey.offset(today, days: i + 1), active: active[i], productive: productive[i])
        }
    }

    /// Average minutes per hour, weekdays vs weekends, from up to 8 weeks (today excluded: it's unfinished).
    public static func rhythm(hourly: [String: [HourBucket]], excluding today: String) -> [RhythmPoint] {
        var wdP = [Double](repeating: 0, count: 24), wdD = wdP, weP = wdP, weD = wdP
        var wdDays = 0.0, weDays = 0.0
        for (day, buckets) in hourly where day != today {
            guard let date = DayKey.date(from: day) else { continue }
            let weekend = Calendar.current.isDateInWeekend(date)
            if weekend { weDays += 1 } else { wdDays += 1 }
            for b in buckets where (0..<24).contains(b.hour) {
                if weekend { weP[b.hour] += b.productive; weD[b.hour] += b.distracting }
                else { wdP[b.hour] += b.productive; wdD[b.hour] += b.distracting }
            }
        }
        return (0..<24).map { h in
            RhythmPoint(hour: h,
                        weekdayProductive: wdP[h] / max(1, wdDays) / 60, weekdayDistracting: wdD[h] / max(1, wdDays) / 60,
                        weekendProductive: weP[h] / max(1, weDays) / 60, weekendDistracting: weD[h] / max(1, weDays) / 60)
        }
    }

    public static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let pos = q * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - Double(lo))
    }

    /// Plain-language findings for the Trends page.
    public static func notes(for data: TrendsData) -> [String] {
        var notes: [String] = []
        func hourText(_ h: Int) -> String {
            let f = DateFormatter(); f.dateFormat = "ha"
            let d = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()
            return f.string(from: d).lowercased()
        }
        if let peak = data.rhythm.max(by: { $0.weekdayProductive < $1.weekdayProductive }), peak.weekdayProductive >= 5 {
            notes.append("On weekdays you're most productive around \(hourText(peak.hour)).")
        }
        if let drift = data.rhythm.max(by: { $0.weekdayDistracting < $1.weekdayDistracting }), drift.weekdayDistracting >= 5 {
            notes.append("Distraction peaks around \(hourText(drift.hour)) on weekdays. A focus block just before could help.")
        }
        let tracked = data.days.filter { $0.activeSeconds >= 60 }
        if tracked.count >= 14 {
            let recent = tracked.suffix(7).map(\.score), before = tracked.dropLast(7).suffix(7).map(\.score)
            let a = Double(recent.reduce(0, +)) / Double(max(1, recent.count))
            let b = Double(before.reduce(0, +)) / Double(max(1, before.count))
            if abs(a - b) >= 3 {
                notes.append("Your average score is \(a > b ? "up" : "down") \(Int(abs(a - b).rounded())) points on the week before.")
            }
        }
        if let f = data.todayFinish {
            notes.append("At this pace you'll finish today with about \(DurationText.short(f.expected)) tracked.")
        }
        if data.trackedDays < 7 {
            notes.append("Forecasts get going after a week of tracking (\(data.trackedDays) of 7 days so far).")
        }
        return notes
    }
}
