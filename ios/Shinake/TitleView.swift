import SceneKit
import simd
import SwiftUI

struct TitleView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TitleCube()
                .frame(height: 210)
                .accessibilityHidden(true)
                .padding(.top, 4)
            VStack(spacing: 8) {
                Text("食蛇")
                    .font(.system(size: 60, weight: .bold, design: .rounded))
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
            Spacer(minLength: 12)
            VStack(spacing: 12) {
                PrimaryButton(title: "开始游戏") { model.requestPlay(.classic) }
                    .accessibilityIdentifier("startButton")
                SecondaryButton(title: "投喂实验室") { model.openLab() }
                    .accessibilityIdentifier("feedLabButton")
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

/// A slow turn of the same cube, so the title isn't an empty field.
private struct TitleCube: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        view.preferredFramesPerSecond = 30
        view.antialiasingMode = .multisampling2X
        view.rendersContinuously = true
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    final class Coordinator {
        let scene = SCNScene()

        init() {
            scene.background.contents = UIColor.clear
            let world = SCNNode()
            scene.rootNode.addChildNode(world)

            let camera = SCNCamera()
            camera.fieldOfView = 32
            camera.zNear = 0.05
            camera.zFar = 40
            let cameraNode = SCNNode()
            cameraNode.camera = camera
            let rig = CameraRig.standard.eyeOffset
            cameraNode.position = SCNVector3(Float(rig.x) * 7.2, Float(rig.y) * 7.2, Float(rig.z) * 7.2)
            cameraNode.look(at: SCNVector3(0, 0.1, 0))
            scene.rootNode.addChildNode(cameraNode)

            let ambient = SCNLight()
            ambient.type = .ambient
            ambient.intensity = 320
            let ambientNode = SCNNode()
            ambientNode.light = ambient
            scene.rootNode.addChildNode(ambientNode)

            let half: Float = 1.35
            let corners: [SIMD3<Float>] = [
                SIMD3(-half, -half, -half), SIMD3(half, -half, -half),
                SIMD3(half, half, -half), SIMD3(-half, half, -half),
                SIMD3(-half, -half, half), SIMD3(half, -half, half),
                SIMD3(half, half, half), SIMD3(-half, half, half),
            ]
            let pairs: [(Int, Int, UIColor)] = [
                (0, 1, Theme.axisX), (1, 2, Theme.axisY), (2, 3, Theme.axisX), (3, 0, Theme.axisY),
                (4, 5, Theme.axisX), (5, 6, Theme.axisY), (6, 7, Theme.axisX), (7, 4, Theme.axisY),
                (0, 4, Theme.axisZ), (1, 5, Theme.axisZ), (2, 6, Theme.axisZ), (3, 7, Theme.axisZ),
            ]
            for (start, end, color) in pairs {
                world.addChildNode(edge(from: corners[start], to: corners[end], color: color))
            }
            let body: [(SIMD3<Float>, Float, UIColor)] = [
                (SIMD3(-0.55, 0, 0), 0.28, UIColor(red: 0.28, green: 0.72, blue: 0.42, alpha: 1)),
                (SIMD3(0, 0, 0), 0.28, UIColor(red: 0.55, green: 0.86, blue: 0.32, alpha: 1)),
                (SIMD3(0.55, 0, 0), 0.32, UIColor(red: 0.82, green: 0.98, blue: 0.40, alpha: 1)),
            ]
            for (position, radius, color) in body {
                let sphere = SCNSphere(radius: CGFloat(radius))
                sphere.segmentCount = 16
                let material = SCNMaterial()
                material.lightingModel = .blinn
                material.diffuse.contents = color
                material.emission.contents = color.withAlphaComponent(0.45)
                sphere.materials = [material]
                let node = SCNNode(geometry: sphere)
                node.simdPosition = position
                world.addChildNode(node)
            }
            let apple = SCNSphere(radius: 0.24)
            apple.segmentCount = 16
            let appleMaterial = SCNMaterial()
            appleMaterial.lightingModel = .constant
            appleMaterial.diffuse.contents = Theme.foodUI(.apple)
            appleMaterial.emission.contents = Theme.foodUI(.apple)
            apple.materials = [appleMaterial]
            let appleNode = SCNNode(geometry: apple)
            appleNode.simdPosition = SIMD3(1.15, 0.15, 0.35)
            world.addChildNode(appleNode)

            world.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 18)))
        }

        private func edge(from start: SIMD3<Float>, to end: SIMD3<Float>, color: UIColor) -> SCNNode {
            let delta = end - start
            let length = simd_length(delta)
            let cylinder = SCNCylinder(radius: 0.035, height: CGFloat(length))
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = color
            cylinder.materials = [material]
            let node = SCNNode(geometry: cylinder)
            node.simdPosition = (start + end) * 0.5
            let target = simd_normalize(delta)
            let up = SIMD3<Float>(0, 1, 0)
            if simd_dot(up, target) < -0.999 {
                node.simdOrientation = simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0))
            } else {
                node.simdOrientation = simd_quatf(from: up, to: target)
            }
            return node
        }
    }
}
