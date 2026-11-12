import SwiftUI

/// On-screen cross for the button scheme. Depth is a two-finger pinch on
/// the board, so this pad has no 深入 / 拉近 keys.
struct ControlPad: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.scheme == .buttons && steeringEnabled {
            dpad
                .padding(.horizontal, 16)
        }
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
}
