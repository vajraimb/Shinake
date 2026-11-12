import QuartzCore
import SceneKit
import SwiftUI
import UIKit

/// Display link on the main run loop, at the screen's own rate (120 Hz on
/// ProMotion). SceneKit node edits stay on that same thread.
struct GameCanvas: UIViewRepresentable {
    var model: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = context.coordinator.scene.view
        let link = CADisplayLink(target: context.coordinator, selector: #selector(Coordinator.tick))
        link.preferredFramesPerSecond = 0
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        context.coordinator.link = link
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        coordinator.link?.invalidate()
        coordinator.link = nil
    }

    final class Coordinator: NSObject {
        let model: AppModel
        let scene = GameSceneController()
        var link: CADisplayLink?
        private var last: CFTimeInterval = 0

        init(model: AppModel) {
            self.model = model
        }

        @objc func tick(_ link: CADisplayLink) {
            let now = link.timestamp
            if last == 0 {
                last = now
                return
            }
            let dt = min(now - last, 1.0 / 20.0)
            last = now
            let snapshot = model.advance(dt: dt)
            scene.render(snapshot, showGuide: model.showGuide, shake: model.shake, dt: dt)
        }
    }
}
