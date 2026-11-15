import Foundation

/// Friend rooms on vajra.one. The process at 127.0.0.1:8796 only forwards
/// frames. The host phone still runs `DuelMatch`.
public enum RoomProtocol {
    public static let version = 1
    public static let maxPlayers = 2
    /// A room code can be joined for this long after it is created.
    public static let roomTTL: TimeInterval = 2 * 60 * 60
    /// A room with no sockets is removed after this long.
    public static let idleTTL: TimeInterval = 20 * 60
    public static let heartbeatInterval: TimeInterval = 5
    /// No inbound frame for this long closes the socket.
    public static let heartbeatTimeout: TimeInterval = 12
    /// Guest may reclaim the seat until the host's forfeit timer fires.
    public static let resumeWindow: TimeInterval = 5
    public static let createPerMinute = 6
    public static let joinPerMinute = 20
    public static let maxRooms = 200
    public static let maxClientIDLength = 64
    public static let listenPort = 8796
}

public enum RoomCode {
    public static func isValid(_ raw: String) -> Bool {
        raw.count == 6 && raw.allSatisfy(\.isNumber) && raw != "000000"
    }

    public static func generate(using rng: inout some RandomNumberGenerator) -> String {
        var digits = ""
        for _ in 0..<6 {
            digits.append(Character(UnicodeScalar(48 + Int.random(in: 0...9, using: &rng))!))
        }
        return isValid(digits) ? digits : generate(using: &rng)
    }
}

/// `https://vajra.one/shinake/join/CODE` is the shared link.
/// `shinake://join/CODE` is the in-page button. Universal Links use the https form.
public enum OnlineLinks {
    public static let scheme = "shinake"
    public static let defaultPublicBase = "https://vajra.one"
    public static let wsPath = "/shinake/ws"
    public static let joinPrefix = "/shinake/join/"

    public static func webSocketURL(publicBase: String = defaultPublicBase) -> URL? {
        guard var parts = URLComponents(string: publicBase), let host = parts.host else { return nil }
        switch parts.scheme {
        case "https": parts.scheme = "wss"
        case "http": parts.scheme = "ws"
        case "wss", "ws": break
        default: return nil
        }
        parts.host = host
        parts.path = wsPath
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    public static func httpsJoin(code: String, publicBase: String = defaultPublicBase) -> URL? {
        guard RoomCode.isValid(code), var parts = URLComponents(string: publicBase) else { return nil }
        parts.path = joinPrefix + code
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    public static func appJoin(code: String) -> URL? {
        guard RoomCode.isValid(code) else { return nil }
        return URL(string: "\(scheme)://join/\(code)")
    }

    public static func roomCode(from url: URL) -> String? {
        if url.scheme?.lowercased() == scheme {
            let host = url.host ?? ""
            return firstCode(in: host + "/" + url.path) ?? queryCode(url)
        }
        if url.path == "/shinake/join" || url.path.hasPrefix(joinPrefix) {
            let rest = url.path.hasPrefix(joinPrefix) ? String(url.path.dropFirst(joinPrefix.count)) : ""
            if let head = rest.split(separator: "/").first, let code = isSix(String(head)) {
                return code
            }
            return queryCode(url)
        }
        return nil
    }

    private static func queryCode(_ url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "code" }?.value.flatMap { isSix($0) }
    }

    private static func firstCode(in raw: String) -> String? {
        raw.split { $0 == "/" || $0 == "?" }.map(String.init).compactMap(isSix).first
    }

    private static func isSix(_ raw: String) -> String? {
        RoomCode.isValid(raw) ? raw : nil
    }
}

public struct RoomHello: Codable, Equatable {
    public var version: Int
    public var clientID: String
    public var roomCode: String?
    public var resumeToken: String?

    public init(version: Int = RoomProtocol.version, clientID: String, roomCode: String? = nil, resumeToken: String? = nil) {
        self.version = version
        self.clientID = clientID
        self.roomCode = roomCode
        self.resumeToken = resumeToken
    }
}

public struct RoomWelcome: Codable, Equatable {
    public var roomCode: String
    public var resumeToken: String
    public var host: Bool
    public var inviteURL: String
    public var appURL: String
    public var expiresAt: Double

    public init(roomCode: String, resumeToken: String, host: Bool, inviteURL: String, appURL: String, expiresAt: Double) {
        self.roomCode = roomCode
        self.resumeToken = resumeToken
        self.host = host
        self.inviteURL = inviteURL
        self.appURL = appURL
        self.expiresAt = expiresAt
    }
}

public struct RoomPeerNotice: Codable, Equatable {
    public var role: DuelRole
    public var connected: Bool

