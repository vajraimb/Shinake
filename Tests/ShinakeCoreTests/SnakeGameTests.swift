import XCTest
#if canImport(ShinakeCore)
@testable import ShinakeCore
#else
@testable import Shinake
#endif

final class SnakeGameTests: XCTestCase {
    private func classic(_ difficulty: Difficulty = .easy, seed: UInt64 = 7, best: Int = 0) -> SnakeGame {
        SnakeGame(profile: difficulty.profile, mode: .classic, seed: seed, best: best)
    }

    func testSnakeWaitsForTheFirstSwipe() {
        let game = classic()
        XCTAssertEqual(game.phase, .ready)
        XCTAssertEqual(game.coachCue, .swipeToStart)
        let head = game.snake[0]
        _ = game.update(dt: 2)
        XCTAssertEqual(game.snake[0], head)
        XCTAssertEqual(game.elapsed, 0, accuracy: 0.0001)

        game.input(.screen(.right))
        XCTAssertEqual(game.phase, .playing)
        _ = game.update(dt: 1.0 / 60.0)
        XCTAssertEqual(game.snake[0].x, head.x + 1)
    }

    func testReverseSwipeIsIgnoredAndDoesNotStartTheRun() {
        let game = classic()
        game.input(.screen(.left))
        XCTAssertEqual(game.phase, .ready)
        XCTAssertFalse(game.started)
    }

    func testQueueDropsOneEightiesAndCapsAtTwo() {
        let game = classic()
        game.input(.screen(.up))
        game.input(.screen(.down)) // 180° against the queued up — dropped
        game.input(.depthIn)
        game.input(.screen(.right)) // third distinct request — dropped
        _ = game.debugStep()
        XCTAssertEqual(game.direction, .yp)
        _ = game.debugStep()
        XCTAssertEqual(game.direction, .zn)
        _ = game.debugStep()
        XCTAssertEqual(game.direction, .zn)
    }

    func testEatingGrowsScoresAndSpeedsUp() {
        let game = classic(seed: 3)
        let food = Vec3(5, 4, 4)
        game.debugArrange(
            snake: [food + .xn, food + .xn + .xn, food + .xn + .xn + .xn],
            direction: .xp,
            foods: [FoodPellet(id: 1, kind: .apple, position: food)]
        )
        let length = game.length
        let events = game.debugStep()
        XCTAssertTrue(events.contains(.ate(.apple)))
        XCTAssertEqual(game.score, 10)
        XCTAssertEqual(game.length, length + 1)
        XCTAssertEqual(game.eaten, 1)
        XCTAssertEqual(game.currentStepDuration(), 0.632, accuracy: 0.0001)
        XCTAssertFalse(game.snake.contains(food) && game.foods.contains { $0.position == food })
        XCTAssertFalse(game.foods.isEmpty)
        XCTAssertFalse(game.snake.contains(game.foods[0].position))
    }

    func testSteppingOntoTheTailIsSafeUntilTheSnakeIsGrowing() {
        let game = classic(.hard)
        // Length 3 moving +X. Arrange a loop where the next cell is the tail
        // and we are not growing: the tail vacates, so this lives.
        let head = Vec3(2, 2, 2)
        game.debugArrange(
            snake: [head, head + .yn, head + .yn + .xn],
            direction: .xn,
            foods: [FoodPellet(id: 1, kind: .apple, position: Vec3(0, 0, 0))]
        )
        // Next cell would be (1, 2, 2), which is not the tail. Build the real case:
        // head (2,2,2), neck (2,3,2), tail (1,2,2), direction -X. Tail is the next cell.
        game.debugArrange(
            snake: [Vec3(2, 2, 2), Vec3(2, 3, 2), Vec3(1, 2, 2)],
            direction: .xn,
            foods: [FoodPellet(id: 1, kind: .apple, position: Vec3(0, 0, 1))]
        )
        let events = game.debugStep()
        XCTAssertFalse(events.contains(.died))
        XCTAssertEqual(game.phase, .playing)
        XCTAssertEqual(game.snake[0], Vec3(1, 2, 2))
    }

