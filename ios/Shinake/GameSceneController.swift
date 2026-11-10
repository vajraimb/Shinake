import SceneKit
import simd
import UIKit

/// The cube, the snake and the food. Nodes are reused across frames so a
/// 60 fps tick on iPhone 13 Pro Max is a handful of position writes, not a
/// rebuild. The camera matches `CameraRig.standard`, which is also what
/// swipe-to-axis mapping is tested against.
final class GameSceneController {
    let view: SCNView
    private let scene = SCNScene()
    private let cameraNode = SCNNode()
    private let world = SCNNode()
    private var gridNode: SCNNode?
    private var edgeRoot = SCNNode()
    private var snakeNodes: [SCNNode] = []
    private var eyeNodes: [SCNNode] = []
    private var foodNodes: [Int: SCNNode] = [:]
    private var solidNodes: [SCNNode] = []
    private var guideNode: SCNNode?
    private var builtGrid = -1
    private var time: Double = 0
    private let headMaterial = Self.gloss(UIColor(red: 0.82, green: 0.98, blue: 0.40, alpha: 1))
    private let bodyMaterials: [SCNMaterial] = [
        Self.gloss(UIColor(red: 0.55, green: 0.86, blue: 0.32, alpha: 1)),
        Self.gloss(UIColor(red: 0.28, green: 0.72, blue: 0.42, alpha: 1)),
        Self.gloss(UIColor(red: 0.14, green: 0.55, blue: 0.42, alpha: 1)),
    ]

    init() {
        view = SCNView()
        view.scene = scene
        view.backgroundColor = Theme.bgUI
        view.antialiasingMode = .multisampling2X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.isUserInteractionEnabled = false

        scene.background.contents = Theme.bgUI
        scene.rootNode.addChildNode(world)

        let camera = SCNCamera()
        camera.fieldOfView = 32
        camera.zNear = 0.05
        camera.zFar = 400
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 280
        ambient.color = UIColor(red: 0.78, green: 0.86, blue: 1, alpha: 1)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let key = SCNLight()
        key.type = .directional
        key.intensity = 780
        key.color = UIColor.white
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.9, 0.45, 0)
        scene.rootNode.addChildNode(keyNode)

