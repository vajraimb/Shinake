import LinkPresentation
import SwiftUI
import UIKit

private enum LabPage: Hashable {
    case editor(String?)
    case cards
    case fusion
    case bestiary
    case ranks
}

struct FeedLabView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: FeedLibrary

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("设计自己的食物，融出稀有，再丢进长方体里。")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundColor(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(weeklyTheme(on: Date()).title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.lime)
                    PrimaryButton(title: "开始投喂 · \(Copy.difficulty(model.difficulty))") {
                        model.requestPlay(.feeding)
                    }
                    .accessibilityIdentifier("startFeeding")
                    labLink("设计投喂", subtitle: "形状、颜色、效果，预算 \(feedEffectBudget) 点", page: .editor(nil))
                    labLink("我的卡片", subtitle: "\(library.designs.count) 张 · 本局 \(library.loadout.count)/3", page: .cards)
                    labLink("融合", subtitle: "两样合成一样，偶尔出稀有", page: .fusion)
                    labLink("图鉴", subtitle: "已经发现的稀有外观和效果", page: .bestiary)
                    labLink("排行榜", subtitle: "这台手机，能连上就同步 Game Center", page: .ranks)
                }
                .padding(20)
                .padding(.bottom, 24)
                }
            }
        .navigationTitle("投喂实验室")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("返回") { model.screen = .title }
                        .foregroundColor(Theme.lime)
                }
            }
            .navigationDestination(for: LabPage.self) { page in
                switch page {
                case .editor(let id):
                    FeedEditor(library: library, existingID: id)
                case .cards:
                    FeedCards(library: library)
                case .fusion:
                    FeedFusion(library: library)
                case .bestiary:
                    FeedBestiary(library: library)
                case .ranks:
                    FeedRanks(library: library)
                }
            }
        }
        .tint(Theme.lime)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .background(KeyboardDismissInstaller())
        .overlay(alignment: .bottom) {
            if let banner = library.banner {
                Text(banner)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.ink)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.lime)
                    .clipShape(Capsule())
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: library.banner)
    }

    private func labLink(_ title: String, subtitle: String, page: LabPage) -> some View {
        NavigationLink(value: page) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(Theme.dim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct FeedEditor: View {
    @ObservedObject var library: FeedLibrary
    var existingID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var draft = FeedDesign.blank(id: "draft")
    @State private var loaded = false
    @State private var keyboardPad: CGFloat = 0

    private let swatches: [FeedColor] = [
        FeedColor(red: 0.95, green: 0.32, blue: 0.34),
        FeedColor(red: 0.45, green: 0.86, blue: 0.34),
        FeedColor(red: 0.30, green: 0.62, blue: 0.98),
        FeedColor(red: 0.98, green: 0.72, blue: 0.22),
        FeedColor(red: 0.72, green: 0.42, blue: 0.96),
        FeedColor(red: 0.98, green: 0.48, blue: 0.72),
        FeedColor(red: 0.95, green: 0.95, blue: 0.96),
        FeedColor(red: 0.18, green: 0.20, blue: 0.24),
    ]

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                FeedPreview(design: draft, height: 180)
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text("形状")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.dim)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(FeedShape.allCases, id: \.self) { shape in
                            Button {
                                draft.look.shape = shape
                                hideKeyboard()
                            } label: {
                                HStack(spacing: 6) {
                                    FeedMark(design: draft.withShape(shape), side: 22)
                                    Text(shape.title)
                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 44)
                                .background(draft.look.shape == shape ? Theme.lime : Theme.card)
                                .foregroundColor(draft.look.shape == shape ? Theme.ink : .white)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                colorRow("主色", selection: draft.look.primary) { draft.look.primary = $0 }
                colorRow("辅色", selection: draft.look.secondary) { draft.look.secondary = $0 }
                VStack(alignment: .leading, spacing: 6) {
                    Text("发光 \(Int(draft.look.glow * 100))%")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.dim)
                    Slider(value: $draft.look.glow, in: 0...1)
                        .tint(Theme.lime)
                }
                Toggle("拖尾", isOn: $draft.look.trail).tint(Theme.lime)
                Toggle("粒子", isOn: $draft.look.particles)
                    .tint(Theme.lime)
                    .background(
                        ScrollAnchor(name: "feed.particles")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    )
                TextField("名字", text: $draft.name)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .padding(12)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.top, 36)
                    .onChange(of: draft.name) { value in
                        if value.count > 16 { draft.name = String(value.prefix(16)) }
                    }
                HStack {
                    Text("效果")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.dim)
                    Spacer()
                    Text("\(draft.cost)/\(feedEffectBudget)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(draft.cost >= feedEffectBudget ? Theme.coral : Theme.lime)
                }
                budgetBar
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(FeedEffect.palette, id: \.self) { effect in
                        effectChip(effect)
                    }
                }
                Text("稀有效果不在这里，要两样食物融合才有机会出现。")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                PrimaryButton(title: "保存") { save() }
            }
            .padding(20)
            .padding(.bottom, 24 + keyboardPad)
            .background(EditorKeyboardLift(bottomInset: $keyboardPad))
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle(existingID == nil ? "新食物" : "改食物")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { hideKeyboard() }
            }
        }
        .onAppear(perform: load)
    }

    private var budgetBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(Theme.lime)
                    .frame(width: proxy.size.width * CGFloat(draft.cost) / CGFloat(feedEffectBudget))
            }
        }
        .frame(height: 8)
    }

    private func colorRow(_ title: String, selection: FeedColor, set: @escaping (FeedColor) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(Theme.dim)
            HStack(spacing: 8) {
                ForEach(Array(swatches.enumerated()), id: \.offset) { _, color in
                    Button { set(color) } label: {
                        Circle()
                            .fill(Color(red: color.red, green: color.green, blue: color.blue))
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(Color.white.opacity(same(color, selection) ? 0.9 : 0), lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 44, height: 44)
                }
            }
        }
    }

    private func effectChip(_ effect: FeedEffect) -> some View {
        let on = draft.effects.contains(effect)
        let fits = draft.adding(effect) != nil
        return Button {
            if on {
                draft = draft.removing(effect)
            } else if let next = draft.adding(effect) {
                draft = next
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(effect.title) · \(effect.cost)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(effect.detail)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.66))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .padding(10)
            .background(on ? Theme.lime.opacity(0.85) : Theme.card)
            .foregroundColor(on ? Theme.ink : .white)
            .opacity(!on && !fits ? 0.38 : 1)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!on && !fits)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let existingID, let saved = library.design(existingID) {
            draft = saved
        } else {
            draft = FeedDesign.blank(id: UUID().uuidString)
        }
    }

    private func save() {
        hideKeyboard()
        let clean = draft.sanitized()
        guard clean.isLegal else {
            library.flash("超预算了，先拿掉一个效果")
            return
        }
        draft = clean
        library.save(clean)
        library.flash("已保存「\(clean.name)」")
        dismiss()
    }

    private func same(_ left: FeedColor, _ right: FeedColor) -> Bool {
        abs(left.red - right.red) < 0.02 && abs(left.green - right.green) < 0.02 && abs(left.blue - right.blue) < 0.02
    }
}

