import Foundation

public enum DuelPhase: String, Codable, Equatable {
    case playing
    case sudden
    case finished
}

public enum DuelEndReason: String, Codable, Equatable {
    case score
    case suddenFood
    case opponentLeft
    case hostLeft
}

public struct DuelSnakeState: Codable, Equatable {
    public var cells: [Vec3]
    public var previous: [Vec3]
    public var direction: Vec3
    public var pendingTurn: Vec3?
    public var fraction: Double
    public var stepDuration: Double
    public var score: Int
    public var alive: Bool
    public var aura: FoodKind?
    public var shield: Bool

    public init(
        cells: [Vec3],
        previous: [Vec3],
        direction: Vec3,
        pendingTurn: Vec3?,
        fraction: Double,
        stepDuration: Double,
        score: Int,
        alive: Bool,
        aura: FoodKind?,
        shield: Bool
    ) {
        self.cells = cells
        self.previous = previous
        self.direction = direction
        self.pendingTurn = pendingTurn
        self.fraction = fraction
        self.stepDuration = stepDuration
        self.score = score
        self.alive = alive
        self.aura = aura
        self.shield = shield
    }
}

public struct DuelSnapshot: Codable, Equatable {
    public var tick: Int
    public var elapsed: Double
    public var timeLeft: Double
    public var phase: DuelPhase
    public var reason: DuelEndReason?
    public var winner: DuelRole?
    public var foods: [FoodPellet]
    public var arena: ArenaSize
    public var host: DuelSnakeState
    public var joiner: DuelSnakeState

    public init(
        tick: Int,
        elapsed: Double,
        timeLeft: Double,
        phase: DuelPhase,
        reason: DuelEndReason?,
        winner: DuelRole?,
        foods: [FoodPellet],
        arena: ArenaSize,
        host: DuelSnakeState,
        joiner: DuelSnakeState
    ) {
        self.tick = tick
        self.elapsed = elapsed
        self.timeLeft = timeLeft
        self.phase = phase
        self.reason = reason
        self.winner = winner
        self.foods = foods
        self.arena = arena
        self.host = host
        self.joiner = joiner
    }

    /// Glide ahead of a received snapshot without moving any cell.
    public func advanced(by dt: Double) -> DuelSnapshot {
        var copy = self
        copy.host = copy.host.glided(by: dt)
        copy.joiner = copy.joiner.glided(by: dt)
        if phase == .playing {
            copy.timeLeft = max(0, timeLeft - dt)
            copy.elapsed += dt
        }
        return copy
    }
}

extension DuelSnakeState {
    fileprivate func glided(by dt: Double) -> DuelSnakeState {
        var copy = self
        guard alive, stepDuration > 0 else { return copy }
        copy.fraction = min(1, fraction + dt / stepDuration)
        return copy
    }
}

public enum DuelWire: Codable, Equatable {
    case hello(String)
    case input(seq: Int, control: ControlInput)
    case snapshot(DuelSnapshot)
}

public enum DuelWireCodec {
    public static func encode(_ wire: DuelWire) throws -> Data {
        try JSONEncoder().encode(wire)
    }

    public static func decode(_ data: Data) -> DuelWire? {
        try? JSONDecoder().decode(DuelWire.self, from: data)
    }
}

/// Who gets a food when both snakes reach it on the same beat.
/// A tie returns nil: the food is thrown out and nobody scores.
public func duelFoodWinner(hostDistance: Int, joinerDistance: Int) -> DuelRole? {
    if hostDistance < joinerDistance { return .host }
    if joinerDistance < hostDistance { return .joiner }
    return nil
}

/// Two snakes, one board, one clock. No sockets: the host runs this and sends snapshots.
public final class DuelMatch {
    public static let stepDuration = 0.28
    public static let matchLength = 180.0
    public static let respawnDelay = 1.5
    public static let respawnPenalty = 10
    public static let invulnDuration = 1.0
    public static let guestDropDelay = 5.0

    public let arena: ArenaSize
    public private(set) var phase: DuelPhase = .playing
    public private(set) var reason: DuelEndReason?
    public private(set) var winner: DuelRole?
    public private(set) var foods: [FoodPellet] = []
    public private(set) var elapsed: Double = 0
    public private(set) var timeLeft: Double = DuelMatch.matchLength
    public private(set) var tick = 0

    private var host = Racer()
    private var joiner = Racer()
    private var rng: SplitMix64
    private var nextFoodID = 1
    private let mapping = steerMapping(rig: .standard)
    private var guestDropLeft: Double?