    public init(role: DuelRole, connected: Bool) {
        self.role = role
        self.connected = connected
    }
}

public enum RoomClientMessage: Codable, Equatable {
    case hello(RoomHello)
    case input(seq: Int, control: ControlInput)
    case snapshot(DuelSnapshot)
    case leave
    case ping(Int)

    private enum Kind: String, Codable { case hello, input, snapshot, leave, ping }
    private enum Key: String, CodingKey { case type, hello, seq, control, snapshot, ping }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .hello(let value):
            try c.encode(Kind.hello, forKey: .type)
            try c.encode(value, forKey: .hello)
        case .input(let seq, let control):
            try c.encode(Kind.input, forKey: .type)
            try c.encode(seq, forKey: .seq)
            try c.encode(control, forKey: .control)
        case .snapshot(let value):
            try c.encode(Kind.snapshot, forKey: .type)
            try c.encode(value, forKey: .snapshot)
        case .leave:
            try c.encode(Kind.leave, forKey: .type)
        case .ping(let value):
            try c.encode(Kind.ping, forKey: .type)
            try c.encode(value, forKey: .ping)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .hello: self = .hello(try c.decode(RoomHello.self, forKey: .hello))
        case .input:
            self = .input(seq: try c.decode(Int.self, forKey: .seq), control: try c.decode(ControlInput.self, forKey: .control))
        case .snapshot: self = .snapshot(try c.decode(DuelSnapshot.self, forKey: .snapshot))
        case .leave: self = .leave
        case .ping: self = .ping(try c.decode(Int.self, forKey: .ping))
        }
    }
}

public enum RoomServerMessage: Codable, Equatable {
    case welcome(RoomWelcome)
    case peer(RoomPeerNotice)
    case input(seq: Int, control: ControlInput)
    case snapshot(DuelSnapshot)
    case rejected(String)
    case ended(String)
    case pong(Int)

    private enum Kind: String, Codable { case welcome, peer, input, snapshot, rejected, ended, pong }
    private enum Key: String, CodingKey { case type, welcome, peer, seq, control, snapshot, rejected, ended, pong }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .welcome(let value):
            try c.encode(Kind.welcome, forKey: .type)
            try c.encode(value, forKey: .welcome)
        case .peer(let value):
            try c.encode(Kind.peer, forKey: .type)
            try c.encode(value, forKey: .peer)
        case .input(let seq, let control):
            try c.encode(Kind.input, forKey: .type)
            try c.encode(seq, forKey: .seq)
            try c.encode(control, forKey: .control)
        case .snapshot(let value):
            try c.encode(Kind.snapshot, forKey: .type)
            try c.encode(value, forKey: .snapshot)
        case .rejected(let value):
            try c.encode(Kind.rejected, forKey: .type)
            try c.encode(value, forKey: .rejected)
        case .ended(let value):
            try c.encode(Kind.ended, forKey: .type)
            try c.encode(value, forKey: .ended)
        case .pong(let value):
            try c.encode(Kind.pong, forKey: .type)
            try c.encode(value, forKey: .pong)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .welcome: self = .welcome(try c.decode(RoomWelcome.self, forKey: .welcome))
        case .peer: self = .peer(try c.decode(RoomPeerNotice.self, forKey: .peer))
        case .input:
            self = .input(seq: try c.decode(Int.self, forKey: .seq), control: try c.decode(ControlInput.self, forKey: .control))
        case .snapshot: self = .snapshot(try c.decode(DuelSnapshot.self, forKey: .snapshot))
        case .rejected: self = .rejected(try c.decode(String.self, forKey: .rejected))
        case .ended: self = .ended(try c.decode(String.self, forKey: .ended))
        case .pong: self = .pong(try c.decode(Int.self, forKey: .pong))
        }
    }
}

public struct RoomDelivery: Equatable {
    public var link: UUID
    public var message: RoomServerMessage

    public init(link: UUID, message: RoomServerMessage) {
        self.link = link
        self.message = message
    }
}

struct SlidingRateLimit {
    var limit: Int
    var window: TimeInterval
    private var stamps: [String: [Date]] = [:]

    init(limit: Int, window: TimeInterval) {
        self.limit = limit
        self.window = window
    }

    mutating func allow(_ key: String, at now: Date) -> Bool {
        var kept = stamps[key] ?? []
        kept.removeAll { now.timeIntervalSince($0) >= window }
        guard kept.count < limit else {
            stamps[key] = kept
            return false
        }
        kept.append(now)
        stamps[key] = kept
        return true
    }
}

