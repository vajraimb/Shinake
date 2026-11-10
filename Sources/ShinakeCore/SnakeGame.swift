import Foundation

public enum PlayMode: String, Codable, Equatable {
    case classic
    case feeding
}

public enum Phase: Equatable {
    case ready
    case playing
    case paused
    case over
    case won
}

public enum FoodKind: String, Codable, CaseIterable, Equatable {
    case apple
    case star
    case chili
    case mushroom
    case shield
}

public struct FoodPellet: Equatable {
    public var id: Int
    public var kind: FoodKind
    public var position: Vec3

    public init(id: Int, kind: FoodKind, position: Vec3) {
        self.id = id
        self.kind = kind
        self.position = position
    }
}

public enum DeathCause: Equatable {
    case wall
    case ownBody
}

public enum GameEvent: Equatable {
    case ate(FoodKind)
    case graceUsed(remaining: Int)
    case shielded
    case died
    case won
    case turned
    case newBest
    case castFull
}

/// What the play screen should be saying. Copy lives in the app, in Chinese.
public enum CoachCue: Equatable {
    case swipeToStart
    /// A specific thumb move that shortens the path to the food.
    case aim(ControlInput)
    case goEat
    case useDepth(inward: Bool)
    /// A wall bump during the opening lesson. The charge was not spent.
    case practiceSaved
    case graceSaved(left: Int)
    case none
}

public struct RenderSnapshot: Equatable {
    public var snake: [Vec3]
    public var previous: [Vec3]
    public var fraction: Double
    public var direction: Vec3
    public var foods: [FoodPellet]
    public var solids: [Vec3]
    public var grid: Int
    public var alive: Bool
}

/// The whole playable game, with no UIKit and no clock of its own.
/// `update(dt:)` is the frame entry; `debugStep()` forces a single move.
public final class SnakeGame {
    public let profile: DifficultyProfile
    public let mode: PlayMode
    public let mapping: SteerMapping

    public private(set) var snake: [Vec3] = []
    public private(set) var previous: [Vec3] = []
    public private(set) var direction: Vec3 = .xp
    public private(set) var foods: [FoodPellet] = []
    public private(set) var solids: Set<Vec3> = []
    public private(set) var score = 0
    public private(set) var best: Int
    public private(set) var eaten = 0
    public private(set) var phase: Phase = .ready
    public private(set) var graceLeft: Int
    public private(set) var deathCause: DeathCause?
    public private(set) var elapsed: Double = 0
    public private(set) var fraction: Double = 0
    public private(set) var started = false
    public private(set) var autopilot = false
    public private(set) var manualDrive = false
    public private(set) var usedDepth = false
    public private(set) var uiToken = 0
    public private(set) var shieldRemaining: Double = 0
    public private(set) var boostRemaining: Double = 0
    public private(set) var confuseRemaining: Double = 0

    private var rng: SplitMix64
    private var queue: [Vec3] = []
    private var pendingGrowth = 0
    private var extraChop = 0
    private var moveAccumulator: Double = 0
    private var nextFoodID = 0
    private var graceCueUntil: Double = 0
    private var rescueWasFree = false
    private var holdMovesUntil: Double = 0
    private var phaseBeforePause: Phase = .playing
    private var lastCue: CoachCue = .none

    public init(profile: DifficultyProfile, mode: PlayMode, seed: UInt64, best: Int = 0) {
        self.profile = profile
        self.mode = mode
        self.mapping = steerMapping(rig: .standard)
        self.best = max(0, best)
        self.graceLeft = profile.graceCharges
        self.rng = SplitMix64(seed: seed == 0 ? 1 : seed)
        self.solids = profile.solids
        resetBoard()
    }

    public var grid: Int { profile.grid }
    public var length: Int { snake.count }
    public var shieldActive: Bool { shieldRemaining > 0 }
    public var boostActive: Bool { boostRemaining > 0 }

    /// How fast the snake is versus the opening tempo. Starts at 1.
    public var speedMultiple: Double {
        let step = currentStepDuration()
        guard step > 0 else { return 1 }
        return profile.startInterval / step
    }

    public func currentStepDuration() -> Double {
        let base = moveInterval(eaten: eaten, profile: profile)
        let multiplier = boostRemaining > 0 ? profile.chiliMultiplier : 1
        return max(0.05, base * multiplier)
    }

