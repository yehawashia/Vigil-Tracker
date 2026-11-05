import Foundation
import Network
import Testing
@testable import VigilCore
@testable import VigilSync

/// Full pair → sync → revoke conversations between a real HostServer and DeviceClient over loopback.
@Suite(.serialized) struct HostClientTests {
    final class Events: @unchecked Sendable {
        var list: [PairingEvent] = []
        func wait(_ match: (PairingEvent) -> Bool, timeout: TimeInterval = 5) async -> PairingEvent? {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                if let e = await MainActor.run(body: { list.first(where: match) }) { return e }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return nil
        }
    }

    private func makeHost() throws -> (HostServer, Events, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vigil-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let host = try HostServer(hostID: "host-test", hostName: "Test Mac", storePath: dir.appendingPathComponent("db.sqlite").path,
                                  keyFile: DeviceKeyFile(url: dir.appendingPathComponent("keys.json")))
        let events = Events()
        host.onPairingEvent = { e in events.list.append(e) }
        return (host, events, dir)
    }

    private func local(_ port: UInt16) -> NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!) }
    private let me = DeviceClient.Identity(name: "Test iPhone", model: "iPhone16,1", platform: "iOS")

    @Test func qrPairThenSyncThenRevoke() async throws {
        let (host, events, dir) = try makeHost()
        host.openPairing(mode: .qr)
        guard case let .open(_, url?, _) = await events.wait({ if case .open = $0 { return true }; return false }),
              let qr = Pairing.QRPayload(url: url), let port = host.pairingPort else { Issue.record("no window"); return }
        let welcome = try await DeviceClient.pair(endpoint: local(port), me: me, qr: qr)
        #expect(welcome.hostName == "Test Mac")
        #expect(await events.wait({ if case .paired = $0 { return true }; return false }) != nil)

        // Keys file is private.
        let perms = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("keys.json").path)[.posixPermissions] as? Int
        #expect(perms == 0o600)

        try await Task.sleep(nanoseconds: 300_000_000)
        guard let syncPort = host.syncPort else { Issue.record("no sync listener"); return }
        let session = DeviceClient.Session(endpoint: local(syncPort), deviceID: welcome.deviceID, key: welcome.deviceKey)
        try await session.connect(name: "Test iPhone", appVersion: "1")
        guard case .snapshot(let snap) = try await session.send(.snapshot) else { Issue.record("no snapshot"); return }
        #expect(snap.hostName == "Test Mac")
        #expect(snap.devices.map(\.id) == [welcome.deviceID])

        // A timetable edit from the phone is applied and attributed to it.
        let start = Date().addingTimeInterval(7200)
        let item = TimetableItem(title: "From phone", start: start, end: start.addingTimeInterval(3600))
        guard case .snapshot(let after) = try await session.send(.editTimetable(op: .create, item: item)) else { Issue.record("edit"); return }
        #expect(after.timetable.contains { $0.title == "From phone" })
        #expect(after.history.first?.author == "device:\(welcome.deviceID)")

        // Usage is validated: the junk row is dropped.
        _ = try await session.send(.pushUsage([
            DeviceUsage(day: DayKey.today, kind: .domain, key: "YouTube.com", seconds: 600, precision: 1, category: .distracting),
            DeviceUsage(day: "not-a-day", kind: .domain, key: "x.com", seconds: 1, precision: 1, category: nil),
        ]))
        session.close()

        host.revoke(deviceID: welcome.deviceID)
        try await Task.sleep(nanoseconds: 300_000_000)
        // After revocation nothing listens with its key: the device can't connect again.
        if let p = host.syncPort {
            let again = DeviceClient.Session(endpoint: local(p), deviceID: welcome.deviceID, key: welcome.deviceKey)
            await #expect(throws: (any Error).self) { try await again.connect(name: "x", appVersion: "1") }
        }
        host.stop()
    }

    @Test func pinPairingNeedsConfirmationOnMac() async throws {
        let (host, events, _) = try makeHost()
        host.openPairing(mode: .pin)
        _ = await events.wait({ if case .open = $0 { return true }; return false })
        guard let port = host.pairingPort else { Issue.record("no window"); return }
        let shown = Events()
        let task = Task { try await DeviceClient.pair(endpoint: local(port), me: me, qr: nil) { code in
            shown.list.append(.confirm(code: code, deviceName: "")) } }
        guard case let .confirm(hostCode, name)? = await events.wait({ if case .confirm = $0 { return true }; return false }) else {
            Issue.record("no confirm"); return
        }
        #expect(name == "Test iPhone")
        guard case let .confirm(deviceCode, _)? = await shown.wait({ _ in true }) else { Issue.record("device code"); return }
        #expect(hostCode == deviceCode)
        host.confirmPairing(false)
        await #expect(throws: DeviceClient.Failure.self) { _ = try await task.value }
        host.stop()
    }

    @Test func wrongQRSecretIsRefused() async throws {
        let (host, events, _) = try makeHost()
        host.openPairing(mode: .qr)
        guard case let .open(_, url?, _) = await events.wait({ if case .open = $0 { return true }; return false }),
              var qr = Pairing.QRPayload(url: url), let port = host.pairingPort else { Issue.record("no window"); return }
        qr.secret = Pairing.randomBytes(32)
        await #expect(throws: DeviceClient.Failure.self) { _ = try await DeviceClient.pair(endpoint: local(port), me: me, qr: qr) }
        host.stop()
    }
}
