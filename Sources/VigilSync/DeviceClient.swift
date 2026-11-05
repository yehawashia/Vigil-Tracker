import CryptoKit
import Foundation
import Network

/// The iPhone/iPad side of pairing and sync. Also used by the Mac's end-to-end tests.
public enum DeviceClient {
    public struct Identity {
        public var name: String, model: String, platform: String
        public init(name: String, model: String, platform: String) { self.name = name; self.model = model; self.platform = platform }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case refused(String), wrongHost, protocolError

        public var description: String {
            switch self {
            case .refused(let why): return why
            case .wrongHost: return "Something other than your Mac answered. Pairing was stopped for safety."
            case .protocolError: return "The Mac sent something unexpected."
            }
        }
    }

    /// Pairs with a host. QR mode checks the host is the one on the screen; PIN mode calls `showCode`
    /// with the code to display, then waits up to 90 s for you to confirm on the Mac.
    public static func pair(endpoint: NWEndpoint, me: Identity, qr: Pairing.QRPayload?,
                            showCode: @escaping (String) -> Void = { _ in }) async throws -> Pairing.Welcome {
        let mode = qr == nil ? "pin" : "qr"
        let key = Curve25519.KeyAgreement.PrivateKey()
        let framed = FramedConnection(NWConnection(to: endpoint, using: Transport.pairingParameters()))
        defer { framed.close() }
        try await framed.open()
        let myHello = Pairing.Hello(role: "device", id: "", name: me.name, model: me.model, platform: me.platform,
                                    ephemeralKey: key.publicKey.rawRepresentation, mode: mode)
        try await framed.send(PairMessage.hello(myHello))
        let reply = try await framed.receive(PairMessage.self)
        if case .refuse(let why) = reply { throw Failure.refused(why) }
        guard case .hello(let host) = reply, host.role == "host", host.mode == mode else { throw Failure.protocolError }
        if let qr {
            guard host.id == qr.hostID, Pairing.fingerprint(host.ephemeralKey) == qr.keyFingerprint else { throw Failure.wrongHost }
        }
        let keys = try Pairing.keys(mine: key, host: host, device: myHello)
        if let qr {
            try await framed.send(PairMessage.proof(Pairing.proof(secret: qr.secret, transcript: keys.transcript)))
        } else {
            showCode(keys.code)
        }
        let final = try await framed.receive(PairMessage.self)
        switch final {
        case .welcome(let sealed):
            let w = try Pairing.open(sealed, keys: keys)
            guard w.hostID == host.id else { throw Failure.wrongHost }
            return w
        case .refuse(let why): throw Failure.refused(why)
        default: throw Failure.protocolError
        }
    }

    /// An authenticated sync session with the host.
    public final class Session {
        private let framed: FramedConnection
        private let deviceID: String
        private let key: Data

        public init(endpoint: NWEndpoint, deviceID: String, key: Data) {
            self.deviceID = deviceID
            self.key = key
            framed = FramedConnection(NWConnection(to: endpoint, using: Transport.syncClientParameters(deviceID: deviceID, key: key)))
        }

        public func connect(name: String, appVersion: String) async throws {
            try await framed.open()
            guard case .challenge(let nonce) = try await framed.receive(HostReply.self), nonce.count == 32 else { throw Failure.protocolError }
            try await framed.send(DeviceRequest.hello(deviceID: deviceID, proof: SyncAuth.proof(key: key, nonce: nonce, deviceID: deviceID),
                                                      name: name, appVersion: appVersion))
            guard case .ok = try await framed.receive(HostReply.self) else { throw Failure.protocolError }
        }

        public func send(_ request: DeviceRequest) async throws -> HostReply {
            try await framed.send(request)
            return try await framed.receive(HostReply.self)
        }

        public func close() { framed.close() }
    }

    /// Finds a host on the local network by Bonjour, matching its id in the TXT record.
    public static func discover(service: String, hostID: String?, timeout: TimeInterval = 6) async -> NWEndpoint? {
        await withCheckedContinuation { (cont: CheckedContinuation<NWEndpoint?, Never>) in
            let params = NWParameters()
            params.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: service, domain: nil), using: params)
            let once = Once()
            browser.browseResultsChangedHandler = { results, _ in
                for r in results {
                    if case let .bonjour(txt) = r.metadata, hostID == nil || txt["id"] == hostID {
                        once.run { browser.cancel(); cont.resume(returning: r.endpoint) }
                        return
                    }
                }
            }
            browser.start(queue: DispatchQueue(label: "dev.vigil.browse"))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.run { browser.cancel(); cont.resume(returning: nil) }
            }
        }
    }
}