/// In-memory rooms. Addresses exist only as rate-limit keys and die with the process.
public final class RoomHub {
    public let publicBase: String
    public var maxRooms: Int
    private var rooms: [String: RelayRoom] = [:]
    private var links: [UUID: LinkSeat] = [:]
    private var createLimit = SlidingRateLimit(limit: RoomProtocol.createPerMinute, window: 60)
    private var joinLimit = SlidingRateLimit(limit: RoomProtocol.joinPerMinute, window: 60)
    private var queuedCodes: [String]
    private var rng = SystemRandomNumberGenerator()

    public init(publicBase: String = OnlineLinks.defaultPublicBase, codes: [String] = [], maxRooms: Int = RoomProtocol.maxRooms) {
        self.publicBase = publicBase
        self.queuedCodes = codes
        self.maxRooms = maxRooms
    }

    public var roomCount: Int { rooms.count }

    public func open(_ link: UUID, at now: Date) {
        links[link] = LinkSeat(lastSeen: now)
    }

    public func receive(_ link: UUID, _ message: RoomClientMessage, ip: String, at now: Date) -> [RoomDelivery] {
        guard var seat = links[link] else { return [] }
        seat.lastSeen = now
        links[link] = seat
        switch message {
        case .hello(let hello):
            return admit(link, hello, ip: ip, at: now)
        case .input(let seq, let control):
            return forwardInput(link, seq: seq, control: control)
        case .snapshot(let snapshot):
            return forwardSnapshot(link, snapshot)
        case .leave:
            return disconnect(link, at: now)
        case .ping(let n):
            return [RoomDelivery(link: link, message: .pong(n))]
        }
    }

    public func disconnect(_ link: UUID, at now: Date) -> [RoomDelivery] {
        guard let seat = links.removeValue(forKey: link), let code = seat.roomCode, var room = rooms[code] else {
            return []
        }
        if seat.role == .host {
            var out: [RoomDelivery] = []
            if let joinerLink = room.joiner?.link {
                out.append(RoomDelivery(link: joinerLink, message: .ended("hostLeft")))
                links[joinerLink]?.roomCode = nil
                links[joinerLink]?.role = nil
            }
            rooms[code] = nil
            return out
        }
        room.joiner?.link = nil
        room.joiner?.goneAt = now
        room.emptySince = room.host.link == nil ? now : nil
        rooms[code] = room
        guard let hostLink = room.host.link else { return [] }
        return [RoomDelivery(link: hostLink, message: .peer(RoomPeerNotice(role: .joiner, connected: false)))]
    }

    /// Closes silent sockets and empty rooms. Call about once a second.
    public func tick(at now: Date) -> [RoomDelivery] {
        var out: [RoomDelivery] = []
        let silent = links.filter { now.timeIntervalSince($0.value.lastSeen) >= RoomProtocol.heartbeatTimeout }.map(\.key)
        for link in silent {
            out.append(contentsOf: disconnect(link, at: now))
        }
        for code in Array(rooms.keys) {
            guard var room = rooms[code] else { continue }
            if let gone = room.joiner?.goneAt, room.joiner?.link == nil, now.timeIntervalSince(gone) >= RoomProtocol.resumeWindow {
                room.joiner = nil
            }
            let noSockets = room.host.link == nil && room.joiner?.link == nil
            if noSockets {
                if room.emptySince == nil { room.emptySince = now }
                if let since = room.emptySince, now.timeIntervalSince(since) >= RoomProtocol.idleTTL {
                    rooms[code] = nil
                    continue
                }
            } else {
                room.emptySince = nil
            }
            if room.joiner == nil && now.timeIntervalSince(room.createdAt) >= RoomProtocol.roomTTL {
                if let hostLink = room.host.link {
                    out.append(RoomDelivery(link: hostLink, message: .ended("expired")))
                    links[hostLink]?.roomCode = nil
                }
                rooms[code] = nil
                continue
            }
            rooms[code] = room
        }
        return out
    }

    private func admit(_ link: UUID, _ hello: RoomHello, ip: String, at now: Date) -> [RoomDelivery] {
        guard hello.version == RoomProtocol.version else {
            return [RoomDelivery(link: link, message: .rejected("版本不对"))]
        }
        guard cleanClientID(hello.clientID) != nil else {
            return [RoomDelivery(link: link, message: .rejected("身份不对"))]
        }
        if let code = hello.roomCode {
            return join(link, hello, code: code, ip: ip, at: now)
        }
        guard createLimit.allow(ip, at: now) else {
            return [RoomDelivery(link: link, message: .rejected("创建太频繁"))]
        }
        guard rooms.count < maxRooms else {
            return [RoomDelivery(link: link, message: .rejected("房间太多了"))]
        }
        let code = nextCode()
        let token = token()
        var room = RelayRoom(code: code, createdAt: now, host: Seat(clientID: hello.clientID, resumeToken: token, link: link))
        room.host.link = link
        rooms[code] = room
        links[link]?.roomCode = code
        links[link]?.role = .host
        return [RoomDelivery(link: link, message: .welcome(makeWelcome(room: room, token: token, host: true)))]
    }

