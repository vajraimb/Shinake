import Foundation

/// Vertical field of view used by the play camera. Kept fixed so a phone
/// doesn't get a fisheye view; distance is what changes to fit the arena.
public let playCameraVerticalFOV = 32.0

/// Empty fraction of each screen edge. The score sits in its own strip above
/// the canvas, so this inset only keeps a corner head off the clip.
public let playCameraMargin = 0.02

/// Extra world units around the arena. Smaller than the drawn head (0.23);
/// the head still lands inside the margin because the fit is limited by the
/// box corner, not by a single axis. The frame's edge tube sits inside it.
public let playCameraPad = 0.18

/// How much farther the camera may sit versus the old cube, on a portrait canvas.
/// The play boards are chosen explicitly and may exceed this; the helper is
/// what the height search still uses.
public let arenaDistanceGrowthLimit = 1.05

/// Play-canvas aspect the height budget is measured on: a tall portrait phone,
/// the same 0.62 the corner test uses. A shorter canvas still frames the board;
/// the camera just sits farther back. Landscape is not a supported orientation.
public let portraitPlayAspects = [0.62]

public struct WorldPoint: Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = WorldPoint(0, 0, 0)
}

/// Width, height, and depth in cells. A step is one cell on every axis, so a
/// layer change is the same length as a sideways step even when the counts differ.
/// Height is the portrait stretch.
public struct ArenaSize: Equatable {
    public var width: Int
    public var height: Int
    public var depth: Int

    public init(width: Int, height: Int, depth: Int) {
        self.width = width
        self.height = height
        self.depth = depth
    }

    public static func cube(_ cells: Int) -> ArenaSize {
        ArenaSize(width: cells, height: cells, depth: cells)
    }

    public var cellCount: Int { width * height * depth }
}

/// Half the world size of one axis. Cell 0 and cell `cells - 1` sit at ±this.
public func axisHalfExtent(_ cells: Int) -> Double {
    Double(max(cells - 1, 1)) * 0.5
}

/// A small shift of the look-at point toward the head. Each axis is capped
/// by that axis's own half, so a tall board does not drag the frame off center.
public func cameraLookAt(headWorld: WorldPoint, arena: ArenaSize, bias: Double = 0.08) -> WorldPoint {
    func pull(_ value: Double, _ cells: Int) -> Double {
        let limit = axisHalfExtent(cells) * 0.35
        return min(limit, max(-limit, value * bias))
    }
    return WorldPoint(
        pull(headWorld.x, arena.width),
        pull(headWorld.y, arena.height),
        pull(headWorld.z, arena.depth)
    )
}

/// Closest distance at which every padded corner falls inside the viewport.
/// `aspect` is view width / height. The camera keeps `CameraRig`'s orientation,
/// so swipe mapping does not change.
public func cameraDistanceToFit(
    arena: ArenaSize,
    aspect: Double,
    verticalFOVDegrees: Double = playCameraVerticalFOV,
    margin: Double = playCameraMargin,
    lookAt: WorldPoint = .zero,
    pad: Double = playCameraPad,
    rig: CameraRig = .standard
) -> Double {
    let reach = max(axisHalfExtent(arena.width), axisHalfExtent(arena.height), axisHalfExtent(arena.depth))
    var low = 0.5
    var high = max(reach * 6, 4)
    var guardrail = 0
    while !playArenaFits(
        arena: arena,
        aspect: aspect,
        distance: high,
        lookAt: lookAt,
        verticalFOVDegrees: verticalFOVDegrees,
        margin: margin,
        pad: pad,
        rig: rig
    ), guardrail < 24 {
        high *= 1.6
        guardrail += 1
    }
    for _ in 0..<32 {
        let mid = (low + high) * 0.5
        if playArenaFits(
            arena: arena,
            aspect: aspect,
            distance: mid,
            lookAt: lookAt,
            verticalFOVDegrees: verticalFOVDegrees,
            margin: margin,
            pad: pad,
            rig: rig
        ) {
            high = mid
        } else {
            low = mid
        }
    }
    return high
}

