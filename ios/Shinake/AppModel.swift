import SwiftUI

enum ControlScheme: String, CaseIterable, Identifiable {
    case swipe
    case buttons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .swipe: return "滑动"
        case .buttons: return "按键"
        }
    }
}

enum AppScreen: Equatable {
    case title
    case lab
    case play
}

enum TutorialIntent: Equatable {
    case gate(PlayMode)
    case review
}

/// Owns the run, the saved settings, and the phone-only juice (sound, haptics).
/// The cube itself is `SnakeGame`; this type only translates that into a screen.
final class AppModel: ObservableObject {
    @Published var screen: AppScreen = .title
    @Published var difficulty: Difficulty {
        didSet { defaults.set(difficulty.rawValue, forKey: Key.difficulty) }
    }
    @Published var scheme: ControlScheme {
        didSet { defaults.set(scheme.rawValue, forKey: Key.scheme) }
    }
    @Published var soundOn: Bool {
        didSet {
            defaults.set(soundOn, forKey: Key.sound)
            sound.enabled = soundOn
        }
    }
    @Published var hapticsOn: Bool {
        didSet {
            defaults.set(hapticsOn, forKey: Key.haptics)
            haptics.enabled = hapticsOn
        }
    }
    @Published var hudTick = 0
    @Published var toast: String?
    @Published var tutorial: TutorialIntent?
    @Published var showSettings = false
    /// Off by default so the clock stays visible. The player can hide it.
    @Published var statusBarHidden: Bool {
        didSet { defaults.set(statusBarHidden, forKey: Key.statusBar) }
    }
    /// Depth is always the two-finger pinch: spread is 深入, pinch-in is 拉近.
    @Published private(set) var runWasRecord = false
    /// Set while a friend-room match is on screen. Nil means solo.
    @Published private(set) var battleRole: DuelRole?
    @Published private(set) var battleSnapshot: DuelSnapshot?
    /// Title-screen line while the room is opening, or a short failure.
    @Published var battleNote: String?
    /// https invite shown on the title screen until the friend joins.
    @Published private(set) var battleInviteURL: URL?
    let battle = MatchSession()
    private var battleClock = -1

