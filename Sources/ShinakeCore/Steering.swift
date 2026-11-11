import Foundation

/// Fixed orbit used by both the logic (which way a swipe goes) and SceneKit.
///
/// Yaw 0 is a camera sitting on +Z looking at the origin. These angles keep
/// screen-right on +X, screen-up on +Y, and the depth axis on Z, while still
/// showing three faces of the cube. The mapping is asserted in tests — if the
/// angle changes, the depth buttons and the hints have to change with it.
public struct CameraRig: Equatable {
    public var yaw: Double
    public var pitch: Double

    public static let standard = CameraRig(yaw: 0.62, pitch: 0.48)

    /// Unit vector from the look-at target out to the eye.
    public var eyeOffset: (x: Double, y: Double, z: Double) {
        let cy = cos(pitch)
        return (sin(yaw) * cy, sin(pitch), cos(yaw) * cy)
    }

    /// Camera basis. `forward` points from the eye into the scene.
    /// `right` / `up` are screen axes (positive x right, positive y up).
    public func basis() -> (right: (Double, Double, Double), up: (Double, Double, Double), forward: (Double, Double, Double)) {
        let eye = eyeOffset
        let forward = normalize((-eye.x, -eye.y, -eye.z))
        let worldUp = (0.0, 1.0, 0.0)
        let right = normalize(cross(forward, worldUp))
        let up = normalize(cross(right, forward))
        return (right, up, forward)
    }
}

public enum ScreenAxis: String, Equatable, CaseIterable {
    case left
    case right
    case up
    case down
}

public enum ControlInput: Equatable {
    case screen(ScreenAxis)
    case depthIn
    case depthOut
}

public struct SteerMapping: Equatable {
    public var right: Vec3
    public var left: Vec3
    public var up: Vec3
    public var down: Vec3
    public var depthIn: Vec3
    public var depthOut: Vec3

    public func direction(for input: ControlInput) -> Vec3 {
        switch input {
        case .screen(.right): return right
        case .screen(.left): return left
        case .screen(.up): return up
        case .screen(.down): return down
        case .depthIn: return depthIn
        case .depthOut: return depthOut
        }
    }
}

public func steerMapping(rig: CameraRig) -> SteerMapping {
    let basis = rig.basis()
    func screenX(_ axis: Vec3) -> Double { dot(axis, basis.right) }
    func screenY(_ axis: Vec3) -> Double { dot(axis, basis.up) }
    func into(_ axis: Vec3) -> Double { dot(axis, basis.forward) }

    let right = Vec3.six.max { screenX($0) < screenX($1) } ?? .xp
    let upChoices = Vec3.six.filter { $0 != right && $0 != -right }
    let up = upChoices.max { screenY($0) < screenY($1) } ?? .yp
    let depthChoices = Vec3.six.filter { $0 != right && $0 != -right && $0 != up && $0 != -up }
    let depthIn = depthChoices.max { into($0) < into($1) } ?? .zn
    return SteerMapping(
        right: right,
        left: -right,
        up: up,
        down: -up,
        depthIn: depthIn,
        depthOut: -depthIn
    )
}

/// Points of finger travel before a swipe counts. Small so the turn is
/// chosen while the finger is still moving, not after it lifts.
public let swipeThreshold = 15.0

/// One pinch, one depth turn. Spread past 1.15 is 深入; gather inside 0.85 is 拉近.
public let pinchInScale = 0.85
public let pinchOutScale = 1.15

public enum DepthPinch: Equatable {
    /// Fingers together. 拉近, +Z, toward the viewer.
    case inward
    /// Fingers spread. 深入, −Z, into the screen.
    case outward
}

/// Pinch out goes into the screen. Pinch in comes toward the viewer.
/// The 深入 and 拉近 buttons are not affected.
public func depthControl(for pinch: DepthPinch) -> ControlInput {
    switch pinch {
    case .outward: return .depthIn
    case .inward: return .depthOut
    }
}

/// Fires a swipe or a pinch once per gesture, then ignores the rest until
/// the fingers lift. A second swipe needs a new touch.
public struct GestureLock {
    public private(set) var swipeArmed = true
    public private(set) var pinchArmed = true

    public init() {}

    public mutating func swipe(dx: Double, dy: Double) -> ScreenAxis? {
        guard swipeArmed else { return nil }
        guard let axis = classifySwipe(dx: dx, dy: dy, threshold: swipeThreshold) else { return nil }
        swipeArmed = false
        return axis
    }

    public mutating func pinch(scale: Double) -> DepthPinch? {
        guard pinchArmed else { return nil }
        if scale <= pinchInScale {
            pinchArmed = false
            return .inward
        }
        if scale >= pinchOutScale {
            pinchArmed = false
            return .outward
        }
        return nil
    }

    public mutating func endSwipe() { swipeArmed = true }
    public mutating func endPinch() { pinchArmed = true }
    /// A pinch that starts mid-drag must not also become a swipe.
    public mutating func cancelSwipe() { swipeArmed = false }
}

/// UIKit drag: positive `dx` is right, positive `dy` is down.
/// Returns nil for taps and for motions shorter than `threshold` points.
public func classifySwipe(dx: Double, dy: Double, threshold: Double = swipeThreshold) -> ScreenAxis? {
    let adx = abs(dx)
    let ady = abs(dy)
    guard max(adx, ady) >= threshold else { return nil }
    if adx >= ady {
        return dx >= 0 ? .right : .left
    }
    return dy >= 0 ? .down : .up
}

private func dot(_ axis: Vec3, _ vector: (Double, Double, Double)) -> Double {
    Double(axis.x) * vector.0 + Double(axis.y) * vector.1 + Double(axis.z) * vector.2
}

private func cross(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> (Double, Double, Double) {
    (
        a.1 * b.2 - a.2 * b.1,
        a.2 * b.0 - a.0 * b.2,
        a.0 * b.1 - a.1 * b.0
    )
}

private func normalize(_ value: (Double, Double, Double)) -> (Double, Double, Double) {
    let length = (value.0 * value.0 + value.1 * value.1 + value.2 * value.2).squareRoot()
    guard length > 1e-8 else { return (0, 0, 0) }
    return (value.0 / length, value.1 / length, value.2 / length)
}
