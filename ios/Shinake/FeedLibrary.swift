import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(GameKit)
import GameKit
#endif

struct FeedStats: Codable, Equatable {
    var timesEaten = 0
    var bestScore = 0
}

struct LocalScore: Codable, Equatable, Identifiable {
    var id: String
    var score: Int
    var week: String
}

struct BoardEntry: Identifiable {
    var id: String
    var rank: Int
    var name: String
    var score: Int
}

/// Saved feeds, the loadout, the rare collection, and the on-device board.
/// Nothing here leaves the phone except a Game Center score submission.
final class FeedLibrary: ObservableObject {
    @Published private(set) var designs: [FeedDesign] = []
    @Published private(set) var stats: [String: FeedStats] = [:]
    @Published private(set) var discoveredEffects: Set<String> = []
    @Published private(set) var discoveredLooks: Set<String> = []
    @Published private(set) var loadout: [String] = []
    @Published private(set) var scores: [LocalScore] = []
    @Published private(set) var gameCenterOn = false
    @Published private(set) var remoteScores: [BoardEntry] = []
    @Published private(set) var remoteWeekly: [BoardEntry] = []
    @Published var banner: String?

    private let defaults: UserDefaults
    private var bannerToken = 0
    private let storageKey = "shinake.feeds.v2"
    private let retiredStorageKey = "shinake.feeds.v1"
    private var askedGameCenter = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
        load()
        if designs.isEmpty {
            designs = [FeedDesign.starterApple(), FeedDesign.starterStar()]
            persist()
        }
    }

    var loadoutDesigns: [FeedDesign] {
        loadout.compactMap { id in designs.first { $0.id == id } }
    }

    func design(_ id: String) -> FeedDesign? {
        designs.first { $0.id == id }
    }

    func stats(for id: String) -> FeedStats {
        stats[id] ?? FeedStats()
    }

    func knows(_ effect: FeedEffect) -> Bool {
        discoveredEffects.contains(effect.rawValue)
    }

    func knows(_ look: RareLook) -> Bool {
        discoveredLooks.contains(look.rawValue)
    }

    func save(_ design: FeedDesign) {
        let clean = design.sanitized()
        guard clean.isLegal else { return }
        if let index = designs.firstIndex(where: { $0.id == clean.id }) {
            designs[index] = clean
        } else {
            designs.insert(clean, at: 0)
        }
        if designs.count > 40 {
            designs = Array(designs.prefix(40))
        }
        noteDiscoveries(in: clean)
        persist()
    }

    func delete(_ id: String) {
        designs.removeAll { $0.id == id }
        loadout.removeAll { $0 == id }
        persist()
    }

    func toggleLoadout(_ id: String) -> String? {
        if let index = loadout.firstIndex(of: id) {
            loadout.remove(at: index)
            persist()
            return "已从本局撤下"
        }
        guard designs.contains(where: { $0.id == id }) else { return nil }
        guard loadout.count < 3 else { return "一局最多带 3 样" }
        loadout.append(id)
        persist()
        return "已加入本局"
    }

    /// Nil when the code is not a feed. Otherwise the imported name.
    func importCode(_ raw: String) -> String? {
        guard var design = FeedCodec.decode(raw) else { return nil }
        if designs.contains(where: { $0.id == design.id }) {
            design.id = "in-\(String(design.id.prefix(6)))-\(Int(Date().timeIntervalSince1970))"
        }
        save(design)
        return design.name
    }

    func fuse(_ leftID: String, _ rightID: String) -> FusionOutcome? {
        guard let left = design(leftID), let right = design(rightID) else { return nil }
        var rng = SplitMix64(seed: UInt64(Date().timeIntervalSince1970 * 1000) ^ 0xA5A5A5A5)
        let outcome = fuseFeeds(left, right, rng: &rng)
        if let effect = outcome.rareEffect { discoveredEffects.insert(effect.rawValue) }
        if let look = outcome.rareLook { discoveredLooks.insert(look.rawValue) }
        save(outcome.design)
        return outcome
    }

    func noteEaten(_ id: String) {
        var stat = stats[id] ?? FeedStats()
        stat.timesEaten += 1
        stats[id] = stat
        persist()
    }

    func finishRun(score: Int, recipes: [String]) {
        for id in Set(recipes) {
            var stat = stats[id] ?? FeedStats()
            if score > stat.bestScore { stat.bestScore = score }
            stats[id] = stat
        }
        if score > 0 {
            scores.append(LocalScore(
                id: UUID().uuidString,
                score: score,
                week: weeklyTheme(on: Date()).id
            ))
            scores.sort { $0.score > $1.score }
            if scores.count > 20 { scores = Array(scores.prefix(20)) }
            submit(score: score)
        }
        persist()
    }

    func flash(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        bannerToken += 1
        let token = bannerToken
        banner = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            guard let self, self.bannerToken == token else { return }
            self.banner = nil
        }
    }

    func authenticateIfNeeded() {
        #if canImport(GameKit)
        guard !askedGameCenter else {
            gameCenterOn = GKLocalPlayer.local.isAuthenticated
            if gameCenterOn { reloadRemote() }
            return
        }
        askedGameCenter = true
        GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, _ in
            #if canImport(UIKit)
            if let viewController, let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let root = scene.windows.first?.rootViewController {
                root.present(viewController, animated: true)
            }
            #endif
            DispatchQueue.main.async {
                let on = GKLocalPlayer.local.isAuthenticated
                self?.gameCenterOn = on
                if on { self?.reloadRemote() }
            }
        }
        #else
        gameCenterOn = false
        #endif
    }

    func submit(score: Int) {
        #if canImport(GameKit)
        guard GKLocalPlayer.local.isAuthenticated, score > 0 else { return }
        // Cube-era boards (one.vajra.shinake.feeding and .weekly) are not submitted.
        GKLeaderboard.submitScore(
            score,
            context: 0,
            player: GKLocalPlayer.local,
            leaderboardIDs: [GameCenterBoards.bestID, GameCenterBoards.weeklyID]
        ) { _ in }
        #endif
    }

    private func reloadRemote() {
        #if canImport(GameKit)
        loadBoard(GameCenterBoards.bestID) { [weak self] rows in
            self?.remoteScores = rows
        }
        loadBoard(GameCenterBoards.weeklyID) { [weak self] rows in
            self?.remoteWeekly = rows
        }
        #endif
    }

    #if canImport(GameKit)
    private func loadBoard(_ id: String, assign: @escaping ([BoardEntry]) -> Void) {
        GKLeaderboard.loadLeaderboards(IDs: [id]) { boards, _ in
            guard let board = boards?.first else {
                DispatchQueue.main.async { assign([]) }
                return
            }
            board.loadEntries(for: .global, timeScope: .allTime, range: NSRange(location: 1, length: 10)) { _, entries, _, _ in
                let rows = (entries ?? []).map {
                    BoardEntry(id: "\(id)-\($0.rank)", rank: $0.rank, name: $0.player.displayName, score: $0.score)
                }
                DispatchQueue.main.async { assign(rows) }
            }
        }
    }
    #endif

    private func noteDiscoveries(in design: FeedDesign) {
        if let look = design.look.rareLook { discoveredLooks.insert(look.rawValue) }
        for effect in design.effects where effect.isRare {
            discoveredEffects.insert(effect.rawValue)
        }
    }

    private struct Archive: Codable {
        var designs: [FeedDesign]
        var stats: [String: FeedStats]
        var discoveredEffects: [String]
        var discoveredLooks: [String]
        var loadout: [String]
        var scores: [LocalScore]
    }

    private func load() {
        if let data = defaults.data(forKey: storageKey),
           let archive = try? JSONDecoder().decode(Archive.self, from: data) {
            apply(archive)
            return
        }
        // Keep the cards from the cube era, and drop scores that were set on it.
        guard let data = defaults.data(forKey: retiredStorageKey),
              let archive = try? JSONDecoder().decode(Archive.self, from: data) else { return }
        apply(archive)
        scores = []
        for id in Array(stats.keys) {
            stats[id]?.bestScore = 0
        }
        persist()
    }

    private func apply(_ archive: Archive) {
        designs = archive.designs
        stats = archive.stats
        discoveredEffects = Set(archive.discoveredEffects)
        discoveredLooks = Set(archive.discoveredLooks)
        loadout = archive.loadout
        scores = archive.scores
    }

    private func persist() {
        let archive = Archive(
            designs: designs,
            stats: stats,
            discoveredEffects: Array(discoveredEffects),
            discoveredLooks: Array(discoveredLooks),
            loadout: loadout,
            scores: scores
        )
        if let data = try? JSONEncoder().encode(archive) {
            defaults.set(data, forKey: storageKey)
        }
    }
}

