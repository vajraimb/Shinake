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
        XCTAssertEqual(easy.grid, 9)
        XCTAssertEqual(easy.startInterval, 0.58, accuracy: 0.0001)
        XCTAssertEqual(easy.minInterval, 0.30, accuracy: 0.0001)
        XCTAssertEqual(easy.speedStep, 0.010, accuracy: 0.0001)
        XCTAssertEqual(easy.graceCharges, 4)
        XCTAssertEqual(easy.graceWindow, 90, accuracy: 0.0001)
        XCTAssertEqual(easy.planarOpeningFoods, 3)
        XCTAssertEqual(easy.minFoodDistance, 2)
        XCTAssertTrue(easy.showsGuide)
    }

    func testHardMatchesTheDesktopPace() {
        let hard = Difficulty.hard.profile
        XCTAssertEqual(hard.grid, LegacyTuning.grid)
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
        XCTAssertEqual(normal.graceCharges, 1)
        XCTAssertEqual(normal.graceWindow, 30, accuracy: 0.0001)
    }

    func testIntervalRampsThenFloors() {
        let easy = DifficultyProfile.easy
        XCTAssertEqual(moveInterval(eaten: 0, profile: easy), 0.58, accuracy: 0.0001)
        XCTAssertEqual(moveInterval(eaten: 10, profile: easy), 0.48, accuracy: 0.0001)
        // 0.58 - 28 * 0.010 = 0.30 exactly, then the floor holds.
        XCTAssertEqual(moveInterval(eaten: 28, profile: easy), 0.30, accuracy: 0.0001)
        XCTAssertEqual(moveInterval(eaten: 80, profile: easy), 0.30, accuracy: 0.0001)

        let hard = DifficultyProfile.hard
        XCTAssertEqual(moveInterval(eaten: 0, profile: hard), 0.27, accuracy: 0.0001)
        // Desktop: floor after (0.27 - 0.08) / 0.007 = 27.14 bites.
        XCTAssertEqual(moveInterval(eaten: 27, profile: hard), 0.081, accuracy: 0.0001)
        XCTAssertEqual(moveInterval(eaten: 40, profile: hard), 0.08, accuracy: 0.0001)
    }

    func testNinetySecondsOfEasyIsStillReadable() {
        // A player biting once every four seconds for a minute and a half
        // has eaten ~22 times. That tempo must stay slower than a quarter-second.
        let after = moveInterval(eaten: 22, profile: .easy)
        XCTAssertGreaterThan(after, 0.25)
        XCTAssertEqual(after, 0.36, accuracy: 0.0001)
    }
}