    public var coachCue: CoachCue {
        if graceCueUntil > elapsed {
            return rescueWasFree ? .practiceSaved : .graceSaved(left: graceLeft)
        }
        if mode == .classic && phase == .ready {
            return .swipeToStart
        }
        // Keep pointing at the food through the opening and the depth lesson.
        // A stray depth tap must not dismiss the cue; it stays until the apple
        // is on the snake's layer or the lesson window closes.
        if mode == .classic && profile.showsGuide && eaten < 8
            && (phase == .playing || phase == .ready), let food = foods.first {
            if let depth = preferredDepthCue(toward: food.position) {
                return depth
            }
            if let suggestion = suggestedInput() {
                switch suggestion {
                case .depthIn:
                    return .useDepth(inward: true)
                case .depthOut:
                    return .useDepth(inward: false)
                default:
                    return .aim(suggestion)
                }
            }
        }
        if mode == .classic && eaten == 0 && (phase == .playing || phase == .ready) {
            return .goEat
        }
        return .none
    }

    public func snapshot() -> RenderSnapshot {
        RenderSnapshot(
            snake: snake,
            previous: previous,
            fraction: fraction,
            direction: direction,
            foods: foods,
            solids: solids.sorted { lhs, rhs in
                if lhs.z != rhs.z { return lhs.z < rhs.z }
                if lhs.y != rhs.y { return lhs.y < rhs.y }
                return lhs.x < rhs.x
            },
            grid: grid,
            alive: phase != .over
        )
    }

    // MARK: Input

    public func input(_ input: ControlInput) {
        guard phase == .ready || phase == .playing else { return }
        if mode == .feeding && autopilot && !manualDrive { return }
        if input == .depthIn || input == .depthOut {
            usedDepth = true
        }
        enqueue(mapping.direction(for: input))
    }

    /// Feeding lab only. Up to three dishes on the board.
    @discardableResult
    public func cast(_ kind: FoodKind) -> Bool {
        guard mode == .feeding else { return false }
        guard phase == .playing || phase == .ready else { return false }
        guard foods.count < 3 else { return false }
        let placed = spawn(kind: kind, bias: .interior)
        touchUI()
        return placed
    }

    public func setManualDrive(_ enabled: Bool) {
        guard mode == .feeding else { return }
        manualDrive = enabled
        autopilot = !enabled
        if !enabled {
            queue.removeAll()
        }
        touchUI()
    }

    public func pause() {
        guard phase == .playing || phase == .ready else { return }
        phaseBeforePause = phase
        phase = .paused
        touchUI()
    }

    public func resume() {
        guard phase == .paused else { return }
        phase = phaseBeforePause
        touchUI()
    }

    public func restart() {
        resetBoard()
        touchUI()
    }

    // MARK: Clock

    /// Advances the simulation. `dt` is clamped so a hitch cannot skip the snake
    /// across the cube. Returns events that happened this call.
    @discardableResult
    public func update(dt raw: Double) -> [GameEvent] {
        let dt = min(max(raw, 0), 1.0 / 20.0)
        guard phase == .playing, started else {
            noteCueChange()
            return []
        }
        elapsed += dt
        tickEffects(dt)
        var events: [GameEvent] = []
        if holdMovesUntil > 0 {
            holdMovesUntil = max(0, holdMovesUntil - dt)
            noteCueChange()
            return events
        }
        moveAccumulator += dt
        var spins = 0
        while phase == .playing && spins < 4 {
            let duration = currentStepDuration()
            if moveAccumulator + 1e-9 < duration { break }
            moveAccumulator -= duration
            events.append(contentsOf: step())
            spins += 1
        }
        let duration = currentStepDuration()
        fraction = min(1, max(0, moveAccumulator / duration))
        noteCueChange()
        return events
    }

    /// One logic move, ignoring the clock. Used by tests and not by the renderer.
    @discardableResult
    public func debugStep() -> [GameEvent] {
        guard phase == .playing, started else { return [] }
        let events = step()
        fraction = 0
        noteCueChange()
        return events
    }

    public func debugSetElapsed(_ seconds: Double) {
        elapsed = seconds
        noteCueChange()
    }

