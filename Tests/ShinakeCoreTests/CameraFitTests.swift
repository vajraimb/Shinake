import XCTest
#if canImport(ShinakeCore)
@testable import ShinakeCore
#else
@testable import Shinake
#endif

final class CameraFitTests: XCTestCase {
    /// Portrait play-canvas aspects: a tall 13 Pro Max canvas, an SE canvas,
    /// a square, and a short wide one.
    private let aspects = [0.62, 0.86, 1.0, 1.35]

    func testFittedDistanceKeepsTheWholeCubeInside() {
        for grid in [9, 10, 12] {
            for aspect in aspects {
                let distance = cameraDistanceToFitCube(grid: grid, aspect: aspect)
                XCTAssertGreaterThan(distance, 1, "grid \(grid) aspect \(aspect)")
                XCTAssertTrue(
                    playCubeFits(grid: grid, aspect: aspect, distance: distance),
                    "grid \(grid) aspect \(aspect) distance \(distance)"
                )
                XCTAssertFalse(
                    playCubeFits(grid: grid, aspect: aspect, distance: distance * 0.985),
                    "grid \(grid) aspect \(aspect) should clip when pulled in"
                )
            }
        }
    }

    func testOldFixedDistanceCropsANarrowPortraitCanvas() {
        // What the device build used: distance = grid * 2.55, FOV 32°.
        // On a tall 13 Pro Max canvas the cube's corners leave the frame.
        let grid = 9
        let old = Double(grid) * 2.55
        XCTAssertFalse(playCubeFits(grid: grid, aspect: 0.66, distance: old))
        let fitted = cameraDistanceToFitCube(grid: grid, aspect: 0.66)
        XCTAssertGreaterThan(fitted, old)
        XCTAssertTrue(playCubeFits(grid: grid, aspect: 0.66, distance: fitted))
    }

    func testNarrowerCanvasNeedsAtLeastAsMuchDistance() {
        let wide = cameraDistanceToFitCube(grid: 9, aspect: 1.2)
        let narrow = cameraDistanceToFitCube(grid: 9, aspect: 0.62)
        XCTAssertGreaterThanOrEqual(narrow, wide)
    }

    func testLookAtBiasStaysGentleAndTheCubeStillFits() {
        let grid = 9
        let half = cubeHalfExtent(grid: grid)
        let head = WorldPoint(half, -half * 0.5, half)
        let look = cameraLookAt(headWorld: head, grid: grid)
        XCTAssertGreaterThan(look.x, 0)
        XCTAssertLessThan(look.x, half * 0.35 + 1e-6)
        XCTAssertEqual(cameraLookAt(headWorld: head, grid: grid, bias: 0), .zero)
        let distance = cameraDistanceToFitCube(grid: grid, aspect: 0.66, lookAt: look)
        XCTAssertTrue(playCubeFits(grid: grid, aspect: 0.66, distance: distance, lookAt: look))
    }

    func testCornerHeadStillProjectsInsideTheMargin() {
        let grid = 9
        let half = cubeHalfExtent(grid: grid)
        let head = WorldPoint(-half, half, -half)
        let look = cameraLookAt(headWorld: head, grid: grid)
        let distance = cameraDistanceToFitCube(grid: grid, aspect: 0.62, lookAt: look)
        let ndc = cameraNDC(
            point: head,
            lookAt: look,
            distance: distance,
            aspect: 0.62
        )
        XCTAssertNotNil(ndc)
        if let ndc {
            XCTAssertLessThan(abs(ndc.x), 1 - playCameraMargin + 1e-6)
            XCTAssertLessThan(abs(ndc.y), 1 - playCameraMargin + 1e-6)
        }
    }
}
