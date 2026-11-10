import SwiftUI
import UIKit

enum Theme {
    static let bgUI = UIColor(red: 0.027, green: 0.039, blue: 0.075, alpha: 1)
    static let bg = Color(bgUI)
    static let lime = Color(red: 0.78, green: 0.96, blue: 0.42)
    static let limeUI = UIColor(red: 0.78, green: 0.96, blue: 0.42, alpha: 1)
    static let ink = Color(red: 0.06, green: 0.09, blue: 0.07)
    static let dim = Color.white.opacity(0.62)
    static let faint = Color.white.opacity(0.38)
    static let card = Color.white.opacity(0.07)
    static let stroke = Color.white.opacity(0.14)
    static let coral = Color(red: 1.0, green: 0.36, blue: 0.42)
    static let blue = Color(red: 0.42, green: 0.62, blue: 0.98)
    static let gold = Color(red: 1.0, green: 0.82, blue: 0.38)

    static let axisX = UIColor(red: 0.89, green: 0.36, blue: 0.38, alpha: 1)
    static let axisY = UIColor(red: 0.36, green: 0.82, blue: 0.48, alpha: 1)
    static let axisZ = UIColor(red: 0.40, green: 0.58, blue: 0.96, alpha: 1)

    static func foodUI(_ kind: FoodKind) -> UIColor {
        switch kind {
        case .apple: return UIColor(red: 1.0, green: 0.34, blue: 0.40, alpha: 1)
        case .star: return UIColor(red: 1.0, green: 0.82, blue: 0.35, alpha: 1)
        case .chili: return UIColor(red: 1.0, green: 0.45, blue: 0.18, alpha: 1)
        case .mushroom: return UIColor(red: 0.74, green: 0.50, blue: 0.98, alpha: 1)
        case .shield: return UIColor(red: 0.45, green: 0.90, blue: 0.95, alpha: 1)
        }
    }

    static func food(_ kind: FoodKind) -> Color { Color(foodUI(kind)) }
}

enum Copy {
    static func difficulty(_ difficulty: Difficulty) -> String {
        switch difficulty {
        case .easy: return "简单"
        case .normal: return "普通"
        case .hard: return "困难"
        }
    }

    static func food(_ kind: FoodKind) -> String {
        switch kind {
        case .apple: return "苹果"
        case .star: return "星星"
        case .chili: return "辣椒"
        case .mushroom: return "蘑菇"
        case .shield: return "护盾"
        }
    }

    static func flavor(_ kind: FoodKind) -> String {
        switch kind {
        case .apple: return "苹果 · 扎实的十分"
        case .star: return "星星 · 亮晶晶的加分"
        case .chili: return "辣椒 · 它要加速了"
        case .mushroom: return "蘑菇 · 味道很怪"
        case .shield: return "护盾 · 撞一下也不怕"
        }
    }

    static func cue(_ cue: CoachCue) -> String? {
        switch cue {
        case .swipeToStart:
            return "滑动开始 · 不能直接掉头"
        case .goEat:
            return "去吃那颗光"
        case .useDepth(let inward):
            return inward ? "果子在里面，点「深入」" : "果子朝你这边，点「拉近」"
        case .graceSaved(let left):
            return left > 0 ? "护盾帮你拐了弯 · 还剩 \(left) 次" : "护盾用完了，接下来要自己躲开"
        case .none:
            return nil
        }
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct PrimaryButton: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Theme.lime)
                .foregroundColor(Theme.ink)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
}

struct SecondaryButton: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Theme.card)
                .foregroundColor(.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Theme.stroke, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
}
