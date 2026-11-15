import XCTest
#if canImport(ShinakeCore)
@testable import ShinakeCore
#else
@testable import Shinake
#endif

final class DuelMatchTests: XCTestCase {
    func testHostIsSolidAndTheJoinerIsAShadowWithARingOnTheirScreen() {
        let hostOnHost = DuelLook.look(of: .host, on: .host)
        let hostOnJoiner = DuelLook.look(of: .host, on: .joiner)
        XCTAssertEqual(hostOnHost.alpha, 1, accuracy: 0.0001)
        XCTAssertFalse(hostOnHost.ownRing)
        XCTAssertEqual(hostOnJoiner.alpha, 1, accuracy: 0.0001)
        XCTAssertFalse(hostOnJoiner.ownRing)

        let joinerOnHost = DuelLook.look(of: .joiner, on: .host)
        let joinerOnJoiner = DuelLook.look(of: .joiner, on: .joiner)
        XCTAssertEqual(joinerOnHost.alpha, 0.35, accuracy: 0.0001)
        XCTAssertFalse(joinerOnHost.ownRing)
        XCTAssertEqual(joinerOnJoiner.alpha, 0.35, accuracy: 0.0001)
        XCTAssertTrue(joinerOnJoiner.ownRing)
    }

    func testBattleUsesTheNormalCuboidAndAFixedStep() {
        let match = DuelMatch(seed: 1)
        XCTAssertEqual(match.arena, Difficulty.normal.profile.arena)
        XCTAssertEqual(match.snapshot().host.stepDuration, DuelMatch.stepDuration, accuracy: 0.0001)
        XCTAssertEqual(match.foods.count, 2)
        XCTAssertEqual(match.timeLeft, 180, accuracy: 0.0001)
        XCTAssertEqual(match.snapshot().host.score, 0)
        XCTAssertEqual(match.snapshot().joiner.score, 0)
    }

    func testEqualRaceThrowsTheFoodOut() {
        let match = DuelMatch(seed: 2)
        let food = Vec3(6, 10, 4)
        match.debugPlace(
            host: [Vec3(5, 10, 4), Vec3(4, 10, 4), Vec3(3, 10, 4)],
            hostDirection: .xp,
            joiner: [Vec3(7, 10, 4), Vec3(8, 10, 4), Vec3(9, 10, 4)],
            joinerDirection: .xn,
            foods: [FoodPellet(id: 1, kind: .star, position: food)]
        )
        match.debugBeat()
        XCTAssertEqual(match.snapshot().host.score, 0)
        XCTAssertEqual(match.snapshot().joiner.score, 0)
        XCTAssertFalse(match.foods.contains { $0.id == 1 })
        XCTAssertEqual(match.snapshot().host.cells[0], Vec3(5, 10, 4))
        XCTAssertEqual(match.snapshot().joiner.cells[0], Vec3(7, 10, 4))
    }

    func testCloserSnakeTakesTheFoodAndTheOtherIsHit() {
        XCTAssertEqual(duelFoodWinner(hostDistance: 1, joinerDistance: 2), .host)
        XCTAssertEqual(duelFoodWinner(hostDistance: 4, joinerDistance: 2), .joiner)
        XCTAssertNil(duelFoodWinner(hostDistance: 2, joinerDistance: 2))

        let match = DuelMatch(seed: 3)
        let food = Vec3(6, 10, 4)
        match.debugPlace(
            host: [Vec3(5, 10, 4), Vec3(4, 10, 4), Vec3(3, 10, 4)],
            hostDirection: .xp,
            joiner: [food + .yp + .yp, food + .yp + .yp + .yp, food + .yp + .yp + .yp + .yp],
            joinerDirection: .yn,
            foods: [FoodPellet(id: 7, kind: .apple, position: food)]
        )
        // Joiner is two cells away, so only the host reaches it this beat.
        match.debugBeat()
        XCTAssertEqual(match.snapshot().host.score, OfficialMenu.appleScore)
        XCTAssertEqual(match.snapshot().host.cells[0], food)
        XCTAssertTrue(match.snapshot().joiner.alive)
    }

    func testHeadOnKillsBothUnlessOneShieldHolds() {
        let both = DuelMatch(seed: 4)
        both.debugPlace(
            host: [Vec3(5, 8, 4), Vec3(4, 8, 4), Vec3(3, 8, 4)],
            hostDirection: .xp,
            joiner: [Vec3(6, 8, 4), Vec3(7, 8, 4), Vec3(8, 8, 4)],
            joinerDirection: .xn,
            foods: []
        )
        both.debugBeat()
        XCTAssertFalse(both.snapshot().host.alive)
        XCTAssertFalse(both.snapshot().joiner.alive)

        let shielded = DuelMatch(seed: 5)
        shielded.debugPlace(
            host: [Vec3(5, 8, 4), Vec3(4, 8, 4), Vec3(3, 8, 4)],
            hostDirection: .xp,
            joiner: [Vec3(6, 8, 4), Vec3(7, 8, 4), Vec3(8, 8, 4)],
            joinerDirection: .xn,
            foods: [],
            hostShield: 10
        )
        shielded.debugBeat()
        XCTAssertTrue(shielded.snapshot().host.alive)
        XCTAssertFalse(shielded.snapshot().host.shield)
        XCTAssertFalse(shielded.snapshot().joiner.alive)
        XCTAssertEqual(shielded.snapshot().host.cells[0], Vec3(6, 8, 4))
    }

