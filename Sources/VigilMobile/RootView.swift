import SwiftUI
import VigilCore
import VigilSync

public enum MobileSection: String, CaseIterable, Identifiable {
    case today, trends, plan, focus, mac
    public var id: String { rawValue }
    var title: String { ["today": "Today", "trends": "Trends", "plan": "Plan", "focus": "Focus", "mac": "Mac"][rawValue]! }
    var symbol: String {
        ["today": "sun.max", "trends": "chart.xyaxis.line", "plan": "calendar", "focus": "timer", "mac": "laptopcomputer"][rawValue]!
    }
}

/// Day / Night / Match system, stored per device.
public enum MobileAppearance: String, CaseIterable, Identifiable {
    case system, day, night
    public var id: String { rawValue }
    var scheme: ColorScheme? { self == .day ? .light : self == .night ? .dark : nil }
    var title: String { self == .system ? "Match iOS" : self == .day ? "Day" : "Night" }
}

/// Entry point for the iPhone/iPad app. `qrScanner` is supplied by the iOS shell (camera).
public struct VigilRootView: View {
    @ObservedObject var state: DeviceState
    var qrScanner: ((@escaping (String) -> Void) -> AnyView)?
    @State private var section: MobileSection = .today
    /// A vigil://pair link opened from the Camera app (or anywhere). Never acted on without asking.
    @State private var pairLink: Pairing.QRPayload?
    @AppStorage("appearance") private var appearance: MobileAppearance = .system
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @Environment(\.scenePhase) private var phase

    public init(state: DeviceState, qrScanner: ((@escaping (String) -> Void) -> AnyView)? = nil) {
        self.state = state
        self.qrScanner = qrScanner
    }

    private var isWide: Bool {
        #if os(iOS)
        return sizeClass == .regular
        #else
        return true
        #endif
    }

