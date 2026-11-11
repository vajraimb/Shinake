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
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("设计自己的食物，融出稀有，再丢进立方体里。")
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
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("投喂实验室")
            .navigationBarTitleDisplayMode(.inline)
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
    @State private var notice: String?

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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                FeedPreview(design: draft, height: 180)
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                TextField("名字", text: $draft.name)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .padding(12)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onChange(of: draft.name) { value in
                        if value.count > 16 { draft.name = String(value.prefix(16)) }
                    }
                Text("形状")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.dim)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(FeedShape.allCases, id: \.self) { shape in
                            Button {
                                draft.look.shape = shape
                            } label: {
                                Text(shape.title)
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .padding(.horizontal, 14)
                                    .frame(height: 40)
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
                Toggle("粒子", isOn: $draft.look.particles).tint(Theme.lime)
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
                if let notice {
                    Text(notice)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.lime)
                }
                PrimaryButton(title: "保存") { save() }
            }
            .padding(20)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(existingID == nil ? "新食物" : "改食物")
        .navigationBarTitleDisplayMode(.inline)
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
        let clean = draft.sanitized()
        guard clean.isLegal else {
            notice = "超预算了，先拿掉一个效果"
            return
        }
        draft = clean
        library.save(clean)
        notice = "已保存「\(clean.name)」"
        dismiss()
    }

    private func same(_ left: FeedColor, _ right: FeedColor) -> Bool {
        abs(left.red - right.red) < 0.02 && abs(left.green - right.green) < 0.02 && abs(left.blue - right.blue) < 0.02
    }
}

private struct FeedCards: View {
    @ObservedObject var library: FeedLibrary
    @State private var importText = ""
    @State private var notice: String?
    @State private var shareItems: [Any] = []
    @State private var showShare = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let notice {
                    Text(notice)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.lime)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("我的卡片")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShare) {
            ActivityView(items: shareItems)
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
                    notice = library.toggleLoadout(design.id)
                } label: {
                    chipLabel(armed ? "撤下" : "上场")
                }
                .buttonStyle(.plain)
                Button { share(design) } label: { chipLabel("分享") }
                    .buttonStyle(.plain)
                Button { library.delete(design.id) } label: { chipLabel("删除") }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.coral)
            }
        }
        .padding(14)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func chipLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
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
        guard let code = FeedCodec.encode(design) else {
            notice = "这张卡超出预算，不能分享"
            return
        }
        let card = FeedShareCard(design: design, code: code)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        let caption = "食蛇投喂 \(design.name)\n\(code)"
        if let image = renderer.uiImage {
            shareItems = [image, caption]
        } else {
            shareItems = [caption]
        }
        showShare = true
    }

    private func importCode() {
        if let name = library.importCode(importText) {
            notice = "已收入「\(name)」"
            importText = ""
        } else {
            notice = "这段代码读不出来"
        }
    }
}

private struct FeedFusion: View {
    @ObservedObject var library: FeedLibrary
    @State private var left: String?
    @State private var right: String?
    @State private var notice: String?
    @State private var result: FeedDesign?

    var body: some View {
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
                    }
                    if let notice {
                        Text(notice)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundColor(Theme.lime)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(20)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("融合")
        .navigationBarTitleDisplayMode(.inline)
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
            notice = "发现稀有效果「\(effect.title)」，已收入图鉴"
        } else if let look = outcome.rareLook {
            notice = "发现稀有外观「\(look.title)」，已收入图鉴"
        } else if outcome.design.look.rareLook != nil || outcome.design.effects.contains(where: \.isRare) {
            notice = "「\(outcome.design.name)」带着稀有，已在图鉴里"
        } else {
            notice = "合成了「\(outcome.design.name)」"
        }
    }
}

private struct FeedBestiary: View {
    @ObservedObject var library: FeedLibrary

    var body: some View {
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
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("图鉴")
        .navigationBarTitleDisplayMode(.inline)
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
        return ScrollView {
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
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("排行榜")
        .navigationBarTitleDisplayMode(.inline)
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

struct FeedPreview: View {
    var design: FeedDesign
    var height: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            let cycle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.2) / 3.2
            Canvas { ctx, size in
                draw(ctx, size: size, cycle: cycle)
            }
        }
        .frame(height: height)
        .accessibilityLabel("\(design.name) 预览")
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize, cycle: Double) {
        let travel = min(1, cycle / 0.72)
        let bite = max(0, (cycle - 0.72) / 0.28)
        let foodX = size.width * 0.78
        let y = size.height * 0.55
        let headX = size.width * 0.18 + (foodX - size.width * 0.18 - 28) * travel
        if design.look.trail {
            for index in 0..<4 {
                let fade = 1 - Double(index) / 4
                var mark = ctx
                mark.opacity = 0.18 * fade
                let blob = Path(ellipseIn: CGRect(x: headX - 18 - CGFloat(index) * 16, y: y - 8, width: 16, height: 16))
                mark.fill(blob, with: .color(Color(red: design.look.secondary.red, green: design.look.secondary.green, blue: design.look.secondary.blue)))
            }
        }
        for index in (0..<5).reversed() {
            let x = headX - CGFloat(index) * 16
            let radius: CGFloat = index == 0 ? 11 : 9 - CGFloat(index)
            let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(Color(red: 0.62, green: 0.9, blue: 0.38)))
        }
        let foodScale = bite > 0 ? max(0, 1 - bite) : 1
        var food = ctx
        food.opacity = 0.35 + 0.65 * design.look.glow
        let side = 34 * foodScale
        let rect = CGRect(x: foodX - side / 2, y: y - side / 2, width: side, height: side)
        let path = foodPath(design.look.shape, in: rect)
        food.fill(path, with: .color(Color(red: design.look.primary.red, green: design.look.primary.green, blue: design.look.primary.blue)))
        if design.look.particles {
            for index in 0..<5 {
                let angle = cycle * 6 + Double(index) * 1.2
                let px = foodX + CGFloat(cos(angle)) * 26
                let py = y + CGFloat(sin(angle)) * 16
                let dot = CGRect(x: px - 2, y: py - 2, width: 4, height: 4)
                ctx.fill(Path(ellipseIn: dot), with: .color(Color(red: design.look.secondary.red, green: design.look.secondary.green, blue: design.look.secondary.blue)))
            }
        }
    }

    private func foodPath(_ shape: FeedShape, in rect: CGRect) -> Path {
        switch shape {
        case .sphere, .heart:
            return Path(ellipseIn: rect)
        case .cube:
            return Path(roundedRect: rect, cornerRadius: 4)
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
                let cx = rect.midX
                let cy = rect.midY
                let outer = rect.width / 2
                let inner = outer * 0.42
                for index in 0..<10 {
                    let angle = Double(index) * .pi / 5 - .pi / 2
                    let radius = index % 2 == 0 ? outer : inner
                    let point = CGPoint(x: cx + CGFloat(cos(angle) * radius), y: cy + CGFloat(sin(angle) * radius))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                path.closeSubpath()
            }
        case .drop:
            return Path { path in
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.midY))
                path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.midY))
            }
        }
    }
}

private struct FeedShareCard: View {
    var design: FeedDesign
    var code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("食蛇 · 投喂")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(Theme.dim)
            Text(design.name)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            FeedPreview(design: design, height: 140)
            Text(design.effects.map(\.title).joined(separator: " · "))
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(Theme.lime)
            Text(code)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.dim)
                .lineLimit(6)
        }
        .padding(18)
        .frame(width: 320)
        .background(Theme.bg)
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    var items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
