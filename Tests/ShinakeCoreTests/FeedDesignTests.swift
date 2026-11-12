import XCTest
#if canImport(ShinakeCore)
@testable import ShinakeCore
#else
@testable import Shinake
#endif

final class FeedDesignTests: XCTestCase {
    func testEffectBudgetRejectsOverflowRaresAndDuplicates() {
        var design = FeedDesign.blank(id: "budget")
        XCTAssertEqual(design.cost, 0)
        XCTAssertTrue(design.withinBudget)

        for effect in FeedEffect.palette {
            if let next = design.adding(effect) {
                design = next
            }
        }
        XCTAssertLessThanOrEqual(design.cost, feedEffectBudget)
        XCTAssertGreaterThan(design.cost, 0)
        XCTAssertFalse(design.effects.contains(where: \.isRare))
        XCTAssertNil(design.adding(.rainbow), "hidden rares stay out of the editor")
        XCTAssertNil(design.adding(design.effects[0]), "an effect cannot be stacked twice")

        let removed = design.removing(design.effects[0])
        XCTAssertLessThan(removed.cost, design.cost)
        XCTAssertTrue(removed.withinBudget)

        var broken = design
        broken.effects = [.ghost, .burst, .split, .scoreMultiplier]
        XCTAssertEqual(broken.cost, 12)
        XCTAssertFalse(broken.withinBudget)
        XCTAssertNil(FeedCodec.encode(broken))
    }

    func testDesignCodeRoundTripsAndRejectsGarbage() {
        var design = FeedDesign.starterStar()
        design.look.trail = true
        design.look.rareLook = nil
        let code = FeedCodec.encode(design)
        XCTAssertNotNil(code)
        XCTAssertTrue(code?.hasPrefix("SH1.") == true)
        XCTAssertEqual(FeedCodec.decode(code ?? ""), design.sanitized())
        XCTAssertEqual(FeedCodec.decode("  \(code ?? "")\n"), design.sanitized())

        XCTAssertNil(FeedCodec.decode("nope"))
        XCTAssertNil(FeedCodec.decode("SH1.!!!!"))
        XCTAssertNil(FeedCodec.decode(""))

        var crowded = FeedDesign.blank(id: "too-much")
        crowded.effects = [.scoreMultiplier, .ghost, .burst]
        XCTAssertNil(FeedCodec.encode(crowded))
        XCTAssertNil(FeedCodec.decode(forcedCode(crowded)))
    }

    func testFusionStaysInBudgetAndCanRevealARare() {
        let apple = FeedDesign.starterApple()
        let star = FeedDesign.starterStar()
        var rngA = SplitMix64(seed: 42)
        var rngB = SplitMix64(seed: 42)
        let once = fuseFeeds(apple, star, rng: &rngA)
        let twice = fuseFeeds(apple, star, rng: &rngB)
        XCTAssertEqual(once, twice)
        XCTAssertTrue(once.design.withinBudget)
        XCTAssertLessThanOrEqual(once.design.cost, feedEffectBudget)

        var sawRare = false
        var sawPlain = false
        for seed in 1...400 {
            var rng = SplitMix64(seed: UInt64(seed))
            let outcome = fuseFeeds(apple, star, rng: &rng)
            XCTAssertTrue(outcome.design.isLegal, "seed \(seed) cost \(outcome.design.cost)")
            XCTAssertLessThanOrEqual(outcome.design.cost, feedEffectBudget)
            XCTAssertEqual(FeedCodec.decode(FeedCodec.encode(outcome.design) ?? ""), outcome.design.sanitized())
            if outcome.rareEffect != nil || outcome.rareLook != nil {
                sawRare = true
                if let effect = outcome.rareEffect {
                    XCTAssertTrue(effect.isRare)
                    XCTAssertTrue(outcome.design.effects.contains(effect))
                    XCTAssertTrue(outcome.discoveryIDs.contains("effect.\(effect.rawValue)"))
                }
                if let look = outcome.rareLook {
                    XCTAssertEqual(outcome.design.look.rareLook, look)
                }
            } else {
                sawPlain = true
            }
        }
        XCTAssertTrue(sawRare)
        XCTAssertTrue(sawPlain)

        var gifted = FeedDesign.blank(id: "gift", name: "稀有糖")
        gifted.effects = [.rainbow]
        var keep = SplitMix64(seed: 7)
        let kept = fuseFeeds(gifted, apple, rng: &keep)
        XCTAssertTrue(kept.design.effects.contains(.rainbow))
        XCTAssertLessThanOrEqual(kept.design.cost, feedEffectBudget)
        XCTAssertNil(kept.rareEffect, "an inherited rare is not rolled again")
    }

    func testWeeklyThemeHoldsForTheWeek() {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 11, day: 11)
        let wednesday = parts.date!
        let thursday = calendar.date(byAdding: .day, value: 1, to: wednesday)!
        let nextWeek = calendar.date(byAdding: .day, value: 8, to: wednesday)!
        let theme = weeklyTheme(on: wednesday, calendar: calendar)
        XCTAssertEqual(theme.id, weeklyTheme(on: thursday, calendar: calendar).id)
        XCTAssertNotEqual(theme.id, weeklyTheme(on: nextWeek, calendar: calendar).id)
        XCTAssertTrue(theme.id.contains("-W"))
        XCTAssertFalse(theme.effect.isRare)
        XCTAssertFalse(theme.title.isEmpty)
    }

    func testCustomFeedAppliesBudgetedEffectsOnce() {
        let game = SnakeGame(profile: .easy, mode: .feeding, seed: 3)
        let food = Vec3(5, 4, 4)
        var design = FeedDesign.blank(id: "boost", name: "加速糖")
        design = design.adding(.speedBoost)!
        design = design.adding(.scoreMultiplier)!
        game.debugArrange(
            snake: [food + .xn, food + .xn + .xn, food + .xn + .xn + .xn],
            direction: .xp,
            foods: [FoodPellet(id: 1, kind: .apple, position: food, recipe: design)]
        )
        let events = game.debugStep()
        XCTAssertTrue(events.contains(.ate(.apple)))
        XCTAssertTrue(events.contains(.recipeEaten("boost")))
        XCTAssertTrue(game.boostActive)
        XCTAssertEqual(game.score, 24)
        XCTAssertEqual(game.eatenRecipes, ["boost"])

        var broken = design
        broken.effects = [.ghost, .burst, .split, .scoreMultiplier]
        XCTAssertFalse(game.cast(broken))
    }

    /// A code for an over-budget design, built the same way as the exporter,
    /// so import cannot be talked into accepting it.
    private func forcedCode(_ design: FeedDesign) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(design)
        let text = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "SH1." + text
    }
}
