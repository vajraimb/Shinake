import Foundation

/// Official foods for an empty-loadout classic run, and for a duel.
/// The first three bites stay apples. From the fourth bite the board rolls this table.
public enum OfficialMenu {
    public static let mixAfterEaten = 3

    public static let appleScore = 10
    public static let starScore = 40
    public static let chiliScore = 8
    public static let chiliSteps = 6
    public static let chiliFactor = 0.55
    public static let frostScore = 8
    public static let frostSeconds = 5.0
    public static let frostFactor = 1.8
    public static let cherryScore = 12
    public static let cherryGrowth = 3
    public static let shieldScore = 6
    public static let shieldSeconds = 10.0
    public static let mushroomScore = 5
    public static let mushroomReverse = 4.0
    public static let mushroomChop = 3
    public static let boltScore = 15
    public static let boltPull = 2
    public static let boltPullInBattle = 1

    /// Spawn weights. They add up to 100.
    public static let weights: [(FoodKind, Int)] = [
        (.apple, 46),
        (.star, 16),
        (.frost, 12),
        (.chili, 8),
        (.cherry, 8),
        (.shield, 5),
        (.mushroom, 3),
        (.bolt, 2),
    ]

    public static var totalWeight: Int {
        weights.reduce(0) { $0 + $1.1 }
    }

    /// `roll` is in `0 ..< totalWeight`.
    public static func kind(forRoll roll: Int) -> FoodKind {
        var cursor = roll
        for (kind, weight) in weights {
            if cursor < weight { return kind }
            cursor -= weight
        }
        return .apple
    }

    public static func roll(_ rng: inout SplitMix64) -> FoodKind {
        kind(forRoll: rng.int(below: totalWeight))
    }
}

/// How a duel snake is drawn. The host is solid on both phones.
/// The joiner is a shadow on both phones, and only their own screen adds a head ring.
public struct SnakeLook: Equatable {
    public var alpha: Double
    public var ownRing: Bool

    public init(alpha: Double, ownRing: Bool) {
        self.alpha = alpha
        self.ownRing = ownRing
    }
}

public enum DuelRole: String, Codable, Equatable {
    case host
    case joiner
}

public enum DuelLook {
    public static let joinerAlpha = 0.35

    public static func look(of role: DuelRole, on screen: DuelRole) -> SnakeLook {
        switch role {
        case .host:
            return SnakeLook(alpha: 1, ownRing: false)
        case .joiner:
            return SnakeLook(alpha: joinerAlpha, ownRing: screen == .joiner)
        }
    }
}