    func testGrowingIntoTheTailDiesOnHard() {
        let game = classic(.hard)
        game.debugArrange(
            snake: [Vec3(2, 2, 2), Vec3(2, 3, 2), Vec3(1, 2, 2)],
            direction: .xn,
            foods: [FoodPellet(id: 1, kind: .apple, position: Vec3(0, 0, 1))],
            pendingGrowth: 1
        )
        let events = game.debugStep()
        XCTAssertTrue(events.contains(.died))
        XCTAssertEqual(game.phase, .over)
        XCTAssertEqual(game.deathCause, .ownBody)
    }

    func testWallKillsImmediatelyOnHard() {
        let game = classic(.hard)
        let edge = game.grid - 1
        game.debugArrange(
            snake: [Vec3(edge, 6, 6), Vec3(edge - 1, 6, 6), Vec3(edge - 2, 6, 6)],
            direction: .xp,
            foods: [FoodPellet(id: 1, kind: .apple, position: Vec3(0, 0, 0))]
        )
        let events = game.debugStep()
        XCTAssertTrue(events.contains(.died))
        XCTAssertEqual(game.snake[0].x, edge)
        XCTAssertEqual(game.deathCause, .wall)
    }

    func testEasyGraceTurnsAWallIntoASave() {
        let game = classic(.easy)
        let edge = game.grid - 1
        game.debugArrange(
            snake: [Vec3(edge, 4, 4), Vec3(edge - 1, 4, 4), Vec3(edge - 2, 4, 4)],
            direction: .xp,
            foods: [FoodPellet(id: 1, kind: .apple, position: Vec3(4, 4, 2))]
        )
        let events = game.debugStep()
        XCTAssertFalse(events.contains(.died))
        XCTAssertEqual(game.phase, .playing)
        // The first three apples are a free lesson. The charge stays.
        XCTAssertEqual(game.graceLeft, 6)
        XCTAssertTrue(events.contains(.graceUsed(remaining: 6)))
        XCTAssertEqual(game.coachCue, .practiceSaved)
        XCTAssertNotEqual(game.direction, .xp)
    }

    func testGraceIsSpentOnlyAfterTheOpeningApples() {
        let game = classic(.easy)
        let edge = game.grid - 1
        game.debugArrange(
            snake: [Vec3(edge, 4, 4), Vec3(edge - 1, 4, 4), Vec3(edge - 2, 4, 4)],
            direction: .xp,
            foods: [FoodPellet(id: 1, kind: .apple, position: Vec3(4, 4, 2))],
            grace: 6,
            eaten: 3
        )
        let events = game.debugStep()
        XCTAssertFalse(events.contains(.died))
        XCTAssertEqual(game.graceLeft, 5)
        XCTAssertTrue(events.contains(.graceUsed(remaining: 5)))
        XCTAssertEqual(game.coachCue, .graceSaved(left: 5))
    }

    func testEatingRestoresASpentChargeOnEasy() {
        let game = classic(.easy)
        let food = Vec3(4, 4, 4)
        game.debugArrange(
            snake: [food + .xn, food + .xn + .xn, food + .xn + .xn + .xn],
            direction: .xp,
            foods: [FoodPellet(id: 1, kind: .apple, position: food)],
            grace: 2,
            eaten: 3
        )
        _ = game.debugStep()
        XCTAssertEqual(game.graceLeft, 6)
    }

    func testGraceExpiresWithTheClock() {
        let game = classic(.easy)
        let edge = game.grid - 1
        game.debugArrange(
            snake: [Vec3(edge, 4, 4), Vec3(edge - 1, 4, 4), Vec3(edge - 2, 4, 4)],
            direction: .xp,
            foods: [FoodPellet(id: 1, kind: .apple, position: Vec3(1, 1, 1))],
            grace: 4,
            eaten: 3
        )
        game.debugSetElapsed(90.01)
        let events = game.debugStep()
        XCTAssertTrue(events.contains(.died))
        XCTAssertEqual(game.deathCause, .wall)
    }