    public init(seed: UInt64, arena: ArenaSize = Difficulty.normal.profile.arena) {
        self.arena = arena
        self.rng = SplitMix64(seed: seed == 0 ? 1 : seed)
        let z = arena.depth / 2
        let y = arena.height / 2
        host.cells = [Vec3(2, y, z), Vec3(1, y, z), Vec3(0, y, z)]
        host.previous = host.cells
        host.direction = .xp
        joiner.cells = [Vec3(arena.width - 3, y, z), Vec3(arena.width - 2, y, z), Vec3(arena.width - 1, y, z)]
        joiner.previous = joiner.cells
        joiner.direction = .xn
        refillFoods()
    }

    public func snapshot() -> DuelSnapshot {
        DuelSnapshot(
            tick: tick,
            elapsed: elapsed,
            timeLeft: timeLeft,
            phase: phase,
            reason: reason,
            winner: winner,
            foods: foods,
            arena: arena,
            host: host.state,
            joiner: joiner.state
        )
    }

    public func input(_ role: DuelRole, _ control: ControlInput) {
        guard phase == .playing || phase == .sudden else { return }
        var racer = self[role]
        guard racer.alive else { return }
        var dir = mapping.direction(for: control)
        if racer.reverseRemaining > 0 { dir = -dir }
        guard dir.isUnitAxis else { return }
        let facing = racer.queue.last ?? racer.direction
        if dir == -facing { return }
        if dir == facing { return }
        guard racer.queue.count < 2 else { return }
        racer.queue.append(dir)
        self[role] = racer
    }

    /// The other phone went away. A dropped guest gives the host the win after five seconds.
    /// A dropped host ends the match immediately.
    public func remoteDropped(_ role: DuelRole) {
        guard phase == .playing || phase == .sudden else { return }
        if role == .host {
            phase = .finished
            reason = .hostLeft
            winner = nil
            return
        }
        if guestDropLeft == nil { guestDropLeft = DuelMatch.guestDropDelay }
    }

    @discardableResult
    public func update(dt raw: Double) -> DuelSnapshot {
        let dt = min(max(raw, 0), 1.0 / 20.0)
        guard phase == .playing || phase == .sudden else { return snapshot() }
        elapsed += dt
        if phase == .playing {
            timeLeft = max(0, DuelMatch.matchLength - elapsed)
        }
        if let left = guestDropLeft {
            let next = left - dt
            if next <= 0 {
                guestDropLeft = nil
                phase = .finished
                reason = .opponentLeft
                winner = .host
                return snapshot()
            }
            guestDropLeft = next
        }
        host.tick(dt)
        joiner.tick(dt)
        let hostMoves = host.alive && host.accumulator + 1e-9 >= host.stepDuration
        let joinerMoves = joiner.alive && joiner.accumulator + 1e-9 >= joiner.stepDuration
        if hostMoves { host.accumulator -= host.stepDuration }
        if joinerMoves { joiner.accumulator -= joiner.stepDuration }
        if hostMoves || joinerMoves {
            beat(hostMoves: hostMoves, joinerMoves: joinerMoves)
            tick += 1
        }
        reapRespawns()
        host.fraction = min(1, host.accumulator / host.stepDuration)
        joiner.fraction = min(1, joiner.accumulator / joiner.stepDuration)
        if phase == .playing && timeLeft <= 0 {
            closeOnTime()
        }
        return snapshot()
    }

    /// One simultaneous beat, ignoring the clock. Tests place the snakes first.
    public func debugBeat() {
        guard phase == .playing || phase == .sudden else { return }
        beat(hostMoves: host.alive, joinerMoves: joiner.alive)
        tick += 1
    }

    public func debugPlace(
        host cells: [Vec3],
        hostDirection: Vec3,
        joiner other: [Vec3],
        joinerDirection: Vec3,
        foods pellets: [FoodPellet],
        hostShield: Double = 0,
        joinerShield: Double = 0
    ) {
        host.cells = cells
        host.previous = cells
        host.direction = hostDirection
        host.queue.removeAll()
        host.alive = true
        host.shieldRemaining = hostShield
        host.invuln = 0
        host.pendingGrowth = 0
        joiner.cells = other
        joiner.previous = other
        joiner.direction = joinerDirection
        joiner.queue.removeAll()
        joiner.alive = true
        joiner.shieldRemaining = joinerShield
        joiner.invuln = 0
        joiner.pendingGrowth = 0
        foods = pellets
    }

    public func debugScores(host: Int, joiner: Int) {
        self.host.score = host
        self.joiner.score = joiner
    }

