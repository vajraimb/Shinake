import Foundation

/// Points a player can spend on effects. Looks are free; the cap keeps a
/// designed feed from stacking every power at once.
public let feedEffectBudget = 8

/// Chances are rolled once per fusion, in this order.
public let fusionRareEffectChance = 0.12
public let fusionRareLookChance = 0.08

public enum FeedShape: String, Codable, CaseIterable, Equatable {
    case sphere = "o"
    case cube = "c"
    case star = "s"
    case heart = "h"
    case diamond = "d"
    case drop = "w"

    public var title: String {
        switch self {
        case .sphere: return "球形"
        case .cube: return "方块"
        case .star: return "星形"
        case .heart: return "心形"
        case .diamond: return "菱形"
        case .drop: return "水滴"
        }
    }
}

public struct FeedColor: Codable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public func clamped() -> FeedColor {
        FeedColor(red: quantizeChannel(red), green: quantizeChannel(green), blue: quantizeChannel(blue))
    }

    public static func blend(_ left: FeedColor, _ right: FeedColor, t: Double) -> FeedColor {
        let mix = min(1, max(0, t))
        return FeedColor(
            red: left.red + (right.red - left.red) * mix,
            green: left.green + (right.green - left.green) * mix,
            blue: left.blue + (right.blue - left.blue) * mix
        ).clamped()
    }

    private enum CodingKeys: String, CodingKey {
        case red = "r"
        case green = "g"
        case blue = "b"
    }
}

public enum RareLook: String, Codable, CaseIterable, Equatable {
    case prism = "pr"
    case ember = "em"
    case voidGlass = "vg"

    public var title: String {
        switch self {
        case .prism: return "棱镜"
        case .ember: return "余烬"
        case .voidGlass: return "琉璃"
        }
    }

    public var detail: String {
        switch self {
        case .prism: return "表面会自己变色"
        case .ember: return "像一小团火"
        case .voidGlass: return "暗色玻璃，边缘发亮"
        }
    }
}

public struct FeedLook: Codable, Equatable {
    public var shape: FeedShape
    public var primary: FeedColor
    public var secondary: FeedColor
    public var glow: Double
    public var trail: Bool
    public var particles: Bool
    public var rareLook: RareLook?

    public init(
        shape: FeedShape,
        primary: FeedColor,
        secondary: FeedColor,
        glow: Double,
        trail: Bool,
        particles: Bool,
        rareLook: RareLook? = nil
    ) {
        self.shape = shape
        self.primary = primary
        self.secondary = secondary
        self.glow = glow
        self.trail = trail
        self.particles = particles
        self.rareLook = rareLook
    }

    public func sanitized() -> FeedLook {
        var copy = self
        copy.primary = primary.clamped()
        copy.secondary = secondary.clamped()
        copy.glow = quantizeChannel(glow)
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case shape = "s"
        case primary = "a"
        case secondary = "b"
        case glow = "g"
        case trail = "t"
        case particles = "p"
        case rareLook = "r"
    }
}

public enum FeedEffect: String, Codable, CaseIterable, Equatable {
    case speedBoost = "sb"
    case slowMo = "sm"
    case split = "sp"
    case colorShift = "cs"
    case magnet = "mg"
    case reverseControls = "rv"
    case burst = "bu"
    case ghost = "gh"
    case grow = "gr"
    case shrink = "sh"
    case scoreMultiplier = "x2"
    case rainbow = "rb"
    case timeFreeze = "fz"
    case golden = "gd"
    case phantomTrail = "pt"

    public var isRare: Bool {
        switch self {
        case .rainbow, .timeFreeze, .golden, .phantomTrail: return true
        default: return false
        }
    }

    public static var palette: [FeedEffect] { allCases.filter { !$0.isRare } }
    public static var rares: [FeedEffect] { allCases.filter(\.isRare) }

    public var cost: Int {
        switch self {
        case .colorShift, .grow, .shrink: return 1
        case .speedBoost, .slowMo, .magnet, .reverseControls, .phantomTrail: return 2
        case .split, .burst, .ghost, .scoreMultiplier, .golden: return 3
        case .rainbow, .timeFreeze: return 4
        }
    }

    public var title: String {
        switch self {
        case .speedBoost: return "加速"
        case .slowMo: return "慢动作"
        case .split: return "分裂"
        case .colorShift: return "变色"
        case .magnet: return "磁铁"
        case .reverseControls: return "反向"
        case .burst: return "连爆"
        case .ghost: return "幽灵"
        case .grow: return "变大"
        case .shrink: return "缩小"
        case .scoreMultiplier: return "加倍"
        case .rainbow: return "彩虹"
        case .timeFreeze: return "时停"
        case .golden: return "金色"
        case .phantomTrail: return "幻影"
        }
    }

