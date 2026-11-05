import SwiftUI
import VigilCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Same Day (paper) / Night (plum) tokens as the Mac app, for iPhone and iPad.
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

    public static let paper = dynamic(0xEEECE8, 0x1E1620)
    public static let card = dynamic(0xF7F6F3, 0x281E2B)
    public static let ink = dynamic(0x161616, 0xE6DCEF)
    public static let hairline = dynamic(0x161616, 0xC9B8D9, dayAlpha: 0.09, nightAlpha: 0.12)
    public static let accent = dynamic(0xF26B2A, 0xF2B166)
    public static let onAccent = dynamic(0xFFFFFF, 0x1E1620)
    public static let productive = dynamic(0x1D1D1D, 0xF2B166)
    public static let neutral = dynamic(0xA29D95, 0x8C7A9E)
    public static let distracting = dynamic(0xF26B2A, 0xE8735A)
    public static let series2 = dynamic(0x8A867F, 0xB9A6CC)

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

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let number { Text(number).font(MTheme.label(10)).foregroundStyle(MTheme.accent) }
                    Text(title.uppercased()).font(MTheme.label(10.5)).tracking(1.2)
                    Spacer()
                    if let note { Text("→ " + note.uppercased()).font(MTheme.label(9)).foregroundStyle(.secondary) }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(MTheme.hairline))
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
