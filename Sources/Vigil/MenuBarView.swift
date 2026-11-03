import AppKit
import SwiftUI
import VigilCore

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @State private var lockNext = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            currentActivity
            focusSection
            topToday
            footer
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { model.refreshSummary(force: true) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ScoreRing(score: model.today.score, size: 46, lineWidth: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text("Today").font(.system(size: 15, weight: .semibold))
                Text(model.today.activeSeconds > 60
                     ? "\(DurationText.short(model.today.activeSeconds)) active · \(Int((model.today.productiveSeconds / model.today.activeSeconds * 100).rounded()))% productive"
                     : "Nothing tracked yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.blockingActive {
                Label("Blocking", systemImage: "hand.raised.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.distracting)
            }
        }
    }

    @ViewBuilder
    private var currentActivity: some View {
        VStack(alignment: .leading, spacing: 8) {
            CategoryBar(productive: model.today.productiveSeconds, neutral: model.today.neutralSeconds,
                        distracting: model.today.distractingSeconds, height: 6)
            HStack(spacing: 10) {
                if let c = model.current {
                    AppIcon(image: model.icon(bundleID: c.bundleID), size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.domain ?? c.appName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(c.windowTitle ?? c.appName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    CategoryPill(category: c.category)
                } else {
                    Image(systemName: model.trackingPaused ? "pause.circle" : "moon.zzz")
                        .foregroundStyle(.secondary)
                    Text(model.trackingPaused ? "Tracking paused" : model.isIdle ? "Idle, not counting" : "Waiting for activity…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private var focusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let focus = model.focus {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(focus.label ?? "Focus session").font(.system(size: 13, weight: .semibold))
                        Text(focus.locked ? "Locked until \(focus.end.formatted(date: .omitted, time: .shortened))"
                                          : "Blocklist active until \(focus.end.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(DurationText.clock(focus.end.timeIntervalSince(context.date)))
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                }
                MeterBar(value: Date().timeIntervalSince(focus.start) / max(1, focus.end.timeIntervalSince(focus.start)))
                if !focus.locked {
                    Button("End session early") { model.stopFocus() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            } else {
                HStack {
                    Text("Start a focus session").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Toggle(isOn: $lockNext) {
                        Label("Lock", systemImage: "lock")
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Locked sessions can't be stopped or quit until they end")
                }
                HStack(spacing: 8) {
                    ForEach([25, 50, 90], id: \.self) { minutes in
                        Button {
                            model.startFocus(minutes: minutes, locked: lockNext, label: nil)
                        } label: {
                            Text("\(minutes)m").frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    @ViewBuilder
    private var topToday: some View {
        let items = Array((model.today.topDomains + model.today.topApps)
            .sorted { $0.seconds > $1.seconds }
            .prefix(4))
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("TOP TODAY").font(.system(size: 10.5, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary)
                ForEach(items) { item in
                    HStack {
                        Circle().fill(item.category.color).frame(width: 7, height: 7)
                        Text(item.name).font(.system(size: 12.5)).lineLimit(1)
                        Spacer()
                        Text(DurationText.short(item.seconds)).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                model.openDashboard(.today)
            } label: {
                Label("Dashboard", systemImage: "rectangle.grid.2x2")
            }
            Spacer()
            Button {
                model.trackingPaused.toggle()
            } label: {
                Image(systemName: model.trackingPaused ? "play.fill" : "pause.fill")
            }
            .help(model.trackingPaused ? "Resume tracking" : "Pause tracking")
            Button {
                model.sendReportNow()
            } label: {
                Image(systemName: "text.badge.checkmark")
            }
            .help("Send a productivity update now")
            Button {
                model.quit()
            } label: {
                Image(systemName: "power")
            }
            .disabled(model.isLocked)
            .help(model.isLocked ? "Locked until the session ends" : model.runsAlways ? "Pause Vigil until next login" : "Quit Vigil")
        }
        .buttonStyle(.borderless)
    }
}