    public var detail: String {
        switch self {
        case .speedBoost: return "吃下后变快一会儿"
        case .slowMo: return "步子变慢一会儿"
        case .split: return "多长出一截身体"
        case .colorShift: return "蛇身换个颜色"
        case .magnet: return "把旁边的食物吸过来"
        case .reverseControls: return "短时间方向相反"
        case .burst: return "裂成一串小食物"
        case .ghost: return "短暂穿过自己的身体"
        case .grow: return "身体变大，并长长"
        case .shrink: return "身体变小，并缩短"
        case .scoreMultiplier: return "这一口和随后几口分数加倍"
        case .rainbow: return "稀有 · 吃下后全身彩虹"
        case .timeFreeze: return "稀有 · 时间停一下"
        case .golden: return "稀有 · 额外加分"
        case .phantomTrail: return "稀有 · 短短的穿身拖影"
        }
    }
}

public struct FeedDesign: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var look: FeedLook
    public var effects: [FeedEffect]

    public init(id: String, name: String, look: FeedLook, effects: [FeedEffect]) {
        self.id = id
        self.name = name
        self.look = look
        self.effects = effects
    }

    public var cost: Int { effects.reduce(0) { $0 + $1.cost } }
    public var withinBudget: Bool { isLegal }

    /// Classic spawn weight. Cheaper designs are more common. Nil when the
    /// design is over budget or otherwise illegal.
    public var classicSpawnWeight: Int? {
        guard withinBudget else { return nil }
        return max(1, 9 - cost)
    }

    /// No duplicate effects, and the total cost fits the cap. Rares are
    /// allowed only when they already fit; the editor cannot add them.
    public var isLegal: Bool {
        !id.isEmpty && Set(effects).count == effects.count && cost <= feedEffectBudget
    }

    public func sanitized() -> FeedDesign {
        var copy = self
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.name = trimmed.isEmpty ? "未命名" : String(trimmed.prefix(16))
        copy.look = look.sanitized()
        var seen = Set<FeedEffect>()
        copy.effects = effects.filter { seen.insert($0).inserted }
        return copy
    }

    /// Palette effects only. Returns nil when the effect is already on,
    /// is a hidden rare, or would blow the budget.
    public func adding(_ effect: FeedEffect) -> FeedDesign? {
        guard !effect.isRare, !effects.contains(effect) else { return nil }
        var copy = sanitized()
        copy.effects.append(effect)
        return copy.isLegal ? copy : nil
    }

    public func removing(_ effect: FeedEffect) -> FeedDesign {
        var copy = sanitized()
        copy.effects.removeAll { $0 == effect }
        return copy
    }

    public static func blank(id: String, name: String = "新食物") -> FeedDesign {
        FeedDesign(id: id, name: name, look: FeedLook(
            shape: .sphere,
            primary: FeedColor(red: 0.95, green: 0.32, blue: 0.34),
            secondary: FeedColor(red: 1, green: 0.78, blue: 0.28),
            glow: 0.5,
            trail: false,
            particles: false
        ), effects: [])
    }

    public static func starterApple() -> FeedDesign {
        var design = blank(id: "starter-apple", name: "青苹果")
        design.look.shape = .sphere
        design.look.primary = FeedColor(red: 0.45, green: 0.86, blue: 0.34)
        design.look.secondary = FeedColor(red: 0.78, green: 0.95, blue: 0.42)
        design.look.glow = 0.4
        design.effects = [.grow]
        return design
    }

    public static func starterStar() -> FeedDesign {
        var design = blank(id: "starter-star", name: "辣椒星")
        design.look.shape = .star
        design.look.primary = FeedColor(red: 0.96, green: 0.32, blue: 0.18)
        design.look.secondary = FeedColor(red: 1, green: 0.72, blue: 0.2)
        design.look.glow = 0.8
        design.look.particles = true
        design.effects = [.speedBoost, .scoreMultiplier]
        return design
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name = "n"
        case look = "l"
        case effects = "e"
    }
}

public enum FeedCodec {
    /// Compact share string. Nil when the design breaks the budget or repeats an effect.
    public static func encode(_ design: FeedDesign) -> String? {
        let clean = design.sanitized()
        guard clean.isLegal else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(clean) else { return nil }
        return "SH1." + base64URL(data)
    }

    public static func decode(_ raw: String) -> FeedDesign? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("SH1.") else { return nil }
        guard let data = dataFromBase64URL(String(trimmed.dropFirst(4))) else { return nil }
        guard let design = try? JSONDecoder().decode(FeedDesign.self, from: data) else { return nil }
        let clean = design.sanitized()
        return clean.isLegal ? clean : nil
    }
}

public struct FusionOutcome: Equatable {
    public var design: FeedDesign
    public var rareEffect: FeedEffect?
    public var rareLook: RareLook?

