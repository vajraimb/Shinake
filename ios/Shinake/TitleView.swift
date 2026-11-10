import SwiftUI

struct TitleView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            VStack(spacing: 8) {
                Text("食蛇")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.lime)
                Text("SHINAKE")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .tracking(7)
                    .foregroundColor(Theme.faint)
                Text("在立方体里追一颗光")
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundColor(Theme.dim)
                    .padding(.top, 6)
            }
            Spacer(minLength: 20)
            VStack(spacing: 12) {
                PrimaryButton(title: "开始游戏") { model.requestPlay(.classic) }
                    .accessibilityIdentifier("startButton")
                SecondaryButton(title: "投喂实验室") { model.requestPlay(.feeding) }
                difficultyPicker
                HStack {
                    Text(bestLine)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundColor(Theme.dim)
                    Spacer()
                    Button {
                        model.showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Theme.card)
                            .clipShape(Circle())
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityLabel("设置")
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private var bestLine: String {
        let best = model.bestForSelected
        if best <= 0 { return "\(Copy.difficulty(model.difficulty)) · 还没有记录" }
        return "\(Copy.difficulty(model.difficulty))最佳 \(best)"
    }

    private var difficultyPicker: some View {
        HStack(spacing: 0) {
            ForEach(Difficulty.allCases, id: \.self) { difficulty in
                Button {
                    model.difficulty = difficulty
                } label: {
                    Text(Copy.difficulty(difficulty))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(model.difficulty == difficulty ? Theme.lime : Color.clear)
                        .foregroundColor(model.difficulty == difficulty ? Theme.ink : Theme.dim)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("难度\(Copy.difficulty(difficulty))")
            }
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
    }
}
