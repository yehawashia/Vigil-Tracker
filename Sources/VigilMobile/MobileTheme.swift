import SwiftUI
import VigilCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Same Day (paper) / Night (black + orange HUD) tokens as the Mac app, for iPhone and iPad.
public enum MTheme {
    static func dynamic(_ day: UInt32, _ night: UInt32, dayAlpha: CGFloat = 1, nightAlpha: CGFloat = 1) -> Color {
        func rgb(_ h: UInt32, _ a: CGFloat) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
            (CGFloat((h >> 16) & 0xFF) / 255, CGFloat((h >> 8) & 0xFF) / 255, CGFloat(h & 0xFF) / 255, a)
        }
        #if canImport(UIKit)
        return Color(UIColor { t in
            let c = t.userInterfaceStyle == .dark ? rgb(night, nightAlpha) : rgb(day, dayAlpha)
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: c.3)
        })
        #else
        return Color(NSColor(name: nil) { a in
            let dark = a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = dark ? rgb(night, nightAlpha) : rgb(day, dayAlpha)
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
        })
        #endif
    }

    public static let paper = dynamic(0xEEECE8, 0x000000)
    public static let card = dynamic(0xF7F6F3, 0x0A0A0A)
    public static let ink = dynamic(0x161616, 0xEDEDED)
    public static let hairline = dynamic(0x161616, 0xFFFFFF, dayAlpha: 0.09, nightAlpha: 0.16)
    public static let accent = dynamic(0xF26B2A, 0xFF6B1F)
    public static let onAccent = dynamic(0xFFFFFF, 0x000000)
    public static let productive = dynamic(0x1D1D1D, 0xF2F2F2)
    public static let neutral = dynamic(0xA29D95, 0x6B6B6B)
    public static let distracting = dynamic(0xF26B2A, 0xFF6B1F)
    public static let series2 = dynamic(0x8A867F, 0x9C9C9C)

    public static func label(_ size: CGFloat = 10.5) -> Font { .system(size: size, weight: .medium, design: .monospaced) }

    public static func color(_ c: ActivityCategory) -> Color {
        switch c { case .productive: return productive; case .neutral: return neutral; case .distracting: return distracting }
    }
}

/// Card with a numbered schematic header, matching the Mac dashboard.
public struct MCard<Content: View>: View {
    var number: String?
    var title: String?
    var note: String?
    @ViewBuilder var content: Content

    public init(_ number: String? = nil, _ title: String? = nil, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.number = number; self.title = title; self.note = note; self.content = content()
    }

    @Environment(\.colorScheme) private var scheme

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let number { Text(number).font(MTheme.label(10)).foregroundStyle(MTheme.accent) }
                    Text(scheme == .dark ? title.uppercased().replacingOccurrences(of: " ", with: "_") : title.uppercased()).font(MTheme.label(10.5)).tracking(1.2)
                    Spacer()
                    if let note { Text("→ " + note.uppercased()).font(MTheme.label(9)).foregroundStyle(.secondary) }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: scheme == .dark ? 2 : 14, style: .continuous).fill(MTheme.card))
        .overlay(RoundedRectangle(cornerRadius: scheme == .dark ? 2 : 14, style: .continuous).strokeBorder(MTheme.hairline))
        .overlay { if scheme == .dark { MBrackets() } }
    }
}

/// HUD corner brackets for the black Night look.
struct MBrackets: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height, l: CGFloat = 9
            Path { p in
                p.move(to: CGPoint(x: 0, y: l)); p.addLine(to: .zero); p.addLine(to: CGPoint(x: l, y: 0))
                p.move(to: CGPoint(x: w - l, y: 0)); p.addLine(to: CGPoint(x: w, y: 0)); p.addLine(to: CGPoint(x: w, y: l))
                p.move(to: CGPoint(x: 0, y: h - l)); p.addLine(to: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: l, y: h))
                p.move(to: CGPoint(x: w - l, y: h)); p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: w, y: h - l))
            }
            .stroke(MTheme.ink.opacity(0.75), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }
}

public enum MHaptics {
    public static func tick() {
        #if canImport(UIKit) && !os(watchOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }
    public static func success() {
        #if canImport(UIKit) && !os(watchOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
}
