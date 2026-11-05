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
                FlowCard(e: e)
                HStack(alignment: .top, spacing: 16) {
                    InspectorCard(e: e).frame(maxWidth: .infinity)
                        .animation(.easeOut(duration: 0.18), value: model.inspected)
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
    @State private var hovered: String?

    var body: some View {
        Card {
            SectionHeader(number: "01", title: "Conclusions", note: "\(e.trackedDays) of \(e.days) days tracked · ranked by time involved")
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
                    .padding(.vertical, 3).padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.accent.opacity(hovered == c.id && c.subject != nil ? 0.08 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? c.id : (hovered == c.id ? nil : hovered) }
                .help(c.subject.map { "Show \($0) in the flow and inspector" } ?? "")
            }
        }
    }
}

// MARK: - Flow

/// Holds the last computed layout so hovering never recomputes geometry.
private final class FlowCache: ObservableObject {
    private var key: (Date, Int, CGSize)?
    private var value = FlowLayout(nodes: [], bands: [], size: .zero, total: 0)
    func layout(_ e: EngineData, _ size: CGSize) -> FlowLayout {
        if let k = key, k.0 == e.computedAt, k.1 == e.days, k.2 == size { return value }
        value = FlowLayout.build(flows: e.flows, size: size)
        key = (e.computedAt, e.days, size)
        return value
    }
}

private struct FlowCard: View {
    var e: EngineData
    @EnvironmentObject var model: AppModel
    @State private var hover: String?

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(number: "02", title: "Flow", note: nil)
                Spacer()
                Text(readout ?? "category → app → site · hover to trace · click to inspect")
                    .font(Theme.label(9.5)).foregroundStyle(readout == nil ? Color.secondary : Theme.accent).lineLimit(1)
                if model.inspected != nil {
                    Button { model.inspected = nil } label: { Label("Clear", systemImage: "xmark").font(Theme.label(9.5)) }
                        .buttonStyle(.borderless).help("Stop highlighting")
                }
            }
            FlowArcs(e: e, selected: $model.inspected, hover: $hover).frame(height: 460)
        }
        .crosshairs()
    }

    private var readout: String? {
        guard let id = hover else { return nil }
        let name = String(id.dropFirst(2))
        let secs = e.flows.reduce(0.0) { acc, f in
            switch id.prefix(2) {
            case "c:": return acc + (f.category.rawValue == name ? f.seconds : 0)
            case "a:": return acc + (f.app == name ? f.seconds : 0)
            default: return acc + (f.site == name ? f.seconds : 0)
            }
        }
        let total = max(1, e.flows.reduce(0) { $0 + $1.seconds })
        guard secs > 0 else { return name.uppercased() }
        return "\(name.uppercased()) · \(DurationText.short(secs)) · \(Int((secs / total * 100).rounded()))% OF TRACKED TIME"
    }
}

/// Category → app → site, drawn in one Canvas from a cached layout.
/// Hover or click anywhere on a row (bar or label); click it again, or on empty space, to clear.
struct FlowArcs: View {
    var e: EngineData
    @Binding var selected: String?
    @Binding var hover: String?
    @StateObject private var cache = FlowCache()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let layout = cache.layout(e, geo.size)
            let focusID = hover ?? selected.flatMap { key in layout.nodes.first { $0.objectKey == key }?.id }
            let lit = focusID.map { layout.neighbourhood(of: $0) }
            Canvas { ctx, _ in
                draw(layout, in: &ctx, focus: focusID, lit: lit)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let id = layout.node(at: p)?.id
                    if id != hover { hover = id }
                case .ended:
                    if hover != nil { hover = nil }
                }
            }
            .gesture(SpatialTapGesture().onEnded { v in
                guard let n = layout.node(at: v.location), let key = n.objectKey else { selected = nil; return }
                selected = selected == key ? nil : key
            })
            .overlay {
                if layout.nodes.isEmpty {
                    Text("Nothing tracked in this range yet.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func draw(_ l: FlowLayout, in ctx: inout GraphicsContext, focus: String?, lit: Set<String>?) {
        // Bands first, dimmed ones underneath highlighted ones.
        let ordered = l.bands.sorted { a, b in
            let la = focus == nil || a.from == focus || a.to == focus
            let lb = focus == nil || b.from == focus || b.to == focus
            return la == lb ? a.seconds > b.seconds : !la
        }
        for b in ordered {
            let on = focus == nil || b.from == focus || b.to == focus
            let mid = (b.x0 + b.x1) / 2
            var p = Path()
            p.move(to: CGPoint(x: b.x0, y: b.y0))
            p.addCurve(to: CGPoint(x: b.x1, y: b.y1), control1: CGPoint(x: mid, y: b.y0), control2: CGPoint(x: mid, y: b.y1))
            p.addLine(to: CGPoint(x: b.x1, y: b.y1 + b.h1))
            p.addCurve(to: CGPoint(x: b.x0, y: b.y0 + b.h0), control1: CGPoint(x: mid, y: b.y1 + b.h1), control2: CGPoint(x: mid, y: b.y0 + b.h0))
            p.closeSubpath()
            let color = b.category.color
            ctx.fill(p, with: .color(color.opacity(on ? (focus == nil ? 0.26 : 0.5) : 0.07)))
            if on {
                var line = Path()
                let c0 = b.y0 + b.h0 / 2, c1 = b.y1 + b.h1 / 2
                line.move(to: CGPoint(x: b.x0, y: c0))
                line.addCurve(to: CGPoint(x: b.x1, y: c1), control1: CGPoint(x: mid, y: c0), control2: CGPoint(x: mid, y: c1))
                ctx.stroke(line, with: .color(color.opacity(0.9)), lineWidth: focus == nil ? 0.7 : 1.2)
            }
        }
        // Nodes and labels.
        for n in l.nodes {
            let on = lit?.contains(n.id) ?? true
            let isFocus = n.id == focus
            ctx.fill(Path(n.rect), with: .color(n.category.color.opacity(on ? 1 : 0.25)))
            if isFocus {
                ctx.stroke(Path(n.rect.insetBy(dx: -2, dy: -1)), with: .color(Theme.accent), lineWidth: 1.5)
            }
            let name = Text(n.column == 0 ? n.label.uppercased() : n.label)
                .font(n.column == 0 ? Theme.label(10) : .system(size: 11.5, weight: isFocus ? .semibold : .regular))
                .foregroundColor(on ? Theme.ink : Theme.ink.opacity(0.3))
            let time = Text("  " + DurationText.short(n.seconds)).font(Theme.label(9)).foregroundColor(.secondary.opacity(on ? 1 : 0.4))
            let label = name + time
            switch n.column {
            case 0:
                ctx.draw(label, at: CGPoint(x: n.rect.minX - 8, y: n.rect.midY), anchor: .trailing)
            case 1:
                // App labels sit over the bands: give them a paper backing so they stay readable.
                let resolved = ctx.resolve(label)
                let sz = resolved.measure(in: CGSize(width: 220, height: 20))
                let box = CGRect(x: n.rect.maxX + 4, y: n.rect.midY - sz.height / 2 - 1, width: sz.width + 8, height: sz.height + 2)
                ctx.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(Theme.cardBackground.opacity(0.85)))
                ctx.draw(resolved, at: CGPoint(x: box.minX + 4, y: n.rect.midY), anchor: .leading)
            default:
                ctx.draw(label, at: CGPoint(x: n.rect.maxX + 8, y: n.rect.midY), anchor: .leading)
            }
        }
    }
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
                    figure("PER_DAY", DurationText.short(o.seconds / Double(max(1, e.trackedDays))))
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