    func testGraceCannotSaveASealedHead() {
        // Head sits on the +X wall. The four side cells are solid, and reversing
        // would enter the neck, so every rescue is fatal.
        var wall = DifficultyProfile.easy
        let boxedHead = Vec3(8, 4, 4)
        wall.solids = [boxedHead + .yp, boxedHead + .yn, boxedHead + .zp, boxedHead + .zn]
        let sealed = SnakeGame(profile: wall, mode: .classic, seed: 1)
        sealed.debugArrange(
            snake: [boxedHead, boxedHead + .xn, boxedHead + .xn + .xn],
            direction: .xp,
            foods: [FoodPellet(id: 9, kind: .apple, position: Vec3(1, 1, 1))],
            grace: 4
        )
        let events = sealed.debugStep()
        XCTAssertTrue(events.contains(.died))
        XCTAssertEqual(sealed.graceLeft, 4)
    }

    func testOpeningAppleStaysOnTheSnakesLayer() {
        for seed: UInt64 in [1, 2, 9, 42, 99] {
            let game = classic(.easy, seed: seed)
            let food = game.foods[0]
            XCTAssertEqual(food.position.z, game.snake[0].z, "seed \(seed)")
            let distance = food.position.manhattan(to: game.snake[0])
            XCTAssertGreaterThanOrEqual(distance, 2, "seed \(seed)")
            XCTAssertLessThanOrEqual(distance, 4, "seed \(seed)")
            XCTAssertFalse(game.snake.contains(food.position))
        }
    }

    func testHardFoodRespectsTheOldDistance() {
        for seed: UInt64 in [1, 4, 11, 20] {
            let game = classic(.hard, seed: seed)
            let distance = game.foods[0].position.manhattan(to: game.snake[0])
            XCTAssertGreaterThanOrEqual(distance, LegacyTuning.minFoodDistance, "seed \(seed)")
            XCTAssertFalse(game.snake.contains(game.foods[0].position))
        }
    }

    func testPauseFreezesTheSnake() {
        let game = classic()
        game.input(.screen(.up))
        _ = game.update(dt: 0.2)
        let head = game.snake[0]
        let elapsed = game.elapsed
        game.pause()
        XCTAssertEqual(game.phase, .paused)
        _ = game.update(dt: 5)
        XCTAssertEqual(game.snake[0], head)
        XCTAssertEqual(game.elapsed, elapsed, accuracy: 0.0001)
        game.resume()
        XCTAssertEqual(game.phase, .playing)
    }

    func testRestartKeepsTheBestAndResetsTheRun() {
        let game = classic(best: 40)
        game.input(.screen(.up))
        _ = game.debugStep()
        game.restart()
        XCTAssertEqual(game.score, 0)
        XCTAssertEqual(game.best, 40)
        XCTAssertEqual(game.phase, .ready)
        XCTAssertEqual(game.length, 3)
        XCTAssertEqual(game.graceLeft, 6)
    }

    func testNewBestFiresOnlyWhenBeatingARealRecord() {
        let fresh = classic(best: 0)
        let food = fresh.foods[0].position
        fresh.debugArrange(
            snake: [food + .xn, food + .xn + .xn, food + .xn + .xn + .xn],
            direction: .xp,
            foods: [FoodPellet(id: 1, kind: .apple, position: food)]
        )
        let first = fresh.debugStep()
        // A first score is a record even when nothing was saved before.
        XCTAssertTrue(first.contains(.newBest))
        XCTAssertEqual(fresh.best, 10)

        let returning = classic(best: 10)
        let apple = Vec3(4, 2, 4)
        returning.debugArrange(
            snake: [apple + .yp, apple + .yp + .yp, apple + .yp + .yp + .yp],
            direction: .yn,
            foods: [FoodPellet(id: 1, kind: .apple, position: apple)]
        )
        // Score goes 0 → 10, which ties the record and does not celebrate.
        var events = returning.debugStep()
        XCTAssertFalse(events.contains(.newBest))
        let second = Vec3(4, 6, 4)
        returning.debugArrange(
            snake: [second + .yp, second + .yp + .yp, second + .yp + .yp + .yp],
            direction: .yn,
            foods: [FoodPellet(id: 2, kind: .apple, position: second)]
        )
        // best is already 10 from the previous bite; this apple makes 20.
        // debugArrange does not reset score. Good.
        events = returning.debugStep()
        XCTAssertTrue(events.contains(.newBest))
        XCTAssertEqual(returning.best, 20)
    }

