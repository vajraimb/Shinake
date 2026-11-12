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