    public func debugSetElapsed(_ seconds: Double) {
        elapsed = seconds
        if phase == .playing {
            timeLeft = max(0, DuelMatch.matchLength - elapsed)
        }
    }

    // MARK: Beat

    private func beat(hostMoves: Bool, joinerMoves: Bool) {
        if hostMoves { host.commitTurn() }
        if joinerMoves { joiner.commitTurn() }
        let nextH = hostMoves ? host.cells[0] + host.direction : host.cells[0]
        let nextJ = joinerMoves ? joiner.cells[0] + joiner.direction : joiner.cells[0]
        let swapping = hostMoves && joinerMoves && nextH == joiner.cells[0] && nextJ == host.cells[0]
        let crowding = hostMoves && joinerMoves && nextH == nextJ
        if crowding, let food = foods.first(where: { $0.position == nextH }) {
            resolveSharedFood(food, next: nextH)
            return
        }
        if swapping {
            resolveClash(nextH: nextH, nextJ: nextJ, hostMoves: hostMoves, joinerMoves: joinerMoves)
            return
        }
        let hostHit = hostMoves && hits(nextH, mover: .host, otherMoves: joinerMoves)
        let joinerHit = joinerMoves && hits(nextJ, mover: .joiner, otherMoves: hostMoves)
        if hostHit { resolveHit(.host) }
        if joinerHit { resolveHit(.joiner) }
        if hostMoves && host.alive { advance(.host, to: nextH) }
        if joinerMoves && joiner.alive { advance(.joiner, to: nextJ) }
        host.decayBoost()
        joiner.decayBoost()
        refillFoods()
    }

    /// Both snakes step onto one food. The snake that started closer eats it.
    /// An equal distance throws the food out and neither snake scores.
    private func resolveSharedFood(_ food: FoodPellet, next: Vec3) {
        let hostDistance = host.cells[0].manhattan(to: food.position)
        let joinerDistance = joiner.cells[0].manhattan(to: food.position)
        if let winner = duelFoodWinner(hostDistance: hostDistance, joinerDistance: joinerDistance) {
            let loser: DuelRole = winner == .host ? .joiner : .host
            if self[loser].shieldRemaining > 0 {
                var spared = self[loser]
                spared.shieldRemaining = 0
                self[loser] = spared
            } else {
                kill(loser)
            }
            advance(winner, to: next)
        } else {
            foods.removeAll { $0.id == food.id }
        }
        host.decayBoost()
        joiner.decayBoost()
        refillFoods()
    }

    private func resolveClash(nextH: Vec3, nextJ: Vec3, hostMoves: Bool, joinerMoves: Bool) {
        let hostShield = host.shieldRemaining > 0
        let joinerShield = joiner.shieldRemaining > 0
        if hostShield && !joinerShield {
            host.shieldRemaining = 0
            kill(.joiner)
            if hostMoves { advance(.host, to: nextH) }
        } else if joinerShield && !hostShield {
            joiner.shieldRemaining = 0
            kill(.host)
            if joinerMoves { advance(.joiner, to: nextJ) }
        } else {
            if hostShield { host.shieldRemaining = 0 }
            if joinerShield { joiner.shieldRemaining = 0 }
            kill(.host)
            kill(.joiner)
        }
        host.decayBoost()
        joiner.decayBoost()
        refillFoods()
    }

    private func hits(_ cell: Vec3, mover: DuelRole, otherMoves: Bool) -> Bool {
        let me = self[mover]
        if me.invuln > 0 { return false }
        if !inBounds(cell) { return true }
        if occupied(by: mover, moving: true).contains(cell) { return true }
        let other: DuelRole = mover == .host ? .joiner : .host
        let them = self[other]
        if them.invuln > 0 || !them.alive { return false }
        return occupied(by: other, moving: otherMoves).contains(cell)
    }

    private func resolveHit(_ role: DuelRole) {
        var racer = self[role]
        if racer.shieldRemaining > 0 {
            racer.shieldRemaining = 0
            self[role] = racer
            return
        }
        self[role] = racer
        kill(role)
    }

    private func advance(_ role: DuelRole, to cell: Vec3) {
        var racer = self[role]
        racer.previous = racer.cells
        racer.cells.insert(cell, at: 0)
        if let index = foods.firstIndex(where: { $0.position == cell }) {
            let pellet = foods.remove(at: index)
            applyEat(pellet, to: &racer, role: role)
        }
        if racer.pendingGrowth > 0 {
            racer.pendingGrowth -= 1
        } else if racer.cells.count > 1 {
            racer.cells.removeLast()
        }
        if racer.extraChop > 0 {
            let chops = racer.extraChop
            racer.extraChop = 0
            for _ in 0..<chops where racer.cells.count > 3 {
                racer.cells.removeLast()
            }
        }
        self[role] = racer
    }