private struct FeedCards: View {
    @ObservedObject var library: FeedLibrary
    @State private var importText = ""

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
            VStack(spacing: 14) {
                ForEach(library.designs) { design in
                    card(design)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("导入")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.dim)
                    TextField("粘贴 SH1. 开头的代码", text: $importText)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .padding(12)
                        .background(Theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Button("导入这张卡") { importCode() }
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Theme.card)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(20)
            .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("我的卡片")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { hideKeyboard() }
            }
        }
    }

    private func card(_ design: FeedDesign) -> some View {
        let stat = library.stats(for: design.id)
        let armed = library.loadout.contains(design.id)
        return VStack(alignment: .leading, spacing: 10) {
            FeedPreview(design: design, height: 120)
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(design.name)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text(cardLine(design))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
            Text("吃过 \(stat.timesEaten) 次 · 最高 \(stat.bestScore)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(Theme.lime)
            HStack(spacing: 8) {
                NavigationLink(value: LabPage.editor(design.id)) {
                    chipLabel("修改")
                }
                .buttonStyle(.plain)
                Button {
                    library.flash(library.toggleLoadout(design.id))
                } label: {
                    chipLabel(armed ? "撤下" : "上场")
                }
                .buttonStyle(.plain)
                Button { share(design) } label: { chipLabel("分享") }
                    .buttonStyle(.plain)
                DeleteCardButton(name: design.name) {
                    library.delete(design.id)
                }
            }
        }
        .padding(14)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func chipLabel(_ title: String, tint: Color = .white) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundColor(tint)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())
    }

    private func cardLine(_ design: FeedDesign) -> String {
        let effects = design.effects.map(\.title).joined(separator: " ")
        let look = design.look.rareLook?.title
        return [design.look.shape.title, look, effects.isEmpty ? "无效果" : effects]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func share(_ design: FeedDesign) {
        hideKeyboard()
        guard let code = FeedCodec.encode(design) else {
            library.flash("这张卡超出预算，不能分享")
            return
        }
        let caption = "食蛇投喂 \(design.name)\n\(code)"
        let image = drawShareCard(design: design, code: code)
        guard shareCardHasInk(image) else {
            library.flash("卡片没画出来")
            return
        }
        SharePresenter.present(image: image, title: design.name, caption: caption)
    }

    private func importCode() {
        hideKeyboard()
        if let name = library.importCode(importText) {
            library.flash("已收入「\(name)」")
            importText = ""
        } else {
            library.flash("这段代码读不出来")
        }
    }
}

