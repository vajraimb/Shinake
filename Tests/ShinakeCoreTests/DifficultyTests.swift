import XCTest
#if canImport(ShinakeCore)
@testable import ShinakeCore
#else
@testable import Shinake
#endif

final class DifficultyTests: XCTestCase {
    func testLegacyDesktopNumbers() {
        XCTAssertEqual(LegacyTuning.grid, 12)
        XCTAssertEqual(LegacyTuning.startInterval, 0.27, accuracy: 0.0001)
        XCTAssertEqual(LegacyTuning.minInterval, 0.08, accuracy: 0.0001)
        XCTAssertEqual(LegacyTuning.speedStep, 0.007, accuracy: 0.0001)
        XCTAssertEqual(LegacyTuning.minFoodDistance, 4)
        XCTAssertEqual(LegacyTuning.graceCharges, 0)
    }

    func testEasyIsTheDefaultProfileShape() {
        let easy = Difficulty.easy.profile
        XCTAssertEqual(easy, .easy)
        XCTAssertEqual(easy.arena.width, 9)
        XCTAssertEqual(easy.arena.depth, 9)
        XCTAssertEqual(easy.arena.height, fittedArenaHeight(width: 9, depth: 9, target: 14))
        XCTAssertLessThanOrEqual(easy.arena.height, 14)
        XCTAssertGreaterThan(easy.arena.height, easy.arena.width)
        XCTAssertEqual(easy.arena.height, 14)
        XCTAssertEqual(easy.startInterval, 0.64, accuracy: 0.0001)
        XCTAssertEqual(easy.minInterval, 0.32, accuracy: 0.0001)
        XCTAssertEqual(easy.speedStep, 0.008, accuracy: 0.0001)
        XCTAssertEqual(easy.graceCharges, 6)
        XCTAssertEqual(easy.graceWindow, 90, accuracy: 0.0001)
        XCTAssertEqual(easy.freeRescuesUntilEaten, 3)
        XCTAssertTrue(easy.refillsGrace)
        XCTAssertEqual(easy.planarOpeningFoods, 3)
        XCTAssertEqual(easy.minFoodDistance, 2)
        XCTAssertTrue(easy.showsGuide)
    }

    func testHardMatchesTheDesktopPace() {
        let hard = Difficulty.hard.profile
        XCTAssertEqual(hard.arena.width, LegacyTuning.grid)
        XCTAssertEqual(hard.arena.depth, LegacyTuning.grid)
        XCTAssertEqual(
            hard.arena.height,
            fittedArenaHeight(width: LegacyTuning.grid, depth: LegacyTuning.grid, target: 19)
        )
        XCTAssertGreaterThan(hard.arena.height, hard.arena.width)
        XCTAssertEqual(hard.arena.height, 19)
        XCTAssertEqual(hard.startInterval, LegacyTuning.startInterval, accuracy: 0.0001)
        XCTAssertEqual(hard.minInterval, LegacyTuning.minInterval, accuracy: 0.0001)
        XCTAssertEqual(hard.speedStep, LegacyTuning.speedStep, accuracy: 0.0001)
        XCTAssertEqual(hard.minFoodDistance, LegacyTuning.minFoodDistance)
        XCTAssertEqual(hard.graceCharges, 0)
        XCTAssertFalse(hard.showsGuide)
    }

    func testNormalSitsBetweenThem() {
        let normal = Difficulty.normal.profile
        XCTAssertGreaterThan(normal.startInterval, Difficulty.hard.profile.startInterval)
        XCTAssertLessThan(normal.startInterval, Difficulty.easy.profile.startInterval)
        XCTAssertGreaterThan(normal.minInterval, LegacyTuning.minInterval)
        XCTAssertEqual(normal.arena.width, 10)
        XCTAssertEqual(normal.arena.depth, 10)
        XCTAssertEqual(normal.arena.height, fittedArenaHeight(width: 10, depth: 10, target: 16))
        XCTAssertGreaterThan(normal.arena.height, normal.arena.width)
        XCTAssertEqual(normal.arena.height, 16)
        XCTAssertEqual(normal.graceCharges, 1)
        XCTAssertEqual(normal.graceWindow, 30, accuracy: 0.0001)
        XCTAssertEqual(normal.freeRescuesUntilEaten, 0)
        XCTAssertFalse(normal.refillsGrace)
    }

    func testIntervalRampsThenFloors() {
        let easy = DifficultyProfile.easy
        XCTAssertEqual(moveInterval(eaten: 0, profile: easy), 0.64, accuracy: 0.0001)
        XCTAssertEqual(moveInterval(eaten: 10, profile: easy), 0.56, accuracy: 0.0001)
        // 0.64 - 40 * 0.008 = 0.32 exactly, then the floor holds.
        XCTAssertEqual(moveInterval(eaten: 40, profile: easy), 0.32, accuracy: 0.0001)
        XCTAssertEqual(moveInterval(eaten: 80, profile: easy), 0.32, accuracy: 0.0001)

        let hard = DifficultyProfile.hard
        XCTAssertEqual(moveInterval(eaten: 0, profile: hard), 0.27, accuracy: 0.0001)
        // Desktop: floor after (0.27 - 0.08) / 0.007 = 27.14 bites.
        XCTAssertEqual(moveInterval(eaten: 27, profile: hard), 0.081, accuracy: 0.0001)
        XCTAssertEqual(moveInterval(eaten: 40, profile: hard), 0.08, accuracy: 0.0001)
    }

    func testNinetySecondsOfEasyIsStillReadable() {
        // A player biting once every four seconds for a minute and a half
        // has eaten ~22 times. 0.64 − 22 × 0.008 = 0.464, still an easy read.
        let after = moveInterval(eaten: 22, profile: .easy)
        XCTAssertGreaterThan(after, 0.40)
        XCTAssertEqual(after, 0.464, accuracy: 0.0001)
    }
}