    public var body: some View {
        Group {
            if state.pairing == nil {
                PairView(state: state, qrScanner: qrScanner)
            } else if isWide {
                NavigationSplitView {
                    List(MobileSection.allCases, selection: Binding(get: { section }, set: { if let s = $0 { section = s } })) { s in
                        Label(s.title, systemImage: s.symbol).tag(s)
                    }
                    .navigationTitle("Vigil")
                } detail: {
                    NavigationStack { screen(section) }
                }
            } else {
                TabView(selection: $section) {
                    ForEach(MobileSection.allCases) { s in
                        NavigationStack { screen(s) }
                            .tabItem { Label(s.title, systemImage: s.symbol) }
                            .tag(s)
                    }
                }
            }
        }
        .tint(MTheme.accent)
        .preferredColorScheme(appearance.scheme)
        .onChange(of: phase) { p in
            if p == .active, state.pairing != nil { state.startAutoSync() } else { state.stopAutoSync() }
        }
        .onAppear { if state.pairing != nil { state.startAutoSync() } }
        .onOpenURL { url in
            guard let payload = Pairing.QRPayload(url: url.absoluteString) else { return }
            if state.pairing != nil {
                state.message = "This device is already paired with \(state.hostName). Unpair it first (Mac tab)."
            } else {
                pairLink = payload
            }
        }
        .confirmationDialog("Pair with \(pairLink?.hostName ?? "this Mac")?", isPresented: Binding(get: { pairLink != nil }, set: { if !$0 { pairLink = nil } }),
                            titleVisibility: .visible) {
            Button("Pair") {
                if let link = pairLink { Task { await state.pair(qrText: link.url) } }
                pairLink = nil
            }
            Button("Cancel", role: .cancel) { pairLink = nil }
        } message: {
            Text("Only continue if this is your Mac and its screen is showing a Vigil pairing code right now.")
        }
        .alert(state.message ?? "", isPresented: Binding(get: { state.message != nil }, set: { if !$0 { state.message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func screen(_ s: MobileSection) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ConnectionBar(state: state)
                switch s {
                case .today: TodayScreen(state: state)
                case .trends: TrendsScreen(state: state)
                case .plan: PlanScreen(state: state)
                case .focus: FocusScreen(state: state)
                case .mac: MacScreen(state: state, appearance: $appearance)
                }
            }
            .padding(16)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(MTheme.paper.ignoresSafeArea())
        .navigationTitle(s.title)
        .refreshable { await state.sync() }
    }
}

/// "● Connected to Amazing's MacBook Pro · synced 2 min ago". Tap to sync now.
struct ConnectionBar: View {
    @ObservedObject var state: DeviceState

    var body: some View {
        Button { Task { await state.sync() } } label: {
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text(text.uppercased()).font(MTheme.label(9.5)).lineLimit(1)
                Spacer()
                if state.link == .connecting { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise").font(.caption) }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().strokeBorder(MTheme.hairline))
        }
        .buttonStyle(.plain)
    }

    private var dotColor: Color {
        switch state.link {
        case .connected: return MTheme.accent
        case .connecting: return MTheme.neutral
        default: return MTheme.distracting
        }
    }

    private var text: String {
        let synced = state.lastSync.map { " · synced " + $0.formatted(.relative(presentation: .named)) } ?? ""
        switch state.link {
        case .connected: return "Connected to \(state.hostName)\(synced)"
        case .connecting: return "Syncing with \(state.hostName)…"
        case .offline(let why): return why + synced
        case .unpaired: return "Not paired"
        }
    }
}

// MARK: - Pairing

struct PairView: View {
    @ObservedObject var state: DeviceState
    var qrScanner: ((@escaping (String) -> Void) -> AnyView)?
    @State private var scanning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Vigil").font(.system(size: 40, weight: .light, design: .rounded))
                Text("Pair this device with the Vigil app on your Mac. They talk only over your local network, encrypted, with a key no one else has.")
                    .foregroundStyle(.secondary)
                step("01", "On your Mac", "Open Vigil → Devices → Start pairing.")
                step("02", "Scan or use a PIN", "Scan the code on the Mac's screen, or choose PIN and compare codes.")
                step("03", "Done", "This device shows which Mac it's connected to. Remove it on the Mac any time.")

                if let code = state.pairingCode {
                    MCard("—", "Check the code") {
                        Text(code.prefix(3) + " " + code.suffix(3)).font(.system(size: 46, weight: .light, design: .monospaced))
                        Text("Your Mac should show the same code. Confirm it there.").foregroundStyle(.secondary)
                    }
                } else if state.busy {
                    HStack { ProgressView(); Text("Pairing…").foregroundStyle(.secondary) }
                } else {
                    VStack(spacing: 10) {
                        if qrScanner != nil {
                            Button { scanning = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity) }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                        }
                        Button { Task { await state.pairWithPIN() } } label: { Label("Pair with PIN", systemImage: "number").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered).controlSize(.large)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(MTheme.paper.ignoresSafeArea())
        .sheet(isPresented: $scanning) {
            if let qrScanner {
                qrScanner { text in
                    scanning = false
                    Task { await state.pair(qrText: text) }
                }
            }
        }
    }

    private func step(_ n: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(n).font(MTheme.label(11)).foregroundStyle(MTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased()).font(MTheme.label(11)).tracking(1)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Mac (host, devices, appearance)

struct MacScreen: View {
    @ObservedObject var state: DeviceState
    @Binding var appearance: MobileAppearance
    @State private var confirmUnpair = false

    var body: some View {
        MCard("01", "Host", note: "local network only") {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer").font(.system(size: 30, weight: .light))
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.hostName).font(.headline)
                    if let p = state.pairing {
                        Text("Paired \(p.pairedAt.formatted(date: .abbreviated, time: .omitted)) · ID \(String(p.hostID.prefix(8)))")
                            .font(MTheme.label(9.5)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        if let devices = state.snapshot?.devices, !devices.isEmpty {
            MCard("02", "Devices on this Mac") {
                ForEach(devices) { d in
                    HStack {
                        Image(systemName: d.platform == "iPadOS" ? "ipad" : "iphone")
                        Text(d.name)
                        if d.id == state.pairing?.deviceID { Text("THIS DEVICE").font(MTheme.label(8.5)).foregroundStyle(MTheme.accent) }
                        Spacer()
                        Text(d.lastSeen.map { $0.formatted(.relative(presentation: .named)) } ?? "—").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        MCard("03", "Look") {
            Picker("Look", selection: $appearance) {
                ForEach(MobileAppearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        if let extra = state.services.settingsView() { extra }
        MCard("04", "Blocking on this device") {
            Text(state.services.canBlock
                 ? "Focus sessions and time blocks from your Mac also shield distracting apps and sites here."
                 : "Screen Time blocking needs Apple's Family Controls permission (paid Apple Developer account). Everything else works without it.")
                .font(.callout).foregroundStyle(.secondary)
        }
        Button(role: .destructive) { confirmUnpair = true } label: { Text("Unpair from \(state.hostName)").frame(maxWidth: .infinity) }
            .buttonStyle(.bordered)
            .confirmationDialog("Unpair from \(state.hostName)?", isPresented: $confirmUnpair) {
                Button("Unpair", role: .destructive) { state.unpair() }
            } message: { Text("The key is deleted from this device. Remove it on the Mac too.") }
    }
}