    private func applyEat(_ pellet: FoodPellet, to racer: inout Racer, role: DuelRole) {
        if phase == .sudden {
            phase = .finished
            reason = .suddenFood
            winner = role
        }
        switch pellet.kind {
        case .apple:
            racer.score += OfficialMenu.appleScore
            racer.pendingGrowth += 1
        case .star:
            racer.score += OfficialMenu.starScore
            racer.pendingGrowth += 1
            racer.flash = .star
        case .chili:
            racer.score += OfficialMenu.chiliScore
            racer.pendingGrowth += 1
            racer.boostSteps = OfficialMenu.chiliSteps
        case .frost:
            racer.score += OfficialMenu.frostScore
            racer.frostRemaining = OfficialMenu.frostSeconds
        case .cherry:
            racer.score += OfficialMenu.cherryScore
            racer.pendingGrowth += OfficialMenu.cherryGrowth
            racer.flash = .cherry
        case .shield:
            racer.score += OfficialMenu.shieldScore
            racer.shieldRemaining = max(racer.shieldRemaining, OfficialMenu.shieldSeconds)
        case .mushroom:
            racer.score += OfficialMenu.mushroomScore
            racer.reverseRemaining = OfficialMenu.mushroomReverse
            if racer.cells.count > 9 { racer.extraChop = OfficialMenu.mushroomChop }
        case .bolt:
            racer.score += OfficialMenu.boltScore
            racer.flash = .bolt
            pullFoods(toward: racer.cells[0], steps: OfficialMenu.boltPullInBattle)
        }
    }

    private func kill(_ role: DuelRole) {
        var racer = self[role]
        guard racer.alive, racer.invuln <= 0 else { return }
        racer.alive = false
        racer.score = max(0, racer.score - DuelMatch.respawnPenalty)
        racer.respawnIn = DuelMatch.respawnDelay
        racer.boostSteps = 0
        racer.frostRemaining = 0
        racer.shieldRemaining = 0
        racer.reverseRemaining = 0
        racer.queue.removeAll()
        self[role] = racer
    }

    private func occupied(by role: DuelRole, moving: Bool) -> Set<Vec3> {
        let racer = self[role]
        guard racer.alive, racer.invuln <= 0 else { return [] }
        var cells = racer.cells
        if moving && racer.pendingGrowth == 0 && cells.count > 1 {
            cells.removeLast()
        }
        return Set(cells)
    }

    private func closeOnTime() {
        if host.score > joiner.score {
            phase = .finished
            reason = .score
            winner = .host
        } else if joiner.score > host.score {
            phase = .finished
            reason = .score
            winner = .joiner
        } else {
            phase = .sudden
            timeLeft = 0
        }
    }

    private func refillFoods() {
        guard phase == .playing || phase == .sudden else { return }
        while foods.count < 2 {
            guard let cell = openCell() else { return }
            let kind = OfficialMenu.roll(&rng)
            foods.append(FoodPellet(id: nextFoodID, kind: kind, position: cell))
            nextFoodID += 1
        }
    }

    private func pullFoods(toward head: Vec3, steps: Int) {
        for _ in 0..<steps {
            var blocked = self.occupied(by: .host, moving: false)
            blocked.formUnion(self.occupied(by: .joiner, moving: false))
            for index in foods.indices {
                let pos = foods[index].position
                let dx = head.x - pos.x
                let dy = head.y - pos.y
                let dz = head.z - pos.z
                let step: Vec3
                if abs(dx) >= abs(dy) && abs(dx) >= abs(dz) && dx != 0 {
                    step = Vec3(dx > 0 ? 1 : -1, 0, 0)
                } else if abs(dy) >= abs(dz) && dy != 0 {
                    step = Vec3(0, dy > 0 ? 1 : -1, 0)
                } else if dz != 0 {
                    step = Vec3(0, 0, dz > 0 ? 1 : -1)
                } else {
                    continue
                }
                let next = pos + step
                if !inBounds(next) || blocked.contains(next) || foods.contains(where: { $0.position == next }) {
                    continue
                }
                foods[index].position = next
                blocked.insert(next)
            }
        }
    }