private struct FeedFusion: View {
    @ObservedObject var library: FeedLibrary
    @State private var left: String?
    @State private var right: String?
    @State private var result: FeedDesign?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if library.designs.count < 2 {
                    Text("先做两样食物，才能融合。")
                        .foregroundColor(Theme.dim)
                } else {
                    picker("左手", selection: $left)
                    picker("右手", selection: $right)
                    PrimaryButton(title: "融合") { fuse() }
                    if let result {
                        FeedPreview(design: result, height: 160)
                            .frame(height: 160)
                            .frame(maxWidth: .infinity)
                            .background(Theme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        Text(result.name)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text(cardCaption(result))
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundColor(Theme.dim)
                    }
                }
            }
            .padding(20)
            .padding(.bottom, 24)
            }
        }
        .navigationTitle("融合")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .onAppear {
            left = left ?? library.designs.first?.id
            right = right ?? library.designs.dropFirst().first?.id
        }
    }

    private func picker(_ title: String, selection: Binding<String?>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(Theme.dim)
            Picker(title, selection: selection) {
                ForEach(library.designs) { design in
                    Text(design.name).tag(Optional(design.id))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func fuse() {
        guard let left, let right else { return }
        guard let outcome = library.fuse(left, right) else { return }
        result = outcome.design
        if let effect = outcome.rareEffect {
            library.flash("发现稀有效果「\(effect.title)」，已收入图鉴")
        } else if let look = outcome.rareLook {
            library.flash("发现稀有外观「\(look.title)」，已收入图鉴")
        } else if outcome.design.look.rareLook != nil || outcome.design.effects.contains(where: \.isRare) {
            library.flash("「\(outcome.design.name)」带着稀有，已在图鉴里")
        } else {
            library.flash("合成了「\(outcome.design.name)」")
        }
    }

    private func cardCaption(_ design: FeedDesign) -> String {
        let effects = design.effects.map(\.title).joined(separator: " ")
        return [design.look.shape.title, design.look.rareLook?.title, effects.isEmpty ? "无效果" : effects]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

private struct FeedBestiary: View {
    @ObservedObject var library: FeedLibrary

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("效果")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.dim)
                ForEach(FeedEffect.rares, id: \.self) { effect in
                    row(title: effect.title, detail: effect.detail, known: library.knows(effect))
                }
                Text("外观")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.dim)
                    .padding(.top, 8)
                ForEach(RareLook.allCases, id: \.self) { look in
                    row(title: look.title, detail: look.detail, known: library.knows(look))
                }
            }
            .padding(20)
            .padding(.bottom, 24)
            }
        }
        .navigationTitle("图鉴")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func row(title: String, detail: String, known: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(known ? title : "？？？")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundColor(known ? .white : Theme.faint)
            Text(known ? detail : "还没融合出来")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(Theme.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct FeedRanks: View {
    @ObservedObject var library: FeedLibrary

    var body: some View {
        let theme = weeklyTheme(on: Date())
        let localRows = library.scores.prefix(10).map {
            BoardEntry(id: $0.id, rank: 0, name: "本机", score: $0.score)
        }
        let weekRows = library.scores.filter { $0.week == theme.id }.prefix(10).map {
            BoardEntry(id: "w-\($0.id)", rank: 0, name: "本周", score: $0.score)
        }
        return ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(theme.title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.lime)
                Text(library.gameCenterOn ? "Game Center 已登录" : "未登录 Game Center，先显示这台手机上的记录")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                section("本机最高", rows: localRows)
                section("本机本周", rows: Array(weekRows))
                if library.gameCenterOn {
                    section("Game Center", rows: library.remoteScores)
                    section("Game Center 本周", rows: library.remoteWeekly)
                }
            }
            .padding(20)
            .padding(.bottom, 24)
            }
        }
        .navigationTitle("排行榜")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .onAppear { library.authenticateIfNeeded() }
    }

    private func section(_ title: String, rows: [BoardEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(Theme.dim)
            if rows.isEmpty {
                Text("还没有分数")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundColor(Theme.faint)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    HStack {
                        Text(row.rank > 0 ? "\(row.rank)" : "\(index + 1)")
                            .frame(width: 28, alignment: .leading)
                            .foregroundColor(Theme.faint)
                        Text(row.name)
                        Spacer()
                        Text("\(row.score)")
                            .foregroundColor(Theme.lime)
                    }
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                }
            }
        }
    }
}

struct FeedMark: View {
    var design: FeedDesign
    var side: CGFloat

