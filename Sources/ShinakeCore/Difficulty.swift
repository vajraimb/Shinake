import Foundation

/// Desktop Shinake (Odin) numbers, kept here so the phone tuning can be
/// compared without rereading `main.odin`.
///
/// Before: 12³, a move every 0.27s, −0.007s per apple, floor 0.08s,
/// food at least 4 cells away, death on the first wall. The four
/// screen keys only cover the two axes that dominate the camera, so the
/// depth axis requires orbiting the cube with the mouse.
public enum LegacyTuning {
    public static let grid = 12
    public static let startInterval = 0.27
    public static let minInterval = 0.08
    public static let speedStep = 0.007
    public static let minFoodDistance = 4
    public static let graceCharges = 0
    public static let graceWindow = 0.0
}

public enum Difficulty: String, CaseIterable, Codable, Equatable {
    case easy
    case normal
    case hard

    public var profile: DifficultyProfile {
        switch self {
        case .easy: return .easy
        case .normal: return .normal
        case .hard: return .hard
        }
    }
}

/// One place for every number that changes how long a casual player lives.
public struct DifficultyProfile: Equatable {
    public var id: String
    public var grid: Int
    /// Seconds between moves at the start of a run.
    public var startInterval: Double
    /// Fastest the permanent ramp is allowed to get.
    public var minInterval: Double
    /// Subtracted from the interval after every bite.
    public var speedStep: Double
    public var minFoodDistance: Int
    /// Fatal moves that are rewritten into a safe turn. 0 = original rules.
    public var graceCharges: Int
    /// Grace stops working after this many seconds of actual play.
    public var graceWindow: Double
    /// Wall bumps before this many bites are turned aside and do not spend a charge.
    /// Exploratory swipes during the opening lesson stay free.
    public var freeRescuesUntilEaten: Int
    /// While the grace window is open, each bite refills the shield back to `graceCharges`.
    public var refillsGrace: Bool
    /// First foods of a classic run stay on the snake's Z layer, distance 2...4.
    public var planarOpeningFoods: Int
    /// Temporary interval multiplier while a chili is active. Lower is faster.
    public var chiliMultiplier: Double
    /// Coach hints (swipe / depth) stay up on the gentler profiles.
    public var showsGuide: Bool
    public var solids: Set<Vec3>

    public init(
        id: String,
        grid: Int,
        startInterval: Double,
        minInterval: Double,
        speedStep: Double,
        minFoodDistance: Int,
        graceCharges: Int,
        graceWindow: Double,
        freeRescuesUntilEaten: Int,
        refillsGrace: Bool,
        planarOpeningFoods: Int,
        chiliMultiplier: Double,
        showsGuide: Bool,
        solids: Set<Vec3> = []
    ) {
        self.id = id
        self.grid = grid
        self.startInterval = startInterval
        self.minInterval = minInterval
        self.speedStep = speedStep
        self.minFoodDistance = minFoodDistance
        self.graceCharges = graceCharges
        self.graceWindow = graceWindow
        self.freeRescuesUntilEaten = freeRescuesUntilEaten
        self.refillsGrace = refillsGrace
        self.planarOpeningFoods = planarOpeningFoods
        self.chiliMultiplier = chiliMultiplier
        self.showsGuide = showsGuide
        self.solids = solids
    }

    /// Default. Opening tempo is 0.64s, then −0.008s per bite, floor 0.32s.
    /// Six charges for the first 90s. The first three apples are on the snake's
    /// layer, and bumps before those three bites do not spend a charge.
    /// Each later bite inside the window refills the shield to 6. A fatal move
    /// during those 90s is still turned aside after the counter hits zero.
    public static let easy = DifficultyProfile(
        id: "easy",
        grid: 9,
        startInterval: 0.64,
        minInterval: 0.32,
        speedStep: 0.008,
        minFoodDistance: 2,
        graceCharges: 6,
        graceWindow: 90,
        freeRescuesUntilEaten: 3,
        refillsGrace: true,
        planarOpeningFoods: 3,
        chiliMultiplier: 0.78,
        showsGuide: true
    )

    /// The middle setting. One forgiven crash in the first 30s, then real walls.
    /// Floor 0.18s is still well above the desktop game's 0.08s panic speed.
    public static let normal = DifficultyProfile(
        id: "normal",
        grid: 10,
        startInterval: 0.40,
        minInterval: 0.18,
        speedStep: 0.012,
        minFoodDistance: 3,
        graceCharges: 1,
        graceWindow: 30,
        freeRescuesUntilEaten: 0,
        refillsGrace: false,
        planarOpeningFoods: 1,
        chiliMultiplier: 0.70,
        showsGuide: true
    )

    /// Desktop pace on the same 12³ void: 0.27s start, −0.007s per bite, floor 0.08s.
    /// Phone controls are the only mercy — no grace, no coach line.
    public static let hard = DifficultyProfile(
        id: "hard",
        grid: LegacyTuning.grid,
        startInterval: LegacyTuning.startInterval,
        minInterval: LegacyTuning.minInterval,
        speedStep: LegacyTuning.speedStep,
        minFoodDistance: LegacyTuning.minFoodDistance,
        graceCharges: LegacyTuning.graceCharges,
        graceWindow: LegacyTuning.graceWindow,
        freeRescuesUntilEaten: 0,
        refillsGrace: false,
        planarOpeningFoods: 0,
        chiliMultiplier: 0.65,
        showsGuide: false
    )
}

public func moveInterval(eaten: Int, profile: DifficultyProfile) -> Double {
    let raw = profile.startInterval - profile.speedStep * Double(max(0, eaten))
    return max(profile.minInterval, raw)
}
