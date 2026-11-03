import Foundation

extension VigilStore {
    public func summary(day: String, topLimit: Int = 10, now: Date = Date()) -> DaySummary {
        var summary = DaySummary.empty(day: day)
        let records = activities(day: day)
        guard !records.isEmpty else {
            summary.blockedAttempts = blockCount(day: day)
            return summary
        }

        var hourly = summary.hourly
        let calendar = Calendar.current
        var lastApp: String?
        var lastEnd: Date?
        var switches = 0

        for r in records {
            let d = r.duration
            summary.activeSeconds += d
            switch r.category {
            case .productive: summary.productiveSeconds += d
            case .neutral: summary.neutralSeconds += d
            case .distracting: summary.distractingSeconds += d
            }

            // Split the segment across hour buckets.
            var cursor = r.start
            while cursor < r.end {
                let hour = calendar.component(.hour, from: cursor)
                let nextHour = calendar.dateInterval(of: .hour, for: cursor)?.end ?? r.end
                let sliceEnd = min(nextHour, r.end)
                let slice = sliceEnd.timeIntervalSince(cursor)
                switch r.category {
                case .productive: hourly[hour].productive += slice
                case .neutral: hourly[hour].neutral += slice
                case .distracting: hourly[hour].distracting += slice
                }
                if sliceEnd <= cursor { break }
                cursor = sliceEnd
            }

            if let lastApp, lastApp != r.appName, let lastEnd, r.start.timeIntervalSince(lastEnd) < 60 {
                switches += 1
            }
            lastApp = r.appName
            lastEnd = r.end
        }

        summary.hourly = hourly
        summary.contextSwitches = switches
        summary.firstActivity = records.first?.start
        summary.lastActivity = records.map(\.end).max()
        summary.score = VigilStore.score(productive: summary.productiveSeconds,
                                         neutral: summary.neutralSeconds,
                                         distracting: summary.distractingSeconds)
        summary.topApps = usage(fromDay: day, toDay: day, groupBy: .app, limit: topLimit)
        summary.topDomains = usage(fromDay: day, toDay: day, groupBy: .domain, limit: topLimit)
        summary.blockedAttempts = blockCount(day: day)

        let sessions = focusSessions(sinceDay: day).filter { DayKey.string(for: $0.start) == day }
        summary.focusSessionsCompleted = sessions.filter { $0.endedEarly == nil && $0.end <= now }.count
        summary.focusMinutes = Int(sessions.reduce(0.0) { total, s in
            total + max(0, min(s.effectiveEnd, now).timeIntervalSince(s.start))
        } / 60)
        return summary
    }

    public static func score(productive: Double, neutral: Double, distracting: Double) -> Int {
        let total = productive + neutral + distracting
        guard total > 0 else { return 0 }
        let weighted = productive * ActivityCategory.productive.weight
            + neutral * ActivityCategory.neutral.weight
            + distracting * ActivityCategory.distracting.weight
        return Int((weighted / total * 100).rounded())
    }

    /// One summary per day, oldest first, for charts and trends.
    public func history(days: Int, endingOn endDay: String = DayKey.today) -> [DaySummary] {
        let startDay = DayKey.offset(endDay, days: -(days - 1))
        let rows = (try? db.query("""
            SELECT day, category, SUM(end - start) AS seconds FROM activity
            WHERE day BETWEEN ? AND ? GROUP BY day, category
            """, [startDay, endDay])) ?? []
        var byDay: [String: DaySummary] = [:]
        for row in rows {
            guard let day = row.string("day") else { continue }
            var s = byDay[day] ?? DaySummary.empty(day: day)
            let seconds = row.double("seconds") ?? 0
            switch ActivityCategory(rawValue: row.string("category") ?? "") ?? .neutral {
            case .productive: s.productiveSeconds += seconds
            case .neutral: s.neutralSeconds += seconds
            case .distracting: s.distractingSeconds += seconds
            }
            s.activeSeconds += seconds
            byDay[day] = s
        }
        return (0..<days).map { i in
            let day = DayKey.offset(startDay, days: i)
            var s = byDay[day] ?? DaySummary.empty(day: day)
            s.score = VigilStore.score(productive: s.productiveSeconds, neutral: s.neutralSeconds,
                                       distracting: s.distractingSeconds)
            return s
        }
    }

    // MARK: - Report text

    public func notificationText(for s: DaySummary) -> String {
        guard s.activeSeconds > 60 else { return "No tracked activity today." }
        var parts = ["Score \(s.score)/100",
                     "\(DurationText.short(s.productiveSeconds)) productive",
                     "\(DurationText.short(s.distractingSeconds)) distracting"]
        if let worst = s.topDomains.first(where: { $0.category == .distracting })
            ?? s.topApps.first(where: { $0.category == .distracting }) {
            parts.append("Biggest distraction: \(worst.name) (\(DurationText.short(worst.seconds)))")
        }
        return parts.joined(separator: " · ")
    }