    func testDeathRespawnsAndTheClockPicksTheHigherScore() {
        let match = DuelMatch(seed: 6)
        match.debugPlace(
            host: [Vec3(0, 8, 4), Vec3(1, 8, 4), Vec3(2, 8, 4)],
            hostDirection: .xn,
            joiner: [Vec3(8, 8, 4), Vec3(9, 8, 4), Vec3(10, 8, 4)],
            joinerDirection: .xp,
            foods: []
        )
        match.debugScores(host: 30, joiner: 12)
        match.debugBeat()
        XCTAssertFalse(match.snapshot().host.alive)
        XCTAssertEqual(match.snapshot().host.score, 20)
        var guardTicks = 0
        while !match.snapshot().host.alive && guardTicks < 40 {
            _ = match.update(dt: 0.05)
            guardTicks += 1
        }
        XCTAssertTrue(match.snapshot().host.alive)
        XCTAssertEqual(match.snapshot().host.cells.count, 3)

        let timed = DuelMatch(seed: 7)
        timed.debugScores(host: 10, joiner: 40)
        timed.debugSetElapsed(DuelMatch.matchLength)
        _ = timed.update(dt: 0.05)
        XCTAssertEqual(timed.phase, .finished)
        XCTAssertEqual(timed.winner, .joiner)
        XCTAssertEqual(timed.reason, .score)
    }

    func testATieWaitsForTheNextFoodAndADroppedGuestWaitsFiveSeconds() {
        let match = DuelMatch(seed: 8)
        match.debugScores(host: 15, joiner: 15)
        match.debugSetElapsed(DuelMatch.matchLength)
        _ = match.update(dt: 0.05)
        XCTAssertEqual(match.phase, .sudden)
        let food = Vec3(4, 10, 4)
        match.debugPlace(
            host: [food + .xn, food + .xn + .xn, food + .xn + .xn + .xn],
            hostDirection: .xp,
            joiner: [Vec3(9, 10, 4), Vec3(10, 10, 4), Vec3(11, 10, 4)],
            joinerDirection: .xn,
            foods: [FoodPellet(id: 3, kind: .apple, position: food)]
        )
        match.debugBeat()
        XCTAssertEqual(match.phase, .finished)
        XCTAssertEqual(match.winner, .host)
        XCTAssertEqual(match.reason, .suddenFood)

        let dropped = DuelMatch(seed: 9)
        dropped.remoteDropped(.joiner)
        _ = dropped.update(dt: 0.05)
        XCTAssertEqual(dropped.phase, .playing)
        for _ in 0..<100 {
            _ = dropped.update(dt: 0.05)
        }
        XCTAssertEqual(dropped.phase, .finished)
        XCTAssertEqual(dropped.winner, .host)
        XCTAssertEqual(dropped.reason, .opponentLeft)

        let hostLeft = DuelMatch(seed: 10)
        hostLeft.remoteDropped(.host)
        XCTAssertEqual(hostLeft.phase, .finished)
        XCTAssertNil(hostLeft.winner)
        XCTAssertEqual(hostLeft.reason, .hostLeft)

        let back = DuelMatch(seed: 12)
        back.remoteDropped(.joiner)
        for _ in 0..<40 {
            _ = back.update(dt: 0.05)
        }
        back.remoteReturned()
        for _ in 0..<80 {
            _ = back.update(dt: 0.05)
        }
        XCTAssertEqual(back.phase, .playing)
        XCTAssertNil(back.winner)
    }

    func testSnapshotGlideAndWireRoundTrip() {
        let match = DuelMatch(seed: 11)
        let shot = match.snapshot()
        let later = shot.advanced(by: 0.14)
        XCTAssertEqual(later.host.fraction, 0.5, accuracy: 0.02)
        XCTAssertEqual(later.host.cells, shot.host.cells)
        let wire = DuelWire.snapshot(shot)
        let data = try? DuelWireCodec.encode(wire)
        XCTAssertEqual(DuelWireCodec.decode(data ?? Data()), wire)
        let input = DuelWire.input(seq: 3, control: .depthIn)
        let encoded = try? DuelWireCodec.encode(input)
        XCTAssertEqual(DuelWireCodec.decode(encoded ?? Data()), input)
    }
}
