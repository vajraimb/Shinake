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
        XCTAssertNil(classifySwipe(dx: 12, dy: 8))
        XCTAssertNil(classifySwipe(dx: 0, dy: 0))
        XCTAssertNil(classifySwipe(dx: 29, dy: 0))
        XCTAssertEqual(classifySwipe(dx: 30, dy: 0), .right)
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
