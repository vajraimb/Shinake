import SwiftUI
import UIKit

struct PlayView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let _ = model.hudTick
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                // The score keeps this strip. The board starts below it, so a
                // head on the top row is not drawn under the numbers.
                hud
                    .padding(.horizontal, 20)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                ZStack(alignment: .bottom) {
                    GameCanvas(model: model)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    BoardGestures(
                        swipes: model.scheme == .swipe,
                        pinch: model.pinchDepth,
                        onSwipe: { model.steer(.screen($0)) },
                        onPinch: { model.steer(depthControl(for: $0)) }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let arrow = aimArrow {
                        AimArrow(
                            symbol: arrow.symbol,
                            caption: arrow.caption,
                            urgent: model.game.hintUrgent || depthCueActive,
                            tint: depthCueActive ? Theme.blue : Theme.lime
                        )
                        .padding(.top, 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .allowsHitTesting(false)
                    }
                    controlsColumn
                }
                .padding(.horizontal, 6)
                .frame(maxHeight: .infinity)
            }

            if model.game.phase == .paused {
                pauseCard
            }
            if model.game.phase == .over || model.game.phase == .won {
                endCard
            }
        }
    }

    /// Buttons sit on the board's lower edge and stay above the gesture layer,
    /// so a tap on 深入 / 拉近 is not eaten by a swipe.
    private var controlsColumn: some View {
        VStack(spacing: 8) {
            if let toast = model.toast {
                toastBanner(toast)
            }
            if let hint = hintText {
                hintBanner(hint)
            }
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
                .padding(.horizontal, 10)
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
                .padding(.horizontal, 10)
                ControlPad(
                    model: model,
                    emphasizeDepthIn: depthHot(inward: true),
                    emphasizeDepthOut: depthHot(inward: false)
                )
            }
        }
        .padding(.bottom, 6)
        .fixedSize(horizontal: false, vertical: true)
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
        case .aim(.depthIn): return ("arrow.down.right", "深入")
        case .aim(.depthOut): return ("arrow.up.left", "拉近")
        case .useDepth(true, let layers):
            return ("arrow.down.right", layers > 1 ? "深入 ×\(layers)" : "深入")
        case .useDepth(false, let layers):
            return ("arrow.up.left", layers > 1 ? "拉近 ×\(layers)" : "拉近")
        default: return nil
        }
    }

    private var hintText: String? {
        if model.game.phase == .over || model.game.phase == .won || model.game.phase == .paused {
            return nil
        }
        if model.game.mode == .feeding && !model.game.manualDrive && model.game.eaten == 0 {
            if model.library.loadoutDesigns.isEmpty {
                return "点下面的菜，AI 会追。想自己开，点「我来开」"
            }
            return "点你设计的食物，AI 会追。想自己开，点「我来开」"
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
        if case .useDepth(let inward, let layers) = model.game.coachCue {
            let name = inward ? "深入" : "拉近"
            if model.pinchDepth {
                let how = inward ? "张开" : "捏合"
                return "还差 \(layers) 层 · \(how)或点「\(name)」"
            }
            return "还差 \(layers) 层 · 点「\(name)」"
        }
        return Copy.cue(model.game.coachCue)
    }

    private var depthCueActive: Bool {
        if case .useDepth = model.game.coachCue { return true }
        return false
    }

    private func depthHot(inward: Bool) -> Bool {
        if case .useDepth(let flag, _) = model.game.coachCue {
            return flag == inward
        }
        return false
    }

    private var feedTray: some View {
        let designed = model.library.loadoutDesigns
        return HStack(spacing: 8) {
            if designed.isEmpty {
                classicTray
            } else {
                ForEach(designed) { design in
                    Button {
                        model.cast(design)
                    } label: {
                        VStack(spacing: 2) {
                            FeedMark(design: design, side: 26)
                            Text(design.name)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(Theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityLabel("投喂\(design.name)")
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var classicTray: some View {
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
        let depth = depthCueActive
        return Text(text)
            .font(.system(size: depth ? 17 : 15, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, depth ? 10 : 8)
            .background(depth ? Theme.blue.opacity(0.94) : Color.black.opacity(0.45))
            .clipShape(Capsule())
            .padding(.horizontal, 16)
    }

    private var pauseCard: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            card(title: "暂停", subtitle: "蛇停在这一格") {
                PrimaryButton(title: "继续", action: model.resume)
                SecondaryButton(title: "重新开始", action: model.restart)
                SecondaryButton(title: model.game.mode == .feeding ? "回实验室" : "回标题", action: model.backToTitle)
                toggleRow
            }
        }
    }

    private var endCard: some View {
        ZStack {
            Color.black.opacity(0.62).ignoresSafeArea()
            card(
                title: model.game.phase == .won ? "格子满了" : Copy.death(model.game.deathCause),
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
                SecondaryButton(title: model.game.mode == .feeding ? "回实验室" : "回标题", action: model.backToTitle)
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
    var tint: Color
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .bold))
                .scaleEffect(urgent && pulse ? 1.22 : 1)
            Text(caption)
                .font(.system(size: 18, weight: .bold, design: .rounded))
        }
        .foregroundColor(tint)
        .shadow(color: .black.opacity(0.85), radius: 6, y: 1)
        .shadow(color: tint.opacity(0.9), radius: urgent ? 16 : 8)
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

/// One-finger pans and two-finger pinches, recognized on the way down.
/// A pinch uses two touches, so it cannot also be a swipe, and nothing here
/// changes the camera.
private struct BoardGestures: UIViewRepresentable {
    var swipes: Bool
    var pinch: Bool
    var onSwipe: (ScreenAxis) -> Void
    var onPinch: (DepthPinch) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> BoardGestureView {
        let view = BoardGestureView()
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ uiView: BoardGestureView, context: Context) {
        context.coordinator.onSwipe = onSwipe
        context.coordinator.onPinch = onPinch
        uiView.pan.isEnabled = swipes
        uiView.pinch.isEnabled = pinch
    }

    final class Coordinator: NSObject {
        var lock = GestureLock()
        var onSwipe: (ScreenAxis) -> Void = { _ in }
        var onPinch: (DepthPinch) -> Void = { _ in }

        func attach(_ view: BoardGestureView) {
            view.pan.addTarget(self, action: #selector(panned(_:)))
            view.pinch.addTarget(self, action: #selector(pinched(_:)))
        }

        @objc func panned(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began, .changed:
                let translation = pan.translation(in: pan.view)
                if let axis = lock.swipe(dx: Double(translation.x), dy: Double(translation.y)) {
                    onSwipe(axis)
                }
            case .ended, .cancelled, .failed:
                lock.endSwipe()
            default:
                break
            }
        }

        @objc func pinched(_ pinch: UIPinchGestureRecognizer) {
            switch pinch.state {
            case .began:
                lock.endPinch()
                lock.cancelSwipe()
            case .changed:
                if let depth = lock.pinch(scale: Double(pinch.scale)) {
                    onPinch(depth)
                }
            case .ended, .cancelled, .failed:
                lock.endPinch()
            default:
                break
            }
        }
    }
}

private final class BoardGestureView: UIView {
    let pan = UIPanGestureRecognizer()
    let pinch = UIPinchGestureRecognizer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
        accessibilityLabel = "滑动转向区域"
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        addGestureRecognizer(pinch)
    }

    required init?(coder: NSCoder) {
        nil
    }
}
