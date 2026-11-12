import Foundation

/// Integer grid coordinate. Head of the snake lives on this lattice.
public struct Vec3: Equatable, Hashable, Codable {
    public var x: Int
    public var y: Int
    public var z: Int

    public init(_ x: Int, _ y: Int, _ z: Int) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vec3(0, 0, 0)
    public static let xp = Vec3(1, 0, 0)
    public static let xn = Vec3(-1, 0, 0)
    public static let yp = Vec3(0, 1, 0)
    public static let yn = Vec3(0, -1, 0)
    public static let zp = Vec3(0, 0, 1)
    public static let zn = Vec3(0, 0, -1)
    public static let six: [Vec3] = [.xp, .xn, .yp, .yn, .zp, .zn]

    public static func + (lhs: Vec3, rhs: Vec3) -> Vec3 {
        Vec3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }

    public static prefix func - (value: Vec3) -> Vec3 {
        Vec3(-value.x, -value.y, -value.z)
    }

    public static func - (lhs: Vec3, rhs: Vec3) -> Vec3 {
        Vec3(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
    }

    public var isUnitAxis: Bool {
        let ax = abs(x), ay = abs(y), az = abs(z)
        return ax + ay + az == 1 && max(ax, ay, az) == 1
    }

    public func manhattan(to other: Vec3) -> Int {
        abs(x - other.x) + abs(y - other.y) + abs(z - other.z)
    }

    public func dot(_ other: Vec3) -> Int {
        x * other.x + y * other.y + z * other.z
    }
}