    func testShieldStopsAWallAndMushroomShortensALongSnake() {
        let game = classic(.hard)
        let edge = game.grid - 1
        game.debugArrange(
            snake: [Vec3(edge, 6, 6), Vec3(edge - 1, 6, 6), Vec3(edge - 2, 6, 6)],
            direction: .xp,
            foods: [],
            shield: 7
        )
        let events = game.debugStep()
        XCTAssertTrue(events.contains(.shielded))
        XCTAssertEqual(game.phase, .playing)
        XCTAssertEqual(game.snake[0].x, edge)

        var body: [Vec3] = []
        for x in 0..<12 {
            body.append(Vec3(x, 1, 1))
        }
        let bite = Vec3(11, 2, 1)
        game.debugArrange(
            snake: [Vec3(11, 1, 1)] + body.dropLast().reversed(),
            direction: .yp,
            foods: [FoodPellet(id: 4, kind: .mushroom, position: bite)]
        )
        // The arranged snake must actually step onto the mushroom.
        // head (11,1,1) moving +Y lands on (11,2,1).
        let before = game.length
        XCTAssertGreaterThan(before, 9)
        let ate = game.debugStep()
        XCTAssertTrue(ate.contains(.ate(.mushroom)))
        XCTAssertEqual(game.length, before - 2)
        XCTAssertGreaterThan(game.confuseRemaining, 0)
    }

    func testChiliMakesTheNextMovesFaster() {
        let game = classic(.easy)
        let before = game.currentStepDuration()
        let food = Vec3(5, 4, 4)
        game.debugArrange(
            snake: [food + .xn, food + .xn + .xn, food + .xn + .xn + .xn],
            direction: .xp,
            foods: [FoodPellet(id: 1, kind: .chili, position: food)]
        )
        _ = game.debugStep()
        XCTAssertTrue(game.boostActive)
        XCTAssertLessThan(game.currentStepDuration(), before * 0.80)
    }

    func testSolidsAreWallsAndAreNeverFood() {
        var profile = DifficultyProfile.hard
        profile.solids = [Vec3(8, 6, 6)]
        let game = SnakeGame(profile: profile, mode: .classic, seed: 5)
        XCTAssertFalse(game.foods.contains { profile.solids.contains($0.position) })
        game.debugArrange(
            snake: [Vec3(7, 6, 6), Vec3(6, 6, 6), Vec3(5, 6, 6)],
            direction: .xp,
            foods: [FoodPellet(id: 1, kind: .apple, position: Vec3(1, 1, 1))]
        )
        let events = game.debugStep()
        XCTAssertTrue(events.contains(.died))
    }

    func testFeedingCastCapsAtThreeAndTheAIEats() {
        let game = SnakeGame(profile: .easy, mode: .feeding, seed: 8)
        XCTAssertEqual(game.phase, .playing)
        XCTAssertTrue(game.autopilot)
        XCTAssertEqual(game.foods.count, 1)
        XCTAssertTrue(game.cast(.star))
        XCTAssertTrue(game.cast(.shield))
        XCTAssertFalse(game.cast(.chili))
        XCTAssertEqual(game.foods.count, 3)

        var alive = true
        for _ in 0..<80 where game.phase == .playing {
            _ = game.debugStep()
        }
        alive = game.phase == .playing
        XCTAssertTrue(alive)
        XCTAssertGreaterThan(game.eaten, 0)
    }

    func testAutopilotSurvivesTheOpeningMinute() {
        for seed: UInt64 in [1, 2, 7, 42] {
            let easy = SnakeGame(profile: .easy, mode: .feeding, seed: seed)
            var time = 0.0
            while time < 90 && easy.phase == .playing {
                _ = easy.update(dt: 1.0 / 30.0)
                time += 1.0 / 30.0
                if easy.foods.count < 2 {
                    _ = easy.cast(.apple)
                }
            }
            XCTAssertEqual(easy.phase, .playing, "easy seed \(seed) died at \(easy.elapsed)")
            XCTAssertGreaterThan(easy.eaten, 8, "easy seed \(seed)")
        }
        let hard = SnakeGame(profile: .hard, mode: .feeding, seed: 3)
        var time = 0.0
        while time < 45 && hard.phase == .playing {
            _ = hard.update(dt: 1.0 / 30.0)
            time += 1.0 / 30.0
            if hard.foods.isEmpty { _ = hard.cast(.apple) }
        }
        XCTAssertEqual(hard.phase, .playing, "hard autopilot died early")
        XCTAssertGreaterThan(hard.eaten, 5)
    }