    var body: some View {
        let lively = design.look.rareLook != nil || design.effects.contains(where: \.isRare)
        return Group {
            if lively {
                TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { context in
                    mark(context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                mark(0)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    private func mark(_ time: TimeInterval) -> some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            FoodInk(design: design).drawShape(ctx, in: rect, cycle: time)
        }
    }
}

struct FeedPreview: View {
    var design: FeedDesign
    var height: CGFloat
    var animate: Bool = true

    var body: some View {
        Group {
            if animate {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let cycle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.2) / 3.2
                    canvas(cycle)
                }
            } else {
                canvas(0.35)
            }
        }
        .frame(height: height)
        .accessibilityLabel("\(design.name) 预览")
    }

    private func canvas(_ cycle: Double) -> some View {
        Canvas { ctx, size in
            draw(ctx, size: size, cycle: cycle)
        }
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize, cycle: Double) {
        let travel = min(1, cycle / 0.72)
        let bite = max(0, (cycle - 0.72) / 0.28)
        let foodX = size.width * 0.78
        let y = size.height * 0.55
        let headX = size.width * 0.18 + (foodX - size.width * 0.18 - 28) * travel
        let secondary = Color(red: design.look.secondary.red, green: design.look.secondary.green, blue: design.look.secondary.blue)
        if design.look.trail || design.effects.contains(.phantomTrail) || design.look.rareLook == .ember {
            for index in 0..<4 {
                let fade = 1 - Double(index) / 4
                var mark = ctx
                mark.opacity = 0.22 * fade
                let blob = Path(ellipseIn: CGRect(x: headX - 18 - CGFloat(index) * 16, y: y - 8, width: 16, height: 16))
                mark.fill(blob, with: .color(secondary))
            }
        }
        for index in (0..<5).reversed() {
            let x = headX - CGFloat(index) * 16
            let radius: CGFloat = index == 0 ? 11 : 9 - CGFloat(index)
            let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(Color(red: 0.62, green: 0.9, blue: 0.38)))
        }
        // Shrink a little as the snake bites, but keep the silhouette readable.
        // A star at a few points across loses its points and looks like a blob.
        let foodScale = bite > 0 ? max(0.78, 1 - bite * 0.22) : 1
        let side = 40 * foodScale
        let rect = CGRect(x: foodX - side / 2, y: y - side / 2, width: side, height: side)
        if design.look.glow > 0.05 {
            var halo = ctx
            halo.opacity = 0.28 * design.look.glow
            halo.fill(Path(ellipseIn: rect.insetBy(dx: -8, dy: -8)), with: .color(secondary))
        }
        FoodInk(design: design).drawShape(ctx, in: rect, cycle: cycle * 3.2)
    }
}

private struct FoodInk {
    var design: FeedDesign

