import CoreGraphics
import Foundation

/// Geometry for the Engine's flow diagram (category → app → site), computed once per data and size.
///
/// - Every node gets at least `minRow` points, so labels never overlap; the rest of the height is
///   shared in proportion to time.
/// - Apps are placed next to the categories they draw from and sites next to the apps they come
///   from (barycentre ordering), and each node's bands leave and arrive in the order of the nodes
///   at their other end. Together that removes most crossings.
public struct FlowLayout: Equatable {
    public struct Node: Equatable, Identifiable {
        public var id: String           // "c:productive", "a:Safari", "s:youtube.com"
        public var label: String
        public var column: Int          // 0 categories, 1 apps, 2 sites
        public var seconds: Double
        public var category: ActivityCategory   // dominant category (colour)
        public var rect: CGRect
        /// The object key the inspector understands (nil for categories and "Other").
        public var objectKey: String?
    }

    public struct Band: Equatable, Identifiable {
        public var from: String, to: String
        public var seconds: Double
        public var category: ActivityCategory
        public var x0: CGFloat, y0: CGFloat, h0: CGFloat   // at the source node
        public var x1: CGFloat, y1: CGFloat, h1: CGFloat   // at the target node
        public var id: String { from + "→" + to }
    }

    public var nodes: [Node]
    public var bands: [Band]
    public var size: CGSize
    public var total: Double

    public init(nodes: [Node], bands: [Band], size: CGSize, total: Double) {
        self.nodes = nodes; self.bands = bands; self.size = size; self.total = total
    }

    public func node(_ id: String) -> Node? { nodes.first { $0.id == id } }

    public static let otherApps = "a:Other apps", otherSites = "s:Other sites"

