import SwiftUI

// Technical-drawing framing used across Vigil (inspired by data-platform schematics):
// numbered sections, corner crosshairs, bracket rails, arrow labels. All drawn with
// hairlines so they read the same in Day (paper) and Night (plum) mode.

/// "01 — TITLE" header with an optional right-hand note.
struct SectionHeader: View {
    var number: String
    var title: String
    var note: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number).font(Theme.label(10)).foregroundStyle(Theme.accent)
            Rectangle().fill(Theme.hairline).frame(width: 18, height: 1).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
            Text(title.uppercased()).font(Theme.label(10.5)).tracking(1.4)
            Spacer()
            if let note { Text("→ " + note.uppercased()).font(Theme.label(9.5)).foregroundStyle(.secondary) }
        }
    }
}

/// Small "+" marks at each corner, like registration marks on a print.
struct CrosshairCorners: View {
    var inset: CGFloat = 8
    var size: CGFloat = 7

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            Path { p in
                for (x, y) in [(inset, inset), (w - inset, inset), (inset, h - inset), (w - inset, h - inset)] {
                    p.move(to: CGPoint(x: x - size / 2, y: y)); p.addLine(to: CGPoint(x: x + size / 2, y: y))
                    p.move(to: CGPoint(x: x, y: y - size / 2)); p.addLine(to: CGPoint(x: x, y: y + size / 2))
                }
            }
            .stroke(Theme.ink.opacity(0.45), lineWidth: 0.8)
        }
        .allowsHitTesting(false)
    }
}

/// Vertical bracket "[" with a number beside it, for grouping a stack of content.
struct BracketRail: View {
    var label: String
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(Theme.label(9.5)).foregroundStyle(.secondary)
            GeometryReader { geo in
                Path { p in
                    p.move(to: CGPoint(x: 6, y: 0)); p.addLine(to: CGPoint(x: 0, y: 0))
                    p.addLine(to: CGPoint(x: 0, y: geo.size.height)); p.addLine(to: CGPoint(x: 6, y: geo.size.height))
                }
                .stroke(Theme.hairline, lineWidth: 1)
            }
            .frame(width: 6)
        }
    }
}

extension View {
    /// Adds corner crosshairs on top of a card or chart.
    func crosshairs() -> some View { overlay(CrosshairCorners()) }
}
