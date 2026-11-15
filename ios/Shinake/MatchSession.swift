import GameKit
import UIKit

/// Game Center match for two phones. The smaller `gamePlayerID` is the host
/// and the only one that runs `DuelMatch`. The guest sends inputs and glides
/// the latest snapshot locally.
final class MatchSession: NSObject, GKMatchDelegate, GKMatchmakerViewControllerDelegate, GKLocalPlayerListener {
    weak var model: AppModel?
    private var match: GKMatch?
    private var maker: GKMatchmakerViewController?
    private var localID = ""
    private var remoteID: String?
    private var role: DuelRole?
    private var duel: DuelMatch?
    private var inputSeq = 0
    private var appliedGuestSeq = 0
    private var guestBase: DuelSnapshot?
    private var guestReceivedAt = Date()
    private var pendingSnapshot: DuelSnapshot?
    private var lastSentTick = -1
    private var lastSentPhase: DuelPhase?
    private var sinceSend = 0.0
    private var looking = false
    private var registered = false

    /// So an accepted Game Center invite can open the matchmaker after login.
    func listenIfAuthenticated() {
        guard GKLocalPlayer.local.isAuthenticated else { return }
        registerInviteListener()
    }

    func begin() {
        looking = true
        model?.showBattleNote("正在连接 Game Center")
        let player = GKLocalPlayer.local
        if player.isAuthenticated {
            presentMaker()
            return
        }
        player.authenticateHandler = { [weak self] viewController, _ in
            DispatchQueue.main.async {
                guard let self, self.looking else { return }
                if let viewController {
                    self.present(viewController)
                    return
                }
                if GKLocalPlayer.local.isAuthenticated {
                    self.presentMaker()
                } else {
                    self.looking = false
                    self.model?.battleFailed("Game Center 没登录")
                }
            }
        }
    }

    func stop() {
        looking = false
        match?.delegate = nil
        match?.disconnect()
        match = nil
        maker?.dismiss(animated: true)
        maker = nil
        role = nil
        duel = nil
        remoteID = nil
        guestBase = nil
        pendingSnapshot = nil
        inputSeq = 0
        appliedGuestSeq = 0
        lastSentTick = -1
        lastSentPhase = nil
        sinceSend = 0
    }

    func steer(_ input: ControlInput) {
        guard let role else { return }
        if role == .host {
            duel?.input(.host, input)
        } else {
            inputSeq += 1
            send(.input(seq: inputSeq, control: input), reliable: true)
        }
    }

    /// Host steps the match. Guest only glides the last snapshot forward.
    func tick(dt: Double) -> DuelSnapshot? {
        if role == .host, let duel {
            let snap = duel.update(dt: dt)
            sinceSend += dt
            let phaseChanged = snap.phase != lastSentPhase
            if snap.tick != lastSentTick || sinceSend >= 0.25 || phaseChanged {
                send(.snapshot(snap), reliable: phaseChanged)
                lastSentTick = snap.tick
                lastSentPhase = snap.phase
                sinceSend = 0
            }
            return snap
        }
        guard let guestBase else { return nil }
        return guestBase.advanced(by: Date().timeIntervalSince(guestReceivedAt))
    }

    private func presentMaker() {
        guard looking, maker == nil, match == nil else { return }
        registerInviteListener()
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = 2
        request.inviteMessage = "来一局食蛇"
        guard let controller = GKMatchmakerViewController(matchRequest: request) else {
            looking = false
            model?.battleFailed("对战界面打不开")
            return
        }
        controller.matchmakerDelegate = self
        maker = controller
        model?.showBattleNote("寻找对手")
        present(controller)
    }

    private func registerInviteListener() {
        guard !registered else { return }
        registered = true
        GKLocalPlayer.local.register(self)
    }

