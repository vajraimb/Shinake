import Foundation
import ShinakeCore

/// Headless frames of a real easy run, for the offline phone preview.
/// One JSON object per line. The last line is a META summary on stdout too.

struct Frame: Encodable {
    var label: String
    var grid: Int
    var snake: [[Int]]
    var food: [[Int]]
    var kinds: [String]
    var score: Int
    var eaten: Int
    var phase: String
    var direction: [Int]
    var grace: Int
    var cue: String
}

func cueName(_ cue: CoachCue) -> String {
    switch cue {
    case .swipeToStart: return "swipe"
    case .goEat: return "eat"
    case .useDepth(let inward): return inward ? "depth-in" : "depth-out"
    case .graceSaved(let left): return "grace-\(left)"
    case .none: return "none"
    }
}

func phaseName(_ phase: Phase) -> String {
    switch phase {
    case .ready: return "ready"
    case .playing: return "playing"
    case .paused: return "paused"
    case .over: return "over"
    case .won: return "won"
    }
}

func dump(_ game: SnakeGame, _ label: String) {
    let snap = game.snapshot()
    let frame = Frame(
        label: label,
        grid: snap.grid,
        snake: snap.snake.map { [$0.x, $0.y, $0.z] },
        food: snap.foods.map { [$0.position.x, $0.position.y, $0.position.z] },
        kinds: snap.foods.map { $0.kind.rawValue },
        score: game.score,
        eaten: game.eaten,
        phase: phaseName(game.phase),
        direction: [game.direction.x, game.direction.y, game.direction.z],
        grace: game.graceLeft,
        cue: cueName(game.coachCue)
    )
    let data = try! JSONEncoder().encode(frame)
    try! FileHandle.standardOutput.write(contentsOf: data)
    try! FileHandle.standardOutput.write(contentsOf: Data([0x0A]))
}

let game = SnakeGame(profile: .easy, mode: .classic, seed: 7)
dump(game, "opening")
if let first = game.suggestedInput() {
    game.input(first)
} else {
    game.input(.screen(.right))
}

var time = 0.0
var sawThree = false
var sawLater = false
while time < 75 && (game.phase == .playing || game.phase == .ready) {
    if let hint = game.suggestedInput() {
        game.input(hint)
    }
    _ = game.update(dt: 1.0 / 30.0)
    time += 1.0 / 30.0
    if !sawThree && game.eaten >= 3 {
        dump(game, "three-apples")
        sawThree = true
    }
    if !sawLater && game.elapsed >= 45 {
        dump(game, "forty-five")
        sawLater = true
    }
}
dump(game, "end")
let summary = "META eaten=\(game.eaten) phase=\(phaseName(game.phase)) elapsed=\(String(format: "%.1f", game.elapsed)) score=\(game.score) length=\(game.length)\n"
try! FileHandle.standardError.write(contentsOf: Data(summary.utf8))
