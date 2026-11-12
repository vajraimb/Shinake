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
    /// Set when the pellet is a player-designed feed. Classic foods leave this nil.
    public var recipe: FeedDesign?

    public init(id: Int, kind: FoodKind, position: Vec3, recipe: FeedDesign? = nil) {
        self.id = id
        self.kind = kind
        self.position = position
        self.recipe = recipe
    }
}

public enum DeathCause: Equatable {
    case wall
    case ownBody
}

public enum GameEvent: Equatable {
    case ate(FoodKind)
    /// A designed feed was eaten. The id is the player's recipe.
    case recipeEaten(String)
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
    /// One press or pinch changes a single layer. `layers` is how many are left.
    case useDepth(inward: Bool, layers: Int)
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
    /// Queued turn the head should face before the body steps.
    public var pendingTurn: Vec3?
    /// 1 is the normal body. Grow and shrink feeds push it for a few seconds.
    public var snakeScale: Double
    public var colorShift: Bool
}

/// Drawn thickness of the snake, in cell radii. Collision stays on the grid.
public enum SnakeBody {
    public static let headRadius = 0.23
    public static let neckRadius = 0.20
    public static let tailRadius = 0.10
    /// Eyes, pupils, sockets, and the tongue, relative to the old 0.30 head.
    public static let featureScale = headRadius / 0.30
    public static let growMultiplier = 1.28
    public static let shrinkMultiplier = 0.72
}

/// Where a classic score is stored. A run that brought a feed loadout must
/// not share a key with the plain 简单 / 普通 / 困难 record.
public enum ScoreBoard {
    public static func localBestKey(difficulty: Difficulty, separateLoadout: Bool) -> String {
        if separateLoadout {
            return "shinake.best.loadout.\(difficulty.rawValue)"
        }
        return "shinake.best.\(difficulty.rawValue)"
    }
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
    /// Recipes eaten during this run, in order, for the feed-card stats.
    public private(set) var eatenRecipes: [String] = []
    /// The opening lesson has gone 15s without a bite. The apple steps closer
    /// and the snake eases off so a lost thumb can catch the arrow.
    public private(set) var hintUrgent = false

    private var rng: SplitMix64
    private var queue: [QueuedTurn] = []
    /// Last X/Y heading. A depth press borrows ±Z for one step, then comes back here.
    private var planarHeading: Vec3 = .xp
    /// The next step should leave Z and restore `planarHeading`.
    private var resumePlanar = false
    /// Depth direction already accepted since the last tick. A second copy is a double-fire.
    private var depthThisTick: Vec3?
    private var pendingGrowth = 0
    private var extraChop = 0
    private var moveAccumulator: Double = 0
    private var nextFoodID = 0
    private var graceCueUntil: Double = 0
    private var rescueWasFree = false
    private var holdMovesUntil: Double = 0
    private var phaseBeforePause: Phase = .playing
    private var lastCue: CoachCue = .none
    /// Which useful hint to show when the best one is blocked or ignored.
    private var hintShift = 0
    private var hintWatchElapsed = 0.0
    private var hintWatchDistance = 0
    private var lastProgressElapsed = 0.0
    private var nudgesIssued = 0
    private var slowRemaining = 0.0
    private var magnetRemaining = 0.0
    private var reverseRemaining = 0.0
    private var ghostRemaining = 0.0
    private var tintRemaining = 0.0
    private var growScaleRemaining = 0.0
    private var shrinkScaleRemaining = 0.0
    private var scoreMultiplierRemaining = 0.0
    /// In-budget designs the classic board may spawn. Empty means plain apples.
    private var classicLoadout: [FeedDesign] = []

    public init(
        profile: DifficultyProfile,
        mode: PlayMode,
        seed: UInt64,
        best: Int = 0,
        loadout: [FeedDesign] = []
    ) {
        self.profile = profile
        self.mode = mode
        self.mapping = steerMapping(rig: .standard)
        self.best = max(0, best)
        self.graceLeft = profile.graceCharges
        self.rng = SplitMix64(seed: seed == 0 ? 1 : seed)
        self.solids = profile.solids
        self.classicLoadout = Array(loadout.filter(\.withinBudget).prefix(3))
        resetBoard()
    }