    func drawShape(_ ctx: GraphicsContext, in rect: CGRect, cycle: Double) {
        let fill = fillColor(cycle: cycle)
        if design.effects.contains(.phantomTrail) {
            var ghost = ctx
            ghost.opacity = 0.32
            ghost.translateBy(x: -rect.width * 0.22, y: rect.height * 0.04)
            fillMain(ghost, in: rect, fill: fill, cycle: cycle, dress: false)
        }
        if design.effects.contains(.timeFreeze) {
            let ring = Path(ellipseIn: rect.insetBy(dx: -3, dy: -3))
            ctx.stroke(ring, with: .color(Color(red: 0.72, green: 0.92, blue: 1)), lineWidth: max(1.5, rect.width * 0.045))
        }
        fillMain(ctx, in: rect, fill: fill, cycle: cycle, dress: true)
        if design.look.rareLook == .ember {
            for index in 0..<4 {
                let phase = (cycle * 0.45 + Double(index) * 0.22).truncatingRemainder(dividingBy: 1)
                let x = rect.midX + CGFloat(index - 2) * rect.width * 0.16
                let y = rect.maxY - 2 - CGFloat(phase) * rect.height * 0.9
                var spark = ctx
                spark.opacity = 1 - phase
                spark.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: max(2, rect.width * 0.08), height: max(2, rect.width * 0.08))),
                    with: .color(Color(red: 1, green: 0.55, blue: 0.1))
                )
            }
        }
        if design.look.particles || design.look.rareLook == .prism || design.effects.contains(.rainbow) {
            for index in 0..<5 {
                let angle = cycle * 2.4 + Double(index) * 1.25
                let px = rect.midX + CGFloat(cos(angle)) * rect.width * 0.62
                let py = rect.midY + CGFloat(sin(angle)) * rect.height * 0.48
                let hue = (cycle * 0.2 + Double(index) * 0.18).truncatingRemainder(dividingBy: 1)
                let dot = CGRect(x: px - 2, y: py - 2, width: 4, height: 4)
                ctx.fill(Path(ellipseIn: dot), with: .color(Color(hue: hue, saturation: 0.7, brightness: 1)))
            }
        }
    }

    private func fillMain(_ ctx: GraphicsContext, in rect: CGRect, fill: Color, cycle: Double, dress: Bool) {
        if design.look.shape == .cube {
            let box = cubeParts(in: rect)
            ctx.fill(box.side, with: .color(fill.opacity(0.62)))
            ctx.fill(box.top, with: .color(fill.opacity(0.82)))
            ctx.fill(box.front, with: .color(fill))
            if dress { dressOutline(ctx, path: box.front, cycle: cycle) }
            return
        }
        let path = shapePath(in: rect)
        ctx.fill(path, with: .color(fill))
        if design.look.shape == .sphere {
            let highlight = CGRect(
                x: rect.minX + rect.width * 0.22,
                y: rect.minY + rect.height * 0.16,
                width: rect.width * 0.28,
                height: rect.height * 0.2
            )
            ctx.fill(Path(ellipseIn: highlight), with: .color(.white.opacity(0.55)))
        }
        if design.look.shape == .diamond {
            var facet = Path()
            facet.move(to: CGPoint(x: rect.midX, y: rect.minY))
            facet.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            facet.move(to: CGPoint(x: rect.minX, y: rect.midY))
            facet.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            ctx.stroke(facet, with: .color(.white.opacity(0.45)), lineWidth: 1)
        }
        if dress { dressOutline(ctx, path: path, cycle: cycle) }
    }

    private func dressOutline(_ ctx: GraphicsContext, path: Path, cycle: Double) {
        let width = max(1.5, 2.2)
        if design.look.rareLook == .prism || design.effects.contains(.rainbow) {
            let hue = (cycle * 0.25).truncatingRemainder(dividingBy: 1)
            ctx.stroke(path, with: .color(Color(hue: hue, saturation: 0.2, brightness: 1)), lineWidth: width)
        }
        if design.look.rareLook == .voidGlass {
            ctx.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: width)
        }
        if design.look.rareLook == .ember {
            ctx.stroke(path, with: .color(Color(red: 1, green: 0.62, blue: 0.12)), lineWidth: width)
        }
        if design.effects.contains(.golden) {
            ctx.stroke(path, with: .color(Color(red: 1, green: 0.84, blue: 0.28)), lineWidth: width + 0.6)
        }
    }

    private func fillColor(cycle: Double) -> Color {
        let primary = design.look.primary
        switch design.look.rareLook {
        case .prism:
            let hue = (cycle * 0.22).truncatingRemainder(dividingBy: 1)
            return Color(hue: hue, saturation: 0.72, brightness: 1)
        case .ember:
            let green = 0.28 + 0.22 * (0.5 + 0.5 * sin(cycle * 8))
            return Color(red: 1, green: green, blue: 0.05)
        case .voidGlass:
            return Color(
                red: primary.red * 0.16,
                green: primary.green * 0.16,
                blue: max(0.28, primary.blue * 0.4)
            )
        case .none:
            if design.effects.contains(.rainbow) {
                let hue = (cycle * 0.22).truncatingRemainder(dividingBy: 1)
                return Color(hue: hue, saturation: 0.78, brightness: 1)
            }
            return Color(red: primary.red, green: primary.green, blue: primary.blue)
        }
    }

    private func shapePath(in rect: CGRect) -> Path {
        switch design.look.shape {
        case .sphere:
            return Path(ellipseIn: rect)
        case .cube:
            return cubeParts(in: rect).front
        case .heart:
            return heartPath(in: rect)
        case .diamond:
            return Path { path in
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
                path.closeSubpath()
            }
        case .star:
            return Path { path in
                let outer = min(rect.width, rect.height) / 2
                let inner = outer * 0.38
                for index in 0..<10 {
                    let angle = Double(index) * .pi / 5 - .pi / 2
                    let radius = index % 2 == 0 ? outer : inner
                    let point = CGPoint(x: rect.midX + CGFloat(cos(angle) * radius), y: rect.midY + CGFloat(sin(angle) * radius))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                path.closeSubpath()
            }
        case .drop:
            return Path { path in
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control: CGPoint(x: rect.maxX + rect.width * 0.05, y: rect.midY))
                path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY), control: CGPoint(x: rect.minX - rect.width * 0.05, y: rect.midY))
            }
        }
    }

    private func heartPath(in rect: CGRect) -> Path {
        var path = Path()
        let x = rect.minX
        let y = rect.minY
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: x + w * 0.5, y: y + h * 0.93))
        path.addCurve(
            to: CGPoint(x: x + w * 0.02, y: y + h * 0.36),
            control1: CGPoint(x: x + w * 0.18, y: y + h * 0.72),
            control2: CGPoint(x: x - w * 0.02, y: y + h * 0.55)
        )
        path.addCurve(
            to: CGPoint(x: x + w * 0.5, y: y + h * 0.30),
            control1: CGPoint(x: x + w * 0.02, y: y + h * 0.05),
            control2: CGPoint(x: x + w * 0.34, y: y + h * 0.02)
        )
        path.addCurve(
            to: CGPoint(x: x + w * 0.98, y: y + h * 0.36),
            control1: CGPoint(x: x + w * 0.66, y: y + h * 0.02),
            control2: CGPoint(x: x + w * 0.98, y: y + h * 0.05)
        )
        path.addCurve(
            to: CGPoint(x: x + w * 0.5, y: y + h * 0.93),
            control1: CGPoint(x: x + w * 1.02, y: y + h * 0.55),
            control2: CGPoint(x: x + w * 0.82, y: y + h * 0.72)
        )
        path.closeSubpath()
        return path
    }

    private func cubeParts(in rect: CGRect) -> (front: Path, top: Path, side: Path) {
        let dx = rect.width * 0.28
        let dy = rect.height * 0.22
        let front = CGRect(x: rect.minX, y: rect.minY + dy, width: rect.width - dx, height: rect.height - dy)
        var top = Path()
        top.move(to: CGPoint(x: front.minX, y: front.minY))
        top.addLine(to: CGPoint(x: front.minX + dx, y: front.minY - dy))
        top.addLine(to: CGPoint(x: front.maxX + dx, y: front.minY - dy))
        top.addLine(to: CGPoint(x: front.maxX, y: front.minY))
        top.closeSubpath()
        var side = Path()
        side.move(to: CGPoint(x: front.maxX, y: front.minY))
        side.addLine(to: CGPoint(x: front.maxX + dx, y: front.minY - dy))
        side.addLine(to: CGPoint(x: front.maxX + dx, y: front.maxY - dy))
        side.addLine(to: CGPoint(x: front.maxX, y: front.maxY))
        side.closeSubpath()
        return (Path(roundedRect: front, cornerRadius: 2), top, side)
    }
}