        for _ in 0..<2 {
            let eye = SCNNode(geometry: SCNSphere(radius: 0.09))
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = UIColor.white
            eye.geometry?.materials = [material]
            world.addChildNode(eye)
            eyeNodes.append(eye)
        }
    }

    func render(_ snapshot: RenderSnapshot, showGuide: Bool, shake: Double, dt: Double) {
        time += dt
        if snapshot.grid != builtGrid {
            rebuildBoard(grid: snapshot.grid)
        }
        placeCamera(grid: snapshot.grid, shake: shake)
        placeSnake(snapshot)
        placeFoods(snapshot)
        placeSolids(snapshot)
        placeGuide(snapshot, visible: showGuide)
    }

    private func rebuildBoard(grid: Int) {
        builtGrid = grid
        gridNode?.removeFromParentNode()
        edgeRoot.removeFromParentNode()
        edgeRoot = SCNNode()
        world.addChildNode(edgeRoot)

        let half = Float(grid - 1) * 0.5
        var vertices: [SCNVector3] = []
        vertices.reserveCapacity(grid * grid * 6)
        for a in 0..<grid {
            for b in 0..<grid {
                let fa = Float(a) - half
                let fb = Float(b) - half
                vertices.append(SCNVector3(-half, fa, fb))
                vertices.append(SCNVector3(half, fa, fb))
                vertices.append(SCNVector3(fa, -half, fb))
                vertices.append(SCNVector3(fa, half, fb))
                vertices.append(SCNVector3(fa, fb, -half))
                vertices.append(SCNVector3(fa, fb, half))
            }
        }
        let source = SCNGeometrySource(vertices: vertices)
        let indices = (0..<Int32(vertices.count)).map { $0 }
        let element = SCNGeometryElement(data: indices.withUnsafeBufferPointer { Data(buffer: $0) },
                                          primitiveType: .line,
                                          primitiveCount: vertices.count / 2,
                                          bytesPerIndex: MemoryLayout<Int32>.size)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor(white: 1, alpha: 0.20)
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        world.addChildNode(node)
        gridNode = node

        let corners = [
            SIMD3<Float>(-half, -half, -half),
            SIMD3<Float>(half, -half, -half),
            SIMD3<Float>(half, half, -half),
            SIMD3<Float>(-half, half, -half),
            SIMD3<Float>(-half, -half, half),
            SIMD3<Float>(half, -half, half),
            SIMD3<Float>(half, half, half),
            SIMD3<Float>(-half, half, half),
        ]
        // Bottom face, top face, then the four verticals.
        let pairs: [(Int, Int, UIColor)] = [
            (0, 1, Theme.axisX), (1, 2, Theme.axisY), (2, 3, Theme.axisX), (3, 0, Theme.axisY),
            (4, 5, Theme.axisX), (5, 6, Theme.axisY), (6, 7, Theme.axisX), (7, 4, Theme.axisY),
            (0, 4, Theme.axisZ), (1, 5, Theme.axisZ), (2, 6, Theme.axisZ), (3, 7, Theme.axisZ),
        ]
        for (start, end, color) in pairs {
            edgeRoot.addChildNode(cylinder(from: corners[start], to: corners[end], color: color))
        }
    }

    private func placeCamera(grid: Int, shake: Double) {
        let rig = CameraRig.standard.eyeOffset
        let distance = Float(grid) * 2.35
        let base = SCNVector3(Float(rig.x) * distance, Float(rig.y) * distance, Float(rig.z) * distance)
        let amp = Float(shake) * 0.22
        cameraNode.position = SCNVector3(
            base.x + sin(Float(time) * 47) * amp,
            base.y + cos(Float(time) * 53) * amp,
            base.z
        )
        cameraNode.look(at: SCNVector3(0, 0.15, 0))
    }

    private func placeSnake(_ snapshot: RenderSnapshot) {
        let count = snapshot.snake.count
        while snakeNodes.count < count {
            let sphere = SCNSphere(radius: 0.46)
            sphere.segmentCount = 24
            let node = SCNNode(geometry: sphere)
            world.addChildNode(node)
            snakeNodes.append(node)
        }
        for index in count..<snakeNodes.count {
            snakeNodes[index].isHidden = true
        }
        let alpha = smooth(Float(snapshot.fraction))
        for index in 0..<count {
            let node = snakeNodes[index]
            node.isHidden = false
            node.position = segmentPosition(index: index, snapshot: snapshot, alpha: alpha)
            node.scale = index == 0 ? SCNVector3(1.12, 1.12, 1.12) : SCNVector3(1, 1, 1)
            if index == 0 {
                node.geometry?.materials = [headMaterial]
            } else {
                node.geometry?.materials = [bodyMaterials[min(index / 3, bodyMaterials.count - 1)]]
            }
        }
        placeEyes(snapshot, alpha: alpha)
    }

    private func placeEyes(_ snapshot: RenderSnapshot, alpha: Float) {
        guard snapshot.snake.first != nil else { return }
        let head = segmentPosition(index: 0, snapshot: snapshot, alpha: alpha)
        let direction = snapshot.direction
        let forward = SIMD3<Float>(Float(direction.x), Float(direction.y), Float(direction.z))
        var up = SIMD3<Float>(0, 1, 0)
        if abs(direction.y) == 1 { up = SIMD3<Float>(1, 0, 0) }
        let side = simd_normalize(simd_cross(forward, up))
        let lift = simd_normalize(simd_cross(side, forward))
        let offsets = [forward * 0.22 + side * 0.13 + lift * 0.10,
                       forward * 0.22 - side * 0.13 + lift * 0.10]
        for (eye, offset) in zip(eyeNodes, offsets) {
            eye.isHidden = false
            eye.position = SCNVector3(head.x + offset.x, head.y + offset.y, head.z + offset.z)
        }
        if !snapshot.alive {
            headMaterial.emission.contents = UIColor(red: 1, green: 0.25, blue: 0.25, alpha: 1)
        } else {
            headMaterial.emission.contents = Theme.limeUI.withAlphaComponent(0.55)
        }
    }

    private func placeFoods(_ snapshot: RenderSnapshot) {
        let live = Set(snapshot.foods.map(\.id))
        for (id, node) in foodNodes where !live.contains(id) {
            node.removeFromParentNode()
            foodNodes.removeValue(forKey: id)
        }
        let half = Float(snapshot.grid - 1) * 0.5
        let pulse = 1 + 0.07 * sin(Float(time) * 3.2)
        for pellet in snapshot.foods {
            let node: SCNNode
            if let existing = foodNodes[pellet.id], existing.name == pellet.kind.rawValue {
                node = existing
            } else {
                foodNodes[pellet.id]?.removeFromParentNode()
                node = makeFood(pellet.kind)
                node.name = pellet.kind.rawValue
                world.addChildNode(node)
                foodNodes[pellet.id] = node
            }
            node.position = worldPoint(pellet.position, grid: snapshot.grid)
            node.scale = SCNVector3(pulse, pulse, pulse)
            if let beacon = node.childNode(withName: "beacon", recursively: false) {
                let height = max(0.2, node.position.y + half)
                beacon.position = SCNVector3(0, -height * 0.5, 0)
                (beacon.geometry as? SCNCylinder)?.height = CGFloat(height)
            }
        }
    }

    private func makeFood(_ kind: FoodKind) -> SCNNode {
        let sphere = SCNSphere(radius: kind == .star ? 0.42 : 0.36)
        sphere.segmentCount = 24
        let material = Self.gloss(Theme.foodUI(kind))
        material.emission.contents = Theme.foodUI(kind).withAlphaComponent(0.85)
        sphere.materials = [material]
        let node = SCNNode(geometry: sphere)
        let beacon = SCNCylinder(radius: 0.035, height: 1)
        let beam = SCNMaterial()
        beam.lightingModel = .constant
        beam.diffuse.contents = Theme.foodUI(kind).withAlphaComponent(0.28)
        beam.writesToDepthBuffer = false
        beacon.materials = [beam]
        let beamNode = SCNNode(geometry: beacon)
        beamNode.name = "beacon"
        node.addChildNode(beamNode)
        let light = SCNLight()
        light.type = .omni
        light.intensity = 180
        light.color = Theme.foodUI(kind)
        light.attenuationEndDistance = 6
        node.light = light
        return node
    }

    private func placeSolids(_ snapshot: RenderSnapshot) {
        if solidNodes.count != snapshot.solids.count {
            for node in solidNodes { node.removeFromParentNode() }
            solidNodes = snapshot.solids.map { _ in
                let box = SCNBox(width: 0.92, height: 0.92, length: 0.92, chamferRadius: 0.08)
                let material = SCNMaterial()
                material.lightingModel = .lambert
                material.diffuse.contents = UIColor(red: 0.35, green: 0.16, blue: 0.20, alpha: 1)
                material.transparency = 0.92
                box.materials = [material]
                let node = SCNNode(geometry: box)
                world.addChildNode(node)
                return node
            }
        }
        for (cell, node) in zip(snapshot.solids, solidNodes) {
            node.position = worldPoint(cell, grid: snapshot.grid)
        }
    }

    private func placeGuide(_ snapshot: RenderSnapshot, visible: Bool) {
        guard visible, let food = snapshot.foods.first, let head = snapshot.snake.first else {
            guideNode?.isHidden = true
            return
        }
        let from = worldPoint(head, grid: snapshot.grid)
        let to = worldPoint(food.position, grid: snapshot.grid)
        let vertices = [from, to]
        let source = SCNGeometrySource(vertices: vertices)
        let indices: [Int32] = [0, 1]
        let element = SCNGeometryElement(data: indices.withUnsafeBufferPointer { Data(buffer: $0) },
                                          primitiveType: .line,
                                          primitiveCount: 1,
                                          bytesPerIndex: MemoryLayout<Int32>.size)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = Theme.limeUI.withAlphaComponent(0.85)
        geometry.materials = [material]
        if guideNode == nil {
            let node = SCNNode()
            world.addChildNode(node)
            guideNode = node
        }
        guideNode?.geometry = geometry
        guideNode?.isHidden = false
    }

    private func segmentPosition(index: Int, snapshot: RenderSnapshot, alpha: Float) -> SCNVector3 {
        let current = snapshot.snake
        let previous = snapshot.previous
        let grid = snapshot.grid
        if index == 0 {
            let from = previous.first ?? current[0]
            return mix(worldPoint(from, grid: grid), worldPoint(current[0], grid: grid), alpha)
        }
        if previous.count == current.count, index < previous.count {
            return mix(worldPoint(previous[index], grid: grid), worldPoint(current[index], grid: grid), alpha)
        }
        let from = (index - 1) < previous.count ? previous[index - 1] : current[index]
        return mix(worldPoint(from, grid: grid), worldPoint(current[index], grid: grid), alpha)
    }

    private func worldPoint(_ cell: Vec3, grid: Int) -> SCNVector3 {
        let half = Float(grid - 1) * 0.5
        return SCNVector3(Float(cell.x) - half, Float(cell.y) - half, Float(cell.z) - half)
    }

    private func cylinder(from start: SIMD3<Float>, to end: SIMD3<Float>, color: UIColor) -> SCNNode {
        let delta = end - start
        let length = simd_length(delta)
        let cylinder = SCNCylinder(radius: 0.045, height: CGFloat(length))
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.emission.contents = color.withAlphaComponent(0.35)
        cylinder.materials = [material]
        let node = SCNNode(geometry: cylinder)
        node.simdPosition = (start + end) * 0.5
        let target = simd_normalize(delta)
        let up = SIMD3<Float>(0, 1, 0)
        if simd_dot(up, target) < -0.999 {
            node.simdOrientation = simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
        } else {
            node.simdOrientation = simd_quatf(from: up, to: target)
        }
        return node
    }

    private static func gloss(_ color: UIColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .blinn
        material.diffuse.contents = color
        material.specular.contents = UIColor.white
        material.shininess = 0.45
        material.emission.contents = color.withAlphaComponent(0.45)
        return material
    }
}

private func mix(_ a: SCNVector3, _ b: SCNVector3, _ t: Float) -> SCNVector3 {
    SCNVector3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t)
}

private func smooth(_ t: Float) -> Float {
    let x = min(1, max(0, t))
    return x * x * (3 - 2 * x)
}
