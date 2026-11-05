import CryptoKit
import Foundation
import VigilCore

/// Every message on the wire: 4-byte big-endian length, then JSON. Max 1 MB.
public enum Frame {
    public static let maxBytes = 1 << 20

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let body = try SyncCoding.encoder.encode(value)
        guard body.count <= maxBytes else { throw SyncError.tooLarge }
        var n = UInt32(body.count).bigEndian
        return Data(bytes: &n, count: 4) + body
    }

    /// Length from a 4-byte header, or nil if it's over the limit.
    public static func length(_ header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let n = header.reduce(0) { $0 << 8 | Int($1) }
        return n <= maxBytes ? n : nil
    }
}

public enum SyncCoding {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e
    }()
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d
    }()
}

public enum SyncError: Error, Equatable {
    case tooLarge, closed, timeout, refused(String), notLocal
}

// MARK: - Pairing messages (unencrypted channel; the protocol authenticates itself)

public enum PairMessage: Codable {
    case hello(Pairing.Hello)
    /// Device → host in QR mode.
    case proof(Data)
    /// Host → device: sealed `Welcome`.
    case welcome(Data)
    /// Either side: give up, with a reason to show.
    case refuse(String)
}

// MARK: - Sync messages (inside TLS-PSK)

/// What a host sends a device: everything the iPhone/iPad app draws.
public struct HostSnapshot: Codable, Equatable {
    public var hostID: String
    public var hostName: String
    public var generatedAt: Date
    public var today: DaySummary
    public var trends: TrendsData?
    public var timetable: [TimetableItem]
    public var proposals: [TimetableRevision]
    public var history: [TimetableRevision]
    public var devices: [PairedDevice]
    public var blockedDomains: [String]
    public var focus: FocusSession?

    public init(hostID: String, hostName: String, generatedAt: Date, today: DaySummary, trends: TrendsData?,
                timetable: [TimetableItem], proposals: [TimetableRevision], history: [TimetableRevision],
                devices: [PairedDevice], blockedDomains: [String], focus: FocusSession?) {
        self.hostID = hostID; self.hostName = hostName; self.generatedAt = generatedAt; self.today = today
        self.trends = trends; self.timetable = timetable; self.proposals = proposals; self.history = history
        self.devices = devices; self.blockedDomains = blockedDomains; self.focus = focus
    }
}

public enum DeviceRequest: Codable {
    /// First message of every sync session: answers the host's challenge with HMAC(device key, nonce ‖ id),
    /// binding the session to one device. Name may change if the user renames the phone.
    case hello(deviceID: String, proof: Data, name: String, appVersion: String)
    case pushUsage([DeviceUsage])
    case snapshot
    case editTimetable(op: TimetableRevision.Op, item: TimetableItem)
    case decideProposal(id: Int64, approve: Bool)
    case revert(revisionID: Int64)
    case startFocus(minutes: Int, locked: Bool, label: String?)
}

public enum HostReply: Codable {
    /// First message of every sync session: a fresh random nonce.
    case challenge(Data)
    case ok
    case snapshot(HostSnapshot)
    case error(String)
    /// This device was revoked on the Mac; forget the host.
    case revoked
}

public enum SyncAuth {
    public static func proof(key: Data, nonce: Data, deviceID: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: nonce + Data(deviceID.utf8), using: SymmetricKey(data: key)))
    }

    public static func verify(_ proof: Data, key: Data, nonce: Data, deviceID: String) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: nonce + Data(deviceID.utf8), using: SymmetricKey(data: key))
    }
}
