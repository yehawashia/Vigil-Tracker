import CoreGraphics
import Foundation
import Testing
@testable import VigilCore

struct FlowLayoutTests {
    func flows(sites: Int) -> [FlowLink] {
        var f = [FlowLink(category: .productive, app: "Xcode", site: nil, seconds: 7200),
                 FlowLink(category: .neutral, app: "Notes", site: nil, seconds: 900)]
        for i in 0..<sites {
            f.append(FlowLink(category: i % 3 == 0 ? .distracting : .productive, app: i % 2 == 0 ? "Safari" : "Chrome",
                              site: "site\(i).com", seconds: Double(3000 - i * 40)))
        }
        return f
    }

    @Test func labelsNeverOverlapAndFitHeight() {
        let size = CGSize(width: 1000, height: 460)
        let l = FlowLayout.build(flows: flows(sites: 60), size: size)
        for col in 0...2 {
            let rects = l.nodes.filter { $0.column == col }.map(\.rect).sorted { $0.minY < $1.minY }
            for (a, b) in zip(rects, rects.dropFirst()) { #expect(a.maxY <= b.minY + 0.5) }
            for r in rects { #expect(r.height >= 15); #expect(r.maxY <= size.height + 0.5) }
        }
    }

    @Test func foldsLongTailIntoOther() {
        let l = FlowLayout.build(flows: flows(sites: 60), size: CGSize(width: 1000, height: 460))
        #expect(l.node(FlowLayout.otherSites) != nil)
        #expect(l.nodes.filter { $0.column == 2 }.last?.id == FlowLayout.otherSites)
        // Time is conserved: every column sums to the total of what flows into it.
        let siteSum = l.nodes.filter { $0.column == 2 }.reduce(0) { $0 + $1.seconds }
        #expect(abs(siteSum - flows(sites: 60).compactMap { $0.site == nil ? nil : $0.seconds }.reduce(0, +)) < 0.5)
    }

    @Test func bandsLeaveInTargetOrder() {
        let l = FlowLayout.build(flows: flows(sites: 12), size: CGSize(width: 1000, height: 460))
        for (_, out) in Dictionary(grouping: l.bands, by: \.from) {
            let byStart = out.sorted { $0.y0 < $1.y0 }
            let targets = byStart.map { l.node($0.to)!.rect.midY }
            #expect(targets == targets.sorted())
        }
    }

    @Test func hitTestFindsRows() {
        let l = FlowLayout.build(flows: flows(sites: 5), size: CGSize(width: 1000, height: 460))
        let safari = l.node("a:Safari")!
        #expect(l.node(at: CGPoint(x: safari.rect.maxX + 40, y: safari.rect.midY))?.id == "a:Safari")
        #expect(l.node(at: CGPoint(x: 5, y: 5))?.column == 0)
        #expect(safari.objectKey == "Safari")
        #expect(l.node("c:productive")?.objectKey == nil)
    }

    @Test func emptyDataIsEmptyLayout() {
        #expect(FlowLayout.build(flows: [], size: CGSize(width: 900, height: 400)).nodes.isEmpty)
    }

    @Test func tinyItemsFoldIntoOther() {
        var f = flows(sites: 4)
        f.append(FlowLink(category: .neutral, app: "loginwindow", site: nil, seconds: 5))
        f.append(FlowLink(category: .neutral, app: "SecurityAgent", site: nil, seconds: 4))
        let l = FlowLayout.build(flows: f, size: CGSize(width: 1000, height: 460))
        #expect(l.node("a:loginwindow") == nil)
        #expect(l.node(FlowLayout.otherApps) != nil)
    }
}