    public func debugArrange(
        snake body: [Vec3],
        direction: Vec3,
        foods pellets: [FoodPellet] = [],
        grace: Int? = nil,
        eaten bites: Int? = nil,
        pendingGrowth: Int = 0,
        shield: Double = 0,
        phase: Phase = .playing,
        started: Bool = true
    ) {
        precondition(body.count >= 2)
        snake = body
        previous = body
        self.direction = direction
        foods = pellets
        if let grace { graceLeft = grace }
        if let bites { eaten = bites }
        deathCause = nil
        self.pendingGrowth = pendingGrowth
        shieldRemaining = shield
        self.phase = phase
        self.started = started
        queue.removeAll()
        extraChop = 0
        moveAccumulator = 0
        fraction = 0
        touchUI()
    }

    /// Greedy "which control aims at the apple", skipping fatal and 180° turns.
    /// The coach uses the same choice a careful thumb would make.
    public func suggestedInput() -> ControlInput? {
        guard let food = foods.first else { return nil }
        let options: [(ControlInput, Vec3)] = [
            (.screen(.right), mapping.right),
            (.screen(.left), mapping.left),
            (.screen(.up), mapping.up),
            (.screen(.down), mapping.down),
            (.depthIn, mapping.depthIn),
            (.depthOut, mapping.depthOut),
        ]
        var best: (ControlInput, Int)?
        let growing = pendingGrowth > 0
        for (control, dir) in options {
            if dir == -direction { continue }
            let next = snake[0] + dir
            if isFatal(next, growing: growing) { continue }
            let remaining = next.manhattan(to: food.position)
            if best == nil || remaining < best!.1 {
                best = (control, remaining)
            }
        }
        return best?.0
    }

    // MARK: Board

    private func resetBoard() {
        let center = profile.grid / 2
        snake = [
            Vec3(center + 1, center, center),
            Vec3(center, center, center),
            Vec3(center - 1, center, center),
        ]
        previous = snake
        direction = .xp
        queue.removeAll()
        foods.removeAll()
        pendingGrowth = 0
        extraChop = 0
        moveAccumulator = 0
        fraction = 0
        elapsed = 0
        score = 0
        eaten = 0
        started = false
        usedDepth = false
        graceLeft = profile.graceCharges
        shieldRemaining = 0
        boostRemaining = 0
        confuseRemaining = 0
        graceCueUntil = 0
        solids = profile.solids
        manualDrive = false
        deathCause = nil
        if mode == .feeding {
            autopilot = true
            started = true
            phase = .playing
            // Sit in the middle long enough for the first-entry hint to be read.
            // The AI's first step is a full move after this hold, not immediately.
            holdMovesUntil = 1.4
            moveAccumulator = 0
            _ = spawn(kind: .apple, bias: .interior)
        } else {
            autopilot = false
            phase = .ready
            holdMovesUntil = 0
            _ = spawn(kind: .apple, bias: profile.planarOpeningFoods > 0 ? .openingPlane : .standard)
        }
    }

    private func enqueue(_ direction: Vec3) {
        guard direction.isUnitAxis else { return }
        let last = queue.last ?? self.direction
        if direction == -last { return }
        if direction == last {
            // A forward swipe still counts as "I'm here" and starts the run.
            beginIfNeeded()
            return
        }
        guard queue.count < 2 else { return }
        queue.append(direction)
        beginIfNeeded()
        touchUI()
    }

    private func beginIfNeeded() {
        guard !started else { return }
        started = true
        phase = .playing
        // The first move happens on the next frame, not after a full wait.
        moveAccumulator = currentStepDuration()
        touchUI()
    }

    private func tickEffects(_ dt: Double) {
        if boostRemaining > 0 { boostRemaining = max(0, boostRemaining - dt) }
        if shieldRemaining > 0 { shieldRemaining = max(0, shieldRemaining - dt) }
        if confuseRemaining > 0 { confuseRemaining = max(0, confuseRemaining - dt) }
    }

