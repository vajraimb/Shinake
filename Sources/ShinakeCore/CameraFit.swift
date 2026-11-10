import Foundation

/// Vertical field of view used by the play camera. Kept fixed so a phone
/// doesn't get a fisheye view; distance is what changes to fit the cube.
public let playCameraVerticalFOV = 32.0

/// Empty fraction of each screen edge. Tight enough that the cube fills the
/// canvas, with a few percent left so a corner head is not shaved off.
public let playCameraMargin = 0.045

/// Extra world units around the grid. Covers the head radius (0.30) and the
/// cube's edge tube without the old loose halo.
public let playCameraPad = 0.38

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

/// Half the grid's world size. Cell 0 and cell `grid - 1` sit at ±this.
public func cubeHalfExtent(grid: Int) -> Double {
    Double(max(grid - 1, 1)) * 0.5
}

/// A small shift of the look-at point toward the head. The shift is capped
/// so the cube stays near the middle of the frame while the head eases inward.
public func cameraLookAt(headWorld: WorldPoint, grid: Int, bias: Double = 0.08) -> WorldPoint {
    let limit = cubeHalfExtent(grid: grid) * 0.35
    func pull(_ value: Double) -> Double {
        min(limit, max(-limit, value * bias))
    }
    return WorldPoint(pull(headWorld.x), pull(headWorld.y), pull(headWorld.z))
}

/// Closest distance at which every padded corner of the play cube falls
/// inside the viewport. `aspect` is view width / height. The camera keeps
/// `CameraRig`'s orientation, so swipe mapping does not change.
public func cameraDistanceToFitCube(
    grid: Int,
    aspect: Double,
    verticalFOVDegrees: Double = playCameraVerticalFOV,
    margin: Double = playCameraMargin,
    lookAt: WorldPoint = .zero,
    pad: Double = playCameraPad,
    rig: CameraRig = .standard
) -> Double {
    var low = 0.5
    var high = max(cubeHalfExtent(grid: grid) * 6, 4)
    var guardrail = 0
    while !playCubeFits(
        grid: grid,
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
        if playCubeFits(
            grid: grid,
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
public func playCubeFits(
    grid: Int,
    aspect: Double,
    distance: Double,
    lookAt: WorldPoint = .zero,
    verticalFOVDegrees: Double = playCameraVerticalFOV,
    margin: Double = playCameraMargin,
    pad: Double = playCameraPad,
    rig: CameraRig = .standard
) -> Bool {
    let limit = 1 - min(0.45, max(0, margin))
    for corner in paddedCorners(grid: grid, pad: pad) {
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

private func paddedCorners(grid: Int, pad: Double) -> [WorldPoint] {
    let half = cubeHalfExtent(grid: grid) + max(0, pad)
    var corners: [WorldPoint] = []
    corners.reserveCapacity(8)
    for x in [-half, half] {
        for y in [-half, half] {
            for z in [-half, half] {
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
