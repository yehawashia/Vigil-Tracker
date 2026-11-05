import CryptoKit
import Foundation

/// Pairing between a Mac (host) and an iPhone/iPad (device). See docs/ARCHITECTURE.md §4.
///
/// 1. Both sides send a `Hello` with a fresh X25519 public key.
/// 2. Both derive the same `PairingKeys` from the exchange and a transcript of both hellos.
/// 3. The device proves it scanned the QR code (HMAC of the transcript with the QR secret),
///    or, in PIN mode, the user confirms both screens show the same 6-digit code.
/// 4. The host sends a `Welcome` (device id + 256-bit device key) sealed with the pairing key.
///    That device key is the TLS pre-shared key for every later sync.
public enum Pairing {
    public static let protocolVersion = "vigil-pair-v1"
    /// QR secrets and pairing windows expire after this long.
    public static let windowSeconds: TimeInterval = 120

    public struct Hello: Codable, Equatable {
        public var role: String          // "host" | "device"
        public var id: String            // host id, or "" for a new device
        public var name: String
        public var model: String
        public var platform: String
        public var ephemeralKey: Data    // X25519 public key, 32 bytes
        public var mode: String          // "qr" | "pin"

        public init(role: String, id: String, name: String, model: String, platform: String, ephemeralKey: Data, mode: String) {
            self.role = role; self.id = id; self.name = String(name.prefix(80)); self.model = String(model.prefix(80))
            self.platform = String(platform.prefix(20)); self.ephemeralKey = ephemeralKey; self.mode = mode
        }
    }

    /// Sent by the host after a successful pairing, sealed with the pairing key.
    public struct Welcome: Codable, Equatable {
        public var deviceID: String
        public var deviceKey: Data       // 32 random bytes; TLS-PSK for sync
        public var hostID: String
        public var hostName: String
        public init(deviceID: String, deviceKey: Data, hostID: String, hostName: String) {
            self.deviceID = deviceID; self.deviceKey = deviceKey; self.hostID = hostID; self.hostName = hostName
        }
    }

    public struct Keys {
        public let transcript: Data
        public let pairingKey: SymmetricKey
        /// 6-digit short authentication string both screens show in PIN mode.
        public let code: String
    }

    public enum Failure: Error, Equatable {
        case badKey, badProof, wrongHost, expired, decryptFailed, malformed
    }

    /// Length-prefixed concatenation, so no two different hellos can produce the same transcript.
    public static func transcript(host: Hello, device: Hello) -> Data {
        var out = Data()
        func put(_ d: Data) {
            var n = UInt32(d.count).bigEndian
            out.append(Data(bytes: &n, count: 4)); out.append(d)
        }
        func put(_ s: String) { put(Data(s.utf8)) }
        put(protocolVersion)
        for h in [host, device] {
            put(h.role); put(h.id); put(h.name); put(h.model); put(h.platform); put(h.mode); put(h.ephemeralKey)
        }
        return Data(SHA256.hash(data: out))
    }

    /// Derives the pairing key and code. `mine` must be the private key behind this side's hello.
    public static func keys(mine: Curve25519.KeyAgreement.PrivateKey, host: Hello, device: Hello) throws -> Keys {
        let peerKey = mine.publicKey.rawRepresentation == host.ephemeralKey ? device.ephemeralKey : host.ephemeralKey
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKey) else { throw Failure.badKey }
        let shared = try mine.sharedSecretFromKeyAgreement(with: peer)
        let t = transcript(host: host, device: device)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: t, sharedInfo: Data("vigil-pair-key".utf8), outputByteCount: 32)
        let codeKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: t, sharedInfo: Data("vigil-pair-code".utf8), outputByteCount: 8)
        let n = codeKey.withUnsafeBytes { raw in raw.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
        return Keys(transcript: t, pairingKey: key, code: String(format: "%06llu", n % 1_000_000))
    }

    // MARK: QR

    /// What the QR code carries. The host's key fingerprint stops anyone else on the network
    /// from answering in the host's place; the secret proves the device actually saw the screen.
    public struct QRPayload: Equatable {
        public var hostID: String
        public var hostName: String
        public var keyFingerprint: Data   // first 16 bytes of SHA256(host ephemeral public key)
        public var secret: Data           // 32 random bytes, single use
        public var address: String?       // "ip:port" hint; Bonjour is used if absent or stale

        public init(hostID: String, hostName: String, keyFingerprint: Data, secret: Data, address: String?) {
            self.hostID = hostID; self.hostName = hostName; self.keyFingerprint = keyFingerprint
            self.secret = secret; self.address = address
        }

        public var url: String {
            var c = URLComponents()
            c.scheme = "vigil"; c.host = "pair"
            c.queryItems = [URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "h", value: hostID),
                            URLQueryItem(name: "n", value: hostName), URLQueryItem(name: "k", value: keyFingerprint.base64URL),
                            URLQueryItem(name: "s", value: secret.base64URL)]
            if let address { c.queryItems?.append(URLQueryItem(name: "a", value: address)) }
            return c.string ?? ""
        }

        public init?(url string: String) {
            guard let c = URLComponents(string: string), c.scheme == "vigil", c.host == "pair" else { return nil }
            func q(_ k: String) -> String? { c.queryItems?.first { $0.name == k }?.value }
            guard q("v") == "1", let h = q("h"), !h.isEmpty, h.count <= 64,
                  let k = q("k").flatMap(Data.init(base64URL:)), k.count == 16,
                  let s = q("s").flatMap(Data.init(base64URL:)), s.count == 32 else { return nil }
            self.init(hostID: h, hostName: String((q("n") ?? "Mac").prefix(80)), keyFingerprint: k, secret: s, address: q("a"))
        }
    }

    public static func fingerprint(_ publicKey: Data) -> Data { Data(SHA256.hash(data: publicKey).prefix(16)) }

    public static func proof(secret: Data, transcript: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: transcript, using: SymmetricKey(data: secret)))
    }

    /// Constant-time check of the device's QR proof.
    public static func verify(proof: Data, secret: Data, transcript: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: transcript, using: SymmetricKey(data: secret))
    }

    // MARK: Welcome

    public static func seal(_ welcome: Welcome, keys: Keys) throws -> Data {
        let plain = try JSONEncoder().encode(welcome)
        guard let combined = try AES.GCM.seal(plain, using: keys.pairingKey, authenticating: keys.transcript).combined else {
            throw Failure.malformed
        }
        return combined
    }

    public static func open(_ sealed: Data, keys: Keys) throws -> Welcome {
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: keys.pairingKey, authenticating: keys.transcript) else {
            throw Failure.decryptFailed
        }
        guard let w = try? JSONDecoder().decode(Welcome.self, from: plain), w.deviceKey.count == 32 else { throw Failure.malformed }
        return w
    }

    public static func randomBytes(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }

    public static func newID() -> String { randomBytes(16).map { String(format: "%02x", $0) }.joined() }
}

extension Data {
    public var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}
