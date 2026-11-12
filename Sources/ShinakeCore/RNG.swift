/// Deterministic generator so food placement and the autopilot are testable.
public struct SplitMix64: RandomNumberGenerator {
    public private(set) var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    public mutating func int(below upper: Int) -> Int {
        precondition(upper > 0)
        return Int(next() % UInt64(upper))
    }

    /// Uniform in [0, 1).
    public mutating func unit() -> Double {
        let bits = next() >> 11
        return Double(bits) / Double(1 << 53)
    }
}
