import SwiftUI

struct PlayView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let _ = model.hudTick
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 8) {
                hud
                ZStack(alignment: .bottom) {
                    GameCanvas(model: model)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    if model.scheme == .swipe {
                        swipeCatcher
                    }
                    if let arrow = aimArrow {
                        AimArrow(symbol: arrow.symbol, caption: arrow.caption, urgent: model.game.hintUrgent)
                            .padding(.top, 18)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .allowsHitTesting(false)
                    }
                    VStack(spacing: 8) {
                        if let toast = model.toast {
                            toastBanner(toast)
                        }
                        if let hint = hintText {
                            hintBanner(hint)
                        }
                    }
                    .padding(.bottom, 10)
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity)
                if model.game.mode == .feeding {
                    feedTray
                }
                if model.game.mode == .feeding && model.game.autopilot && !model.game.manualDrive {
                    Button(action: model.toggleManual) {
                        Text("我来开")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Theme.card)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(PressStyle())
                    .padding(.horizontal, 16)
                } else if model.game.mode == .feeding {
                    Button(action: model.toggleManual) {
                        Text("交给 AI")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundColor(Theme.dim)
                    }
                    .buttonStyle(.plain)
                }
                if !runEnded {
                    HStack {
                        pauseButton
                        Spacer(minLength: 8)
                        if model.game.mode == .feeding && !model.game.manualDrive {
                            Text("AI 在飞")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundColor(Theme.ink)
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .background(Theme.lime)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 16)
                    ControlPad(
                        model: model,
                        emphasizeDepthIn: depthHot(inward: true),
                        emphasizeDepthOut: depthHot(inward: false)
                    )
                }
            }
            .padding(.bottom, 6)

            if model.game.phase == .paused {
                pauseCard
            }
            if model.game.phase == .over || model.game.phase == .won {
                endCard
            }
        }
    }

    private var hud: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.game.score)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .monospacedDigit()
                Text(statusLine)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(Theme.dim)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    private var runEnded: Bool {
        model.game.phase == .over || model.game.phase == .won
    }

    private var canPause: Bool {
        model.game.phase == .playing || model.game.phase == .ready
    }

    private var pauseButton: some View {
        Button(action: model.pause) {
            Image(systemName: "pause.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 52, height: 52)
                .background(Theme.card)
                .clipShape(Circle())
                .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(PressStyle())
        .opacity(canPause ? 1 : 0.28)
        .disabled(!canPause)
        .accessibilityLabel("暂停")
    }

    private var statusLine: String {
        var parts = ["长度 \(model.game.length)"]
        let profile = model.game.profile
        let inWindow = profile.graceCharges > 0 && model.game.elapsed <= profile.graceWindow
        let opening = profile.freeRescuesUntilEaten > 0 && model.game.eaten < profile.freeRescuesUntilEaten
        if inWindow || opening {
            parts.append("护盾 \(model.game.graceLeft)")
        }
        if model.game.shieldActive {
            parts.append("金身")
        }
        let speed = model.game.speedMultiple
        if speed > 1.05 || speed < 0.95 {
            parts.append(String(format: "×%.1f", speed))
        }
        return parts.joined(separator: " · ")
    }

    private var aimArrow: (symbol: String, caption: String)? {
        switch model.game.coachCue {
        case .aim(.screen(.right)): return ("arrow.right", "向右")
        case .aim(.screen(.left)): return ("arrow.left", "向左")
        case .aim(.screen(.up)): return ("arrow.up", "向上")
        case .aim(.screen(.down)): return ("arrow.down", "向下")
        case .aim(.depthIn), .useDepth(true): return ("arrow.down.right", "深入")
        case .aim(.depthOut), .useDepth(false): return ("arrow.up.left", "拉近")
        default: return nil
        }
    }

    private var hintText: String? {
        if model.game.phase == .over || model.game.phase == .won || model.game.phase == .paused {
            return nil
        }
        if model.game.mode == .feeding && !model.game.manualDrive && model.game.eaten == 0 {
            return "点下面的菜，AI 会追。想自己开，点「我来开」"
        }
        if model.game.hintUrgent {
            switch model.game.coachCue {
            case .practiceSaved, .graceSaved, .swipeToStart:
                break
            default:
                return "顺着箭头滑"
            }
        }
        if model.scheme == .buttons && model.game.coachCue == .swipeToStart {
            return "点方向键开始 · 不能直接掉头"
        }
        return Copy.cue(model.game.coachCue)
    }

    private func depthHot(inward: Bool) -> Bool {
        if case .useDepth(let flag) = model.game.coachCue {
            return flag == inward
        }
        return false
    }

    @ViewBuilder
    private var swipeCatcher: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        let axis = classifySwipe(
                            dx: Double(value.translation.width),
                            dy: Double(value.translation.height)
                        )
                        if let axis {
                            model.steer(.screen(axis))
                        }
                    }
            )
            .accessibilityLabel("滑动转向区域")
    }

    private var feedTray: some View {
        HStack(spacing: 8) {
            ForEach(FoodKind.allCases, id: \.self) { kind in
                Button {
                    model.cast(kind)
                } label: {
                    VStack(spacing: 4) {
                        Circle()
                            .fill(Theme.food(kind))
                            .frame(width: 18, height: 18)
                            .shadow(color: Theme.food(kind).opacity(0.7), radius: 6)
                        Text(Copy.food(kind))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("投喂\(Copy.food(kind))")
            }
        }
        .padding(.horizontal, 12)
    }

    private func toastBanner(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundColor(Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.lime)
            .clipShape(Capsule())
    }

    private func hintBanner(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.45))
            .clipShape(Capsule())
    }

    private var pauseCard: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            card(title: "暂停", subtitle: "蛇停在这一格") {
                PrimaryButton(title: "继续", action: model.resume)
                SecondaryButton(title: "重新开始", action: model.restart)
                SecondaryButton(title: "回标题", action: model.backToTitle)
                toggleRow
            }
        }
    }

    private var endCard: some View {
        ZStack {
            Color.black.opacity(0.62).ignoresSafeArea()
            card(
                title: model.game.phase == .won ? "立方体满了" : Copy.death(model.game.deathCause),
                subtitle: endSubtitle
            ) {
                Text("\(model.game.score)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.lime)
                    .monospacedDigit()
                Text("长度 \(model.game.length)  ·  用时 \(clock(model.game.elapsed))")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundColor(Theme.dim)
                PrimaryButton(title: "再来一局", action: model.restart)
                    .accessibilityIdentifier("restartButton")
                SecondaryButton(title: "回标题", action: model.backToTitle)
            }
        }
    }

    private var endSubtitle: String {
        if model.runWasRecord { return "新纪录" }
        return "最佳 \(model.game.best)"
    }

    private var toggleRow: some View {
        HStack(spacing: 18) {
            Toggle("音效", isOn: $model.soundOn)
            Toggle("震动", isOn: $model.hapticsOn)
        }
        .font(.system(size: 15, weight: .medium, design: .rounded))
        .tint(Theme.lime)
        .foregroundColor(.white)
    }

    private func card<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 14) {
            Text(title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text(subtitle)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundColor(Theme.dim)
            content()
        }
        .padding(22)
        .frame(maxWidth: 420)
        .background(Color(red: 0.07, green: 0.09, blue: 0.14))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
        .padding(.horizontal, 28)
    }

    private func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Lime arrow over the cube. Pulses once the opening has gone quiet.
private struct AimArrow: View {
    var symbol: String
    var caption: String
    var urgent: Bool
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .bold))
                .scaleEffect(urgent && pulse ? 1.22 : 1)
            Text(caption)
                .font(.system(size: 16, weight: .bold, design: .rounded))
        }
        .foregroundColor(Theme.lime)
        .shadow(color: .black.opacity(0.55), radius: 8, y: 2)
        .onAppear { startPulse() }
        .onChange(of: urgent) { _ in startPulse() }
    }

    private func startPulse() {
        guard urgent else {
            pulse = false
            return
        }
        pulse = false
        withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}
