import Foundation
import Network
import SwiftUI
import VigilCore
import VigilSync

/// iOS-only capabilities the app shell plugs in (camera, Screen Time, Safari extension data).
/// Defaults do nothing, so the shared screens build and run anywhere.
public protocol PlatformServices: AnyObject {
    /// Usage measured on this device since the last sync (Safari domains, app groups, focus).
    func collectUsage() -> [DeviceUsage]
    /// Turn shields on/off for these domains (and the user's picked apps) until `until`.
    func applyBlocking(domains: [String], until: Date?, reason: String?)
    /// Whether Screen Time permission is available (paid developer account + user approval).
    var canBlock: Bool { get }
    var deviceName: String { get }
    var deviceModel: String { get }
    var platform: String { get }
    /// Declared here (not only in the extension) so the shell's version is the one called.
    func settingsView() -> AnyView?
}

public extension PlatformServices {
    /// Extra settings the shell shows on the Mac tab (e.g. Screen Time app groups). Nil by default.
    func settingsView() -> AnyView? { nil }
}

public final class NoPlatformServices: PlatformServices {
    public init() {}
    public func collectUsage() -> [DeviceUsage] { [] }
    public func applyBlocking(domains: [String], until: Date?, reason: String?) {}
    public var canBlock: Bool { false }
    public var deviceName: String { "This device" }
    public var deviceModel: String { "Unknown" }
    public var platform: String { "iOS" }
}

/// Everything the iPhone/iPad app knows, and the only thing that talks to the Mac.
@MainActor
public final class DeviceState: ObservableObject {
    public enum Link: Equatable { case unpaired, connecting, connected, offline(String) }

    @Published public private(set) var pairing: SecureStore.Pairing?
    @Published public private(set) var snapshot: HostSnapshot?
    @Published public private(set) var link: Link = .unpaired
    @Published public private(set) var lastSync: Date?
    @Published public var message: String?
    @Published public var pairingCode: String?
    @Published public var busy = false

    public let services: PlatformServices
    private let cacheURL: URL
    private var syncTask: Task<Void, Never>?

    public init(services: PlatformServices = NoPlatformServices()) {
        self.services = services
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Vigil", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheURL = dir.appendingPathComponent("snapshot.json")
        pairing = SecureStore.load()
        link = pairing == nil ? .unpaired : .offline("Not synced yet")
        if pairing != nil, let data = try? Data(contentsOf: cacheURL) {
            snapshot = try? SyncCoding.decoder.decode(HostSnapshot.self, from: data)
            lastSync = snapshot?.generatedAt
        }
    }

    public var hostName: String { pairing?.hostName ?? "your Mac" }

    // MARK: Pairing

    private var me: DeviceClient.Identity {
        DeviceClient.Identity(name: services.deviceName, model: services.deviceModel, platform: services.platform)
    }

    /// Pairs from a scanned QR code. Tries the address in the code first, then Bonjour.
    public func pair(qrText: String) async {
        guard let qr = Pairing.QRPayload(url: qrText) else { message = "That isn't a Vigil pairing code."; return }
        busy = true; defer { busy = false }
        var endpoints: [NWEndpoint] = []
        if let a = qr.address, let colon = a.lastIndex(of: ":"), let port = NWEndpoint.Port(String(a[a.index(after: colon)...])) {
            endpoints.append(.hostPort(host: NWEndpoint.Host(String(a[..<colon])), port: port))
        }
        if let found = await DeviceClient.discover(service: Transport.pairService, hostID: qr.hostID) { endpoints.append(found) }
        guard !endpoints.isEmpty else { message = "Couldn't find \(qr.hostName). Make sure both are on the same Wi-Fi."; return }
        var lastError: Error?
        for ep in endpoints {
            do { finish(try await DeviceClient.pair(endpoint: ep, me: me, qr: qr)); return } catch { lastError = error }
        }
        message = describe(lastError)
    }

