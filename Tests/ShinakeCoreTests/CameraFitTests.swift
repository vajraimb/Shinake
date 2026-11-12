import XCTest
#if canImport(ShinakeCore)
@testable import ShinakeCore
#else
@testable import Shinake
#endif

final class CameraFitTests: XCTestCase {
    private let profiles = [DifficultyProfile.easy, DifficultyProfile.normal, DifficultyProfile.hard]

    func testPortraitCuboidStaysWithinFivePercentOfTheCube() {
        for profile in profiles {
            let arena = profile.arena
            let cube = ArenaSize.cube(arena.width)
            XCTAssertEqual(arena.depth, arena.width)
            XCTAssertGreaterThan(arena.height, arena.width)
            for aspect in portraitPlayAspects {
                let cubeDistance = cameraDistanceToFit(arena: cube, aspect: aspect)
                let distance = cameraDistanceToFit(arena: arena, aspect: aspect)
                XCTAssertLessThanOrEqual(
                    distance,
                    cubeDistance * arenaDistanceGrowthLimit + 1e-6,
                    "\(profile.id) aspect \(aspect) grew past 5%"
                )
                XCTAssertTrue(
                    playArenaFits(arena: arena, aspect: aspect, distance: distance),
                    "\(profile.id) aspect \(aspect)"
                )
                XCTAssertFalse(
                    playArenaFits(arena: arena, aspect: aspect, distance: distance * 0.985),
                    "\(profile.id) aspect \(aspect) should clip when pulled in"
                )
            }
        }
    }

    func testHeightIsTheTallestThatStillFitsPortrait() {
        let targets = [(9, 14), (10, 16), (12, 19)]
        for (width, target) in targets {
            let height = fittedArenaHeight(width: width, depth: width, target: target)
            XCTAssertGreaterThan(height, width)
            XCTAssertLessThanOrEqual(height, target)
            let chosen = ArenaSize(width: width, height: height, depth: width)
            let cube = ArenaSize.cube(width)
            for aspect in portraitPlayAspects {
                let base = cameraDistanceToFit(arena: cube, aspect: aspect)
                let distance = cameraDistanceToFit(arena: chosen, aspect: aspect)
                XCTAssertLessThanOrEqual(distance, base * arenaDistanceGrowthLimit + 1e-6)
            }
            if height < target {
                let taller = ArenaSize(width: width, height: height + 1, depth: width)
                let overflows = portraitPlayAspects.contains { aspect in
                    let base = cameraDistanceToFit(arena: cube, aspect: aspect)
                    let next = cameraDistanceToFit(arena: taller, aspect: aspect)
                    return next > base * arenaDistanceGrowthLimit + 1e-6
                }
                XCTAssertTrue(overflows, "width \(width) could have been taller than \(height)")
            }
            // A shorter portrait canvas still frames the whole board.
            let short = cameraDistanceToFit(arena: chosen, aspect: 0.86)
            XCTAssertTrue(playArenaFits(arena: chosen, aspect: 0.86, distance: short))
        }
    }

    func testCuboidCornersStayInsideATallPortraitCanvas() {
        let aspect = 0.62
        for profile in profiles {
            let arena = profile.arena
            let hx = axisHalfExtent(arena.width)
            let hy = axisHalfExtent(arena.height)
            let hz = axisHalfExtent(arena.depth)
            let corner = WorldPoint(-hx, hy, -hz)
            let look = cameraLookAt(headWorld: corner, arena: arena)
            let distance = cameraDistanceToFit(arena: arena, aspect: aspect, lookAt: look)
            let ndc = cameraNDC(point: corner, lookAt: look, distance: distance, aspect: aspect)
            XCTAssertNotNil(ndc, profile.id)
            if let ndc {
                XCTAssertLessThan(abs(ndc.x), 1 - playCameraMargin + 1e-4, profile.id)
                XCTAssertLessThan(abs(ndc.y), 1 - playCameraMargin + 1e-4, profile.id)
            }
            let surface = WorldPoint(-(hx + 0.30), hy, -hz)
            let surfaceNDC = cameraNDC(point: surface, lookAt: .zero, distance: cameraDistanceToFit(arena: arena, aspect: aspect), aspect: aspect)
            XCTAssertNotNil(surfaceNDC, profile.id)
            if let surfaceNDC {
                XCTAssertLessThan(abs(surfaceNDC.x), 1 - playCameraMargin + 1e-4, profile.id)
                XCTAssertLessThan(abs(surfaceNDC.y), 1 - playCameraMargin + 1e-4, profile.id)
            }
        }
    }

    func testOldFixedDistanceCropsANarrowPortraitCanvas() {
        // What the device build used: distance = width * 2.55, FOV 32°.
        let cube = ArenaSize.cube(DifficultyProfile.easy.arena.width)
        let old = Double(cube.width) * 2.55
        XCTAssertFalse(playArenaFits(arena: cube, aspect: 0.66, distance: old))
        let fitted = cameraDistanceToFit(arena: cube, aspect: 0.66)
        XCTAssertGreaterThan(fitted, old)
        XCTAssertTrue(playArenaFits(arena: cube, aspect: 0.66, distance: fitted))
    }

    func testTighterMarginPullsTheCameraCloser() {
        let cube = ArenaSize.cube(DifficultyProfile.easy.arena.width)
        let roomy = cameraDistanceToFit(arena: cube, aspect: 0.66, margin: 0.12, pad: 0.55)
        let tight = cameraDistanceToFit(arena: cube, aspect: 0.66)
        XCTAssertEqual(playCameraMargin, 0.045, accuracy: 0.0001)
        XCTAssertLessThan(playCameraPad, 0.5)
        XCTAssertLessThan(tight, roomy * 0.92)
        XCTAssertTrue(playArenaFits(arena: cube, aspect: 0.66, distance: tight))
    }

    func testNarrowerPortraitCanvasNeedsAtLeastAsMuchDistance() {
        let arena = DifficultyProfile.easy.arena
        let wider = cameraDistanceToFit(arena: arena, aspect: 0.86)
        let narrow = cameraDistanceToFit(arena: arena, aspect: 0.62)
        XCTAssertGreaterThanOrEqual(narrow, wider)
    }

    func testLookAtBiasStaysGentleAndTheArenaStillFits() {
        let arena = DifficultyProfile.easy.arena
        let hx = axisHalfExtent(arena.width)
        let hy = axisHalfExtent(arena.height)
        let head = WorldPoint(hx, -hy * 0.5, hx)
        let look = cameraLookAt(headWorld: head, arena: arena)
        XCTAssertGreaterThan(look.x, 0)
        XCTAssertLessThan(look.x, hx * 0.35 + 1e-6)
        XCTAssertLessThan(abs(look.y), hy * 0.35 + 1e-6)
        XCTAssertEqual(cameraLookAt(headWorld: head, arena: arena, bias: 0), .zero)
        let distance = cameraDistanceToFit(arena: arena, aspect: 0.62, lookAt: look)
        XCTAssertTrue(playArenaFits(arena: arena, aspect: 0.62, distance: distance, lookAt: look))
    }
}