    /// Classic runs that field a loadout keep a separate local record.
    public var recordsSeparately: Bool { mode == .classic && !classicLoadout.isEmpty }

    public var grid: Int { profile.grid }
    /// The turn that will apply on the next step, if the player already swiped.
    public var pendingTurn: Vec3? { queue.first?.vector }
    public var length: Int { snake.count }
    public var shieldActive: Bool { shieldRemaining > 0 }
    public var boostActive: Bool { boostRemaining > 0 }
    public var controlsReversed: Bool { reverseRemaining > 0 }
    public var ghosting: Bool { ghostRemaining > 0 }
    public var snakeScale: Double {
        if growScaleRemaining > 0 { return SnakeBody.growMultiplier }
        if shrinkScaleRemaining > 0 { return SnakeBody.shrinkMultiplier }
        return 1
    }

    /// How fast the snake is versus the opening tempo. Starts at 1.
    public var speedMultiple: Double {
        let base = moveInterval(eaten: eaten, profile: profile)
        let multiplier = boostRemaining > 0 ? profile.chiliMultiplier : 1
        let step = max(0.05, base * multiplier)
        return profile.startInterval / step
    }

    public func currentStepDuration() -> Double {
        let base = moveInterval(eaten: eaten, profile: profile)
        let multiplier = boostRemaining > 0 ? profile.chiliMultiplier : 1
        let crawl = hintUrgent ? 1.35 : 1
        let drag = slowRemaining > 0 ? 1.55 : 1
        return max(0.05, base * multiplier * crawl * drag)
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
            // The first three apples stay on this layer, so depth is not a hint yet.
            if !keepsFoodPlanar, let depth = preferredDepthCue(toward: food.position) {
                return depth
            }
            if let suggestion = suggestedInput() {
                switch suggestion {
                case .depthIn:
                    return depthCue(inward: true)
                case .depthOut:
                    return depthCue(inward: false)
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
            alive: phase != .over,
            pendingTurn: queue.first?.vector,
            snakeScale: snakeScale,
            colorShift: tintRemaining > 0
        )
    }

    // MARK: Input

    public func input(_ input: ControlInput) {
        guard phase == .ready || phase == .playing else { return }
        if mode == .feeding && autopilot && !manualDrive { return }
        let raw = mapping.direction(for: input)
        let dir = reverseRemaining > 0 ? -raw : raw
        if input == .depthIn || input == .depthOut {
            // Touch-down plus touch-up, or a button and a pinch, land in one tick.
            if depthThisTick == dir { return }
            depthThisTick = dir
            usedDepth = true
            enqueueDepth(dir)
            return
        }
        enqueuePlanar(dir)
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

    /// Feeding lab only. A designed feed has to fit the effect budget.
    @discardableResult
    public func cast(_ design: FeedDesign) -> Bool {
        guard design.withinBudget else { return false }
        guard mode == .feeding else { return false }
        guard phase == .playing || phase == .ready else { return false }
        guard foods.count < 3 else { return false }
        let placed = spawn(kind: .apple, bias: .interior, recipe: design)
        touchUI()
        return placed
    }

    /// Swap the opening dish for the first feed in the player's loadout.
    public func serve(_ design: FeedDesign) {
        guard mode == .feeding, design.withinBudget, !foods.isEmpty else { return }
        foods[0].recipe = design
        foods[0].kind = .apple
        touchUI()
    }

    public func setManualDrive(_ enabled: Bool) {
        guard mode == .feeding else { return }
        manualDrive = enabled
        autopilot = !enabled
        if !enabled {
            queue.removeAll()
            resumePlanar = false
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
        depthThisTick = nil
        let dt = min(max(raw, 0), 1.0 / 20.0)
        guard phase == .playing, started else {
            noteCueChange()
            return []
        }
        elapsed += dt
        tickEffects(dt)
        refreshCoachAssist()
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
        depthThisTick = nil
        guard phase == .playing, started else { return [] }
        let events = step()
        fraction = 0
        noteCueChange()
        return events
    }

    public func debugSetElapsed(_ seconds: Double) {
        elapsed = seconds
        refreshCoachAssist()
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
        if direction.z == 0 {
            planarHeading = direction
        } else if let earlier = planarFromBody(body) {
            planarHeading = earlier
        }
        resumePlanar = false
        depthThisTick = nil
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
        hintShift = 0
        hintWatchElapsed = elapsed
        hintWatchDistance = foods.first.map { snake[0].manhattan(to: $0.position) } ?? 0
        lastProgressElapsed = elapsed
        nudgesIssued = 0
        hintUrgent = false
        clearRecipeTimers()
        keepOpeningFoodPlanar()
        touchUI()
    }

    /// The control that still closes in on the apple.
    /// A wall, the body, or a forbidden U-turn drops that axis, and the next
    /// useful direction takes over. Ignoring the same hint for a step rotates
    /// to another direction that still helps.
    public func suggestedInput() -> ControlInput? {
        let plans = hintPlans()
        guard !plans.isEmpty else { return nil }
        return plans[hintShift % plans.count].control
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
        planarHeading = .xp
        resumePlanar = false
        depthThisTick = nil
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
        clearRecipeTimers()
        hintShift = 0
        hintWatchElapsed = 0
        hintUrgent = false
        lastProgressElapsed = 0
        nudgesIssued = 0
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
            spawnNextClassicFood(bias: profile.planarOpeningFoods > 0 ? .openingPlane : .standard)
            hintWatchDistance = foods.first.map { snake[0].manhattan(to: $0.position) } ?? 0
        }
    }

    /// X/Y heading the snake is committed to, ignoring a one-shot depth step.
    private func committedPlanar() -> Vec3 {
        for turn in queue.reversed() {
            if case .planar(let dir) = turn { return dir }
        }
        if direction.z == 0 { return direction }
        return planarHeading
    }

    private func enqueuePlanar(_ direction: Vec3) {
        guard direction.isUnitAxis, direction.z == 0 else { return }
        let last = committedPlanar()
        if direction == -last { return }
        if direction == last {
            // A forward swipe still counts as "I'm here" and starts the run.
            beginIfNeeded()
            return
        }
        guard queue.count < 2 else { return }
        queue.append(.planar(direction))
        beginIfNeeded()
        touchUI()
    }

    /// One queued depth turn moves one cell, then the planar heading resumes.
    private func enqueueDepth(_ direction: Vec3) {
        guard direction.isUnitAxis, direction.z != 0 else { return }
        let upcoming = queue.last?.vector ?? self.direction
        if direction == -upcoming { return }
        guard queue.count < 2 else { return }
        queue.append(.depth(direction))
        beginIfNeeded()
        touchUI()
    }

    private func beginIfNeeded() {
        guard !started else { return }
        started = true
        phase = .playing
        // The first move happens on the next frame, not after a full wait.
        moveAccumulator = currentStepDuration()
        hintShift = 0
        hintWatchElapsed = elapsed
        hintWatchDistance = foods.first.map { snake[0].manhattan(to: $0.position) } ?? 0
        touchUI()
    }

    private func tickEffects(_ dt: Double) {
        if boostRemaining > 0 { boostRemaining = max(0, boostRemaining - dt) }
        if shieldRemaining > 0 { shieldRemaining = max(0, shieldRemaining - dt) }
        if confuseRemaining > 0 { confuseRemaining = max(0, confuseRemaining - dt) }
        if slowRemaining > 0 { slowRemaining = max(0, slowRemaining - dt) }
        if magnetRemaining > 0 { magnetRemaining = max(0, magnetRemaining - dt) }
        if reverseRemaining > 0 { reverseRemaining = max(0, reverseRemaining - dt) }
        if ghostRemaining > 0 { ghostRemaining = max(0, ghostRemaining - dt) }
        if tintRemaining > 0 { tintRemaining = max(0, tintRemaining - dt) }
        if growScaleRemaining > 0 { growScaleRemaining = max(0, growScaleRemaining - dt) }
        if shrinkScaleRemaining > 0 { shrinkScaleRemaining = max(0, shrinkScaleRemaining - dt) }
        if scoreMultiplierRemaining > 0 { scoreMultiplierRemaining = max(0, scoreMultiplierRemaining - dt) }
    }

    private func clearRecipeTimers() {
        slowRemaining = 0
        magnetRemaining = 0
        reverseRemaining = 0
        ghostRemaining = 0
        tintRemaining = 0
        growScaleRemaining = 0
        shrinkScaleRemaining = 0
        scoreMultiplierRemaining = 0
        eatenRecipes = []
    }

    private func step() -> [GameEvent] {
        var events: [GameEvent] = []
        previous = snake

        if autopilot && !manualDrive {
            let chosen = chooseAI()
            if chosen.z == 0 { planarHeading = chosen }
            resumePlanar = false
            apply(chosen, events: &events)
        } else if !queue.isEmpty {
            switch queue.removeFirst() {
            case .planar(let dir):
                planarHeading = dir
                resumePlanar = false
                apply(dir, events: &events)
            case .depth(let dir):
                if self.direction.z == 0 { planarHeading = self.direction }
                apply(dir, events: &events)
                resumePlanar = true
            }
        } else if resumePlanar {
            resumePlanar = false
            apply(planarHeading, events: &events)
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
                if rescue.z == 0 { planarHeading = rescue }
                resumePlanar = false
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
            events.append(contentsOf: applyEat(pellet))
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
        keepOpeningFoodPlanar()
        pullFoodsTowardHead()
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

    private func applyEat(_ pellet: FoodPellet) -> [GameEvent] {
        var events: [GameEvent] = []
        eaten += 1
        if let recipe = pellet.recipe {
            applyRecipe(recipe, events: &events)
        } else {
            switch pellet.kind {
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
        }
        if score > best {
            best = score
            events.append(.newBest)
        }
        lastProgressElapsed = elapsed
        nudgesIssued = 0
        hintUrgent = false
        hintShift = 0
        hintWatchElapsed = elapsed
        // A bite puts the shield back to full, so one apple undoes a clumsy stretch.
        if profile.refillsGrace && !inFreeOpening && elapsed <= profile.graceWindow + 1e-6 {
            graceLeft = profile.graceCharges
        }
        events.append(.ate(pellet.recipe == nil ? pellet.kind : .apple))
        if mode == .classic {
            replenishClassicFoods()
        }
        return events
    }

    /// One food during the opening, then two. A loadout picks the design;
    /// an empty loadout stays on plain apples.
    private func replenishClassicFoods() {
        let target = eaten >= 3 ? 2 : 1
        if foods.count < target {
            spawnNextClassicFood(bias: classicBias)
        }
        while foods.count < target {
            spawnNextClassicFood(bias: .standard)
        }
    }

    private func spawnNextClassicFood(bias: SpawnBias) {
        _ = spawn(kind: .apple, bias: bias, recipe: nextClassicRecipe())
    }

    private func nextClassicRecipe() -> FeedDesign? {
        let pool = classicLoadout
        guard !pool.isEmpty else { return nil }
        let weights = pool.map { max(1, 9 - $0.cost) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return nil }
        var roll = rng.int(below: total)
        for (design, weight) in zip(pool, weights) {
            if roll < weight { return design }
            roll -= weight
        }
        return pool.last
    }

    /// Easy's free opening shows the design and pays its score, but holds
    /// the disruptive effects until those three bites are done.
    private var defersCombatEffects: Bool {
        mode == .classic && profile.planarOpeningFoods >= 3 && eaten <= profile.planarOpeningFoods
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

    private func applyRecipe(_ recipe: FeedDesign, events: inout [GameEvent]) {
        let doubled = scoreMultiplierRemaining > 0 || recipe.effects.contains(.scoreMultiplier)
        var points = doubled ? 24 : 12
        if recipe.effects.contains(.golden) { points += 20 }
        score += points
        pendingGrowth += 1
        for effect in recipe.effects {
            if defersCombatEffects && Self.deferredCombatEffects.contains(effect) { continue }
            switch effect {
            case .speedBoost:
                boostRemaining = max(boostRemaining, 5)
            case .slowMo:
                slowRemaining = max(slowRemaining, 4)
            case .split:
                pendingGrowth += 2
            case .colorShift, .rainbow:
                tintRemaining = max(tintRemaining, effect == .rainbow ? 6 : 4)
            case .magnet:
                magnetRemaining = max(magnetRemaining, 4)
            case .reverseControls:
                reverseRemaining = max(reverseRemaining, 3)
            case .burst:
                for _ in 0..<3 where foods.count < 6 {
                    _ = spawn(kind: .apple, bias: .interior)
                }
            case .ghost:
                ghostRemaining = max(ghostRemaining, 3)
            case .grow:
                pendingGrowth += 2
                growScaleRemaining = max(growScaleRemaining, 4)
                shrinkScaleRemaining = 0
            case .shrink:
                extraChop += 2
                shrinkScaleRemaining = max(shrinkScaleRemaining, 4)
                growScaleRemaining = 0
            case .scoreMultiplier:
                scoreMultiplierRemaining = max(scoreMultiplierRemaining, 8)
            case .timeFreeze:
                holdMovesUntil = max(holdMovesUntil, 1.2)
                slowRemaining = max(slowRemaining, 2)
            case .golden:
                break
            case .phantomTrail:
                ghostRemaining = max(ghostRemaining, 2)
                tintRemaining = max(tintRemaining, 2)
            }
        }
        eatenRecipes.append(recipe.id)
        events.append(.recipeEaten(recipe.id))
    }

    private static let deferredCombatEffects: Set<FeedEffect> = [
        .speedBoost, .slowMo, .reverseControls, .timeFreeze, .shrink, .ghost, .phantomTrail,
    ]

    private func pullFoodsTowardHead() {
        guard magnetRemaining > 0, let head = snake.first else { return }
        var occupied = solids
        for cell in snake { occupied.insert(cell) }
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
            if !inBounds(next) || occupied.contains(next) || foods.contains(where: { $0.position == next }) {
                continue
            }
            foods[index].position = next
            occupied.insert(next)
        }
    }

    private func spawn(kind: FoodKind, bias: SpawnBias, recipe: FeedDesign? = nil) -> Bool {
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
                        } else if cell.z == head.z && distance >= 2 {
                            fallback.append(cell)
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
                    if bias != .interior && bias != .openingPlane { fallback.append(cell) }
                }
            }
        }
        let pool = preferred.isEmpty ? fallback : preferred
        guard !pool.isEmpty else { return false }
        let index = rng.int(below: pool.count)
        nextFoodID += 1
        foods.append(FoodPellet(id: nextFoodID, kind: kind, position: pool[index], recipe: recipe))
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
        isFatal(cell, growing: growing, snake: snake)
    }

    private func isFatal(_ cell: Vec3, growing: Bool, snake body: [Vec3]) -> Bool {
        if !inBounds(cell) || solids.contains(cell) { return true }
        if ghostRemaining > 0 { return false }
        let bodyCount = growing ? body.count : max(0, body.count - 1)
        if bodyCount == 0 { return false }
        for index in 0..<bodyCount where body[index] == cell {
            return true
        }
        return false
    }

    /// First three classic apples stay on the head's Z, including after a rescue
    /// that had to leave the layer.
    private var keepsFoodPlanar: Bool {
        mode == .classic && profile.planarOpeningFoods > 0 && eaten < profile.planarOpeningFoods
    }

    private func controlOptions() -> [(ControlInput, Vec3)] {
        [
            (.screen(.right), mapping.right),
            (.screen(.left), mapping.left),
            (.screen(.up), mapping.up),
            (.screen(.down), mapping.down),
            (.depthIn, mapping.depthIn),
            (.depthOut, mapping.depthOut),
        ]
    }

    private struct HintPlan {
        var control: ControlInput
        var direction: Vec3
        var closesNow: Bool
        var gap: Int
    }

    /// Closing moves first, largest gap first. If every closing move is a wall,
    /// the body, or a U-turn, the list is the turns that unlock one.
    private func hintPlans() -> [HintPlan] {
        guard let food = foods.first else { return [] }
        let growing = pendingGrowth > 0
        let head = snake[0]
        let target = food.position
        let options = controlOptions().filter { control, _ in
            if keepsFoodPlanar && (control == .depthIn || control == .depthOut) { return false }
            return true
        }
        var closing: [HintPlan] = []
        var setups: [HintPlan] = []
        for (control, dir) in options {
            if dir == -direction { continue }
            let next = head + dir
            if isFatal(next, growing: growing) { continue }
            let gap = axisGap(dir, from: head, to: target)
            if gap > 0 {
                closing.append(HintPlan(control: control, direction: dir, closesNow: true, gap: gap))
                continue
            }
            let unlocked = unlockedGap(after: dir, next: next, target: target, growing: growing)
            if unlocked > 0 {
                setups.append(HintPlan(control: control, direction: dir, closesNow: false, gap: unlocked))
            }
        }
        let ranked: (HintPlan, HintPlan) -> Bool = { lhs, rhs in
            if lhs.gap != rhs.gap { return lhs.gap > rhs.gap }
            return axisOrder(lhs.direction) < axisOrder(rhs.direction)
        }
        if !closing.isEmpty { return closing.sorted(by: ranked) }
        if !setups.isEmpty { return setups.sorted(by: ranked) }
        return options.compactMap { control, dir in
            if dir == -direction || isFatal(head + dir, growing: growing) { return nil }
            return HintPlan(control: control, direction: dir, closesNow: false, gap: 0)
        }
    }

    private func axisGap(_ dir: Vec3, from cell: Vec3, to target: Vec3) -> Int {
        dir.x * (target.x - cell.x) + dir.y * (target.y - cell.y) + dir.z * (target.z - cell.z)
    }

    /// How much of the gap a follow-up step can close after turning `dir`.
    private func unlockedGap(after dir: Vec3, next: Vec3, target: Vec3, growing: Bool) -> Int {
        let moved = bodyAfterStep(nextHead: next, growing: growing)
        let secondGrowing = pendingGrowth > 1
        var best = 0
        for dir2 in Vec3.six {
            if keepsFoodPlanar && dir2.z != 0 { continue }
            if dir2 == -dir { continue }
            let gap = axisGap(dir2, from: next, to: target)
            if gap <= 0 { continue }
            if isFatal(next + dir2, growing: secondGrowing, snake: moved) { continue }
            best = max(best, gap)
        }
        return best
    }

    private func bodyAfterStep(nextHead: Vec3, growing: Bool) -> [Vec3] {
        var body = snake
        body.insert(nextHead, at: 0)
        if !growing, body.count > 1 { body.removeLast() }
        return body
    }

    private func refreshCoachAssist() {
        keepOpeningFoodPlanar()
        let lesson = keepsFoodPlanar && profile.freeRescuesUntilEaten > 0 && started
            && (phase == .playing || phase == .ready)
        let stalled = elapsed - lastProgressElapsed
        let wasUrgent = hintUrgent
        hintUrgent = lesson && stalled >= 15
        if hintUrgent {
            let due = Int(stalled / 15)
            if due > nudgesIssued {
                nudgesIssued = due
                nudgeFoodCloser()
            }
        }
        let shiftBefore = hintShift
        advanceHintIfStuck()
        if hintUrgent != wasUrgent || hintShift != shiftBefore {
            touchUI()
        }
    }

    /// After 15s with no bite in the opening, put the apple two or three cells
    /// along a direction the hint can actually use.
    private func nudgeFoodCloser() {
        guard !foods.isEmpty else { return }
        let head = snake[0]
        let rawHint = hintPlans().first?.direction ?? planarHeading
        // A depth hint is one layer per press, so the nudge stays on this Z.
        let hintDir = rawHint.z == 0 ? rawHint : planarHeading
        var best: Vec3?
        var bestScore = Int.min
        for y in 0..<grid {
            for x in 0..<grid {
                let cell = Vec3(x, y, head.z)
                let distance = cell.manhattan(to: head)
                if distance < 2 || distance > 3 { continue }
                if solids.contains(cell) || snake.contains(cell) { continue }
                let align = hintDir.x * (cell.x - head.x) + hintDir.y * (cell.y - head.y)
                let score = align * 10 - distance * 20
                if score > bestScore {
                    bestScore = score
                    best = cell
                }
            }
        }
        if let best {
            foods[0].position = best
            hintShift = 0
            hintWatchElapsed = elapsed
            hintWatchDistance = head.manhattan(to: best)
            touchUI()
        }
    }

    private func advanceHintIfStuck() {
        guard mode == .classic, phase == .playing || phase == .ready else { return }
        guard let food = foods.first else { return }
        let plans = hintPlans()
        let distance = snake[0].manhattan(to: food.position)
        if distance < hintWatchDistance {
            hintShift = 0
            hintWatchDistance = distance
            hintWatchElapsed = elapsed
            return
        }
        if !plans.isEmpty {
            let current = plans[hintShift % plans.count]
            if current.direction.z != 0, food.position.z != snake[0].z {
                // One press buys one layer. Leave the hint on depth and let the
                // count fall, instead of treating the Z heading as a full run.
                return
            }
            if direction == current.direction && phase == .playing {
                hintShift = 0
                hintWatchElapsed = elapsed
                hintWatchDistance = distance
                return
            }
        }
        guard phase == .playing, started, plans.count > 1 else { return }
        let beat = max(0.35, moveInterval(eaten: eaten, profile: profile))
        if elapsed - hintWatchElapsed + 1e-9 >= beat {
            hintShift = (hintShift + 1) % plans.count
            hintWatchElapsed = elapsed
        }
    }

    private func keepOpeningFoodPlanar() {
        guard keepsFoodPlanar, !foods.isEmpty else { return }
        let head = snake[0]
        let food = foods[0].position
        guard food.z != head.z else { return }
        var occupied = solids
        for cell in snake { occupied.insert(cell) }
        var best: Vec3?
        var bestScore = Int.max
        for y in 0..<grid {
            for x in 0..<grid {
                let cell = Vec3(x, y, head.z)
                if occupied.contains(cell) { continue }
                let distance = cell.manhattan(to: head)
                if distance < 2 { continue }
                let drift = abs(cell.x - food.x) + abs(cell.y - food.y)
                let score = drift * 10 + distance
                if score < bestScore {
                    bestScore = score
                    best = cell
                }
            }
        }
        if let best {
            foods[0].position = best
        }
    }

    /// Depth wins ties. Otherwise a same-length planar step hides the lesson.
    private func preferredDepthCue(toward food: Vec3) -> CoachCue? {
        guard !keepsFoodPlanar else { return nil }
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
        let presses = depthPressesRemaining(depth.0)
        guard presses > 0 else { return nil }
        return .useDepth(inward: depth.0 == mapping.depthIn, layers: presses)
    }

    /// Presses still required in `dir`. Queued depth turns already count.
    private func depthPressesRemaining(_ dir: Vec3) -> Int {
        guard let food = foods.first, dir.z != 0 else { return 0 }
        let gap = food.position.z - snake[0].z
        guard gap != 0, gap.signum() == dir.z.signum() else { return 0 }
        var queued = 0
        for turn in queue {
            if case .depth(let queuedDir) = turn, queuedDir == dir { queued += 1 }
        }
        return max(0, abs(gap) - queued)
    }

    private func depthCue(inward: Bool) -> CoachCue {
        let dir = inward ? mapping.depthIn : mapping.depthOut
        return .useDepth(inward: inward, layers: max(1, depthPressesRemaining(dir)))
    }

    /// Latest X/Y segment, walking back from the head. Nil when the body is a Z line.
    private func planarFromBody(_ body: [Vec3]) -> Vec3? {
        for index in 0..<(body.count - 1) {
            let step = Vec3(body[index].x - body[index + 1].x, body[index].y - body[index + 1].y, 0)
            if step.isUnitAxis { return step }
        }
        return nil
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
        var options = Vec3.six.filter { dir in
            dir != -direction && !isFatal(snake[0] + dir, growing: growing)
        }
        if keepsFoodPlanar {
            let planar = options.filter { $0.z == 0 }
            if !planar.isEmpty { options = planar }
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

/// A swipe changes the heading. A depth press is spent on the next step only.
private enum QueuedTurn: Equatable {
    case planar(Vec3)
    case depth(Vec3)

    var vector: Vec3 {
        switch self {
        case .planar(let dir), .depth(let dir):
            return dir
        }
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