    public static func build(flows: [FlowLink], size: CGSize, leftMargin: CGFloat = 118, rightMargin: CGFloat = 230,
                             minRow: CGFloat = 15, gap: CGFloat = 4, nodeWidth: CGFloat = 10, minShare: Double = 0.01) -> FlowLayout {
        let flows = flows.filter { $0.seconds > 0 }
        let total = flows.reduce(0) { $0 + $1.seconds }
        guard total > 0, size.width > leftMargin + rightMargin + 60, size.height > 40 else {
            return FlowLayout(nodes: [], bands: [], size: size, total: 0)
        }

        // How many rows fit per column (the rest fold into "Other").
        let maxRows = max(3, Int((size.height + gap) / (minRow + gap)))
        func top(_ pairs: [String: Double]) -> Set<String> {
            Set(pairs.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(maxRows - 1).map(\.key))
        }
        var appTotals: [String: Double] = [:], siteTotals: [String: Double] = [:]
        for f in flows {
            appTotals[f.app, default: 0] += f.seconds
            if let s = f.site { siteTotals[s, default: 0] += f.seconds }
        }
        // Fold the long tail (and anything under ~1% of its column) into "Other" so the view stays readable.
        func keep(_ totals: [String: Double]) -> Set<String> {
            let colTotal = totals.values.reduce(0, +)
            let big = totals.filter { $0.value >= colTotal * minShare }
            let kept = big.count <= maxRows ? Set(big.keys) : top(big)
            // Don't fold a single item on its own into "Other".
            return totals.count - kept.count == 1 ? Set(totals.keys) : kept
        }
        let keepApps = keep(appTotals)
        let keepSites = keep(siteTotals)

        // Aggregate nodes and links.
        var seconds: [String: Double] = [:]
        var catSeconds: [String: [ActivityCategory: Double]] = [:]
        var links: [String: (from: String, to: String, s: Double, c: ActivityCategory)] = [:]
        func link(_ a: String, _ b: String, _ s: Double, _ c: ActivityCategory) {
            let k = a + "→" + b
            links[k] = (a, b, (links[k]?.s ?? 0) + s, links[k]?.c ?? c)
        }
        for f in flows {
            let c = "c:" + f.category.rawValue
            let a = keepApps.contains(f.app) ? "a:" + f.app : otherApps
            seconds[c, default: 0] += f.seconds
            seconds[a, default: 0] += f.seconds
            catSeconds[a, default: [:]][f.category, default: 0] += f.seconds
            link(c, a, f.seconds, f.category)
            if let site = f.site {
                let s = keepSites.contains(site) ? "s:" + site : otherSites
                seconds[s, default: 0] += f.seconds
                catSeconds[s, default: [:]][f.category, default: 0] += f.seconds
                link(a, s, f.seconds, f.category)
            }
        }
        for c in ActivityCategory.allCases { catSeconds["c:" + c.rawValue] = [c: 1] }
        let linkList = Array(links.values)

        // Column x positions.
        let x0 = leftMargin, x2 = size.width - rightMargin - nodeWidth
        let x1 = (x0 + x2) / 2
        let colX = [x0, x1, x2]

        // Stack a column: minRow each, remaining height in proportion to time.
        var rects: [String: CGRect] = [:]
        func stack(_ ids: [String], column: Int) {
            guard !ids.isEmpty else { return }
            let colTotal = ids.reduce(0) { $0 + (seconds[$1] ?? 0) }
            let spare = max(0, size.height - CGFloat(ids.count) * minRow - CGFloat(ids.count - 1) * gap)
            var y: CGFloat = 0
            for id in ids {
                let h = minRow + spare * CGFloat((seconds[id] ?? 0) / max(1, colTotal))
                rects[id] = CGRect(x: colX[column], y: y, width: nodeWidth, height: h)
                y += h + gap
            }
        }
        func centre(_ id: String) -> CGFloat { rects[id]?.midY ?? 0 }
        func barycentre(_ id: String, upstream: Bool) -> CGFloat {
            let rel = linkList.filter { upstream ? $0.to == id : $0.from == id }
            let w = rel.reduce(0) { $0 + $1.s }
            guard w > 0 else { return .greatestFiniteMagnitude }
            return rel.reduce(0) { $0 + centre(upstream ? $1.from : $1.to) * CGFloat($1.s) } / CGFloat(w)
        }
        func isOther(_ id: String) -> Bool { id == otherApps || id == otherSites }

        let cats = ActivityCategory.allCases.map { "c:" + $0.rawValue }.filter { (seconds[$0] ?? 0) > 0 }
        stack(cats, column: 0)
        let apps = seconds.keys.filter { $0.hasPrefix("a:") }.sorted {
            if isOther($0) != isOther($1) { return isOther($1) }     // "Other" last
            let b0 = barycentre($0, upstream: true), b1 = barycentre($1, upstream: true)
            return b0 != b1 ? b0 < b1 : (seconds[$0]! != seconds[$1]! ? seconds[$0]! > seconds[$1]! : $0 < $1)
        }
        stack(apps, column: 1)
        let sites = seconds.keys.filter { $0.hasPrefix("s:") }.sorted {
            if isOther($0) != isOther($1) { return isOther($1) }
            let b0 = barycentre($0, upstream: true), b1 = barycentre($1, upstream: true)
            return b0 != b1 ? b0 < b1 : (seconds[$0]! != seconds[$1]! ? seconds[$0]! > seconds[$1]! : $0 < $1)
        }
        stack(sites, column: 2)

        // Bands: leave each source in the order of their targets, arrive in the order of their sources.
        var outOffset: [String: CGFloat] = [:], inOffset: [String: CGFloat] = [:]
        var outEdge: [String: (CGFloat, CGFloat)] = [:], inEdge: [String: (CGFloat, CGFloat)] = [:]
        for (src, group) in Dictionary(grouping: linkList, by: \.from) {
            guard let r = rects[src] else { continue }
            for l in group.sorted(by: { centre($0.to) < centre($1.to) }) {
                let h = r.height * CGFloat(l.s / max(1, seconds[src] ?? 1))
                outEdge[l.from + "→" + l.to] = (r.minY + (outOffset[src] ?? 0), h)
                outOffset[src, default: 0] += h
            }
        }
        for (dst, group) in Dictionary(grouping: linkList, by: \.to) {
            guard let r = rects[dst] else { continue }
            for l in group.sorted(by: { centre($0.from) < centre($1.from) }) {
                let h = r.height * CGFloat(l.s / max(1, seconds[dst] ?? 1))
                inEdge[l.from + "→" + l.to] = (r.minY + (inOffset[dst] ?? 0), h)
                inOffset[dst, default: 0] += h
            }
        }
        let bands: [Band] = linkList.compactMap { l in
            let k = l.from + "→" + l.to
            guard let a = rects[l.from], let b = rects[l.to], let o = outEdge[k], let i = inEdge[k] else { return nil }
            return Band(from: l.from, to: l.to, seconds: l.s, category: l.c, x0: a.maxX, y0: o.0, h0: o.1, x1: b.minX, y1: i.0, h1: i.1)
        }.sorted { $0.seconds > $1.seconds }

        let nodes: [Node] = (cats + apps + sites).compactMap { id in
            guard let r = rects[id] else { return nil }
            let column = id.hasPrefix("c:") ? 0 : id.hasPrefix("a:") ? 1 : 2
            let name = String(id.dropFirst(2))
            let dominant = catSeconds[id]?.max { $0.value < $1.value }?.key ?? .neutral
            return Node(id: id, label: column == 0 ? (ActivityCategory(rawValue: name)?.label ?? name) : name,
                        column: column, seconds: seconds[id] ?? 0,
                        category: column == 0 ? (ActivityCategory(rawValue: name) ?? .neutral) : dominant,
                        rect: r, objectKey: column == 0 || isOther(id) ? nil : name)
        }
        return FlowLayout(nodes: nodes, bands: bands, size: size, total: total)
    }

    /// Node whose row (bar plus its label area) contains `p`.
    public func node(at p: CGPoint) -> Node? {
        nodes.first { n in
            let row = CGRect(x: n.column == 0 ? 0 : n.rect.minX - 4, y: n.rect.minY - 1,
                             width: n.column == 0 ? n.rect.maxX + 4 : (n.column == 1 ? 170 : size.width - n.rect.minX),
                             height: n.rect.height + 2)
            return row.contains(p)
        }
    }

    /// Ids of everything directly linked to `id` (including itself).
    public func neighbourhood(of id: String) -> Set<String> {
        var s: Set<String> = [id]
        for b in bands where b.from == id || b.to == id { s.insert(b.from); s.insert(b.to) }
        return s
    }
}
