import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VigilCore

enum Theme {
    static let accent = Color(red: 0.25, green: 0.71, blue: 0.55)
    static let productive = Color(red: 0.25, green: 0.71, blue: 0.55)
    static let neutral = Color(red: 0.52, green: 0.58, blue: 0.68)
    static let distracting = Color(red: 0.93, green: 0.45, blue: 0.38)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color.primary.opacity(0.08)
}

extension ActivityCategory {
    var color: Color {
        switch self {
        case .productive: return Theme.productive
        case .neutral: return Theme.neutral
        case .distracting: return Theme.distracting
        }
    }

    var symbol: String {
        switch self {
        case .productive: return "bolt.fill"
        case .neutral: return "circle.fill"
        case .distracting: return "flame.fill"
        }
    }
}

struct Card<Content: View>: View {
    var title: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || trailing != nil {
                HStack {
                    if let title {
                        Text(title.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let trailing { trailing }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
    }
}

struct StatTile: View {
    var label: String
    var value: String
    var tint: Color = .primary
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(footnote ?? " ").font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }
}

struct ScoreRing: View {
    var score: Int
    var size: CGFloat = 64
    var lineWidth: CGFloat = 7

    private var color: Color {
        score >= 65 ? Theme.productive : score >= 40 ? Theme.neutral : Theme.distracting
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(100, max(0, score))) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)")
                .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: size, height: size)
    }
}

/// Horizontal productive / neutral / distracting proportion bar.
struct CategoryBar: View {
    var productive: Double
    var neutral: Double
    var distracting: Double
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let total = max(1, productive + neutral + distracting)
            HStack(spacing: 2) {
                if productive > 0 {
                    Capsule().fill(Theme.productive).frame(width: max(3, geo.size.width * productive / total))
                }
                if neutral > 0 {
                    Capsule().fill(Theme.neutral).frame(width: max(3, geo.size.width * neutral / total))
                }
                if distracting > 0 {
                    Capsule().fill(Theme.distracting).frame(width: max(3, geo.size.width * distracting / total))
                }
                if productive + neutral + distracting == 0 {
                    Capsule().fill(Color.primary.opacity(0.08))
                }
            }
        }
        .frame(height: height)
    }
}

struct CategoryPill: View {
    var category: ActivityCategory

    var body: some View {
        Text(category.label)
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(category.color.opacity(0.16)))
            .foregroundStyle(category.color)
    }
}

struct AppIcon: View {
    var image: NSImage?
    var fallbackSymbol: String = "app.dashed"
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else if fallbackSymbol == "app.dashed" {
                Image(nsImage: AppNames.genericAppIcon).resizable().interpolation(.high)
            } else {
                Image(systemName: fallbackSymbol)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.15)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// A row in a "top apps / top websites" list, with a context menu to recategorise it.
struct UsageRow: View {
    @EnvironmentObject var model: AppModel
    var item: UsageItem
    var kind: TargetKind
    var maxSeconds: Double

    var body: some View {
        HStack(spacing: 10) {
            if kind == .app {
                AppIcon(image: model.icon(bundleID: item.detail), size: 20)
            } else {
                AppIcon(image: nil, fallbackSymbol: "globe", size: 20)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(DurationText.short(item.seconds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 13))
                GeometryReader { geo in
                    Capsule()
                        .fill(item.category.color.opacity(0.85))
                        .frame(width: max(3, geo.size.width * item.seconds / max(1, maxSeconds)))
                }
                .frame(height: 4)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .contextMenu {
            Section("Categorise \(item.name) as") {
                ForEach(ActivityCategory.allCases) { c in
                    Button {
                        model.setCategory(kind: kind, pattern: kind == .app ? (item.detail ?? item.name) : item.name, category: c)
                    } label: {
                        Label(c.label, systemImage: item.category == c ? "checkmark" : c.symbol)
                    }
                }
            }
            Divider()
            Button("Add to blocklist") {
                model.addBlock(kind: kind, pattern: kind == .app ? (item.detail ?? item.name) : item.name)
            }
            Menu("Set daily limit") {
                ForEach([15, 30, 60, 120], id: \.self) { m in
                    Button("\(m) minutes") {
                        model.setLimit(kind: kind, pattern: kind == .app ? (item.detail ?? item.name) : item.name, minutes: m)
                    }
                }
            }
        }
    }
}

struct EmptyHint: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

extension View {
    func pageHeader(_ title: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 26, weight: .bold, design: .rounded))
                if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
            }
            self
        }
    }
}

/// Human-friendly app names for bundle IDs, whether or not the app is installed.
enum AppNames {
    static let genericAppIcon: NSImage = NSWorkspace.shared.icon(for: .applicationBundle)

    private static let known: [String: String] = [
        "com.apple.dt.Xcode": "Xcode", "com.microsoft.VSCode": "Visual Studio Code",
        "com.todesktop.230313mzl4w4u92": "Cursor", "dev.zed.Zed": "Zed", "com.apple.Terminal": "Terminal",
        "com.googlecode.iterm2": "iTerm", "dev.warp.Warp-Stable": "Warp", "com.mitchellh.ghostty": "Ghostty",
        "com.jetbrains.pycharm": "PyCharm", "com.jetbrains.intellij": "IntelliJ IDEA", "com.sublimetext.4": "Sublime Text",
        "com.anthropic.claudefordesktop": "Claude", "md.obsidian": "Obsidian", "notion.id": "Notion",
        "com.apple.iWork.Pages": "Pages", "com.apple.iWork.Numbers": "Numbers", "com.apple.iWork.Keynote": "Keynote",
        "com.microsoft.Word": "Word", "com.microsoft.Excel": "Excel", "com.microsoft.Powerpoint": "PowerPoint",
        "com.apple.Preview": "Preview", "com.apple.Notes": "Notes", "com.mathworks.matlab": "MATLAB",
        "org.R-project.R": "R", "com.postmanlabs.mac": "Postman", "com.docker.docker": "Docker",
        "com.figma.Desktop": "Figma", "com.hnc.Discord": "Discord", "com.valvesoftware.steam": "Steam",
        "com.apple.TV": "TV", "com.netflix.Netflix": "Netflix", "com.apple.Arcade": "Arcade",
        "com.facebook.archon": "Messenger", "com.apple.MobileSMS": "Messages", "com.apple.Music": "Music",
        "com.apple.Safari": "Safari", "com.google.Chrome": "Google Chrome", "company.thebrowser.Browser": "Arc",
        "com.brave.Browser": "Brave", "com.microsoft.edgemac": "Microsoft Edge", "org.mozilla.firefox": "Firefox",
    ]

    static func displayName(for pattern: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: pattern) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        if let name = known[pattern] { return name }
        guard pattern.contains("."), !pattern.contains(" ") else { return pattern }
        let last = pattern.split(separator: ".").last.map(String.init) ?? pattern
        return last.prefix(1).uppercased() + last.dropFirst()
    }
}

/// A progress bar that keeps its colour in inactive windows (unlike ProgressView).
struct MeterBar: View {
    var value: Double
    var tint: Color = Theme.accent
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(tint).frame(width: max(height, geo.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: height)
    }
}
