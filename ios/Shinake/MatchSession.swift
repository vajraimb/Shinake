import Foundation

/// Friend room on vajra.one. The phone that creates the room is the host and
/// the only one that runs `DuelMatch`. The guest sends inputs and glides the
/// latest snapshot. Game Center is not used for matchmaking.
final class MatchSession {
    weak var model: AppModel?
    private let session: URLSession
    private let defaults: UserDefaults
    private let clientID: String
    private var task: URLSessionWebSocketTask?
    private var clock: Timer?
    private var role: DuelRole?
    private var duel: DuelMatch?
    private var isHost = false
    private var roomCode: String?
    private var resumeToken: String?
    private var inputSeq = 0
    private var appliedGuestSeq = 0
    private var guestBase: DuelSnapshot?
    private var guestReceivedAt = Date()
    private var lastSentTick = -1
    private var lastSentPhase: DuelPhase?
    private var sinceSend = 0.0
    private var lastInbound = Date()
    private var lastPing = Date()
    private var ping = 0
    private var stopped = true
    private var closing = false
    private var settled = false
    private var resumedOnce = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let key = "shinake.roomClientID"
        if let stored = defaults.string(forKey: key), Self.isClientID(stored) {
            clientID = stored
        } else {
            let made = UUID().uuidString.lowercased()
            defaults.set(made, forKey: key)
            clientID = made
        }
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    func begin() {
        model?.showBattleNote("正在开房")
        open(code: nil, token: nil, fresh: true)
    }

    func join(code: String) {
        model?.showBattleNote("正在加入 \(code)")
        open(code: code, token: nil, fresh: true)
    }

    func stop() {
        stopped = true
        send(.leave)
        clock?.invalidate()
        clock = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        role = nil
        duel = nil
        isHost = false
        roomCode = nil
        resumeToken = nil
        guestBase = nil
        inputSeq = 0
        appliedGuestSeq = 0
        lastSentTick = -1
        lastSentPhase = nil
        sinceSend = 0
        resumedOnce = false
        settled = false
    }

    func steer(_ input: ControlInput) {
        guard let role else { return }
        if role == .host {
            duel?.input(.host, input)
        } else {
            inputSeq += 1
            send(.input(seq: inputSeq, control: input))
        }
    }

    /// Host steps the match. Guest only glides the last snapshot forward.
    func tick(dt: Double) -> DuelSnapshot? {
        if role == .host, let duel {
            let snap = duel.update(dt: dt)
            sinceSend += dt
            let phaseChanged = snap.phase != lastSentPhase
            if snap.tick != lastSentTick || sinceSend >= 0.25 || phaseChanged {
                send(.snapshot(snap))
                lastSentTick = snap.tick
                lastSentPhase = snap.phase
                sinceSend = 0
            }
            return snap
        }
        guard let guestBase else { return nil }
        return guestBase.advanced(by: Date().timeIntervalSince(guestReceivedAt))
    }

    private func open(code: String?, token: String?, fresh: Bool) {
        clock?.invalidate()
        let previous = task
        task = nil
        previous?.cancel(with: .goingAway, reason: nil)
        stopped = false
        closing = false
        if fresh {
            settled = false
            role = nil
            duel = nil
            isHost = false
            guestBase = nil
            resumeToken = nil
            resumedOnce = false
            inputSeq = 0
            appliedGuestSeq = 0
            lastSentTick = -1
            lastSentPhase = nil
            sinceSend = 0
            roomCode = code
        }
        guard let url = OnlineLinks.webSocketURL() else {
            model?.battleFailed("房间地址不对")
            return
        }
        let hello = RoomHello(clientID: clientID, roomCode: code ?? roomCode, resumeToken: fresh ? nil : token)
        let socket = session.webSocketTask(with: url)
        task = socket
        lastInbound = Date()
        lastPing = Date()
        socket.resume()
        send(.hello(hello))
        armClock()
        read(socket)
    }

