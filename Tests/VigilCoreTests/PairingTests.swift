import CryptoKit
import Foundation
import Network
import Testing
@testable import VigilSync

struct PairingTests {
    private func hellos(mode: String = "qr") -> (Curve25519.KeyAgreement.PrivateKey, Pairing.Hello, Curve25519.KeyAgreement.PrivateKey, Pairing.Hello) {
        let hk = Curve25519.KeyAgreement.PrivateKey(), dk = Curve25519.KeyAgreement.PrivateKey()
        let host = Pairing.Hello(role: "host", id: "host1", name: "Mac", model: "MacBookPro", platform: "macOS",
                                 ephemeralKey: hk.publicKey.rawRepresentation, mode: mode)
        let dev = Pairing.Hello(role: "device", id: "", name: "iPhone", model: "iPhone16,1", platform: "iOS",
                                ephemeralKey: dk.publicKey.rawRepresentation, mode: mode)
        return (hk, host, dk, dev)
    }

    @Test func bothSidesDeriveSameKeyAndCode() throws {
        let (hk, host, dk, dev) = hellos()
        let a = try Pairing.keys(mine: hk, host: host, device: dev)
        let b = try Pairing.keys(mine: dk, host: host, device: dev)
        #expect(a.code == b.code)
        #expect(a.code.count == 6)
        #expect(a.transcript == b.transcript)
        let w = Pairing.Welcome(deviceID: "d1", deviceKey: Pairing.randomBytes(32), hostID: "host1", hostName: "Mac")
        #expect(try Pairing.open(try Pairing.seal(w, keys: a), keys: b) == w)
    }

    @Test func manInTheMiddleGetsDifferentCode() throws {
        // Attacker relays but substitutes its own keys on each side: codes no longer match.
        let (hk, host, dk, dev) = hellos(mode: "pin")
        let mk = Curve25519.KeyAgreement.PrivateKey()
        var fakeDev = dev; fakeDev.ephemeralKey = mk.publicKey.rawRepresentation
        var fakeHost = host; fakeHost.ephemeralKey = mk.publicKey.rawRepresentation
        let hostView = try Pairing.keys(mine: hk, host: host, device: fakeDev)
        let devView = try Pairing.keys(mine: dk, host: fakeHost, device: dev)
        #expect(hostView.code != devView.code)
    }

    @Test func qrProofRequiresSecret() throws {
        let (hk, host, _, dev) = hellos()
        let keys = try Pairing.keys(mine: hk, host: host, device: dev)
        let secret = Pairing.randomBytes(32)
        #expect(Pairing.verify(proof: Pairing.proof(secret: secret, transcript: keys.transcript), secret: secret, transcript: keys.transcript))
        #expect(!Pairing.verify(proof: Pairing.proof(secret: Pairing.randomBytes(32), transcript: keys.transcript), secret: secret, transcript: keys.transcript))
    }

    @Test func tamperedWelcomeFails() throws {
        let (hk, host, dk, dev) = hellos()
        let a = try Pairing.keys(mine: hk, host: host, device: dev)
        let b = try Pairing.keys(mine: dk, host: host, device: dev)
        var sealed = try Pairing.seal(Pairing.Welcome(deviceID: "d", deviceKey: Pairing.randomBytes(32), hostID: "h", hostName: "M"), keys: a)
        sealed[sealed.count - 1] ^= 1
        #expect(throws: Pairing.Failure.decryptFailed) { try Pairing.open(sealed, keys: b) }
    }

    @Test func qrRoundTripAndRejectsJunk() {
        let p = Pairing.QRPayload(hostID: "abc", hostName: "Amazing's Mac", keyFingerprint: Pairing.randomBytes(16),
                                  secret: Pairing.randomBytes(32), address: "192.168.1.4:5000")
        #expect(Pairing.QRPayload(url: p.url) == p)
        #expect(Pairing.QRPayload(url: "https://evil.example/pair") == nil)
        #expect(Pairing.QRPayload(url: "vigil://pair?v=1&h=x&k=AA&s=BB") == nil)
    }

    @Test func onlyLocalAddressesAllowed() {
        func ep(_ s: String) -> NWEndpoint { .hostPort(host: NWEndpoint.Host(s), port: 1) }
        #expect(Transport.isLocal(ep("192.168.1.20")))
        #expect(Transport.isLocal(ep("10.0.0.2")))
        #expect(Transport.isLocal(ep("fe80::1")))
        #expect(!Transport.isLocal(ep("8.8.8.8")))
        #expect(!Transport.isLocal(ep("2001:4860:4860::8888")))
        #expect(!Transport.isLocal(ep("172.32.0.1")))
    }
}

/// Real TLS-PSK handshakes over loopback: the right key connects, a wrong or unknown one doesn't.
struct PSKLoopbackTests {
    private func roundTrip(clientID: String, clientKey: Data, serverKeys: [String: Data]) async throws -> String {
        let listener = try NWListener(using: Transport.syncServerParameters(keys: serverKeys), on: .any)
        let ready = AsyncStream<UInt16> { cont in
            listener.stateUpdateHandler = { if case .ready = $0 { cont.yield(listener.port?.rawValue ?? 0); cont.finish() } }
        }
        listener.newConnectionHandler = { conn in
            let framed = FramedConnection(conn)
            Task {
                try? await framed.open()
                if let msg = try? await framed.receive(String.self) { try? await framed.send("echo:" + msg) }
            }
        }
        listener.start(queue: DispatchQueue(label: "test.listener"))
        defer { listener.cancel() }
        var port: UInt16 = 0
        for await p in ready { port = p }
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                using: Transport.syncClientParameters(deviceID: clientID, key: clientKey))
        let client = FramedConnection(conn)
        defer { client.close() }
        try await client.open(timeout: 5)
        try await client.send("hi")
        return try await client.receive(String.self)
    }

    @Test func correctKeyConnects() async throws {
        let k = Pairing.randomBytes(32)
        let reply = try await roundTrip(clientID: "dev1", clientKey: k, serverKeys: ["dev1": k, "dev2": Pairing.randomBytes(32)])
        #expect(reply == "echo:hi")
    }

    @Test func wrongKeyFails() async {
        await #expect(throws: (any Error).self) {
            _ = try await roundTrip(clientID: "dev1", clientKey: Pairing.randomBytes(32), serverKeys: ["dev1": Pairing.randomBytes(32)])
        }
    }

    @Test func unknownDeviceFails() async {
        let k = Pairing.randomBytes(32)
        await #expect(throws: (any Error).self) {
            _ = try await roundTrip(clientID: "intruder", clientKey: k, serverKeys: ["dev1": k])
        }
    }
}