    private func join(_ link: UUID, _ hello: RoomHello, code: String, ip: String, at now: Date) -> [RoomDelivery] {
        guard RoomCode.isValid(code), var room = rooms[code] else {
            return [RoomDelivery(link: link, message: .rejected("房间不存在"))]
        }
        if links[link]?.role != nil {
            return [RoomDelivery(link: link, message: .rejected("已经在房间里"))]
        }
        if let seat = room.joiner, seat.clientID == hello.clientID || seat.resumeToken == hello.resumeToken {
            guard seat.link == nil, let gone = seat.goneAt, now.timeIntervalSince(gone) < RoomProtocol.resumeWindow else {
                return [RoomDelivery(link: link, message: .rejected("重连超时"))]
            }
            room.joiner?.link = link
            room.joiner?.goneAt = nil
            rooms[code] = room
            links[link]?.roomCode = code
            links[link]?.role = .joiner
            var out = [RoomDelivery(link: link, message: .welcome(makeWelcome(room: room, token: seat.resumeToken, host: false)))]
            if let hostLink = room.host.link {
                out.append(RoomDelivery(link: hostLink, message: .peer(RoomPeerNotice(role: .joiner, connected: true))))
            }
            return out
        }
        guard now.timeIntervalSince(room.createdAt) < RoomProtocol.roomTTL else {
            return [RoomDelivery(link: link, message: .rejected("房间码已过期"))]
        }
        guard room.joiner?.link == nil && room.joiner?.goneAt == nil else {
            return [RoomDelivery(link: link, message: .rejected("房间满了"))]
        }
        guard joinLimit.allow(ip, at: now) else {
            return [RoomDelivery(link: link, message: .rejected("加入太频繁"))]
        }
        let token = token()
        room.joiner = Seat(clientID: hello.clientID, resumeToken: token, link: link)
        rooms[code] = room
        links[link]?.roomCode = code
        links[link]?.role = .joiner
        var out = [RoomDelivery(link: link, message: .welcome(makeWelcome(room: room, token: token, host: false)))]
        if let hostLink = room.host.link {
            out.append(RoomDelivery(link: hostLink, message: .peer(RoomPeerNotice(role: .joiner, connected: true))))
        }
        return out
    }

    private func forwardInput(_ link: UUID, seq: Int, control: ControlInput) -> [RoomDelivery] {
        guard let seat = links[link], seat.role == .joiner, let code = seat.roomCode, let room = rooms[code], let hostLink = room.host.link else {
            return []
        }
        return [RoomDelivery(link: hostLink, message: .input(seq: seq, control: control))]
    }

    private func forwardSnapshot(_ link: UUID, _ snapshot: DuelSnapshot) -> [RoomDelivery] {
        guard let seat = links[link], seat.role == .host, let code = seat.roomCode, let room = rooms[code], let joinerLink = room.joiner?.link else {
            return []
        }
        return [RoomDelivery(link: joinerLink, message: .snapshot(snapshot))]
    }

    private func makeWelcome(room: RelayRoom, token: String, host: Bool) -> RoomWelcome {
        let invite = OnlineLinks.httpsJoin(code: room.code, publicBase: publicBase)?.absoluteString ?? ""
        let app = OnlineLinks.appJoin(code: room.code)?.absoluteString ?? ""
        return RoomWelcome(
            roomCode: room.code,
            resumeToken: token,
            host: host,
            inviteURL: invite,
            appURL: app,
            expiresAt: room.createdAt.addingTimeInterval(RoomProtocol.roomTTL).timeIntervalSince1970
        )
    }

    private func nextCode() -> String {
        while !queuedCodes.isEmpty {
            let code = queuedCodes.removeFirst()
            if rooms[code] == nil { return code }
        }
        for _ in 0..<20 {
            let code = RoomCode.generate(using: &rng)
            if rooms[code] == nil { return code }
        }
        return RoomCode.generate(using: &rng)
    }

    private func token() -> String {
        String(format: "%016llx%016llx", rng.next(), rng.next())
    }

    private func cleanClientID(_ raw: String) -> String? {
        guard (8...RoomProtocol.maxClientIDLength).contains(raw.count) else { return nil }
        guard raw.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        return raw
    }
}

private struct LinkSeat {
    var lastSeen: Date
    var roomCode: String?
    var role: DuelRole?
}

private struct Seat {
    var clientID: String
    var resumeToken: String
    var link: UUID?
    var goneAt: Date?
}

private struct RelayRoom {
    var code: String
    var createdAt: Date
    var host: Seat
    var joiner: Seat?
    var emptySince: Date?
}