    func testFollowingTheHintSurvivesTheFirstMinuteOnEasy() {
        // A careful player: whenever a control shortens the path to the apple
        // without dying, take it. This is the behavior the coach hint describes.
        for seed: UInt64 in [1, 5, 12, 18] {
            let game = classic(.easy, seed: seed)
            if let first = game.suggestedInput() {
                game.input(first)
            } else {
                game.input(.screen(.right))
            }
            var time = 0.0
            while time < 70 && game.phase == .playing {
                if let hint = game.suggestedInput() {
                    game.input(hint)
                }
                _ = game.update(dt: 1.0 / 60.0)
                time += 1.0 / 60.0
            }
            XCTAssertEqual(game.phase, .playing, "seed \(seed) phase \(game.phase) eaten \(game.eaten)")
            XCTAssertGreaterThanOrEqual(game.elapsed, 60, "seed \(seed)")
            XCTAssertGreaterThan(game.eaten, 6, "seed \(seed) only ate \(game.eaten)")
        }
    }

    func testSuggestedInputPointsAtTheApple() {
        let game = classic(.hard)
        let head = Vec3(6, 6, 6)
        game.debugArrange(
            snake: [head, head + .xn, head + .xn + .xn],
            direction: .xp,
            foods: [FoodPellet(id: 1, kind: .apple, position: Vec3(6, 6, 3))]
        )
        // Food is toward -Z, which is depth-in for the standard camera.
        XCTAssertEqual(game.suggestedInput(), .depthIn)
        XCTAssertEqual(game.coachCue, .goEat)
    }

    func testDepthCueAfterThePlanarLessons() {
        let game = classic(.easy, seed: 4)
        // Eat the three opening apples by dropping each one on the head's next cell.
        for _ in 0..<3 {
            let head = game.snake[0]
            let bite = head + .xp
            guard game.grid > bite.x else { break }
            game.debugArrange(
                snake: game.snake,
                direction: .xp,
                foods: [FoodPellet(id: 1, kind: .apple, position: bite)],
                grace: game.graceLeft
            )
            // debugArrange resets nothing about eaten — but it replaces foods.
            // Score and eaten persist. Good.
            _ = game.debugStep()
        }
        XCTAssertGreaterThanOrEqual(game.eaten, 3)
        // Force a food on another layer and ask the coach.
        let head = game.snake[0]
        let buried = Vec3(head.x, head.y, max(0, head.z - 2))
        game.debugArrange(
            snake: game.snake,
            direction: game.direction,
            foods: [FoodPellet(id: 9, kind: .apple, position: buried)]
        )
        if case .useDepth(let inward) = game.coachCue {
            XCTAssertTrue(inward)
        } else {
            XCTFail("expected a depth cue, got \(game.coachCue)")
        }
        game.input(.depthIn)
        XCTAssertTrue(game.usedDepth)
    }

    func testManualDriveHandsTheFeedingSnakeBack() {
        let game = SnakeGame(profile: .normal, mode: .feeding, seed: 2)
        XCTAssertTrue(game.autopilot)
        game.setManualDrive(true)
        XCTAssertFalse(game.autopilot)
        let head = game.snake[0]
        game.input(.screen(.up))
        _ = game.debugStep()
        XCTAssertEqual(game.direction, .yp)
        XCTAssertNotEqual(game.snake[0], head)
        game.setManualDrive(false)
        XCTAssertTrue(game.autopilot)
    }

    func testStarScoreAndShieldTimer() {
        let game = classic(.normal)
        let food = Vec3(4, 5, 5)
        game.debugArrange(
            snake: [food + .yn, food + .yn + .yn, food + .yn + .yn + .yn],
            direction: .yp,
            foods: [FoodPellet(id: 1, kind: .star, position: food)]
        )
        _ = game.debugStep()
        XCTAssertEqual(game.score, 30)
        let shieldAt = game.foods[0].position
        game.debugArrange(
            snake: [shieldAt + .yn, shieldAt + .yn + .yn, shieldAt + .yn + .yn + .yn],
            direction: .yp,
            foods: [FoodPellet(id: 2, kind: .shield, position: shieldAt)]
        )
        _ = game.debugStep()
        XCTAssertTrue(game.shieldActive)
        XCTAssertEqual(game.score, 36)
    }

