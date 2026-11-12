import XCTest
#if canImport(ShinakeCore)
@testable import ShinakeCore
#else
@testable import Shinake
#endif

final class SnakeMotionTests: XCTestCase {
    func testStraightRunHitsTheCellsAndTheMidpoint() {
        let previous = [Vec3(2, 5, 3), Vec3(1, 5, 3), Vec3(0, 5, 3)]
        let current = [Vec3(3, 5, 3), Vec3(2, 5, 3), Vec3(1, 5, 3)]
        let start = SnakeMotion.position(index: 0, previous: previous, current: current, pendingTurn: nil, fraction: 0)
        let mid = SnakeMotion.position(index: 0, previous: previous, current: current, pendingTurn: nil, fraction: 0.5)
        let end = SnakeMotion.position(index: 0, previous: previous, current: current, pendingTurn: nil, fraction: 1)
        XCTAssertEqual(start, WorldPoint(2, 5, 3))
        XCTAssertEqual(mid, WorldPoint(2.5, 5, 3))
        XCTAssertEqual(end, WorldPoint(3, 5, 3))

        let neck = SnakeMotion.position(index: 1, previous: previous, current: current, pendingTurn: nil, fraction: 0.5)
        XCTAssertEqual(neck, WorldPoint(1.5, 5, 3))

        let early = SnakeMotion.position(index: 0, previous: previous, current: current, pendingTurn: nil, fraction: 0.2)
        let later = SnakeMotion.position(index: 0, previous: previous, current: current, pendingTurn: nil, fraction: 0.5)
        XCTAssertEqual(later.x - early.x, 0.3, accuracy: 0.0001)
        XCTAssertEqual(later.y, early.y, accuracy: 0.0001)
        XCTAssertEqual(later.z, early.z, accuracy: 0.0001)
    }

    func testCornerFilletLeavesTheCellAndRejoinsTheOutgoingLine() {
        let previous = [Vec3(1, 0, 0), Vec3(0, 0, 0), Vec3(-1, 0, 0)]
        let current = [Vec3(1, 1, 0), Vec3(1, 0, 0), Vec3(0, 0, 0)]
        let radius = SnakeMotion.cornerRadius
        let atCorner = SnakeMotion.position(index: 0, previous: previous, current: current, pendingTurn: nil, fraction: 0)
        XCTAssertNotEqual(atCorner, WorldPoint(1, 0, 0))
        let offset = ((atCorner.x - 1) * (atCorner.x - 1) + atCorner.y * atCorner.y).squareRoot()
        XCTAssertEqual(offset, (2.squareRoot() - 1) * radius, accuracy: 0.0001)
        XCTAssertEqual(atCorner.z, 0, accuracy: 0.0001)

        let rejoined = SnakeMotion.position(index: 0, previous: previous, current: current, pendingTurn: nil, fraction: radius)
        XCTAssertEqual(rejoined.x, 1, accuracy: 0.0001)
        XCTAssertEqual(rejoined.y, radius, accuracy: 0.0001)
        XCTAssertEqual(rejoined.z, 0, accuracy: 0.0001)

        let halfway = SnakeMotion.position(index: 0, previous: previous, current: current, pendingTurn: nil, fraction: 0.5)
        XCTAssertEqual(halfway, WorldPoint(1, 0.5, 0))
        let arrived = SnakeMotion.position(index: 0, previous: previous, current: current, pendingTurn: nil, fraction: 1)
        XCTAssertEqual(arrived, WorldPoint(1, 1, 0))
    }

    func testBodyFollowsTheSameCornerTheHeadJustTook() {
        let previous = [Vec3(1, 0, 0), Vec3(0, 0, 0), Vec3(-1, 0, 0)]
        let current = [Vec3(1, 1, 0), Vec3(1, 0, 0), Vec3(0, 0, 0)]
        let neckAtEnd = SnakeMotion.position(index: 1, previous: previous, current: current, pendingTurn: nil, fraction: 1)

        let nextPrevious = current
        let next = [Vec3(1, 2, 0), Vec3(1, 1, 0), Vec3(1, 0, 0)]
        let neckAtStart = SnakeMotion.position(index: 1, previous: nextPrevious, current: next, pendingTurn: nil, fraction: 0)
        XCTAssertEqual(neckAtEnd.x, neckAtStart.x, accuracy: 0.0001)
        XCTAssertEqual(neckAtEnd.y, neckAtStart.y, accuracy: 0.0001)
        XCTAssertEqual(neckAtEnd.z, neckAtStart.z, accuracy: 0.0001)
        XCTAssertNotEqual(neckAtEnd, WorldPoint(1, 0, 0))
    }

    func testQueuedTurnStartsTheFilletBeforeTheStepLands() {
        let previous = [Vec3(0, 0, 0), Vec3(-1, 0, 0), Vec3(-2, 0, 0)]
        let current = [Vec3(1, 0, 0), Vec3(0, 0, 0), Vec3(-1, 0, 0)]
        let radius = SnakeMotion.cornerRadius
        let before = SnakeMotion.position(
            index: 0,
            previous: previous,
            current: current,
            pendingTurn: .yp,
            fraction: 1 - radius
        )
        XCTAssertEqual(before.x, 1 - radius, accuracy: 0.0001)
        XCTAssertEqual(before.y, 0, accuracy: 0.0001)

        let atEnd = SnakeMotion.position(index: 0, previous: previous, current: current, pendingTurn: .yp, fraction: 1)
        XCTAssertNotEqual(atEnd, WorldPoint(1, 0, 0))
        let bulge = ((atEnd.x - 1) * (atEnd.x - 1) + atEnd.y * atEnd.y).squareRoot()
        XCTAssertEqual(bulge, (2.squareRoot() - 1) * radius, accuracy: 0.0001)
    }
}