    private func openCell() -> Vec3? {
        var blocked = occupied(by: .host, moving: false)
        blocked.formUnion(occupied(by: .joiner, moving: false))
        for food in foods { blocked.insert(food.position) }
        var picks: [Vec3] = []
        for z in 0..<arena.depth {
            for y in 1..<(arena.height - 1) {
                for x in 1..<(arena.width - 1) {
                    let cell = Vec3(x, y, z)
                    if blocked.contains(cell) { continue }
                    picks.append(cell)
                }
            }
        }
        guard !picks.isEmpty else { return nil }
        return picks[rng.int(below: picks.count)]
    }

    private func respawn(_ role: DuelRole) {
        let other: DuelRole = role == .host ? .joiner : .host
        let otherHead = self[other].cells.first ?? Vec3(arena.width / 2, arena.height / 2, arena.depth / 2)
        var spot: Vec3?
        for z in 0..<arena.depth {
            for y in 2..<(arena.height - 2) {
                for x in 2..<(arena.width - 2) {
                    let cell = Vec3(x, y, z)
                    if cell.manhattan(to: otherHead) < 6 { continue }
                    if foods.contains(where: { $0.position == cell }) { continue }
                    if occupied(by: other, moving: false).contains(cell) { continue }
                    spot = cell
                    break
                }
                if spot != nil { break }
            }
            if spot != nil { break }
        }
        guard let head = spot else { return }
        var dir = Vec3.xp
        var tailA = head + .xn
        var tailB = head + .xn + .xn
        if !inBounds(tailB) {
            dir = .xn
            tailA = head + .xp
            tailB = head + .xp + .xp
        }
        var racer = self[role]
        racer.cells = [head, tailA, tailB]
        racer.previous = racer.cells
        racer.direction = dir
        racer.alive = true
        racer.respawnIn = 0
        racer.invuln = DuelMatch.invulnDuration
        racer.fraction = 0
        racer.accumulator = 0
        self[role] = racer
    }

    private func inBounds(_ cell: Vec3) -> Bool {
        cell.x >= 0 && cell.y >= 0 && cell.z >= 0
            && cell.x < arena.width && cell.y < arena.height && cell.z < arena.depth
    }

    private subscript(role: DuelRole) -> Racer {
        get { role == .host ? host : joiner }
        set {
            if role == .host { host = newValue } else { joiner = newValue }
        }
    }
}

private struct Racer {
    var cells: [Vec3] = []
    var previous: [Vec3] = []
    var direction: Vec3 = .xp
    var queue: [Vec3] = []
    var score = 0
    var alive = true
    var accumulator = 0.0
    var fraction = 0.0
    var boostSteps = 0
    var frostRemaining = 0.0
    var shieldRemaining = 0.0
    var reverseRemaining = 0.0
    var respawnIn = 0.0
    var invuln = 0.0
    var pendingGrowth = 0
    var extraChop = 0
    var flash: FoodKind?

    var stepDuration: Double {
        var duration = DuelMatch.stepDuration
        if boostSteps > 0 { duration *= OfficialMenu.chiliFactor }
        if frostRemaining > 0 { duration *= OfficialMenu.frostFactor }
        return duration
    }

    var state: DuelSnakeState {
        DuelSnakeState(
            cells: cells,
            previous: previous,
            direction: direction,
            pendingTurn: queue.first,
            fraction: fraction,
            stepDuration: stepDuration,
            score: score,
            alive: alive,
            aura: aura,
            shield: shieldRemaining > 0
        )
    }

    var aura: FoodKind? {
        if shieldRemaining > 0 { return .shield }
        if frostRemaining > 0 { return .frost }
        if boostSteps > 0 { return .chili }
        if reverseRemaining > 0 { return .mushroom }
        return flash
    }

    mutating func tick(_ dt: Double) {
        if frostRemaining > 0 { frostRemaining = max(0, frostRemaining - dt) }
        if shieldRemaining > 0 { shieldRemaining = max(0, shieldRemaining - dt) }
        if reverseRemaining > 0 { reverseRemaining = max(0, reverseRemaining - dt) }
        if invuln > 0 { invuln = max(0, invuln - dt) }
        if !alive {
            respawnIn = max(0, respawnIn - dt)
        }
    }

    mutating func commitTurn() {
        guard alive, let turn = queue.first else { return }
        queue.removeFirst()
        if turn == direction || turn == -direction { return }
        direction = turn
    }

    mutating func decayBoost() {
        if boostSteps > 0 { boostSteps -= 1 }
    }
}

extension DuelMatch {
    /// Respawn is checked from update, after effects tick, so a 1.5s timer can be tested with `update`.
    fileprivate func reapRespawns() {
        if !host.alive && host.respawnIn <= 0 { respawn(.host) }
        if !joiner.alive && joiner.respawnIn <= 0 { respawn(.joiner) }
    }
}
