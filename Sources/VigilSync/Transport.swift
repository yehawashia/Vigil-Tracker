import Foundation
import Network
import Security

/// Network setup for Vigil. Local network only: no internet, no relays, no cellular.
public enum Transport {
    /// Bonjour type for paired-device sync (TLS-PSK).
    public static let syncService = "_vigil._tcp"
    /// Bonjour type for the pairing window (open for 2 minutes at a time).
    public static let pairService = "_vigilpair._tcp"

    private static func base(_ tcp: NWProtocolTCP.Options = NWProtocolTCP.Options(), tls: NWProtocolTLS.Options?) -> NWParameters {
        tcp.connectionTimeout = 8
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let p = NWParameters(tls: tls, tcp: tcp)
        p.prohibitedInterfaceTypes = [.cellular]   // never leave the local network
        p.includePeerToPeer = true                 // AWDL: works even without shared Wi-Fi when nearby
        return p
    }

    /// Plain TCP for pairing. The pairing protocol itself authenticates and encrypts the only secret it sends.
    public static func pairingParameters() -> NWParameters { base(tls: nil) }

    private static func pskOptions(_ configure: (sec_protocol_options_t) -> Void) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        configure(sec)
        return tls
    }

    private static func dispatchData(_ d: Data) -> __DispatchData {
        d.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
    }

    /// Device side: authenticate with this device's id and key.
    public static func syncClientParameters(deviceID: String, key: Data) -> NWParameters {
        base(tls: pskOptions { sec in
            sec_protocol_options_add_pre_shared_key(sec, dispatchData(key), dispatchData(Data(deviceID.utf8)))
        })
    }

    /// Host side: registers every paired device's key (identity = device id). The listener is recreated
    /// whenever a device is paired or revoked, so a revoked device's key no longer exists anywhere in it.
    /// Unknown identities fail the handshake and the connection never opens.
    public static func syncServerParameters(keys: [String: Data]) -> NWParameters {
        let queue = DispatchQueue(label: "dev.vigil.psk")
        return base(tls: pskOptions { sec in
            for (id, key) in keys {
                sec_protocol_options_add_pre_shared_key(sec, dispatchData(key), dispatchData(Data(id.utf8)))
            }
            if keys.isEmpty {
                // PSK mode needs at least one key; this random one is never shared with anyone.
                sec_protocol_options_add_pre_shared_key(sec, dispatchData(Pairing.randomBytes(32)), dispatchData(Pairing.randomBytes(16)))
            }
            // Picks which registered identity to use; nil (unknown device) aborts the handshake.
            sec_protocol_options_set_pre_shared_key_selection_block(sec, { _, identity, complete in
                guard let identity else { complete(nil); return }
                let id = String(decoding: Data(identity as DispatchData), as: UTF8.self)
                complete(keys[id] != nil ? identity : nil)
            }, queue)
        })
    }

    /// True for loopback, link-local and private (RFC 1918 / ULA) addresses. The host drops anything else.
    public static func isLocal(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return true } // Bonjour/service endpoints are local
        switch host {
        case .ipv4(let a):
            let b = [UInt8](a.rawValue)
            guard b.count == 4 else { return false }
            return b[0] == 10 || b[0] == 127 || (b[0] == 172 && (16...31).contains(b[1])) ||
                (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
        case .ipv6(let a):
            let b = [UInt8](a.rawValue)
            guard b.count == 16 else { return false }
            if a.isLoopback || a.isLinkLocal { return true }
            if (b[0] & 0xFE) == 0xFC { return true }                       // fc00::/7 unique local
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {  // IPv4-mapped
                return isLocal(.hostPort(host: .ipv4(IPv4Address(Data(b[12..<16]))!), port: 1))
            }
            return false
        case .name: return false
        @unknown default: return false
        }
    }
}

/// Length-prefixed JSON messages over an NWConnection, with async send/receive.
public final class FramedConnection {
    public let connection: NWConnection
    private let queue: DispatchQueue

    public init(_ connection: NWConnection, queue: DispatchQueue = DispatchQueue(label: "dev.vigil.conn")) {
        self.connection = connection
        self.queue = queue
    }

    /// Starts the connection and waits until it's ready (or fails, or times out).
    public func open(timeout: TimeInterval = 10) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { cont.resume() }
                case .failed(let e): once.run { cont.resume(throwing: e) }
                case .waiting(let e): once.run { cont.resume(throwing: e) }
                case .cancelled: once.run { cont.resume(throwing: SyncError.closed) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [connection] in
                once.run { connection.cancel(); cont.resume(throwing: SyncError.timeout) }
            }
        }
    }

    public func send<T: Encodable>(_ value: T) async throws {
        let data = try Frame.encode(value)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    public func receive<T: Decodable>(_ type: T.Type) async throws -> T {
        let header = try await read(4)
        guard let n = Frame.length(header) else { throw SyncError.tooLarge }
        let body = n == 0 ? Data() : try await read(n)
        return try SyncCoding.decoder.decode(T.self, from: body)
    }

    private func read(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, complete, error in
                if let error { cont.resume(throwing: error) }
                else if let data, data.count == count { cont.resume(returning: data) }
                else if complete { cont.resume(throwing: SyncError.closed) }
                else { cont.resume(throwing: SyncError.closed) }
            }
        }
    }

    public func close() { connection.cancel() }
}

/// Runs a block at most once (continuations must resume exactly once).
final class Once {
    private var done = false
    private let lock = NSLock()
    func run(_ block: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        block()
    }
}
