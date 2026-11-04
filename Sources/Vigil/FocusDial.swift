import AppKit
import SwiftUI
import VigilCore

/// Ring of tick marks shared by the setting dial and the running countdown.
/// Drawn with Canvas: one draw call, no per-tick views, so dragging stays at display refresh rate.
private struct DialTicks: View {
    var fraction: Double          // 0…1 of the ring that is lit
    var tint: Color
    var count = 60

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let lit = Int((fraction * Double(count)).rounded())
            for i in 0..<count {
                let angle = Double(i) / Double(count) * 2 * .pi - .pi / 2
                let isLit = i < lit
                let isHead = lit > 0 && i == lit - 1
                let major = i % 5 == 0
                let length: CGFloat = isHead ? r * 0.2 : (isLit ? r * 0.13 : (major ? r * 0.09 : r * 0.06))
                let outer = r - 2
                let inner = outer - length
                var path = Path()
                path.move(to: CGPoint(x: center.x + CGFloat(cos(angle)) * inner, y: center.y + CGFloat(sin(angle)) * inner))
                path.addLine(to: CGPoint(x: center.x + CGFloat(cos(angle)) * outer, y: center.y + CGFloat(sin(angle)) * outer))
                let color: Color = isHead ? tint : (isLit ? Color.primary.opacity(0.85) : Color.primary.opacity(major ? 0.28 : 0.16))
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: isHead ? 3 : (isLit ? 2 : 1.2), lineCap: .round))
            }
        }
    }
}

/// Drag around the dial to choose how long to block distractions. Also works with the arrow keys,
/// VoiceOver (adjustable), and a Force Touch trackpad gives a click at every step.
struct FocusDial: View {
    @Binding var minutes: Int
    var size: CGFloat = 220
    var maxMinutes = 180
    var step = 5
    var tint: Color = Theme.accent

    @State private var dragging = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            DialTicks(fraction: Double(minutes) / Double(maxMinutes), tint: tint)
            Circle()
                .fill(Color.primary.opacity(dragging ? 0.06 : 0.035))
                .padding(size * 0.2)
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(minutes)")
                        .font(.system(size: size * 0.24, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("min")
                        .font(.system(size: size * 0.065, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text("until \(Date().addingTimeInterval(Double(minutes) * 60).formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: max(10, size * 0.05)))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    dragging = true
                    update(at: value.location)
                }
                .onEnded { _ in dragging = false }
        )
        .focusable()
        .focused($focused)
        .onMoveCommand { direction in
            switch direction {
            case .up, .right: set(minutes + step)
            case .down, .left: set(minutes - step)
            @unknown default: break
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Focus length")
        .accessibilityValue("\(minutes) minutes")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(minutes + step)
            case .decrement: set(minutes - step)
            @unknown default: break
            }
        }
        .help("Drag around the dial, or use the arrow keys")
    }

    private func update(at point: CGPoint) {
        let dx = point.x - size / 2
        let dy = point.y - size / 2
        guard dx * dx + dy * dy > 16 else { return }  // ignore the dead centre
        var angle = atan2(Double(dx), Double(-dy))      // 0 at 12 o'clock, clockwise
        if angle < 0 { angle += 2 * .pi }
        var value = Int((angle / (2 * .pi) * Double(maxMinutes) / Double(step)).rounded()) * step
        // Don't wrap past 12 o'clock: sweeping from the end to the start pins to the end, and vice versa.
        if minutes >= maxMinutes * 3 / 4 && value < maxMinutes / 4 { value = maxMinutes }
        if minutes <= maxMinutes / 4 && value > maxMinutes * 3 / 4 { value = step }
        set(value)
    }

    private func set(_ value: Int) {
        let clamped = min(maxMinutes, max(step, value))
        guard clamped != minutes else { return }
        withAnimation(.easeOut(duration: 0.12)) { minutes = clamped }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

/// The same dial during a session: the lit ticks drain as time runs out.
struct FocusDialRunning: View {
    var session: FocusSession
    var size: CGFloat = 220

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let total = max(1, session.end.timeIntervalSince(session.start))
            let remaining = max(0, session.end.timeIntervalSince(context.date))
            ZStack {
                DialTicks(fraction: remaining / total, tint: session.locked ? Theme.distracting : Theme.accent)
                Circle().fill(Color.primary.opacity(0.035)).padding(size * 0.2)
                VStack(spacing: 2) {
                    Text(DurationText.clock(remaining))
                        .font(.system(size: size * 0.17, weight: .light, design: .rounded))
                        .monospacedDigit()
                    HStack(spacing: 4) {
                        if session.locked { Image(systemName: "lock.fill") }
                        Text("remaining")
                    }
                    .font(.system(size: max(10, size * 0.05)))
                    .foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Focus session, \(Int(remaining / 60)) minutes remaining")
        }
    }
}