    private func armClock() {
        clock?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.housekeep()
        }
        clock = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func housekeep() {
        guard task != nil, !stopped else { return }
        if Date().timeIntervalSince(lastInbound) >= RoomProtocol.heartbeatTimeout {
            task?.cancel(with: .goingAway, reason: nil)
            socketClosed()
            return
        }
        if Date().timeIntervalSince(lastPing) >= RoomProtocol.heartbeatInterval {
            lastPing = Date()
            ping &+= 1
            send(.ping(ping))
        }
    }

    private func read(_ socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.task === socket, !self.stopped else { return }
                switch result {
                case .failure:
                    self.socketClosed()
                case .success(let message):
                    self.lastInbound = Date()
                    if case .string(let text) = message {
                        self.handle(text)
                    }
                    if self.task === socket, !self.stopped {
                        self.read(socket)
                    }
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(RoomServerMessage.self, from: data) else { return }
        switch message {
        case .welcome(let card):
            resumeToken = card.resumeToken
            roomCode = card.roomCode
            isHost = card.host
            if card.host {
                if duel == nil, let invite = URL(string: card.inviteURL) {
                    model?.battleLobby(code: card.roomCode, invite: invite)
                }
            } else if role == nil {
                role = .joiner
                model?.showBattleNote("正在同步")
            }
        case .peer(let peer):
            guard isHost else { return }
            if peer.connected {
                if duel == nil {
                    startHostMatch()
                } else {
                    duel?.remoteReturned()
                }
            } else {
                duel?.remoteDropped(.joiner)
            }
        case .input(let seq, let control):
            guard role == .host, seq > appliedGuestSeq else { return }
            appliedGuestSeq = seq
            duel?.input(.joiner, control)
        case .snapshot(let snap):
            guard !isHost else { return }
            role = .joiner
            accept(snap)
            if model?.inBattle != true {
                model?.battleDidConnect(role: .joiner, snapshot: snap)
            }
        case .rejected(let reason):
            model?.battleFailed(reason)
        case .ended(let reason):
            settled = true
            if reason == "hostLeft" {
                finishGuest(note: "主机断开")
            } else if reason == "expired" {
                model?.battleFailed("房间已过期")
            } else {
                model?.battleFailed("对战结束了")
            }
        case .pong:
            break
        }
    }

    private func startHostMatch() {
        var seed = UInt64(Date().timeIntervalSince1970 * 1000)
        if seed == 0 { seed = 1 }
        let match = DuelMatch(seed: seed)
        duel = match
        role = .host
        let opening = match.snapshot()
        send(.snapshot(opening))
        lastSentTick = opening.tick
        lastSentPhase = opening.phase
        sinceSend = 0
        model?.battleDidConnect(role: .host, snapshot: opening)
    }

    private func finishGuest(note: String) {
        guard var snap = guestBase else {
            model?.battleFailed(note)
            return
        }
        snap.phase = .finished
        snap.reason = .hostLeft
        snap.winner = nil
        accept(snap)
        if model?.inBattle != true {
            model?.battleDidConnect(role: .joiner, snapshot: snap)
        }
    }

    private func accept(_ snap: DuelSnapshot) {
        if let current = guestBase, snap.tick < current.tick, snap.phase == current.phase {
            return
        }
        guestBase = snap
        guestReceivedAt = Date()
    }

    private func socketClosed() {
        guard !stopped, !closing, !settled else { return }
        if !isHost, let code = roomCode, let token = resumeToken, !resumedOnce {
            resumedOnce = true
            open(code: code, token: token, fresh: false)
            return
        }
        closing = true
        model?.battleFailed("连接断了")
    }

    private func send(_ message: RoomClientMessage) {
        guard let task,
              let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private static func isClientID(_ raw: String) -> Bool {
        guard (8...RoomProtocol.maxClientIDLength).contains(raw.count) else { return false }
        return raw.allSatisfy { $0.isHexDigit || $0 == "-" }
    }
}
