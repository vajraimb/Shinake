import SwiftUI

/// Thumb controls. Swipe mode keeps two large depth keys under the home-side
/// thumb; button mode adds a cross for people who would rather tap.
struct ControlPad: View {
    @ObservedObject var model: AppModel
    var emphasizeDepthIn: Bool
    var emphasizeDepthOut: Bool

    var body: some View {
        VStack(spacing: 10) {
            if model.scheme == .buttons && steeringEnabled {
                dpad
            }
            if steeringEnabled {
                HStack(spacing: 10) {
                    depthButton("深入", subtitle: "往里", input: .depthIn, hot: emphasizeDepthIn)
                    depthButton("拉近", subtitle: "往外", input: .depthOut, hot: emphasizeDepthOut)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    /// Hidden only while the feeding AI holds the wheel. Pausing keeps the
    /// pad in place so the cube doesn't jump under the overlay.
    private var steeringEnabled: Bool {
        if model.game.mode == .feeding && model.game.autopilot && !model.game.manualDrive {
            return false
        }
        return true
    }

    private var dpad: some View {
        VStack(spacing: 8) {
            padKey("上", input: .screen(.up))
            HStack(spacing: 8) {
                padKey("左", input: .screen(.left))
                padKey("下", input: .screen(.down))
                padKey("右", input: .screen(.right))
            }
        }
    }

    private func padKey(_ title: String, input: ControlInput) -> some View {
        Button {
            model.steer(input)
        } label: {
            Text(title)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .frame(width: 72, height: 60)
                .background(Theme.card)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Theme.stroke, lineWidth: 1)
                )
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(title)
    }

    private func depthButton(_ title: String, subtitle: String, input: ControlInput, hot: Bool) -> some View {
        Button {
            model.steer(input)
        } label: {
            VStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.66))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 68)
            .background(hot ? Theme.blue.opacity(0.55) : Theme.card)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(hot ? Theme.lime : Theme.axisZColor, lineWidth: hot ? 3 : 1)
            )
            .scaleEffect(hot ? 1.03 : 1)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("\(title)，\(subtitle)")
    }
}

private extension Theme {
    static var axisZColor: Color { Color(Theme.axisZ).opacity(0.7) }
}