    private func step() -> [GameEvent] {
        var events: [GameEvent] = []
        previous = snake

        if autopilot && !manualDrive {
            apply(chooseAI(), events: &events)
        } else if !queue.isEmpty {
            apply(queue.removeFirst(), events: &events)
        }

        var next = snake[0] + direction
        let growing = pendingGrowth > 0
        if isFatal(next, growing: growing) {
            if shieldRemaining > 0 && (!inBounds(next) || solids.contains(next)) {
                events.append(.shielded)
                touchUI()
                return events
            }
            if shieldRemaining > 0 {
                events.append(.shielded)
            } else if let rescue = graceRescue() {
                let free = inFreeOpening
                if !free && graceLeft > 0 { graceLeft -= 1 }
                rescueWasFree = free
                direction = rescue
                next = snake[0] + direction
                graceCueUntil = elapsed + 1.7
                events.append(.graceUsed(remaining: graceLeft))
                touchUI()
            } else {
                phase = .over
                deathCause = (!inBounds(next) || solids.contains(next)) ? .wall : .ownBody
                events.append(.died)
                touchUI()
                return events
            }
        }

        snake.insert(next, at: 0)
        if let index = foods.firstIndex(where: { $0.position == next }) {
            let pellet = foods.remove(at: index)
            events.append(contentsOf: applyEat(pellet.kind))
        }
        if pendingGrowth > 0 {
            pendingGrowth -= 1
        } else if snake.count > 1 {
            snake.removeLast()
        }
        if extraChop > 0 {
            let chops = extraChop
            extraChop = 0
            for _ in 0..<chops where snake.count > 3 {
                snake.removeLast()
            }
        }
        let boardCleared = mode == .classic && foods.isEmpty
        if phase == .playing && (snake.count >= freeCellCount || boardCleared) {
            phase = .won
            events.append(.won)
        }
        touchUI()
        return events
    }

    private func apply(_ candidate: Vec3, events: inout [GameEvent]) {
        guard candidate.isUnitAxis else { return }
        if candidate == direction || candidate == -direction { return }
        direction = candidate
        events.append(.turned)
    }

    private func applyEat(_ kind: FoodKind) -> [GameEvent] {
        var events: [GameEvent] = []
        eaten += 1
        switch kind {
        case .apple:
            score += 10
            pendingGrowth += 1
        case .star:
            score += 30
            pendingGrowth += 1
        case .chili:
            score += 8
            pendingGrowth += 1
            boostRemaining = 5
        case .mushroom:
            score += 5
            confuseRemaining = 2.4
            // Head is already inserted, so count is one above the pre-bite length.
            if snake.count > 9 { extraChop = 2 }
        case .shield:
            score += 6
            shieldRemaining = max(shieldRemaining, 7)
        }
        if score > best {
            best = score
            events.append(.newBest)
        }
        // A bite puts the shield back to full, so one apple undoes a clumsy stretch.
        if profile.refillsGrace && !inFreeOpening && elapsed <= profile.graceWindow + 1e-6 {
            graceLeft = profile.graceCharges
        }
        events.append(.ate(kind))
        if mode == .classic {
            _ = spawn(kind: .apple, bias: classicBias)
        }
        return events
    }

    private var classicBias: SpawnBias {
        if eaten < profile.planarOpeningFoods { return .openingPlane }
        if profile.showsGuide && eaten == profile.planarOpeningFoods { return .depthLesson }
        return .standard
    }

    private enum SpawnBias {
        case openingPlane
        case depthLesson
        case interior
        case standard
    }

    @discardableResult
    private func spawn(kind: FoodKind, bias: SpawnBias) -> Bool {
        let head = snake[0]
        var occupied = solids
        for cell in snake { occupied.insert(cell) }
        for pellet in foods { occupied.insert(pellet.position) }

        var preferred: [Vec3] = []
        var fallback: [Vec3] = []
        let n = profile.grid
        let margin = bias == .interior ? 2 : 1
        for z in 0..<n {
            for y in 0..<n {
                for x in 0..<n {
                    let cell = Vec3(x, y, z)
                    if occupied.contains(cell) { continue }
                    let distance = cell.manhattan(to: head)
                    let inset = x >= margin && y >= margin && z >= margin
                        && x < n - margin && y < n - margin && z < n - margin
                    switch bias {
                    case .openingPlane:
                        if cell.z == head.z && distance >= 2 && distance <= 4 && inset {
                            preferred.append(cell)
                        }
                    case .depthLesson:
                        let planar = abs(cell.x - head.x) + abs(cell.y - head.y)
                        let depth = abs(cell.z - head.z)
                        if depth >= 1 && planar <= 2 && distance >= 2 && distance <= 5 && inset {
                            preferred.append(cell)
                        }
                    case .interior:
                        if inset && cell.z == head.z && distance >= 2 && distance <= 4 {
                            preferred.append(cell)
                        } else if inset && distance >= profile.minFoodDistance {
                            fallback.append(cell)
                        }
                    case .standard:
                        if distance >= profile.minFoodDistance {
                            preferred.append(cell)
                        }
                    }
                    if bias != .interior { fallback.append(cell) }
                }
            }
        }
        let pool = preferred.isEmpty ? fallback : preferred
        guard !pool.isEmpty else { return false }
        let index = rng.int(below: pool.count)
        nextFoodID += 1
        foods.append(FoodPellet(id: nextFoodID, kind: kind, position: pool[index]))
        return true
    }