private extension FeedDesign {
    func withShape(_ shape: FeedShape) -> FeedDesign {
        var copy = self
        copy.look.shape = shape
        return copy
    }
}

private func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

private func drawShareCard(design: FeedDesign, code: String) -> UIImage {
    let size = CGSize(width: 640, height: 1040)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
        Theme.bgUI.setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
        let title = "食蛇 · 投喂" as NSString
        let name = design.name as NSString
        let effects = (design.effects.map(\.title).joined(separator: " · ").isEmpty
            ? "无效果"
            : design.effects.map(\.title).joined(separator: " · ")) as NSString
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 26, weight: .semibold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.62),
        ]
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 56, weight: .bold),
            .foregroundColor: UIColor.white,
        ]
        let effectAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 28, weight: .medium),
            .foregroundColor: Theme.limeUI,
        ]
        let codeAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 18, weight: .medium),
            .foregroundColor: UIColor.white.withAlphaComponent(0.62),
        ]
        title.draw(in: CGRect(x: 36, y: 36, width: 560, height: 40), withAttributes: titleAttrs)
        name.draw(in: CGRect(x: 36, y: 84, width: 560, height: 80), withAttributes: nameAttrs)
        let glyph = CGRect(x: 170, y: 200, width: 300, height: 300)
        drawShareGlyph(design, in: glyph, context: ctx.cgContext)
        effects.draw(in: CGRect(x: 36, y: 540, width: 568, height: 80), withAttributes: effectAttrs)
        (code as NSString).draw(
            in: CGRect(x: 36, y: 640, width: 568, height: 360),
            withAttributes: codeAttrs
        )
    }
}

private func drawShareGlyph(_ design: FeedDesign, in rect: CGRect, context: CGContext) {
    let color = UIColor(
        red: CGFloat(design.look.primary.red),
        green: CGFloat(design.look.primary.green),
        blue: CGFloat(design.look.primary.blue),
        alpha: 1
    )
    let path = shareShapePath(design.look.shape, in: rect)
    context.saveGState()
    context.addPath(path.cgPath)
    context.setFillColor(color.cgColor)
    context.fillPath()
    context.addPath(path.cgPath)
    context.setStrokeColor(UIColor.white.withAlphaComponent(0.9).cgColor)
    context.setLineWidth(6)
    context.strokePath()
    context.restoreGState()
}

private func shareCardHasInk(_ image: UIImage) -> Bool {
    guard image.size.width > 32, image.size.height > 32, let cgImage = image.cgImage else { return false }
    guard cgImage.bitsPerPixel >= 32, let data = cgImage.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
        return false
    }
    let width = cgImage.width
    let height = cgImage.height
    let bytesPerRow = cgImage.bytesPerRow
    let bytesPerPixel = cgImage.bitsPerPixel / 8
    let stepX = max(1, width / 48)
    let stepY = max(1, height / 48)
    var y = 0
    while y < height {
        var x = 0
        while x < width {
            let pixel = bytes + y * bytesPerRow + x * bytesPerPixel
            var bright = 0
            for channel in 0..<4 where pixel[channel] > 80 { bright += 1 }
            // A flat dark card has only the alpha byte above this. White type and the food color do not.
            if bright >= 2 { return true }
            x += stepX
        }
        y += stepY
    }
    return false
}