    /// PIN pairing: finds a Mac with pairing open, shows the code, waits for you to confirm on the Mac.
    public func pairWithPIN() async {
        busy = true; defer { busy = false; pairingCode = nil }
        guard let ep = await DeviceClient.discover(service: Transport.pairService, hostID: nil, timeout: 8) else {
            message = "No Mac is ready to pair. On your Mac open Vigil → Devices → Start pairing (PIN)."
            return
        }
        do {
            let w = try await DeviceClient.pair(endpoint: ep, me: me, qr: nil) { code in
                Task { @MainActor in self.pairingCode = code }
            }
            finish(w)
        } catch { message = describe(error) }
    }

    private func finish(_ w: Pairing.Welcome) {
        let p = SecureStore.Pairing(hostID: w.hostID, hostName: w.hostName, deviceID: w.deviceID, key: w.deviceKey, pairedAt: Date())
        guard SecureStore.save(p) else { message = "Couldn't save the pairing to the Keychain."; return }
        pairing = p
        MHaptics.success()
        message = "Paired with \(w.hostName)."
        Task { await sync() }
    }

    public func unpair() {
        SecureStore.clear()
        try? FileManager.default.removeItem(at: cacheURL)
        pairing = nil; snapshot = nil; lastSync = nil; link = .unpaired
        services.applyBlocking(domains: [], until: nil, reason: nil)
    }

    private func describe(_ error: Error?) -> String {
        if let e = error as? DeviceClient.Failure { return e.description }
        if let e = error as? Pairing.Failure, e == .decryptFailed { return "The pairing was tampered with or interrupted. Try again." }
        return "Couldn't pair: \(error.map { "\($0)" } ?? "unknown error")."
    }

    // MARK: Sync

    /// One sync: push this device's usage, pull a fresh snapshot, apply blocking. Safe to call often.
    public func sync() async {
        _ = await request(nil)
    }

    /// Sends one request (or just syncs if nil) and refreshes the snapshot from the reply.
    @discardableResult
    public func request(_ r: DeviceRequest?) async -> Bool {
        guard let p = pairing else { return false }
        link = .connecting
        guard let ep = await DeviceClient.discover(service: Transport.syncService, hostID: p.hostID) else {
            link = .offline("\(p.hostName) isn't reachable. Same Wi-Fi?")
            return false
        }
        let session = DeviceClient.Session(endpoint: ep, deviceID: p.deviceID, key: p.key)
        defer { session.close() }
        do {
            try await session.connect(name: services.deviceName, appVersion: "1.0")
            let usage = services.collectUsage()
            if !usage.isEmpty { _ = try await session.send(.pushUsage(usage)) }
            var ok = true
            if let r {
                let reply = try await session.send(r)
                if case .error(let why) = reply { message = why; ok = false }
                if case .revoked = reply { unpair(); message = "This device was removed on the Mac."; return false }
            }
            if case .snapshot(let snap) = try await session.send(.snapshot) { store(snap) }
            link = .connected
            lastSync = Date()
            return ok
        } catch {
            link = .offline("Couldn't reach \(p.hostName).")
            return false
        }
    }

    private func store(_ snap: HostSnapshot) {
        snapshot = snap
        if let data = try? SyncCoding.encoder.encode(snap) {
            try? data.write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        // Enforce on this device what the Mac says is active (focus session or time block).
        let now = Date()
        let block = snap.timetable.first { $0.kind == .block && $0.isActive(at: now) }
        if let f = snap.focus, f.end > now {
            services.applyBlocking(domains: snap.blockedDomains, until: f.end, reason: f.label ?? "Focus session")
        } else if let b = block {
            services.applyBlocking(domains: snap.blockedDomains, until: b.end, reason: b.title)
        } else {
            services.applyBlocking(domains: [], until: nil, reason: nil)
        }
    }

    /// Re-syncs every 60 s while the app is open (no background polling).
    public func startAutoSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sync()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    public func stopAutoSync() { syncTask?.cancel(); syncTask = nil }
}
