import SwiftUI
import VigilCore

/// The data engine: ranked conclusions, flow arcs (category → app → site), an object inspector
/// (what comes before and after anything you use) and the plans that got interrupted.
struct EngineView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Engine").font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("Where your time goes, what leads where, and what it costs.").foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $model.engineDays) {
                    Text("7 days").tag(7); Text("14 days").tag(14); Text("30 days").tag(30)
                }
                .pickerStyle(.segmented).frame(width: 240)
            }
            if let e = model.engine {
                ConclusionsCard(e: e)
                Card {
                    SectionHeader(number: "02", title: "Flow", note: "category → app → site · hover to trace, click to inspect")
                    FlowArcs(e: e, selected: $model.inspected).frame(height: 460)
                }
                .crosshairs()
                HStack(alignment: .top, spacing: 16) {
                    InspectorCard(e: e).frame(maxWidth: .infinity)
                    InterruptionsCard(e: e).frame(maxWidth: .infinity)
                }
            } else {
                Card { EmptyHint(symbol: "point.3.connected.trianglepath.dotted", title: "Building the engine…", message: "This takes a moment.") }
            }
        }
        .onAppear { model.refreshEngine(force: true) }
        .onChange(of: model.engineDays) { _ in model.refreshEngine(force: true) }
    }
}

// MARK: - Conclusions

private struct ConclusionsCard: View {
    var e: EngineData
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            SectionHeader(number: "01", title: "Conclusions", note: "\(e.days) days · ranked by time involved")
            if e.conclusions.isEmpty {
                Text("Not enough to go on yet. Conclusions appear after a few days of tracking and planned blocks.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(e.conclusions.prefix(6).enumerated()), id: \.element.id) { i, c in
                Button { if let s = c.subject { model.inspected = s } } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Text(String(format: "%02d", i + 1)).font(Theme.label(10)).foregroundStyle(.secondary).frame(width: 18)
                        Text(c.kind.rawValue.uppercased()).font(Theme.label(9))
                            .foregroundStyle(c.kind == .win ? Theme.productive : Theme.accent)
                            .frame(width: 92, alignment: .leading)
                        Text(c.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(DurationText.short(c.impactSeconds)).font(Theme.label(10)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }
        }
    }
}

// MARK: - Flow arcs

/// Three columns (categories, apps, sites) joined by curved bands whose width is time.
/// Drawn in one Canvas; hovering a node highlights only its bands.
struct FlowArcs: View {
    var e: EngineData
    @Binding var selected: String?
    @State private var hover: String?

    private struct Node { var id: String; var label: String; var column: Int; var seconds: Double; var category: ActivityCategory?; var rect: CGRect = .zero }
    private struct Band { var from: String; var to: String; var seconds: Double; var category: ActivityCategory }

    /// Top 10 apps and 14 sites; the rest are folded into "Other".
    private func layout(size: CGSize) -> (nodes: [String: Node], bands: [Band]) {
        let topApps = Set(Dictionary(grouping: e.flows, by: \.app).mapValues { $0.reduce(0) { $0 + $1.seconds } }
            .sorted { $0.value > $1.value }.prefix(10).map(\.key))
        let topSites = Set(Dictionary(grouping: e.flows.compactMap { f in f.site.map { (site: $0, s: f.seconds) } }, by: \.site)
            .mapValues { $0.reduce(0) { $0 + $1.s } }.sorted { $0.value > $1.value }.prefix(14).map(\.key))
        var nodes: [String: Node] = [:]
        var bandMap: [String: Band] = [:]
        func add(_ id: String, _ label: String, _ col: Int, _ s: Double, _ cat: ActivityCategory?) {
            var n = nodes[id] ?? Node(id: id, label: label, column: col, seconds: 0, category: cat)
            n.seconds += s
            nodes[id] = n
        }
        func band(_ a: String, _ b: String, _ s: Double, _ c: ActivityCategory) {
            let k = a + "→" + b
            bandMap[k, default: Band(from: a, to: b, seconds: 0, category: c)].seconds += s
        }
        for f in e.flows where f.seconds > 0 {
            let cat = "c:" + f.category.rawValue
            let app = topApps.contains(f.app) ? "a:" + f.app : "a:Other apps"
            add(cat, f.category.label, 0, f.seconds, f.category)
            add(app, String(app.dropFirst(2)), 1, f.seconds, nil)
            band(cat, app, f.seconds, f.category)
            if let site = f.site {
                let sid = topSites.contains(site) ? "s:" + site : "s:Other sites"
                add(sid, String(sid.dropFirst(2)), 2, f.seconds, f.category)
                band(app, sid, f.seconds, f.category)
            }
        }
        // Stack each column top to bottom, largest first, with gaps.
        let colX: [CGFloat] = [0, size.width * 0.42, size.width - 12]
        for col in 0...2 {
            let ids = nodes.values.filter { $0.column == col }.sorted { $0.seconds > $1.seconds }.map(\.id)
            let total = ids.reduce(0) { $0 + nodes[$1]!.seconds }
            let gap: CGFloat = col == 0 ? 18 : 6
            let usable = max(10, size.height - gap * CGFloat(max(0, ids.count - 1)))
            var y: CGFloat = 0
            for id in ids {
                let h = max(3, usable * CGFloat(nodes[id]!.seconds / max(1, total)))
                nodes[id]!.rect = CGRect(x: colX[col], y: y, width: 12, height: h)
                y += h + gap
            }
        }
        return (nodes, bandMap.values.sorted { $0.seconds > $1.seconds })
    }