    private var freeCellCount: Int {
        profile.grid * profile.grid * profile.grid - solids.count
    }

    private func inBounds(_ cell: Vec3) -> Bool {
        cell.x >= 0 && cell.y >= 0 && cell.z >= 0
            && cell.x < grid && cell.y < grid && cell.z < grid
    }

    /// `growing` means the tail cell does not vacate this move.
    private func isFatal(_ cell: Vec3, growing: Bool) -> Bool {
        if !inBounds(cell) || solids.contains(cell) { return true }
        let bodyCount = growing ? snake.count : max(0, snake.count - 1)
        if bodyCount == 0 { return false }
        for index in 0..<bodyCount where snake[index] == cell {
            return true
        }
        return false
    }

    /// Depth wins ties. Otherwise a same-length planar step hides the lesson.
    private func preferredDepthCue(toward food: Vec3) -> CoachCue? {
        guard food.z != snake[0].z else { return nil }
        let growing = pendingGrowth > 0
        func remaining(_ dir: Vec3) -> Int? {
            if dir == -direction { return nil }
            let next = snake[0] + dir
            if isFatal(next, growing: growing) { return nil }
            return next.manhattan(to: food)
        }
        let inward = remaining(mapping.depthIn)
        let outward = remaining(mapping.depthOut)
        let depth: (Vec3, Int)?
        if let left = inward, left <= (outward ?? Int.max) {
            depth = (mapping.depthIn, left)
        } else if let right = outward {
            depth = (mapping.depthOut, right)
        } else {
            depth = nil
        }
        guard let depth else { return nil }
        let planar = [mapping.right, mapping.left, mapping.up, mapping.down]
        var bestPlanar = Int.max
        for dir in planar {
            if let left = remaining(dir) { bestPlanar = min(bestPlanar, left) }
        }
        guard depth.1 <= bestPlanar else { return nil }
        return .useDepth(inward: depth.0 == mapping.depthIn)
    }

    /// Opening bumps are free, so a player feeling out the cube is not punished
    /// before the three on-layer apples and the depth lesson.
    private var inFreeOpening: Bool {
        profile.freeRescuesUntilEaten > 0 && eaten < profile.freeRescuesUntilEaten
    }

    /// Easy keeps turning a fatal move aside for the whole grace window, even
    /// after the counter hits zero, so a clumsy first minute can finish the lesson.
    private var windowKeepsYouAlive: Bool {
        profile.refillsGrace && profile.graceWindow > 0 && elapsed <= profile.graceWindow + 1e-6
    }

    private func graceRescue() -> Vec3? {
        let charged = graceLeft > 0 && elapsed <= profile.graceWindow + 1e-6
        guard inFreeOpening || windowKeepsYouAlive || charged else { return nil }
        let growing = pendingGrowth > 0
        let options = Vec3.six.filter { dir in
            dir != -direction && !isFatal(snake[0] + dir, growing: growing)
        }
        guard !options.isEmpty else { return nil }
        let target = foods.first?.position
        return options.min { lhs, rhs in
            let leftDistance = target?.manhattan(to: snake[0] + lhs) ?? 0
            let rightDistance = target?.manhattan(to: snake[0] + rhs) ?? 0
            if leftDistance != rightDistance { return leftDistance < rightDistance }
            return axisOrder(lhs) < axisOrder(rhs)
        }
    }

    private func touchUI() {
        uiToken &+= 1
    }

    private func noteCueChange() {
        let cue = coachCue
        if cue != lastCue {
            lastCue = cue
            touchUI()
        }
    }

    // MARK: Autopilot
    //
    // The desktop snake chases food with BFS and only bites when it can still
    // reach its own tail afterwards. Same idea, smaller: the phone board is
    // at most 12³, so a full search per move is cheap.

