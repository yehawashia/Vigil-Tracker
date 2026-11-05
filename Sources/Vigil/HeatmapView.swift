import SwiftUI
import VigilCore

/// Hour × day heatmap for the last 4 weeks, with an exact-minutes readout on hover.
/// (Replaced the 3D "time terrain": a flat grid answers "when do I work?" faster.)
struct HeatmapCard: View {
    var t: TrendsData
    @State private var hover: (day: String, hour: Int)?

    var body: some View {
        Card {
            SectionHeader(number: "03", title: "Hour by day", note: readout ?? "hover for minutes")
            Text("last 4 weeks · each row a day, each column an hour · brighter = more time · orange = mostly distracting")
                .font(Theme.label(10)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(Array(t.terrain.enumerated()), id: \.offset) { i, d in
                        Text(i % 7 == 0 ? shortDate(d.day) : " ").font(Theme.label(8.5)).foregroundStyle(.secondary)
                            .frame(height: 280 / CGFloat(max(1, t.terrain.count)))
                    }
                }
                VStack(spacing: 4) {
                    HourHeatmap(terrain: t.terrain, hover: $hover).frame(height: 280)
                    HStack {
                        ForEach([0, 6, 12, 18], id: \.self) { h in
                            Text(String(format: "%02d:00", h)).font(Theme.label(8.5)).foregroundStyle(.secondary)
                            if h != 18 { Spacer() }
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private var readout: String? {
        guard let h = hover, let d = t.terrain.first(where: { $0.day == h.day }), h.hour < d.hours.count else { return nil }
        let b = d.hours[h.hour]
        return "\(shortDate(h.day)) \(String(format: "%02d:00", h.hour)) · \(Int((b.productive / 60).rounded()))m productive · \(Int((b.distracting / 60).rounded()))m distracting"
    }

    private func shortDate(_ day: String) -> String {
        guard let d = DayKey.date(from: day) else { return day }
        let f = DateFormatter(); f.dateFormat = "d MMM"
        return f.string(from: d).uppercased()
    }
}

/// Day rows × hour columns; cell darkness = active minutes. Hover reports the cell.
struct HourHeatmap: View {
    var terrain: [DayHours]
    @Binding var hover: (day: String, hour: Int)?

    var body: some View {
        GeometryReader { geo in
            let rows = max(1, terrain.count)
            let cw = geo.size.width / 24, ch = geo.size.height / CGFloat(rows)
            let peak = max(60, terrain.flatMap(\.hours).map { $0.productive + $0.neutral + $0.distracting }.max() ?? 60)
            Canvas { ctx, _ in
                for (r, d) in terrain.enumerated() {
                    for b in d.hours {
                        let total = b.productive + b.neutral + b.distracting
                        let rect = CGRect(x: CGFloat(b.hour) * cw + 0.5, y: CGFloat(r) * ch + 0.5, width: cw - 1, height: ch - 1)
                        if total <= 0 {
                            ctx.fill(Path(ellipseIn: rect.insetBy(dx: cw * 0.42, dy: ch * 0.42)), with: .color(Theme.hairline))
                            continue
                        }
                        let dominant: ActivityCategory = b.distracting > b.productive ? .distracting : (b.productive >= b.neutral ? .productive : .neutral)
                        ctx.fill(Path(rect), with: .color(dominant.color.opacity(0.15 + 0.85 * min(1, total / peak))))
                    }
                }
                if let h = hover, let r = terrain.firstIndex(where: { $0.day == h.day }) {
                    let rect = CGRect(x: CGFloat(h.hour) * cw, y: CGFloat(r) * ch, width: cw, height: ch)
                    ctx.stroke(Path(rect), with: .color(Theme.ink), lineWidth: 1.2)
                    var cross = Path()
                    cross.move(to: CGPoint(x: rect.midX, y: 0)); cross.addLine(to: CGPoint(x: rect.midX, y: geo.size.height))
                    cross.move(to: CGPoint(x: 0, y: rect.midY)); cross.addLine(to: CGPoint(x: geo.size.width, y: rect.midY))
                    ctx.stroke(cross, with: .color(Theme.ink.opacity(0.25)), style: StrokeStyle(lineWidth: 0.6, dash: [2, 3]))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let hour = max(0, min(23, Int(p.x / cw)))
                    let row = max(0, min(rows - 1, Int(p.y / ch)))
                    if row < terrain.count { hover = (terrain[row].day, hour) }
                case .ended: hover = nil
                }
            }
        }
    }
}