    let library: FeedLibrary
    private(set) var game: SnakeGame
    private(set) var shake: Double = 0
    private var toastSerial = 0
    private var seenToken = 0
    private var loggedFeedResult = false
    private let defaults: UserDefaults
    private let sound = SoundBank()
    private let haptics = HapticBank()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        library = FeedLibrary(defaults: defaults)
        let storedDifficulty = Difficulty(rawValue: defaults.string(forKey: Key.difficulty) ?? "") ?? .easy
        let storedScheme = ControlScheme(rawValue: defaults.string(forKey: Key.scheme) ?? "") ?? .swipe
        let storedSound = defaults.object(forKey: Key.sound) as? Bool ?? true
        let storedHaptics = defaults.object(forKey: Key.haptics) as? Bool ?? true
        let storedStatusBar = defaults.object(forKey: Key.statusBar) as? Bool ?? false
        difficulty = storedDifficulty
        scheme = storedScheme
        soundOn = storedSound
        hapticsOn = storedHaptics
        statusBarHidden = storedStatusBar
        sound.enabled = storedSound
        haptics.enabled = storedHaptics
        let armed = AppModel.classicLoadout(from: library)
        game = SnakeGame(
            profile: storedDifficulty.profile,
            mode: .classic,
            seed: AppModel.seed(),
            best: defaults.integer(forKey: ScoreBoard.localBestKey(
                difficulty: storedDifficulty,
                separateLoadout: !armed.isEmpty
            )),
            loadout: armed
        )
        seenToken = game.uiToken
        battle.model = self
    }

    var inBattle: Bool { battleRole != nil }

    var duelRender: DuelRender? {
        guard let battleSnapshot, let battleRole else { return nil }
        return DuelRender(snapshot: battleSnapshot, screen: battleRole)
    }

    func requestBattle() {
        battleInviteURL = nil
        battle.model = self
        battle.begin()
    }

    func openInvite(_ url: URL) {
        guard let code = OnlineLinks.roomCode(from: url), !inBattle else { return }
        battleInviteURL = nil
        battle.stop()
        battle.model = self
        battle.join(code: code)
    }

    func battleLobby(code: String, invite: URL) {
        battleInviteURL = invite
        battleNote = "房间 \(code)"
        hudTick += 1
    }

    func battleSearchEnded() {
        guard !inBattle else { return }
        battleNote = nil
        hudTick += 1
    }

    func cancelBattle() {
        battle.stop()
        battleInviteURL = nil
        battleNote = nil
        hudTick += 1
    }

    func leaveBattle() {
        battle.stop()
        battleInviteURL = nil
        battleRole = nil
        battleSnapshot = nil
        battleNote = nil
        battleClock = -1
        screen = .title
        hudTick += 1
    }

    func showBattleNote(_ message: String) {
        battleNote = message
        hudTick += 1
    }

    func battleDidConnect(role: DuelRole, snapshot: DuelSnapshot?) {
        battleRole = role
        battleSnapshot = snapshot
        battleInviteURL = nil
        battleNote = nil
        battleClock = snapshot.map { Int($0.timeLeft) } ?? -1
        screen = .play
        hudTick += 1
        sound.play("ui")
    }

    func battleFailed(_ message: String) {
        battle.stop()
        battleInviteURL = nil
        battleRole = nil
        battleSnapshot = nil
        battleNote = message
        battleClock = -1
        if screen == .play { screen = .title }
        hudTick += 1
    }

    var showGuide: Bool {
        game.mode == .classic && game.profile.showsGuide && game.eaten < 6 && game.phase != .over
    }

    var bestForSelected: Int {
        defaults.integer(forKey: ScoreBoard.localBestKey(difficulty: difficulty, separateLoadout: false))
    }

    func prepareFeedback() {
        sound.prepare()
        haptics.prepare()
        battle.model = self
    }

    func openLab() {
        screen = .lab
        hudTick += 1
    }

    func requestPlay(_ mode: PlayMode) {
        if defaults.bool(forKey: Key.tutorial) {
            begin(mode)
        } else {
            tutorial = .gate(mode)
        }
    }

    func reviewTutorial() {
        showSettings = false
        tutorial = .review
    }

    func finishTutorial(startPlaying: Bool) {
        defaults.set(true, forKey: Key.tutorial)
        let intent = tutorial
        tutorial = nil
        guard startPlaying, case .gate(let mode) = intent else { return }
        begin(mode)
    }

    func begin(_ mode: PlayMode) {
        runWasRecord = false
        loggedFeedResult = false
        shake = 0
        let armed = mode == .classic ? AppModel.classicLoadout(from: library) : []
        game = SnakeGame(
            profile: difficulty.profile,
            mode: mode,
            seed: AppModel.seed(),
            best: defaults.integer(forKey: ScoreBoard.localBestKey(
                difficulty: difficulty,
                separateLoadout: !armed.isEmpty
            )),
            loadout: armed
        )
        seenToken = game.uiToken
        if mode == .feeding, let first = library.loadoutDesigns.first {
            game.serve(first)
        }
        screen = .play
        hudTick += 1
        sound.play("ui")
    }

    func restart() {
        recordFeedingIfLeaving()
        begin(game.mode)
    }

    func backToTitle() {
        recordFeedingIfLeaving()
        screen = game.mode == .feeding ? .lab : .title
        hudTick += 1
    }

    /// A feeding score counts when the run ends, including pause → 回实验室
    /// and 重新开始. Death still records from the frame loop; the flag stops a second write.
    private func recordFeedingIfLeaving() {
        guard game.mode == .feeding, !loggedFeedResult else { return }
        loggedFeedResult = true
        library.finishRun(score: game.score, recipes: game.eatenRecipes)
    }

    func pause() {
        game.pause()
        refresh()
    }

    func resume() {
        game.resume()
        sound.play("ui")
        refresh()
    }

    func steer(_ input: ControlInput) {
        if inBattle {
            battle.steer(input)
            haptics.tap()
            return
        }
        let before = game.uiToken
        game.input(input)
        if game.uiToken != before {
            haptics.tap()
            refresh()
        }
    }

    func cast(_ kind: FoodKind) {
        if game.foods.count >= 3 {
            showToast("场上已经有三样了")
            haptics.tap()
            return
        }
        if game.cast(kind) {
            showToast(Copy.flavor(kind))
            haptics.tap()
            sound.play("ui")
        } else {
            showToast("这一下没放进去")
        }
        refresh()
    }

    func cast(_ design: FeedDesign) {
        if game.foods.count >= 3 {
            showToast("场上已经有三样了")
            haptics.tap()
            return
        }
        if game.cast(design) {
            showToast("投出「\(design.name)」")
            haptics.tap()
            sound.play("ui")
        } else {
            showToast("这一下没放进去")
        }
        refresh()
    }

    func toggleManual() {
        game.setManualDrive(!game.manualDrive)
        haptics.tap()
        sound.play("ui")
        showToast(game.manualDrive ? "方向盘给你了" : "交给 AI 了")
        refresh()
    }

    /// Called from the display link. Does not publish unless the HUD changed.
    func advance(dt: Double) -> RenderSnapshot {
        if inBattle {
            advanceBattle(dt: dt)
            return game.snapshot()
        }
        let events = game.update(dt: dt)
        if shake > 0 {
            shake = max(0, shake - dt / 0.42)
        }
        for event in events {
            respond(to: event)
        }
        let bestKey = ScoreBoard.localBestKey(
            difficulty: game.profile.idDifficulty,
            separateLoadout: game.recordsSeparately
        )
        if game.best > defaults.integer(forKey: bestKey) {
            defaults.set(game.best, forKey: bestKey)
        }
        if game.uiToken != seenToken {
            seenToken = game.uiToken
            hudTick += 1
        }
        if !loggedFeedResult && game.mode == .feeding && (game.phase == .over || game.phase == .won) {
            loggedFeedResult = true
            library.finishRun(score: game.score, recipes: game.eatenRecipes)
        }
        return game.snapshot()
    }

    private func advanceBattle(dt: Double) {
        guard let snap = battle.tick(dt: dt) else { return }
        let clock = Int(snap.timeLeft)
        let previous = battleSnapshot
        let changed = previous == nil
            || snap.tick != previous?.tick
            || snap.phase != previous?.phase
            || snap.reason != previous?.reason
            || snap.winner != previous?.winner
            || snap.host.score != previous?.host.score
            || snap.joiner.score != previous?.joiner.score
            || snap.host.alive != previous?.host.alive
            || snap.joiner.alive != previous?.joiner.alive
            || snap.host.aura != previous?.host.aura
            || snap.joiner.aura != previous?.joiner.aura
            || clock != battleClock
        if let role = battleRole, let previous {
            let was = role == .host ? previous.host : previous.joiner
            let now = role == .host ? snap.host : snap.joiner
            if now.score > was.score {
                haptics.eat()
                sound.play("eat")
            }
            if was.alive && !now.alive {
                shake = 1
                haptics.die()
                sound.play("die")
            }
            if previous.phase != .finished && snap.phase == .finished {
                if snap.winner == role {
                    haptics.record()
                    sound.play("record")
                }
            }
        }
        if shake > 0 {
            shake = max(0, shake - dt / 0.42)
        }
        battleSnapshot = snap
        battleClock = clock
        if changed { hudTick += 1 }
    }

    private func respond(to event: GameEvent) {
        switch event {
        case .recipeEaten(let id):
            library.noteEaten(id)
        case .ate:
            haptics.eat()
            sound.play("eat")
        case .graceUsed:
            haptics.save()
            sound.play("save")
        case .shielded:
            haptics.save()
            sound.play("save")
            showToast("护盾挡住了")
        case .died:
            shake = 1
            haptics.die()
            sound.play("die")
            refresh()
        case .won:
            haptics.record()
            sound.play("record")
            refresh()
        case .newBest:
            runWasRecord = true
            haptics.record()
            sound.play("record")
            showToast("新纪录")
        case .turned, .castFull:
            break
        }
    }

    private func refresh() {
        seenToken = game.uiToken
        hudTick += 1
    }

    private func showToast(_ text: String) {
        toastSerial += 1
        toast = text
        let serial = toastSerial
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.toastSerial == serial else { return }
            self.toast = nil
        }
    }

    private static func seed() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000) ^ 0x9E3779B97F4A7C15
    }
}

extension AppModel {
    /// Designs the title's 开始游戏 may spawn. Deleted and over-budget cards are left out.
    static func classicLoadout(from library: FeedLibrary) -> [FeedDesign] {
        Array(library.loadoutDesigns.filter(\.withinBudget).prefix(3))
    }
}

private enum Key {
    static let sound = "shinake.sound"
    static let haptics = "shinake.haptics"
    static let scheme = "shinake.scheme"
    static let difficulty = "shinake.difficulty"
    static let tutorial = "shinake.tutorialSeen"
    static let statusBar = "shinake.statusBarHidden"
}

private extension DifficultyProfile {
    /// Maps a profile id back to the saved-score bucket. Custom test profiles
    /// fall through to easy, which the app never constructs.
    var idDifficulty: Difficulty {
        switch id {
        case "normal": return .normal
        case "hard": return .hard
        default: return .easy
        }
    }
}