    func player(_ player: GKPlayer, didAccept invite: GKInvite) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.looking = true
            self.maker?.dismiss(animated: false)
            guard let controller = GKMatchmakerViewController(invite: invite) else {
                self.model?.battleFailed("邀请打不开")
                return
            }
            controller.matchmakerDelegate = self
            self.maker = controller
            self.present(controller)
        }
    }

    func matchmakerViewControllerWasCancelled(_ viewController: GKMatchmakerViewController) {
        let stillSearching = looking
        looking = false
        maker = nil
        viewController.dismiss(animated: true)
        if stillSearching {
            model?.battleSearchEnded()
        }
    }

    func matchmakerViewController(_ viewController: GKMatchmakerViewController, didFailWithError error: Error) {
        looking = false
        maker = nil
        viewController.dismiss(animated: true)
        model?.battleFailed("没找到对手")
    }

    func matchmakerViewController(_ viewController: GKMatchmakerViewController, didFind match: GKMatch) {
        viewController.dismiss(animated: true)
        maker = nil
        looking = false
        adopt(match)
    }

    private func adopt(_ match: GKMatch) {
        self.match = match
        match.delegate = self
        localID = GKLocalPlayer.local.gamePlayerID
        if localID.isEmpty {
            localID = GKLocalPlayer.local.teamPlayerID
        }
        sendHello()
        for player in match.players {
            noteRemote(player.gamePlayerID)
        }
    }

    private func sendHello() {
        guard !localID.isEmpty else {
            model?.battleFailed("Game Center 身份是空的")
            return
        }
        send(.hello(localID), reliable: true)
    }

    func match(_ match: GKMatch, player: GKPlayer, didChange state: GKPlayerConnectionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if state == .connected {
                self.sendHello()
                let remote = player.gamePlayerID.isEmpty ? player.teamPlayerID : player.gamePlayerID
                self.noteRemote(remote)
            } else if state == .disconnected {
                self.remoteWentAway()
            }
        }
    }

    func match(_ match: GKMatch, didReceive data: Data, fromRemotePlayer player: GKPlayer) {
        guard let wire = DuelWireCodec.decode(data) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.receive(wire, fallbackID: player.gamePlayerID)
        }
    }

    func match(_ match: GKMatch, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.remoteWentAway()
        }
    }

    private func receive(_ wire: DuelWire, fallbackID: String) {
        switch wire {
        case .hello(let id):
            noteRemote(id.isEmpty ? fallbackID : id)
        case .input(let seq, let control):
            guard role == .host, seq > appliedGuestSeq else { return }
            appliedGuestSeq = seq
            duel?.input(.joiner, control)
        case .snapshot(let snap):
            guard role != .host else { return }
            if role == nil {
                pendingSnapshot = snap
                return
            }
            accept(snap)
        }
    }

    private func noteRemote(_ remote: String) {
        guard remoteID == nil, !remote.isEmpty else { return }
        guard !localID.isEmpty, localID != remote else {
            if localID == remote {
                model?.battleFailed("两台机器的 Game Center 身份一样")
            }
            return
        }
        remoteID = remote
        let hosting = localID < remote
        role = hosting ? .host : .joiner
        var opening: DuelSnapshot?
        if hosting {
            var seed = UInt64(Date().timeIntervalSince1970 * 1000)
            if seed == 0 { seed = 1 }
            duel = DuelMatch(seed: seed)
            opening = duel?.snapshot()
            if let opening {
                send(.snapshot(opening), reliable: true)
                lastSentTick = opening.tick
                lastSentPhase = opening.phase
            }
        } else if let pendingSnapshot {
            accept(pendingSnapshot)
            opening = pendingSnapshot
            self.pendingSnapshot = nil
        }
        model?.battleDidConnect(role: role ?? .joiner, snapshot: opening)
    }

    private func accept(_ snap: DuelSnapshot) {
        if let current = guestBase, snap.tick < current.tick, snap.phase == current.phase {
            return
        }
        guestBase = snap
        guestReceivedAt = Date()
    }

    private func remoteWentAway() {
        guard match != nil || role != nil else { return }
        if role == .host {
            duel?.remoteDropped(.joiner)
            return
        }
        if role == .joiner {
            if var snap = guestBase {
                snap.phase = .finished
                snap.reason = .hostLeft
                snap.winner = nil
                accept(snap)
            } else {
                model?.battleFailed("主机断开")
            }
            match?.disconnect()
            match = nil
            return
        }
        model?.battleFailed("对手离开了")
    }

    /// Unreliable while the payload stays under Game Center's small datagram cap.
    private func send(_ wire: DuelWire, reliable: Bool) {
        guard let match, let data = try? DuelWireCodec.encode(wire) else { return }
        let mode: GKMatch.SendDataMode = (reliable || data.count > 900) ? .reliable : .unreliable
        try? match.sendData(toAllPlayers: data, with: mode)
    }

    private func present(_ controller: UIViewController) {
        guard let root = Self.topViewController() else { return }
        if let presented = root.presentedViewController {
            presented.dismiss(animated: false) {
                root.present(controller, animated: true)
            }
        } else {
            root.present(controller, animated: true)
        }
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var controller = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}
