import SwiftUI

struct TutorialView: View {
    @ObservedObject var model: AppModel
    @State private var page = 0

    private let pages: [(title: String, body: String)] = [
        ("滑动转向", "手指在画面上滑。蛇顺着那个方向拐，但不能直接掉头，免得咬到自己。"),
        ("先吃到光", "开局很慢，箭头会告诉你往哪滑。吃到会变长。\n投喂实验室里，你点菜，AI 替你追。"),
        ("还有一层深浅", "立方体有前后。底部「深\u{2060}入」往画面里面走，「拉\u{2060}近」往你这边退。\n双指捏合＝深\u{2060}入 · 张开＝拉\u{2060}近。\n简单难度先送 6 次护\u{2060}盾。前三个苹果撞到了也不扣。"),
    ]

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 22) {
                Spacer(minLength: 12)
                illustration
                    .frame(height: 180)
                Text(pages[page].title)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text(pages[page].body)
                    .font(.system(size: 17, weight: .regular, design: .rounded))
                    .foregroundColor(Theme.dim)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 8)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ForEach(pages.indices, id: \.self) { index in
                        Circle()
                            .fill(index == page ? Theme.lime : Color.white.opacity(0.25))
                            .frame(width: 8, height: 8)
                    }
                }
                Spacer()
                Button(model.tutorial == .review ? "关闭" : "跳过") {
                    model.finishTutorial(startPlaying: true)
                }
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Theme.stroke, lineWidth: 1)
                )
                PrimaryButton(title: page == pages.count - 1 ? "开始玩" : "下一页") {
                    if page == pages.count - 1 {
                        model.finishTutorial(startPlaying: true)
                    } else {
                        page += 1
                    }
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private var illustration: some View {
        switch page {
        case 0:
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 28).fill(Theme.card))
                HStack(spacing: 28) {
                    arrow("←")
                    arrow("↑")
                    arrow("↓")
                    arrow("→")
                }
            }
            .frame(maxWidth: 280)
        case 1:
            HStack(spacing: 18) {
                Circle().fill(Theme.lime).frame(width: 54, height: 54)
                Circle().fill(Theme.lime.opacity(0.75)).frame(width: 36, height: 36)
                Circle().fill(Theme.lime.opacity(0.45)).frame(width: 28, height: 28)
                Circle().fill(Theme.coral).frame(width: 32, height: 32)
                    .shadow(color: Theme.coral.opacity(0.8), radius: 10)
            }
        default:
            HStack(spacing: 12) {
                depthPreview("深入", "往里")
                depthPreview("拉近", "往外")
            }
            .frame(maxWidth: 320)
        }
    }

    private func arrow(_ symbol: String) -> some View {
        Text(symbol)
            .font(.system(size: 28, weight: .bold, design: .rounded))
            .foregroundColor(Theme.lime)
            .frame(width: 48, height: 48)
    }

    private func depthPreview(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
            Text(subtitle)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 72)
        .background(Theme.card)
        .foregroundColor(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(Theme.axisZ).opacity(0.8), lineWidth: 1)
        )
    }
}

struct SettingsSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            settingsBody
        }
        .background(Theme.bg)
        .tint(Theme.lime)
        .foregroundColor(.white)
    }

    private var settingsBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("设置")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Spacer()
                Button("完成") { model.showSettings = false }
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.ink)
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .background(Theme.lime)
                    .clipShape(Capsule())
                    .accessibilityLabel("完成")
            }
            Text("操作方式")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(Theme.dim)
            HStack(spacing: 0) {
                ForEach(ControlScheme.allCases) { scheme in
                    Button {
                        model.scheme = scheme
                    } label: {
                        Text(scheme.title)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(model.scheme == scheme ? Theme.lime : Color.clear)
                            .foregroundColor(model.scheme == scheme ? Theme.ink : Theme.dim)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(model.scheme == .swipe
                 ? "在画面上滑动来转向。底部两个大按钮管立方体的前后。"
                 : "六个大按钮，适合单手点。左右上下是画面方向，深入和拉近是前后。")
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundColor(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("音效", isOn: $model.soundOn)
            Toggle("震动", isOn: $model.hapticsOn)
            Toggle("隐藏状态栏", isOn: $model.statusBarHidden)
            Toggle("双指深浅", isOn: $model.pinchDepth)
                .tint(Theme.lime)
            Text("音效会跟着手机的静音开关。简单难度有 6 次护\u{2060}盾，前三个苹果不扣。")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundColor(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Button(action: model.reviewTutorial) {
                Text("再看一遍教程")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Theme.card)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(PressStyle())
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