    public func insights(for s: DaySummary, previous: DaySummary?) -> [String] {
        var lines: [String] = []
        guard s.activeSeconds > 60 else { return ["Nothing tracked yet for this day."] }

        if let previous, previous.activeSeconds > 60 {
            let delta = s.score - previous.score
            if delta > 0 { lines.append("Your score is up \(delta) points on the previous day.") }
            else if delta < 0 { lines.append("Your score is down \(-delta) points on the previous day.") }
            else { lines.append("Same score as the previous day.") }
            let prodDelta = s.productiveSeconds - previous.productiveSeconds
            if abs(prodDelta) >= 600 {
                lines.append("\(DurationText.short(abs(prodDelta))) \(prodDelta > 0 ? "more" : "less") productive time than the day before.")
            }
        }

        if let best = s.hourly.max(by: { $0.productive < $1.productive }), best.productive > 300 {
            lines.append(String(format: "Most productive hour: %02d:00–%02d:00 (%@ of focused work).",
                                best.hour, (best.hour + 1) % 24, DurationText.short(best.productive)))
        }
        if let worst = s.hourly.max(by: { $0.distracting < $1.distracting }), worst.distracting > 300 {
            lines.append(String(format: "Distraction peaked %02d:00–%02d:00 (%@).",
                                worst.hour, (worst.hour + 1) % 24, DurationText.short(worst.distracting)))
        }
        if let site = s.topDomains.first(where: { $0.category == .distracting }), site.seconds > 300 {
            lines.append("Top distracting site: \(site.name) at \(DurationText.short(site.seconds)). Consider a daily limit or adding it to the blocklist.")
        }
        if s.blockedAttempts > 0 {
            lines.append("Vigil blocked \(s.blockedAttempts) attempt\(s.blockedAttempts == 1 ? "" : "s") to open something on your blocklist.")
        }
        let hoursActive = s.activeSeconds / 3600
        if hoursActive > 0.5 {
            let perHour = Double(s.contextSwitches) / hoursActive
            if perHour > 40 {
                lines.append(String(format: "High context switching: about %.0f app switches per hour. Try a focus session to batch work.", perHour))
            }
        }
        if s.focusSessionsCompleted == 0 && s.productiveSeconds < 3600 {
            lines.append("No completed focus sessions. A single 25–50 minute session is a good place to start tomorrow.")
        }
        return lines
    }

    public func markdownReport(day: String) -> String {
        let s = summary(day: day)
        let previous = summary(day: DayKey.offset(day, days: -1))
        let dateText: String = {
            guard let d = DayKey.date(from: day) else { return day }
            let f = DateFormatter()
            f.dateStyle = .full
            return f.string(from: d)
        }()
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        var md = "# Vigil daily report: \(dateText)\n\n"
        if s.activeSeconds < 60 {
            md += "No tracked activity on this day.\n"
            return md
        }
        var scoreLine = "**Productivity score: \(s.score)/100**"
        if previous.activeSeconds > 60 {
            let delta = s.score - previous.score
            scoreLine += delta == 0 ? " (no change)" : " (\(delta > 0 ? "+" : "")\(delta) vs previous day)"
        }
        md += scoreLine + "\n\n"
        md += "- Active time: \(DurationText.short(s.activeSeconds))"
        if let first = s.firstActivity, let last = s.lastActivity {
            md += " (\(timeFormatter.string(from: first))–\(timeFormatter.string(from: last)))"
        }
        md += "\n"
        md += "- Productive \(DurationText.short(s.productiveSeconds)) · Neutral \(DurationText.short(s.neutralSeconds)) · Distracting \(DurationText.short(s.distractingSeconds))\n"
        md += "- Focus sessions completed: \(s.focusSessionsCompleted) (\(s.focusMinutes) min in focus)\n"
        md += "- Blocked attempts: \(s.blockedAttempts)\n"
        md += "- App switches: \(s.contextSwitches)\n\n"

        md += "## Insights\n\n"
        for line in insights(for: s, previous: previous) { md += "- \(line)\n" }

        md += "\n## Top apps\n\n| App | Time | Category |\n|---|---:|---|\n"
        for item in s.topApps.prefix(8) {
            md += "| \(item.name) | \(DurationText.short(item.seconds)) | \(item.category.label) |\n"
        }
        if !s.topDomains.isEmpty {
            md += "\n## Top websites\n\n| Site | Time | Category |\n|---|---:|---|\n"
            for item in s.topDomains.prefix(8) {
                md += "| \(item.name) | \(DurationText.short(item.seconds)) | \(item.category.label) |\n"
            }
        }
        return md
    }

    /// Writes the report to ~/Library/Application Support/Vigil/Reports/YYYY-MM-DD.md and returns its URL.
    @discardableResult
    public func saveReport(day: String) -> URL? {
        let url = VigilPaths.reportsDirectory.appendingPathComponent("\(day).md")
        do {
            try markdownReport(day: day).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
