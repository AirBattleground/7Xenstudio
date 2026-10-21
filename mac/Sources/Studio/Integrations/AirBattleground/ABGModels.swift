// AirBattleground integration: wire models. Shapes copied from the old Node client
// (src/server/integrations/airbattleground/client.ts) and CONTRACT.md.
import Foundation

let abgDefaultHost = "https://airbattleground.com"

struct ABGAccount: Codable, Equatable, Sendable { var name: String; var org: String? }

struct ABGMatch: Identifiable, Equatable, Hashable, Sendable {
    enum Status: String, Codable, Sendable { case upcoming, live, done }
    var id: String, title: String, subtitle: String
    var startsAt: String?
    var status: Status
}
extension ABGMatch: Decodable {
    private enum K: String, CodingKey { case id, title, subtitle, startsAt, status }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decodeFlexibleString(.id)
        title = (try? c.decode(String.self, forKey: .title)) ?? "Match"
        subtitle = ((try? c.decodeIfPresent(String.self, forKey: .subtitle)) ?? nil) ?? ""
        startsAt = (try? c.decodeIfPresent(String.self, forKey: .startsAt)) ?? nil
        status = ((try? c.decodeIfPresent(Status.self, forKey: .status)) ?? nil) ?? .upcoming
    }
}

struct ABGOutputs: Decodable, Equatable, Sendable {
    struct SiteYouTube: Decodable, Equatable, Sendable { var channelTitle: String }
    struct Destination: Decodable, Equatable, Sendable { var id: String, name: String, kind: String }
    var livePage = false
    var siteYoutube: SiteYouTube?
    var destinations: [Destination] = []
    init(livePage: Bool = false, siteYoutube: SiteYouTube? = nil, destinations: [Destination] = []) {
        self.livePage = livePage; self.siteYoutube = siteYoutube; self.destinations = destinations
    }
    private enum K: String, CodingKey { case livePage, siteYoutube, destinations }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        livePage = ((try? c.decodeIfPresent(Bool.self, forKey: .livePage)) ?? nil) ?? false
        siteYoutube = (try? c.decodeIfPresent(SiteYouTube.self, forKey: .siteYoutube)) ?? nil
        destinations = ((try? c.decodeIfPresent([Destination].self, forKey: .destinations)) ?? nil) ?? []
    }
}

struct ABGBroadcastInput: Encodable, Equatable, Sendable {
    var matchId: String?
    var title: String
    var livePage: Bool
    var siteYoutube: Bool
    var destinationIds: [String]
    // The old client sends `matchId: null` explicitly.
    private enum K: String, CodingKey { case matchId, title, livePage, siteYoutube, destinationIds }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        if let matchId { try c.encode(matchId, forKey: .matchId) } else { try c.encodeNil(forKey: .matchId) }
        try c.encode(title, forKey: .title); try c.encode(livePage, forKey: .livePage)
        try c.encode(siteYoutube, forKey: .siteYoutube); try c.encode(destinationIds, forKey: .destinationIds)
    }
}

struct ABGBroadcast: Decodable, Equatable, Sendable {
    struct Target: Decodable, Equatable, Sendable { var id: String, name: String, url: String }
    var id: String
    var targets: [Target]
    var watchUrl: String?
    private enum K: String, CodingKey { case id, targets, watchUrl }
    init(id: String, targets: [Target], watchUrl: String?) { self.id = id; self.targets = targets; self.watchUrl = watchUrl }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decodeFlexibleString(.id)
        targets = ((try? c.decodeIfPresent([Target].self, forKey: .targets)) ?? nil) ?? []
        watchUrl = (try? c.decodeIfPresent(String.self, forKey: .watchUrl)) ?? nil
    }
}

struct ABGHeartbeat: Encodable, Equatable, Sendable {
    /// "live" | "starting" | "error"
    var state: String
    var fps: Double?
    var bitrateKbps: Double?
    private enum K: String, CodingKey { case state, fps, bitrateKbps }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(state, forKey: .state)
        if let fps { try c.encode(fps, forKey: .fps) } else { try c.encodeNil(forKey: .fps) }
        if let bitrateKbps { try c.encode(bitrateKbps, forKey: .bitrateKbps) } else { try c.encodeNil(forKey: .bitrateKbps) }
    }
}

struct ABGCredentials: Codable, Equatable, Sendable {
    var host: String
    var key: String
    var account: ABGAccount
}

/// Show.link from the old app (src/shared/types.ts ShowLink), stored on the native show.
struct ShowLink: Codable, Hashable, Sendable {
    var integration: String
    var eventId: String?
    var eventTitle: String?
    /// additive (native): teams / round line and status of the picked match
    var eventSubtitle: String?
    var eventStatus: String?
    var startsAt: String?
}

/// Errors with the same user-facing wording as the old client (client.ts).
enum ABGError: LocalizedError, Equatable {
    case notConnected, invalidLink, unreachable, keyInvalid, api(String), http(Int), badResponse
    case noMatch, noYouTube, noStreamKey
    var errorDescription: String? {
        switch self {
        case .notConnected: "Connect AirBattleground first."
        case .invalidLink: "That isn't an AirBattleground studio link. Scan the QR again or paste the key (it starts with sw_)."
        case .unreachable: "Can't reach AirBattleground. Check the internet connection."
        case .keyInvalid: "AirBattleground didn't accept this studio's key. Connect again with a new QR code."
        case .api(let m): "AirBattleground: \(m)"
        case .http(let c): "AirBattleground answered with an error (\(c)). Try again."
        case .badResponse: "AirBattleground sent an answer the studio doesn't understand."
        case .noMatch: "Pick the AirBattleground match to cover first."
        case .noYouTube: "No YouTube channel is connected on this AirBattleground account. Connect YouTube there, then try again."
        case .noStreamKey: "AirBattleground did not return a YouTube stream key for this match. Check the broadcast on AirBattleground and try again."
        }
    }
    /// worth retrying right away (network down); everything else needs the operator
    var isTransient: Bool { if case .unreachable = self { true } else if case .http(let c) = self { c >= 500 } else { false } }
}

extension KeyedDecodingContainer {
    /// Old client does String(id): accept strings and numbers.
    func decodeFlexibleString(_ key: Key) throws -> String {
        if let s = try? decode(String.self, forKey: key) { return s }
        if let i = try? decode(Int.self, forKey: key) { return String(i) }
        if let d = try? decode(Double.self, forKey: key) { return String(Int(d)) }
        throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "id"))
    }
}