/// True when all eight padded corners project inside the inset frame and
/// in front of the camera.
public func playArenaFits(
    arena: ArenaSize,
    aspect: Double,
    distance: Double,
    lookAt: WorldPoint = .zero,
    verticalFOVDegrees: Double = playCameraVerticalFOV,
    margin: Double = playCameraMargin,
    pad: Double = playCameraPad,
    rig: CameraRig = .standard
) -> Bool {
    let limit = 1 - min(0.45, max(0, margin))
    for corner in paddedCorners(arena: arena, pad: pad) {
        guard let ndc = cameraNDC(
            point: corner,
            lookAt: lookAt,
            distance: distance,
            aspect: aspect,
            verticalFOVDegrees: verticalFOVDegrees,
            rig: rig
        ) else { return false }
        if abs(ndc.x) > limit + 1e-6 || abs(ndc.y) > limit + 1e-6 { return false }
    }
    return true
}

/// Tallest height from `width` through `target` whose fitted distance stays
/// within `arenaDistanceGrowthLimit` of the cube on every portrait aspect.
/// If `target` itself fits, that height is used. Otherwise the search stops
/// at the last height that still fits.
public func fittedArenaHeight(
    width: Int,
    depth: Int,
    target: Int,
    aspects: [Double] = portraitPlayAspects
) -> Int {
    let cap = max(width, target)
    let cube = ArenaSize(width: width, height: width, depth: depth)
    let baselines = aspects.map { cameraDistanceToFit(arena: cube, aspect: $0) }
    var chosen = width
    guard cap > width else { return width }
    for height in (width + 1)...cap {
        let arena = ArenaSize(width: width, height: height, depth: depth)
        let fits = zip(aspects, baselines).allSatisfy { aspect, base in
            let distance = cameraDistanceToFit(arena: arena, aspect: aspect)
            return distance <= base * arenaDistanceGrowthLimit + 1e-6
        }
        if fits {
            chosen = height
        } else {
            break
        }
    }
    return chosen
}

/// Normalized device coordinates. ±1 is the edge of the frustum before margin.
/// Nil when the point is behind the camera.
public func cameraNDC(
    point: WorldPoint,
    lookAt: WorldPoint,
    distance: Double,
    aspect: Double,
    verticalFOVDegrees: Double = playCameraVerticalFOV,
    rig: CameraRig = .standard
) -> (x: Double, y: Double, depth: Double)? {
    let safeAspect = aspect > 0.05 ? aspect : 0.05
    let eye = normalize(rig.eyeOffset)
    let basis = rig.basis()
    let camera = WorldPoint(
        lookAt.x + eye.x * distance,
        lookAt.y + eye.y * distance,
        lookAt.z + eye.z * distance
    )
    let relative = WorldPoint(point.x - camera.x, point.y - camera.y, point.z - camera.z)
    let depth = dot(relative, basis.forward)
    guard depth > 0.02 else { return nil }
    let halfY = tan(verticalFOVDegrees * .pi / 360)
    guard halfY > 1e-6 else { return nil }
    let halfX = halfY * safeAspect
    let x = dot(relative, basis.right) / depth / halfX
    let y = dot(relative, basis.up) / depth / halfY
    return (x, y, depth)
}

private func paddedCorners(arena: ArenaSize, pad: Double) -> [WorldPoint] {
    let extra = max(0, pad)
    let hx = axisHalfExtent(arena.width) + extra
    let hy = axisHalfExtent(arena.height) + extra
    let hz = axisHalfExtent(arena.depth) + extra
    var corners: [WorldPoint] = []
    corners.reserveCapacity(8)
    for x in [-hx, hx] {
        for y in [-hy, hy] {
            for z in [-hz, hz] {
                corners.append(WorldPoint(x, y, z))
            }
        }
    }
    return corners
}

private func dot(_ point: WorldPoint, _ vector: (Double, Double, Double)) -> Double {
    point.x * vector.0 + point.y * vector.1 + point.z * vector.2
}

private func normalize(_ value: (x: Double, y: Double, z: Double)) -> (x: Double, y: Double, z: Double) {
    let length = (value.x * value.x + value.y * value.y + value.z * value.z).squareRoot()
    guard length > 1e-8 else { return (0, 0, 1) }
    return (value.x / length, value.y / length, value.z / length)
}
