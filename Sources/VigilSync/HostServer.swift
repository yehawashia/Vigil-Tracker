import CryptoKit
import Foundation
import Network
import VigilCore

/// Per-device sync keys on the Mac: one JSON file, 0600, in the 0700 Vigil folder.
/// (Same protection as the activity database itself. Ad-hoc-signed builds can't use the
/// data-protection Keychain without prompting after every rebuild, so keys live beside the data.)
public final class DeviceKeyFile {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    public func all() -> [String: Data] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict.compactMapValues { Data(base64Encoded: $0) }.filter { $0.value.count == 32 }
    }

    public func set(_ key: Data?, for id: String) {
        var keys = all()
        lock.lock(); defer { lock.unlock() }
        keys[id] = key
        let encoded = keys.mapValues { $0.base64EncodedString() }
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum PairingMode: String { case qr, pin }

public enum PairingEvent: Equatable {
    case open(mode: PairingMode, qrURL: String?, expires: Date)
    /// PIN mode: show this code and ask "Does your device show the same code?"
    case confirm(code: String, deviceName: String)
    case paired(PairedDevice)
    case failed(String)
    case closed
}

/// The Mac side of pairing and sync. Owns its own SQLite connection and a private queue;
/// events are delivered on the main queue.
public final class HostServer {
    public let hostID: String
    public let hostName: String
    public var onPairingEvent: ((PairingEvent) -> Void)?
    /// Called on the main queue when devices are added, revoked or seen.
    public var onDevicesChanged: (() -> Void)?

    private let store: VigilStore
    private let keys: DeviceKeyFile
    private let queue = DispatchQueue(label: "dev.vigil.host")
    private var syncListener: NWListener?
    private var window: PairingWindow?
    private var trendsCache: (TrendsData, Date)?
    private var engineCache: (EngineData, Date)?
    private(set) public var connectedDevices: Set<String> = []

    public init(hostID: String, hostName: String, storePath: String, keyFile: DeviceKeyFile) throws {
        self.hostID = hostID
        self.hostName = hostName
        self.store = try VigilStore(path: storePath)
        self.keys = keyFile
    }

    // MARK: Sync listener

    /// (Re)starts the sync listener with exactly the keys of current, non-revoked devices.
    /// With no paired devices nothing listens at all.
    public func restartSync() {
        queue.async { [self] in
            syncListener?.cancel()
            syncListener = nil
            let active = Set(store.devices().map(\.id))
            let current = keys.all().filter { active.contains($0.key) }
            guard !current.isEmpty, let listener = try? NWListener(using: Transport.syncServerParameters(keys: current)) else { return }
            listener.service = NWListener.Service(name: hostName, type: Transport.syncService,
                                                  txtRecord: NWTXTRecord(["id": hostID]))
            listener.newConnectionHandler = { [weak self] conn in self?.handleSync(conn, keys: current) }
            listener.start(queue: queue)
            syncListener = listener
        }
    }

    public func stop() {
        queue.async { [self] in
            syncListener?.cancel(); syncListener = nil
            window?.close(); window = nil
        }
    }

    /// Port of the sync listener (tests connect to it directly).
    public var syncPort: UInt16? { queue.sync { syncListener?.port?.rawValue } }

    public func revoke(deviceID: String) {
        queue.async { [self] in
            store.revokeDevice(id: deviceID)
            keys.set(nil, for: deviceID)
            connectedDevices.remove(deviceID)
            notifyDevicesChanged()
        }
        restartSync()   // drops the revoked key from TLS; its open session (if any) is cancelled with the old listener
    }

    private func notifyDevicesChanged() { DispatchQueue.main.async { self.onDevicesChanged?() } }
    private func emit(_ e: PairingEvent) { DispatchQueue.main.async { self.onPairingEvent?(e) } }

    private func handleSync(_ conn: NWConnection, keys: [String: Data]) {
        guard Transport.isLocal(conn.endpoint) else { conn.cancel(); return }
        let framed = FramedConnection(conn)
        Task {
            var deviceID: String?
            defer {
                framed.close()
                if let deviceID { queue.async { self.connectedDevices.remove(deviceID); self.notifyDevicesChanged() } }
            }
            do {
                try await framed.open()
                let nonce = Pairing.randomBytes(32)
                try await framed.send(HostReply.challenge(nonce))
                guard case let .hello(id, proof, name, _) = try await framed.receive(DeviceRequest.self),
                      let key = keys[id], SyncAuth.verify(proof, key: key, nonce: nonce, deviceID: id) else { return }
                deviceID = id
                queue.sync {
                    store.touchDevice(id: id, name: name)
                    connectedDevices.insert(id)
                }
                notifyDevicesChanged()
                try await framed.send(HostReply.ok)
                while true {
                    let request = try await framed.receive(DeviceRequest.self)
                    let reply = queue.sync { self.handle(request, from: id) }
                    try await framed.send(reply)
                }
            } catch {
                // Closed, timed out or malformed: just end the session.
            }
        }
    }

    /// Runs on `queue`. Every write is attributed to the device and validated by VigilCore.
    private func handle(_ request: DeviceRequest, from id: String) -> HostReply {
        guard store.devices().contains(where: { $0.id == id }) else { return .revoked }
        store.touchDevice(id: id)
        switch request {
        case .hello: return .error("Already said hello.")
        case .snapshot: return .snapshot(snapshot())
        case .pushUsage(let usage):
            store.recordDeviceUsage(deviceID: id, usage)
            return .ok
        case let .editTimetable(op, item):
            do { try store.applyTimetableChange(op, item: item, author: "device:\(id)"); return .snapshot(snapshot()) }
            catch { return .error("\(error)") }
        case let .decideProposal(proposal, approve):
            do {
                if approve { try store.approveProposal(id: proposal) } else { store.rejectProposal(id: proposal) }
                return .snapshot(snapshot())
            } catch { return .error("\(error)") }
        case .revert(let revision):
            do { try store.revert(revisionID: revision, author: "device:\(id)"); return .snapshot(snapshot()) }
            catch { return .error("\(error)") }
        case let .startFocus(minutes, locked, label):
            guard (1...480).contains(minutes) else { return .error("Minutes must be 1–480.") }
            do {
                _ = try store.startFocusSession(minutes: minutes, locked: locked, label: label.map { String($0.prefix(100)) },
                                                createdBy: "device")
                return .snapshot(snapshot())
            } catch { return .error("\(error)") }
        }
    }

    /// Runs on `queue`. Trends are cached for a minute (they're the expensive part).
    private func snapshot() -> HostSnapshot {
        let now = Date()
        if trendsCache == nil || now.timeIntervalSince(trendsCache!.1) > 60 { trendsCache = (store.trends(now: now), now) }
        if engineCache == nil || now.timeIntervalSince(engineCache!.1) > 60 {
            var e = store.engine(days: 14, now: now)
            e.objects = Array(e.objects.prefix(40)); e.flows = Array(e.flows.prefix(80))
            e.transitions = Array(e.transitions.prefix(80)); e.interruptions = Array(e.interruptions.prefix(20))
            engineCache = (e, now)
        }
        let from = Calendar.current.startOfDay(for: now).addingTimeInterval(-7 * 86400)
        return HostSnapshot(hostID: hostID, hostName: hostName, generatedAt: now,
                            today: store.summary(day: DayKey.string(for: now)), trends: trendsCache?.0,
                            timetable: store.timetable(from: from, to: from.addingTimeInterval(35 * 86400)),
                            proposals: store.pendingProposals(), history: store.timetableHistory(limit: 50),
                            devices: store.devices(), blockedDomains: store.blocklist().filter { $0.kind == .domain }.map(\.pattern),
                            focus: store.activeFocusSession(now: now), todos: store.todos(), engine: engineCache?.0)
    }

    // MARK: Pairing

    /// Opens a 2-minute pairing window. Only one pairing can succeed per window.
    public func openPairing(mode: PairingMode) {
        queue.async { [self] in
            window?.close()
            let w = PairingWindow(mode: mode, host: self)
            window = w
            w.start()
        }
    }

    public func closePairing() {
        queue.async { [self] in window?.close(); window = nil; emit(.closed) }
    }

    /// PIN mode: the user's answer to "do the codes match?"
    public func confirmPairing(_ matches: Bool) {
        queue.async { [self] in window?.decide(matches) }
    }

    /// Port of the open pairing listener (tests connect to it directly).
    public var pairingPort: UInt16? { queue.sync { window?.listener?.port?.rawValue } }

    fileprivate final class PairingWindow {
        let mode: PairingMode
        unowned let host: HostServer
        let key = Curve25519.KeyAgreement.PrivateKey()
        let secret = Pairing.randomBytes(32)
        let expires = Date().addingTimeInterval(Pairing.windowSeconds)
        var listener: NWListener?
        var busy = false
        var failures = 0
        var done = false
        var decision: CheckedContinuation<Bool, Never>?

        init(mode: PairingMode, host: HostServer) { self.mode = mode; self.host = host }

        func start() {
            guard let l = try? NWListener(using: Transport.pairingParameters()) else { host.emit(.failed("Couldn't open pairing.")); return }
            l.service = NWListener.Service(name: host.hostName, type: Transport.pairService, txtRecord: NWTXTRecord(["id": host.hostID]))
            l.stateUpdateHandler = { [weak self] state in
                guard let self, case .ready = state else { return }
                let address = LocalAddress.primaryIPv4().map { "\($0):\(l.port?.rawValue ?? 0)" }
                let qr = self.mode == .qr ? Pairing.QRPayload(hostID: self.host.hostID, hostName: self.host.hostName,
                                                               keyFingerprint: Pairing.fingerprint(self.key.publicKey.rawRepresentation),
                                                               secret: self.secret, address: address).url : nil
                self.host.emit(.open(mode: self.mode, qrURL: qr, expires: self.expires))
            }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.start(queue: host.queue)
            listener = l
            host.queue.asyncAfter(deadline: .now() + Pairing.windowSeconds) { [weak self] in
                guard let self, !self.done, self.host.window === self else { return }
                self.close(); self.host.window = nil
                self.host.emit(.failed("Pairing timed out. Open it again when your device is ready."))
            }
        }

        func close() {
            done = true
            listener?.cancel(); listener = nil
            decision?.resume(returning: false); decision = nil
        }

        func decide(_ ok: Bool) { decision?.resume(returning: ok); decision = nil }

        /// Runs on host.queue.
        private func accept(_ conn: NWConnection) {
            guard !done, !busy, Date() < expires, Transport.isLocal(conn.endpoint) else { conn.cancel(); return }
            busy = true
            let framed = FramedConnection(conn)
            Task { await self.run(framed) }
        }

        private func run(_ framed: FramedConnection) async {
            defer { framed.close(); host.queue.async { self.busy = false } }
            do {
                try await framed.open()
                guard case .hello(let device) = try await framed.receive(PairMessage.self),
                      device.role == "device", device.mode == mode.rawValue, device.ephemeralKey.count == 32 else {
                    try? await framed.send(PairMessage.refuse("Unexpected message.")); return fail()
                }
                let hostHello = Pairing.Hello(role: "host", id: host.hostID, name: host.hostName, model: LocalAddress.model,
                                              platform: "macOS", ephemeralKey: key.publicKey.rawRepresentation, mode: mode.rawValue)
                try await framed.send(PairMessage.hello(hostHello))
                let keys = try Pairing.keys(mine: key, host: hostHello, device: device)

                switch mode {
                case .qr:
                    guard case .proof(let p) = try await framed.receive(PairMessage.self),
                          Pairing.verify(proof: p, secret: secret, transcript: keys.transcript) else {
                        try? await framed.send(PairMessage.refuse("That QR code isn't valid any more."))
                        return fail()
                    }
                case .pin:
                    host.emit(.confirm(code: keys.code, deviceName: device.name))
                    let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                        host.queue.async {
                            self.decision = c
                            self.host.queue.asyncAfter(deadline: .now() + 90) { self.decide(false) }
                        }
                    }
                    guard ok else { try? await framed.send(PairMessage.refuse("The codes weren't confirmed on the Mac.")); return fail() }
                }

                let deviceID = Pairing.newID()
                let deviceKey = Pairing.randomBytes(32)
                let paired = PairedDevice(id: deviceID, name: device.name, model: device.model, platform: device.platform,
                                          pairedAt: Date(), lastSeen: Date(), revoked: false)
                try host.queue.sync {
                    host.keys.set(deviceKey, for: deviceID)
                    try host.store.addDevice(paired)
                }
                let welcome = Pairing.Welcome(deviceID: deviceID, deviceKey: deviceKey, hostID: host.hostID, hostName: host.hostName)
                try await framed.send(PairMessage.welcome(try Pairing.seal(welcome, keys: keys)))
                host.queue.async {
                    self.close(); self.host.window = nil
                    self.host.emit(.paired(paired))
                    self.host.notifyDevicesChanged()
                }
                host.restartSync()
            } catch {
                fail()
            }
        }

        private func fail() {
            host.queue.async {
                self.failures += 1
                if self.failures >= 5 {
                    self.close(); self.host.window = nil
                    self.host.emit(.failed("Too many failed attempts. Pairing was closed."))
                }
            }
        }
    }
}

/// Small helpers for the pairing screen.
public enum LocalAddress {
    /// First private IPv4 address on an active interface (for the QR code's address hint).
    public static func primaryIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if Transport.isLocal(.hostPort(host: NWEndpoint.Host(ip), port: 1)) && !ip.hasPrefix("169.254") { return ip }
        }
        return nil
    }

    public static var model: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