    func testAimCueNamesTheSwipeTowardTheApple() {
        let game = classic(.easy)
        let head = Vec3(3, 4, 4)
        game.debugArrange(
            snake: [head, head + .xn, head + .xn + .xn],
            direction: .xp,
            foods: [FoodPellet(id: 1, kind: .apple, position: Vec3(3, 7, 4))]
        )
        XCTAssertEqual(game.coachCue, .aim(.screen(.up)))
        XCTAssertEqual(game.suggestedInput(), .screen(.up))
    }

    func testFourthAppleLeavesTheLayerAndLightsDepth() {
        let game = classic(.easy, seed: 3)
        var head = Vec3(3, 4, 4)
        for _ in 0..<3 {
            game.debugArrange(
                snake: [head, head + .xn, head + .xn + .xn],
                direction: .xp,
                foods: [FoodPellet(id: 1, kind: .apple, position: head + .xp)],
                grace: game.graceLeft,
                eaten: game.eaten
            )
            let events = game.debugStep()
            XCTAssertTrue(events.contains(.ate(.apple)))
            head = game.snake[0]
        }
        XCTAssertEqual(game.eaten, 3)
        XCTAssertNotEqual(game.foods[0].position.z, game.snake[0].z)
        if case .useDepth = game.coachCue {
        } else {
            XCTFail("expected a depth cue, got \(game.coachCue)")
        }
    }

    func testFeedingOpensInTheMiddleAndWaits() {
        let game = SnakeGame(profile: .easy, mode: .feeding, seed: 4)
        let head = game.snake[0]
        let food = game.foods[0].position
        XCTAssertEqual(food.z, head.z)
        let distance = food.manhattan(to: head)
        XCTAssertGreaterThanOrEqual(distance, 2)
        XCTAssertLessThanOrEqual(distance, 4)
        let limit = game.grid - 2
        XCTAssertGreaterThan(food.x, 1)
        XCTAssertLessThan(food.x, limit)
        XCTAssertGreaterThan(food.y, 1)
        XCTAssertLessThan(food.y, limit)
        let start = game.snake
        _ = game.update(dt: 0.2)
        XCTAssertEqual(game.snake, start)
    }

    func testMessyThumbsReachTheDepthLessonAlive() {
        // A casual thumb: often follows the arrow, sometimes swipes the wrong way.
        for seed: UInt64 in [1, 7, 11, 21] {
            var rng = SplitMix64(seed: seed &* 17 &+ 3)
            let game = classic(.easy, seed: seed)
            if let first = game.suggestedInput() {
                game.input(first)
            } else {
                game.input(.screen(.right))
            }
            var time = 0.0
            var ticks = 0
            var sawDepth = false
            let inputs: [ControlInput] = [
                .screen(.up), .screen(.down), .screen(.left), .screen(.right), .depthIn, .depthOut,
            ]
            while time < 75 && game.phase == .playing {
                if ticks % 8 == 0 {
                    if rng.unit() < 0.62, let hint = game.suggestedInput() {
                        game.input(hint)
                    } else {
                        game.input(inputs[rng.int(below: inputs.count)])
                    }
                }
                if case .useDepth = game.coachCue { sawDepth = true }
                _ = game.update(dt: 1.0 / 30.0)
                time += 1.0 / 30.0
                ticks += 1
            }
            XCTAssertEqual(game.phase, .playing, "seed \(seed) died at \(game.elapsed) eaten \(game.eaten) grace \(game.graceLeft) cause \(String(describing: game.deathCause))")
            XCTAssertGreaterThanOrEqual(game.elapsed, 60, "seed \(seed)")
            XCTAssertGreaterThanOrEqual(game.eaten, 3, "seed \(seed) eaten \(game.eaten)")
            XCTAssertTrue(sawDepth, "seed \(seed) never saw the depth cue")
        }
    }
}