    var body: some View {
        GeometryReader { geo in
            let plot = CGSize(width: geo.size.width - 300, height: geo.size.height)
            let (nodes, bands) = layout(size: plot)
            let focus = hover ?? selected.map { k in nodes.keys.first { $0.hasSuffix(":" + k) } ?? k }
            let linked: Set<String> = focus.map { f in Set(bands.filter { $0.from == f || $0.to == f }.flatMap { [$0.from, $0.to] }).union([f]) } ?? []
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    var outOffset: [String: CGFloat] = [:], inOffset: [String: CGFloat] = [:]
                    for b in bands {
                        guard let a = nodes[b.from], let z = nodes[b.to] else { continue }
                        let ha = a.rect.height * CGFloat(b.seconds / max(1, a.seconds))
                        let hz = z.rect.height * CGFloat(b.seconds / max(1, z.seconds))
                        let y0 = a.rect.minY + (outOffset[b.from] ?? 0), y1 = z.rect.minY + (inOffset[b.to] ?? 0)
                        outOffset[b.from, default: 0] += ha; inOffset[b.to, default: 0] += hz
                        let x0 = a.rect.maxX, x1 = z.rect.minX, mid = (x0 + x1) / 2
                        var p = Path()
                        p.move(to: CGPoint(x: x0, y: y0))
                        p.addCurve(to: CGPoint(x: x1, y: y1), control1: CGPoint(x: mid, y: y0), control2: CGPoint(x: mid, y: y1))
                        p.addLine(to: CGPoint(x: x1, y: y1 + hz))
                        p.addCurve(to: CGPoint(x: x0, y: y0 + ha), control1: CGPoint(x: mid, y: y1 + hz), control2: CGPoint(x: mid, y: y0 + ha))
                        p.closeSubpath()
                        let lit = focus == nil || (b.from == focus || b.to == focus)
                        let color = b.category.color
                        ctx.fill(p, with: .color(color.opacity(lit ? 0.32 : 0.05)))
                        // A thin centre line gives the arcs their drawn, poster-like look.
                        var line = Path()
                        let c0 = y0 + ha / 2, c1 = y1 + hz / 2
                        line.move(to: CGPoint(x: x0, y: c0))
                        line.addCurve(to: CGPoint(x: x1, y: c1), control1: CGPoint(x: mid, y: c0), control2: CGPoint(x: mid, y: c1))
                        ctx.stroke(line, with: .color(color.opacity(lit ? 0.9 : 0.12)), lineWidth: lit && focus != nil ? 1.4 : 0.8)
                    }
                    for n in nodes.values {
                        let on = focus == nil || linked.contains(n.id)
                        ctx.fill(Path(n.rect), with: .color((n.category?.color ?? Theme.ink).opacity(on ? 1 : 0.2)))
                    }
                }
                .frame(width: plot.width, height: plot.height)
                // Labels (right of each node; sites column labelled on the far right).
                ForEach(Array(nodes.values), id: \.id) { n in
                    let on = focus == nil || linked.contains(n.id)
                    HStack(spacing: 6) {
                        Text(n.column == 0 ? n.label.uppercased() : n.label)
                            .font(n.column == 0 ? Theme.label(10) : .system(size: 11.5, weight: n.id == focus ? .semibold : .regular))
                            .lineLimit(1)
                        Text(DurationText.short(n.seconds)).font(Theme.label(9)).foregroundStyle(.secondary)
                    }
                    .opacity(on ? 1 : 0.3)
                    .fixedSize()
                    .position(x: n.rect.maxX + 8, y: n.rect.midY)
                    .offset(x: labelWidthGuess(n) / 2)
                    .onHover { inside in hover = inside ? n.id : (hover == n.id ? nil : hover) }
                    .onTapGesture { if n.column > 0, !n.label.hasPrefix("Other") { selected = n.label } }
                }
            }
        }
    }

    private func labelWidthGuess(_ n: Node) -> CGFloat { CGFloat(min(26, n.label.count + 7)) * 6.6 }
}

