import Foundation

/// Where the snake is drawn between grid steps. Collision stays on the cells.
/// A straight run moves at constant speed: fraction 0 sits on the previous
/// cell, fraction 1 on the current cell. A turn replaces 0.15 cell on each
/// side of the corner with a quarter-circle fillet so the body does not stop
/// and then snap to a new axis.
public enum SnakeMotion {
    /// How much of the cell, on each side of a corner, the fillet replaces.
    public static let cornerRadius = 0.15

    public static func position(
        index: Int,
        previous: [Vec3],
        current: [Vec3],
        pendingTurn: Vec3?,
        fraction: Double
    ) -> WorldPoint {
        let t = min(1, max(0, fraction))
        let ends = segmentEnds(index: index, previous: previous, current: current)
        let travel = ends.to - ends.from
        guard travel.isUnitAxis else {
            return mix(ends.from, ends.to, t)
        }
        let radius = cornerRadius
        if let incoming = incomingDirection(index: index, from: ends.from, previous: previous),
           t <= radius,
           turns(incoming, travel) {
            let u = 0.5 + 0.5 * (t / radius)
            return fillet(corner: ends.from, incoming: incoming, outgoing: travel, radius: radius, u: u)
        }
        if let outgoing = outgoingDirection(
            index: index,
            travel: travel,
            previous: previous,
            current: current,
            pendingTurn: pendingTurn
        ), t >= 1 - radius, turns(travel, outgoing) {
            let u = 0.5 * ((t - (1 - radius)) / radius)
            return fillet(corner: ends.to, incoming: travel, outgoing: outgoing, radius: radius, u: u)
        }
        return mix(ends.from, ends.to, t)
    }
}

private func segmentEnds(index: Int, previous: [Vec3], current: [Vec3]) -> (from: Vec3, to: Vec3) {
    guard let head = current.first else { return (.zero, .zero) }
    if index <= 0 {
        return (previous.first ?? head, head)
    }
    if previous.count == current.count, index < previous.count {
        return (previous[index], current[index])
    }
    let clamped = min(index, current.count - 1)
    let from = (index - 1) < previous.count ? previous[index - 1] : current[clamped]
    return (from, current[clamped])
}

/// Direction this segment used to arrive at `from`. Nil when the body has
/// no cell behind it, which is the new tail on a growth step.
private func incomingDirection(index: Int, from: Vec3, previous: [Vec3]) -> Vec3? {
    let behindIndex = index + 1
    guard behindIndex < previous.count else { return nil }
    let step = from - previous[behindIndex]
    return step.isUnitAxis ? step : nil
}

/// Direction this segment will leave `to` on. The head uses the queued turn.
/// A body segment uses the segment ahead, which has already taken the corner.
private func outgoingDirection(
    index: Int,
    travel: Vec3,
    previous: [Vec3],
    current: [Vec3],
    pendingTurn: Vec3?
) -> Vec3? {
    if index <= 0 {
        if let pendingTurn, turns(travel, pendingTurn) { return pendingTurn }
        return nil
    }
    guard previous.count == current.count, index - 1 < previous.count, index - 1 < current.count else {
        return nil
    }
    let ahead = current[index - 1] - previous[index - 1]
    return turns(travel, ahead) ? ahead : nil
}

private func turns(_ incoming: Vec3, _ outgoing: Vec3) -> Bool {
    incoming.isUnitAxis && outgoing.isUnitAxis && incoming.dot(outgoing) == 0
}

private func mix(_ from: Vec3, _ to: Vec3, _ t: Double) -> WorldPoint {
    WorldPoint(
        Double(from.x) + Double(to.x - from.x) * t,
        Double(from.y) + Double(to.y - from.y) * t,
        Double(from.z) + Double(to.z - from.z) * t
    )
}

/// Quarter-circle that is tangent to `incoming` at u = 0 and to `outgoing` at u = 1.
/// u = 0.5 is the point shared by the end of one step and the start of the next,
/// so the head does not jump when the grid step lands.
private func fillet(corner: Vec3, incoming: Vec3, outgoing: Vec3, radius: Double, u: Double) -> WorldPoint {
    let theta = min(1, max(0, u)) * .pi / 2
    let centerX = Double(corner.x) + Double(-incoming.x + outgoing.x) * radius
    let centerY = Double(corner.y) + Double(-incoming.y + outgoing.y) * radius
    let centerZ = Double(corner.z) + Double(-incoming.z + outgoing.z) * radius
    let cosine = cos(theta)
    let sine = sin(theta)
    let offsetX = (Double(-outgoing.x) * cosine + Double(incoming.x) * sine) * radius
    let offsetY = (Double(-outgoing.y) * cosine + Double(incoming.y) * sine) * radius
    let offsetZ = (Double(-outgoing.z) * cosine + Double(incoming.z) * sine) * radius
    return WorldPoint(centerX + offsetX, centerY + offsetY, centerZ + offsetZ)
}