private func shareShapePath(_ shape: FeedShape, in rect: CGRect) -> UIBezierPath {
    switch shape {
    case .sphere:
        return UIBezierPath(ovalIn: rect)
    case .cube:
        return UIBezierPath(roundedRect: rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.08), cornerRadius: 18)
    case .heart:
        let path = UIBezierPath()
        let x = rect.minX
        let y = rect.minY
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: x + w * 0.5, y: y + h * 0.93))
        path.addCurve(
            to: CGPoint(x: x + w * 0.02, y: y + h * 0.36),
            controlPoint1: CGPoint(x: x + w * 0.18, y: y + h * 0.72),
            controlPoint2: CGPoint(x: x - w * 0.02, y: y + h * 0.55)
        )
        path.addCurve(
            to: CGPoint(x: x + w * 0.5, y: y + h * 0.30),
            controlPoint1: CGPoint(x: x + w * 0.02, y: y + h * 0.05),
            controlPoint2: CGPoint(x: x + w * 0.34, y: y + h * 0.02)
        )
        path.addCurve(
            to: CGPoint(x: x + w * 0.98, y: y + h * 0.36),
            controlPoint1: CGPoint(x: x + w * 0.66, y: y + h * 0.02),
            controlPoint2: CGPoint(x: x + w * 0.98, y: y + h * 0.05)
        )
        path.addCurve(
            to: CGPoint(x: x + w * 0.5, y: y + h * 0.93),
            controlPoint1: CGPoint(x: x + w * 1.02, y: y + h * 0.55),
            controlPoint2: CGPoint(x: x + w * 0.82, y: y + h * 0.72)
        )
        path.close()
        return path
    case .diamond:
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.close()
        return path
    case .star:
        let path = UIBezierPath()
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.38
        for index in 0..<10 {
            let angle = CGFloat(index) * .pi / 5 - .pi / 2
            let radius = index % 2 == 0 ? outer : inner
            let point = CGPoint(x: rect.midX + cos(angle) * radius, y: rect.midY + sin(angle) * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.close()
        return path
    case .drop:
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY), controlPoint: CGPoint(x: rect.maxX, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY), controlPoint: CGPoint(x: rect.minX, y: rect.midY))
        path.close()
        return path
    }
}

final class FeedCardActivity: NSObject, UIActivityItemSource {
    let image: UIImage
    let title: String

    init(image: UIImage, title: String) {
        self.image = image
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        image
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        image
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.imageProvider = NSItemProvider(object: image)
        metadata.iconProvider = NSItemProvider(object: image)
        return metadata
    }
}

private enum SharePresenter {
    static func present(image: UIImage, title: String, caption: String) {
        let card = FeedCardActivity(image: image, title: title)
        let items: [Any] = [card, caption]
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        guard let presenter = topViewController() else { return }
        if let popover = activity.popoverPresentationController {
            popover.sourceView = presenter.view
            let bounds = presenter.view.bounds
            popover.sourceRect = CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        presenter.present(activity, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.flatMap(\.windows).first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        if let nav = top as? UINavigationController {
            top = nav.visibleViewController ?? nav
        }
        return top
    }
}

private struct DeleteCardButton: View {
    var name: String
    var onDelete: () -> Void
    @State private var anchor: UIView?

    var body: some View {
        Button {
            DeletePrompt.present(name: name, source: anchor, onDelete: onDelete)
        } label: {
            Text("删除")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(Theme.coral)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(AnchorCatcher { anchor = $0 })
    }
}

private struct AnchorCatcher: UIViewRepresentable {
    var onView: (UIView) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async { onView(uiView) }
    }
}

private enum DeletePrompt {
    static func present(name: String, source: UIView?, onDelete: @escaping () -> Void) {
        guard let presenter = frontMostController() else { return }
        let regular = presenter.traitCollection.horizontalSizeClass == .regular
            || presenter.traitCollection.userInterfaceIdiom == .pad
        let alert = UIAlertController(
            title: "删除「\(name)」？",
            message: "这张卡会从列表和本局里去掉。",
            preferredStyle: regular ? .actionSheet : .alert
        )
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { _ in onDelete() })
        if regular, let popover = alert.popoverPresentationController {
            let anchor = (source?.window == nil ? nil : source) ?? presenter.view!
            popover.sourceView = anchor
            popover.sourceRect = anchor.bounds.isEmpty
                ? CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
                : anchor.bounds
            popover.permittedArrowDirections = [.up, .down]
            // A cancel-styled action is left out of a popover, so 取消 stays a visible button.
            alert.addAction(UIAlertAction(title: "取消", style: .default, handler: nil))
        } else {
            alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        }
        presenter.present(alert, animated: true)
    }
}

private struct ScrollAnchor: UIViewRepresentable {
    var name: String

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.accessibilityIdentifier = name
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.accessibilityIdentifier = name
    }
}