// MARK: - Inspector

private struct InspectorCard: View {
    var e: EngineData
    @EnvironmentObject var model: AppModel

    var body: some View {
        let key = model.inspected ?? e.objects.first?.key
        Card {
            SectionHeader(number: "03", title: "Inspector", note: key.map { _ in "click anything in the flow" })
            if let key, let o = e.object(key) {
                HStack(alignment: .firstTextBaseline) {
                    Text(o.key).font(.system(size: 20, weight: .semibold)).lineLimit(1)
                    Text(o.kind == .site ? "SITE · \(o.app.uppercased())" : "APP").font(Theme.label(9)).foregroundStyle(.secondary)
                    Spacer()
                    CategoryPill(category: o.category)
                }
                HStack(spacing: 18) {
                    figure("TOTAL", DurationText.short(o.seconds))
                    figure("PER_DAY", DurationText.short(o.seconds / Double(max(1, e.days))))
                    figure("VISITS", "\(o.visits)")
                    figure("AVG_VISIT", DurationText.short(o.averageVisit))
                }
                HStack(alignment: .top, spacing: 18) {
                    links("BEFORE", e.incoming(key).prefix(5).map { ($0.from, $0.count, e.object($0.from)?.category ?? .neutral) })
                    links("AFTER", e.outgoing(key).prefix(5).map { ($0.to, $0.count, $0.toCategory) })
                }
                let hits = e.interruptions.filter { $0.topInterrupter == key }
                if !hits.isEmpty {
                    Text("Interrupted \(hits.count) planned block\(hits.count == 1 ? "" : "s"): \(hits.prefix(3).map(\.title).joined(separator: ", "))")
                        .font(.callout).foregroundStyle(Theme.accent)
                }
            } else {
                Text("Click an app or site in the flow to see what leads to it and what it leads to.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Theme.label(9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .light)).monospacedDigit()
        }
    }

    private func links(_ title: String, _ rows: [(String, Int, ActivityCategory)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(Theme.label(9)).foregroundStyle(.secondary)
            if rows.isEmpty { Text("—").foregroundStyle(.secondary) }
            ForEach(rows, id: \.0) { k, n, c in
                Button { model.inspected = k } label: {
                    HStack(spacing: 6) {
                        Circle().fill(c.color).frame(width: 6, height: 6)
                        Text(k).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("×\(n)").font(Theme.label(9.5)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Interruptions

private struct InterruptionsCard: View {
    var e: EngineData
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            SectionHeader(number: "04", title: "Interrupted plans", note: "tasks · time blocks · focus")
            if e.interruptions.isEmpty {
                Text("Plan tasks or focus blocks and Vigil shows what got into them.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(e.interruptions.prefix(8)) { i in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(i.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        Text(i.kind.uppercased()).font(Theme.label(8.5)).foregroundStyle(.secondary)
                        Spacer()
                        Text(i.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())).font(Theme.label(9)).foregroundStyle(.secondary)
                    }
                    GeometryReader { g in
                        let share = i.distractingSeconds / max(1, i.trackedSeconds)
                        HStack(spacing: 1) {
                            Rectangle().fill(Theme.productive.opacity(0.8)).frame(width: g.size.width * (1 - share))
                            Rectangle().fill(Theme.distracting).frame(width: g.size.width * share)
                        }
                    }
                    .frame(height: 4)
                    Text(i.distractingSeconds < 60 ? "Clean: no distraction"
                         : "\(DurationText.short(i.distractingSeconds)) lost\(i.topInterrupter.map { ", mostly to \($0)" } ?? "")")
                        .font(.caption).foregroundStyle(i.distractingSeconds < 60 ? Color.secondary : Theme.accent)
                        .onTapGesture { if let t = i.topInterrupter { model.inspected = t } }
                }
                .padding(.vertical, 3)
            }
        }
    }
}
