import XCTest
#if canImport(ShinakeCore)
@testable import ShinakeCore
#else
@testable import Shinake
#endif

final class SteeringTests: XCTestCase {
    func testStandardCameraSeparatesTheThreeAxes() {
        let mapping = steerMapping(rig: .standard)
        XCTAssertEqual(mapping.right, .xp)
        XCTAssertEqual(mapping.left, .xn)
        XCTAssertEqual(mapping.up, .yp)
        XCTAssertEqual(mapping.down, .yn)
        XCTAssertEqual(mapping.depthIn, .zn)
        XCTAssertEqual(mapping.depthOut, .zp)
    }

    func testEveryControlIsADistinctAxis() {
        let mapping = steerMapping(rig: .standard)
        let directions = [
            mapping.right, mapping.left, mapping.up, mapping.down, mapping.depthIn, mapping.depthOut,
        ]
        XCTAssertEqual(Set(directions).count, 6)
        XCTAssertTrue(directions.allSatisfy(\.isUnitAxis))
    }

    func testSwipeUsesUIKitCoordinates() {
        XCTAssertEqual(classifySwipe(dx: 40, dy: 4), .right)
        XCTAssertEqual(classifySwipe(dx: -48, dy: 10), .left)
        XCTAssertEqual(classifySwipe(dx: 3, dy: -50), .up)
        XCTAssertEqual(classifySwipe(dx: -6, dy: 42), .down)
    }

    func testShortDragsAreNotTurns() {
        XCTAssertNil(classifySwipe(dx: 10, dy: 4))
        XCTAssertNil(classifySwipe(dx: 0, dy: 0))
        XCTAssertNil(classifySwipe(dx: 14, dy: 0))
        XCTAssertEqual(classifySwipe(dx: 15, dy: 0), .right)
        XCTAssertEqual(classifySwipe(dx: 16, dy: 4), .right)
    }

    func testGestureLockFiresOnceUntilTheFingerLifts() {
        var lock = GestureLock()
        XCTAssertNil(lock.swipe(dx: 8, dy: 1))
        XCTAssertEqual(lock.swipe(dx: 18, dy: -4), .right)
        XCTAssertNil(lock.swipe(dx: 40, dy: 30), "the same drag does not queue a second turn")
        lock.endSwipe()
        XCTAssertEqual(lock.swipe(dx: 2, dy: -20), .up)

        XCTAssertNil(lock.pinch(scale: 1))
        XCTAssertNil(lock.pinch(scale: 0.9))
        XCTAssertEqual(lock.pinch(scale: 0.85), .inward)
        XCTAssertNil(lock.pinch(scale: 0.4), "one pinch is one depth turn")
        lock.endPinch()
        XCTAssertEqual(lock.pinch(scale: 1.15), .outward)
        lock.endPinch()
        XCTAssertNil(lock.pinch(scale: 1.05))

        var mixed = GestureLock()
        XCTAssertEqual(mixed.swipe(dx: 4, dy: 0), nil)
        mixed.cancelSwipe()
        XCTAssertNil(mixed.swipe(dx: 30, dy: 0), "a pinch cancels the drag that has not turned yet")
        mixed.endSwipe()
        XCTAssertEqual(mixed.swipe(dx: 0, dy: 16), .down)
    }

    func testDiagonalSwipeFollowsTheStrongerAxis() {
        XCTAssertEqual(classifySwipe(dx: 50, dy: 20), .right)
        XCTAssertEqual(classifySwipe(dx: -10, dy: 40), .down)
    }

    func testMappingAgreesWithControlInput() {
        let mapping = steerMapping(rig: .standard)
        XCTAssertEqual(mapping.direction(for: .screen(.up)), .yp)
        XCTAssertEqual(mapping.direction(for: .depthIn), .zn)
        XCTAssertEqual(mapping.direction(for: .depthOut), .zp)
    }
}
