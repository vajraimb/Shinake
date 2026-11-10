import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if model.screen == .title {
                TitleView(model: model)
            } else {
                PlayView(model: model)
            }
            if model.tutorial != nil {
                TutorialView(model: model)
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(model.statusBarHidden)
        .onAppear { model.prepareFeedback() }
        .onChange(of: scenePhase) { phase in
            guard phase != .active, model.screen == .play else { return }
            model.pause()
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsSheet(model: model)
                .preferredColorScheme(.dark)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}