    public var discoveryIDs: [String] {
        var ids: [String] = []
        if let rareEffect { ids.append("effect.\(rareEffect.rawValue)") }
        if let rareLook { ids.append("look.\(rareLook.rawValue)") }
        return ids
    }
}

/// Mix two feeds. Inherited rares are kept when they fit. A plain mix has a
/// small chance to reveal one hidden effect or look. The result always fits
/// the budget.
public func fuseFeeds(_ left: FeedDesign, _ right: FeedDesign, rng: inout SplitMix64) -> FusionOutcome {
    var look = left.look.sanitized()
    if rng.int(below: 2) == 1 { look.shape = right.look.shape }
    look.primary = FeedColor.blend(left.look.primary, right.look.primary, t: 0.5)
    look.secondary = FeedColor.blend(left.look.secondary, right.look.secondary, t: 0.5)
    look.glow = max(left.look.glow, right.look.glow)
    look.trail = left.look.trail || right.look.trail
    look.particles = left.look.particles || right.look.particles
    look.rareLook = nil
    look = look.sanitized()

    let merged = uniqueEffects(left.effects + right.effects)
    let inheritedRares = merged.filter(\.isRare).sorted { $0.rawValue < $1.rawValue }
    let normals = merged.filter { !$0.isRare }.sorted { lhs, rhs in
        if lhs.cost != rhs.cost { return lhs.cost < rhs.cost }
        return lhs.rawValue < rhs.rawValue
    }

    var chosen: [FeedEffect] = []
    func tryAdd(_ effect: FeedEffect) {
        guard !chosen.contains(effect) else { return }
        let next = chosen.reduce(0) { $0 + $1.cost } + effect.cost
        if next <= feedEffectBudget { chosen.append(effect) }
    }
    inheritedRares.forEach(tryAdd)
    normals.forEach(tryAdd)

    var rareEffect: FeedEffect?
    var rareLook: RareLook?
    if !chosen.contains(where: \.isRare) {
        let roll = rng.unit()
        if roll < fusionRareEffectChance {
            let rare = FeedEffect.rares[rng.int(below: FeedEffect.rares.count)]
            var cost = chosen.reduce(0) { $0 + $1.cost } + rare.cost
            while cost > feedEffectBudget, let index = mostExpensiveNormal(in: chosen) {
                cost -= chosen[index].cost
                chosen.remove(at: index)
            }
            if cost <= feedEffectBudget {
                chosen.append(rare)
                rareEffect = rare
            }
        } else if roll < fusionRareEffectChance + fusionRareLookChance {
            let rolled = RareLook.allCases[rng.int(below: RareLook.allCases.count)]
            look.rareLook = rolled
            rareLook = rolled
        }
    }

    chosen.sort { $0.rawValue < $1.rawValue }
    let design = FeedDesign(
        id: String(rng.next(), radix: 16),
        name: fusedName(left.name, right.name),
        look: look,
        effects: chosen
    )
    return FusionOutcome(design: design, rareEffect: rareEffect, rareLook: rareLook)
}

public struct WeeklyTheme: Equatable {
    public var id: String
    public var title: String
    public var shape: FeedShape
    public var effect: FeedEffect
}

public func weeklyTheme(on date: Date, calendar: Calendar = Calendar(identifier: .iso8601)) -> WeeklyTheme {
    let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
    let year = parts.yearForWeekOfYear ?? 2026
    let week = parts.weekOfYear ?? 1
    let shape = FeedShape.allCases[(abs(year) + week) % FeedShape.allCases.count]
    let effect = FeedEffect.palette[(abs(year) * 3 + week) % FeedEffect.palette.count]
    return WeeklyTheme(
        id: String(format: "%d-W%02d", year, week),
        title: "本周 \(shape.title) · \(effect.title)",
        shape: shape,
        effect: effect
    )
}

private func quantizeChannel(_ value: Double) -> Double {
    (min(1, max(0, value)) * 100).rounded() / 100
}

private func uniqueEffects(_ effects: [FeedEffect]) -> [FeedEffect] {
    var seen = Set<FeedEffect>()
    return effects.filter { seen.insert($0).inserted }
}

private func mostExpensiveNormal(in effects: [FeedEffect]) -> Int? {
    effects.indices.filter { !effects[$0].isRare }.max { effects[$0].cost < effects[$1].cost }
}

private func fusedName(_ left: String, _ right: String) -> String {
    let a = String(left.prefix(4))
    let b = String(right.prefix(4))
    let joined = "\(a)+\(b)"
    return joined == "+" ? "融合" : String(joined.prefix(16))
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func dataFromBase64URL(_ raw: String) -> Data? {
    var text = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let pad = (4 - text.count % 4) % 4
    text += String(repeating: "=", count: pad)
    return Data(base64Encoded: text)
}