    private func chooseAI() -> Vec3 {
        let reverse = -direction
        if confuseRemaining > 0 && rng.unit() < 0.45 {
            let options = safeDirections().filter { $0 != reverse }
            if !options.isEmpty {
                return options[rng.int(below: options.count)]
            }
        }
        if let target = nearestFood() {
            let field = distances(to: target, blocked: blockedCells())
            var best: Vec3?
            var bestDistance = Int.max
            for dir in Vec3.six where dir != reverse {
                let next = snake[0] + dir
                guard let distance = field[next], distance < bestDistance else { continue }
                if safeToPursue(first: dir, target: target, field: field) {
                    bestDistance = distance
                    best = dir
                }
            }
            if let best { return best }
        }
        let tail = snake[snake.count - 1]
        let field = distances(to: tail, blocked: blockedCells())
        var best: Vec3?
        var bestDistance = Int.max
        for dir in Vec3.six where dir != reverse {
            let next = snake[0] + dir
            guard let distance = field[next], distance < bestDistance else { continue }
            bestDistance = distance
            best = dir
        }
        if let best { return best }
        if let side = safeDirections().first(where: { $0 != reverse }) { return side }
        return safeDirections().first ?? direction
    }

    private func nearestFood() -> Vec3? {
        let blocked = blockedCells()
        var best: Vec3?
        var bestDistance = Int.max
        for pellet in foods {
            let field = distances(to: pellet.position, blocked: blocked)
            guard let distance = field[snake[0]], distance < bestDistance else { continue }
            bestDistance = distance
            best = pellet.position
        }
        return best
    }

    private func blockedCells() -> Set<Vec3> {
        var blocked = solids
        for cell in snake { blocked.insert(cell) }
        blocked.remove(snake[0])
        if pendingGrowth <= 0 {
            blocked.remove(snake[snake.count - 1])
        }
        return blocked
    }

    private func safeDirections() -> [Vec3] {
        let growing = pendingGrowth > 0
        return Vec3.six.filter { !isFatal(snake[0] + $0, growing: growing) }
    }

    private func distances(to target: Vec3, blocked: Set<Vec3>) -> [Vec3: Int] {
        guard inBounds(target), !blocked.contains(target) else { return [:] }
        var distance: [Vec3: Int] = [target: 0]
        var queue: [Vec3] = [target]
        var head = 0
        while head < queue.count {
            let cell = queue[head]
            head += 1
            let base = distance[cell] ?? 0
            for dir in Vec3.six {
                let next = cell + dir
                if !inBounds(next) || blocked.contains(next) || distance[next] != nil { continue }
                distance[next] = base + 1
                queue.append(next)
            }
        }
        return distance
    }

    /// Walk the shortest path after taking `first`, then ask whether the head
    /// can still reach its tail. A bite that seals the snake in is refused.
    private func safeToPursue(first: Vec3, target: Vec3, field: [Vec3: Int]) -> Bool {
        var sim = snake
        var grow = pendingGrowth
        var current = snake[0]
        var steps = 0
        let limit = grid * grid * grid
        while true {
            let next: Vec3
            if steps == 0 {
                next = current + first
                if field[next] == nil { return false }
            } else {
                guard let here = field[current] else { return false }
                var found: Vec3?
                for dir in Vec3.six {
                    let candidate = current + dir
                    if field[candidate] == here - 1 {
                        found = candidate
                        break
                    }
                }
                guard let found else { return false }
                next = found
            }
            current = next
            sim.insert(current, at: 0)
            if current == target { grow += 1 }
            if grow > 0 {
                grow -= 1
            } else if sim.count > 1 {
                sim.removeLast()
            }
            steps += 1
            if current == target { break }
            if steps > limit { return false }
        }

        var blocked = solids
        for cell in sim { blocked.insert(cell) }
        blocked.remove(sim[0])
        if sim.count > 1 { blocked.remove(sim[sim.count - 1]) }
        let tailField = distances(to: sim[sim.count - 1], blocked: blocked)
        for dir in Vec3.six {
            let next = sim[0] + dir
            if tailField[next] != nil { return true }
        }
        return false
    }
}

private func axisOrder(_ direction: Vec3) -> Int {
    switch direction {
    case .xp: return 0
    case .xn: return 1
    case .yp: return 2
    case .yn: return 3
    case .zp: return 4
    default: return 5
    }
}
