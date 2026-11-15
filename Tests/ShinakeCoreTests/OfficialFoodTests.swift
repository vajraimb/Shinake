import XCTest
#if canImport(ShinakeCore)
@testable import ShinakeCore
#else
@testable import Shinake
#endif

final class OfficialFoodTests: XCTestCase {
    func testWeightsCoverTheEightFoods() {
        XCTAssertEqual(OfficialMenu.totalWeight, 100)
        XCTAssertEqual(OfficialMenu.weights.count, 8)
        var seen: [FoodKind: Int] = [:]
        for roll in 0..<OfficialMenu.totalWeight {
            seen[OfficialMenu.kind(forRoll: roll), default: 0] += 1
        }
        XCTAssertEqual(seen[.apple], 46)
        XCTAssertEqual(seen[.star], 16)
        XCTAssertEqual(seen[.frost], 12)
        XCTAssertEqual(seen[.chili], 8)
        XCTAssertEqual(seen[.cherry], 8)
        XCTAssertEqual(seen[.shield], 5)
        XCTAssertEqual(seen[.mushroom], 3)
        XCTAssertEqual(seen[.bolt], 2)
        XCTAssertEqual(OfficialMenu.kind(forRoll: 0), .apple)
        XCTAssertEqual(OfficialMenu.kind(forRoll: 45), .apple)
        XCTAssertEqual(OfficialMenu.kind(forRoll: 46), .star)
        XCTAssertEqual(OfficialMenu.kind(forRoll: 99), .bolt)
    }

    func testEmptyLoadoutMixesFromTheFourthBite() {
        let game = SnakeGame(profile: .easy, mode: .classic, seed: 4)
        XCTAssertEqual(game.foods.map(\.kind), [.apple])
        eatApple(game)
        eatApple(game)
        XCTAssertEqual(game.eaten, 2)
        XCTAssertTrue(game.foods.allSatisfy { $0.kind == .apple })
        eatApple(game)
        XCTAssertEqual(game.eaten, 3)
        var mixed = false
        for seed: UInt64 in 1...40 {
            let run = SnakeGame(profile: .hard, mode: .classic, seed: seed)
            eatApple(run)
            eatApple(run)
            eatApple(run)
            if run.foods.contains(where: { $0.kind != .apple }) {
                mixed = true
                break
            }
        }
        XCTAssertTrue(mixed, "the fourth bite should be able to leave the apple")
    }

    func testStarFrostChiliCherryBoltAndMushroom() {
        let star = bite(.star)
        XCTAssertEqual(star.game.score, OfficialMenu.starScore)
        XCTAssertEqual(star.game.bodyAura, .star)

        let frost = bite(.frost)
        let eased = moveInterval(eaten: frost.game.eaten, profile: frost.game.profile)
        XCTAssertEqual(frost.game.currentStepDuration(), eased * OfficialMenu.frostFactor, accuracy: 0.0001)
        XCTAssertEqual(frost.game.bodyAura, .frost)

        let chili = bite(.chili)
        let sped = moveInterval(eaten: chili.game.eaten, profile: chili.game.profile)
        XCTAssertEqual(chili.game.currentStepDuration(), sped * OfficialMenu.chiliFactor, accuracy: 0.0001)
        XCTAssertEqual(chili.game.boostSteps, OfficialMenu.chiliSteps)
        for _ in 0..<OfficialMenu.chiliSteps {
            _ = chili.game.debugStep()
        }
        XCTAssertEqual(chili.game.boostSteps, 0)

        let cherry = bite(.cherry)
        XCTAssertEqual(cherry.game.score, OfficialMenu.cherryScore)
        XCTAssertEqual(cherry.game.length, cherry.before + 1)
        _ = cherry.game.debugStep()
        _ = cherry.game.debugStep()
        XCTAssertEqual(cherry.game.length, cherry.before + OfficialMenu.cherryGrowth)

        let bolt = SnakeGame(profile: .normal, mode: .classic, seed: 2)
        let head = Vec3(5, 5, 5)
        bolt.debugArrange(
            snake: [head, head + .xn, head + .xn + .xn],
            direction: .xp,
            foods: [
                FoodPellet(id: 1, kind: .bolt, position: head + .xp),
                FoodPellet(id: 2, kind: .apple, position: head + .xp + .xp + .xp + .xp + .xp),
            ]
        )
        _ = bolt.debugStep()
        XCTAssertEqual(bolt.score, OfficialMenu.boltScore)
        XCTAssertEqual(bolt.foods[0].position, Vec3(8, 5, 5))

        var body: [Vec3] = []
        for x in 0..<12 { body.append(Vec3(x, 1, 1)) }
        let mushroom = SnakeGame(profile: .hard, mode: .classic, seed: 1)
        let biteAt = Vec3(11, 2, 1)
        mushroom.debugArrange(
            snake: [Vec3(11, 1, 1)] + body.dropLast().reversed(),
            direction: .yp,
            foods: [FoodPellet(id: 4, kind: .mushroom, position: biteAt)]
        )
        let before = mushroom.length
        _ = mushroom.debugStep()
        XCTAssertEqual(mushroom.length, before - 3)
        XCTAssertTrue(mushroom.controlsReversed)
        XCTAssertGreaterThan(mushroom.confuseRemaining, 0)
    }

    func testShieldLastsTenSeconds() {
        let eaten = bite(.shield)
        XCTAssertEqual(eaten.game.shieldRemaining, OfficialMenu.shieldSeconds, accuracy: 0.0001)
        _ = eaten.game.update(dt: 1)
        XCTAssertEqual(eaten.game.shieldRemaining, OfficialMenu.shieldSeconds - 0.05, accuracy: 0.001)
    }

    private func eatApple(_ game: SnakeGame) {
        let head = game.snake[0]
        let next = head + .xp
        guard next.x < game.width else { return }
        game.debugArrange(
            snake: [head, head + .xn, head + .xn + .xn],
            direction: .xp,
            foods: [FoodPellet(id: 1, kind: .apple, position: next)],
            grace: game.graceLeft,
            eaten: game.eaten
        )
        _ = game.debugStep()
    }

    private func bite(_ kind: FoodKind) -> (game: SnakeGame, before: Int) {
        let game = SnakeGame(profile: .normal, mode: .classic, seed: 3)
        let head = Vec3(2, 8, 4)
        let before = 3
        game.debugArrange(
            snake: [head, head + .xn, head + .xn + .xn],
            direction: .xp,
            foods: [FoodPellet(id: 1, kind: kind, position: head + .xp)]
        )
        _ = game.debugStep()
        return (game, before)
    }
}