private struct EditorKeyboardLift: UIViewRepresentable {
    @Binding var bottomInset: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(bottomInset: $bottomInset) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        context.coordinator.host = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.host = uiView
        context.coordinator.bottomInset = $bottomInset
        context.coordinator.install()
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator: NSObject {
        weak var host: UIView?
        var bottomInset: Binding<CGFloat>
        private var tokens: [NSObjectProtocol] = []
        private let toolbarHeight: CGFloat = 56

        init(bottomInset: Binding<CGFloat>) {
            self.bottomInset = bottomInset
        }

        func install() {
            guard tokens.isEmpty else { return }
            let names = [
                UIResponder.keyboardWillChangeFrameNotification,
                UIResponder.keyboardDidShowNotification,
            ]
            tokens = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    self?.lift(note)
                }
            }
        }

        func remove() {
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
            tokens.removeAll()
        }

        func lift(_ note: Notification) {
            guard let host, let window = host.window else { return }
            guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let space = window.windowScene?.screen.coordinateSpace
            let keyboard = space.map { window.convert(end, from: $0) } ?? end
            let hidden = keyboard.minY >= window.bounds.maxY - 1
            let keyboardHeight = hidden ? 0 : max(0, window.bounds.maxY - keyboard.minY)
            let needed = hidden ? 0 : keyboardHeight + toolbarHeight
            if abs(bottomInset.wrappedValue - needed) > 0.5 {
                bottomInset.wrappedValue = needed
            }
            guard let scroll = host.enclosingScrollView() else { return }
            applyInset(needed, on: scroll)
            guard !hidden else { return }
            let limit = keyboard.minY - toolbarHeight
            scrollClear(of: limit, in: scroll, window: window)
            for delay in [0.05, 0.28] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, let host = self.host, let window = host.window, let scroll = host.enclosingScrollView() else { return }
                    self.applyInset(needed, on: scroll)
                    self.scrollClear(of: limit, in: scroll, window: window)
                }
            }
        }

        private func applyInset(_ needed: CGFloat, on scroll: UIScrollView) {
            let safeExtra = scroll.adjustedContentInset.bottom - scroll.contentInset.bottom
            scroll.contentInset.bottom = max(0, needed - safeExtra)
            scroll.verticalScrollIndicatorInsets.bottom = scroll.contentInset.bottom
        }

        private func scrollClear(of limit: CGFloat, in scroll: UIScrollView, window: UIWindow) {
            var overflow: CGFloat = 0
            if let focus = window.firstResponderView() {
                overflow = max(overflow, focus.convert(focus.bounds, to: window).maxY - limit)
            }
            if let marker = window.view(withAccessibilityIdentifier: "feed.particles") {
                overflow = max(overflow, marker.convert(marker.bounds, to: window).maxY + 8 - limit)
            }
            guard overflow > 1 else { return }
            let maxOffset = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let target = min(max(0, scroll.contentOffset.y + overflow), maxOffset)
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: target), animated: false)
        }
    }
}

private extension UIView {
    func enclosingScrollView() -> UIScrollView? {
        var current: UIView? = superview
        while let view = current {
            if let scroll = view as? UIScrollView { return scroll }
            current = view.superview
        }
        return nil
    }

    func firstResponderView() -> UIView? {
        if isFirstResponder { return self }
        for subview in subviews {
            if let found = subview.firstResponderView() { return found }
        }
        return nil
    }

    func view(withAccessibilityIdentifier identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier { return self }
        for subview in subviews {
            if let found = subview.view(withAccessibilityIdentifier: identifier) { return found }
        }
        return nil
    }
}

private func frontMostController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.flatMap(\.windows).first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
        top = presented
    }
    if let nav = top as? UINavigationController {
        top = nav.visibleViewController ?? nav
    }
    return top
}

private struct KeyboardDismissInstaller: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attach(from: uiView)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private var tap: UITapGestureRecognizer?

        func attach(from view: UIView) {
            guard let window = view.window else { return }
            if let existing = window.gestureRecognizers?.first(where: { $0.name == "shinake.keyboardDismiss" }) as? UITapGestureRecognizer {
                tap = existing
                return
            }
            if tap?.view === window { return }
            remove()
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(dismiss))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            recognizer.name = "shinake.keyboardDismiss"
            window.addGestureRecognizer(recognizer)
            tap = recognizer
        }

        func remove() {
            if let tap { tap.view?.removeGestureRecognizer(tap) }
            tap = nil
        }

        @objc func dismiss() {
            tap?.view?.endEditing(true)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView { return false }
                let name = NSStringFromClass(type(of: current))
                if name.contains("TextField") || name.contains("TextView") { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
