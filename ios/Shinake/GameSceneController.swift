import SceneKit
import simd
import UIKit

/// Body diameter stays near half a cell so the grid reads. Food is a smaller
/// apple, not another ball of the same size as the head.
private enum SnakeFood {
    static let radius: CGFloat = 0.275
}

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
    private var jointNodes: [SCNNode] = []
    private var linkNodes: [SCNNode] = []
    private var eyeNodes: [SCNNode] = []
    private var pupilNodes: [SCNNode] = []
    private let tongueNode = SCNNode()
    private var smoothedLook = SIMD3<Float>(0, 0, 0)
    private var foodNodes: [Int: SCNNode] = [:]
    private var solidNodes: [SCNNode] = []
    private var guideNode: SCNNode?
    private let snakeLayer = sliceNode(Theme.limeUI.withAlphaComponent(0.16))
    private let foodLayer = sliceNode(UIColor(red: 1, green: 0.36, blue: 0.42, alpha: 0.22))
    private var builtGrid = -1
    private var time: Double = 0
    private var snakeAlive = true

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
        world.addChildNode(snakeLayer)
        world.addChildNode(foodLayer)
        snakeLayer.isHidden = true
        foodLayer.isHidden = true

        let camera = SCNCamera()
        camera.fieldOfView = CGFloat(playCameraVerticalFOV)
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
            let eye = SCNNode(geometry: SCNSphere(radius: 0.055))
            (eye.geometry as? SCNSphere)?.segmentCount = 12
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = UIColor.white
            eye.geometry?.materials = [material]
            world.addChildNode(eye)
            eyeNodes.append(eye)

            let pupil = SCNNode(geometry: SCNSphere(radius: 0.026))
            (pupil.geometry as? SCNSphere)?.segmentCount = 8
            let pupilMaterial = SCNMaterial()
            pupilMaterial.lightingModel = .constant
            pupilMaterial.diffuse.contents = UIColor(white: 0.08, alpha: 1)
            pupil.geometry?.materials = [pupilMaterial]
            world.addChildNode(pupil)
            pupilNodes.append(pupil)
        }
        let tongue = SCNBox(width: 0.045, height: 0.16, length: 0.02, chamferRadius: 0.008)
        let tongueMaterial = SCNMaterial()
        tongueMaterial.lightingModel = .constant
        tongueMaterial.diffuse.contents = UIColor(red: 0.95, green: 0.25, blue: 0.38, alpha: 1)
        tongue.materials = [tongueMaterial]
        tongueNode.geometry = tongue
        world.addChildNode(tongueNode)
    }

    func render(_ snapshot: RenderSnapshot, showGuide: Bool, shake: Double, dt: Double) {
        time += dt
        if snapshot.grid != builtGrid {
            rebuildBoard(grid: snapshot.grid)
        }
        placeCamera(snapshot, shake: shake, dt: dt)
        placeLayers(snapshot)
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

    private func placeCamera(_ snapshot: RenderSnapshot, shake: Double, dt: Double) {
        let bounds = view.bounds
        let aspect: Double
        if bounds.width > 2, bounds.height > 2 {
            aspect = Double(bounds.width / bounds.height)
        } else {
            // Before layout, assume a tall portrait canvas so the first frame
            // cannot be tighter than a 13 Pro Max play view.
            aspect = 0.62
        }
        let headWorld: WorldPoint
        if let head = snapshot.snake.first {
            let point = worldPoint(head, grid: snapshot.grid)
            headWorld = WorldPoint(Double(point.x), Double(point.y), Double(point.z))
        } else {
            headWorld = .zero
        }
        let target = cameraLookAt(headWorld: headWorld, grid: snapshot.grid)
        let aim = SIMD3<Float>(Float(target.x), Float(target.y), Float(target.z))
        let follow = Float(1 - exp(-dt * 2.8))
        smoothedLook += (aim - smoothedLook) * min(1, max(0, follow))
        let distance = cameraDistanceToFitCube(
            grid: snapshot.grid,
            aspect: aspect,
            lookAt: WorldPoint(Double(smoothedLook.x), Double(smoothedLook.y), Double(smoothedLook.z))
        )
        let eye = CameraRig.standard.eyeOffset
        let rig = simd_normalize(SIMD3<Float>(Float(eye.x), Float(eye.y), Float(eye.z)))
        let amp = Float(shake) * 0.12
        let wobble = SIMD3<Float>(sin(Float(time) * 47) * amp, cos(Float(time) * 53) * amp, 0)
        let position = smoothedLook + rig * Float(distance) + wobble
        cameraNode.simdPosition = position
        cameraNode.look(at: SCNVector3(smoothedLook.x, smoothedLook.y, smoothedLook.z))
    }

    private func placeSnake(_ snapshot: RenderSnapshot) {
        snakeAlive = snapshot.alive
        let count = snapshot.snake.count
        let alpha = smooth(Float(snapshot.fraction))
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(count)
        for index in 0..<count {
            let point = segmentPosition(index: index, snapshot: snapshot, alpha: alpha)
            points.append(SIMD3<Float>(point.x, point.y, point.z))
        }
        while jointNodes.count < count {
            jointNodes.append(makeJoint())
        }
        for index in count..<jointNodes.count {
            jointNodes[index].isHidden = true
        }
        let linkCount = max(0, count - 1)
        while linkNodes.count < linkCount {
            linkNodes.append(makeLink())
        }
        for index in linkCount..<linkNodes.count {
            linkNodes[index].isHidden = true
        }
        for index in 0..<count {
            let radius = bodyRadius(index: index, count: count)
            let node = jointNodes[index]
            node.isHidden = false
            node.simdPosition = points[index]
            node.simdScale = SIMD3<Float>(repeating: radius)
            tint(node, index: index, count: count, head: index == 0)
        }
        for index in 0..<linkCount {
            let start = points[index]
            let end = points[index + 1]
            let delta = end - start
            let length = simd_length(delta)
            let node = linkNodes[index]
            guard length > 0.001, let cone = node.geometry as? SCNCone else {
                node.isHidden = true
                continue
            }
            node.isHidden = false
            cone.bottomRadius = CGFloat(bodyRadius(index: index, count: count))
            cone.topRadius = CGFloat(bodyRadius(index: index + 1, count: count))
            cone.height = CGFloat(length)
            node.simdPosition = (start + end) * 0.5
            orient(node, along: delta)
            tint(node, index: index, count: count, head: false)
        }
        placeFace(snapshot, points: points)
    }

    private func makeJoint() -> SCNNode {
        let sphere = SCNSphere(radius: 1)
        sphere.segmentCount = 18
        let material = glossMaterial(Theme.limeUI)
        material.emission.contents = Theme.limeUI.withAlphaComponent(0.16)
        sphere.materials = [material]
        let node = SCNNode(geometry: sphere)
        let glint = SCNSphere(radius: 0.28)
        glint.segmentCount = 8
        let shine = SCNMaterial()
        shine.lightingModel = .constant
        shine.diffuse.contents = UIColor(white: 1, alpha: 0.42)
        glint.materials = [shine]
        let glintNode = SCNNode(geometry: glint)
        glintNode.simdPosition = SIMD3<Float>(0.34, 0.42, 0.22)
        node.addChildNode(glintNode)
        world.addChildNode(node)
        return node
    }

    private func makeLink() -> SCNNode {
        let cone = SCNCone(topRadius: 0.2, bottomRadius: 0.2, height: 1)
        cone.radialSegmentCount = 12
        let material = glossMaterial(Theme.limeUI)
        material.emission.contents = Theme.limeUI.withAlphaComponent(0.16)
        cone.materials = [material]
        let node = SCNNode(geometry: cone)
        world.addChildNode(node)
        return node
    }

    /// Head diameter 0.60 of a cell. The body starts at 0.54 and tapers to 0.28.
    private func bodyRadius(index: Int, count: Int) -> Float {
        let wave = 1 + 0.025 * sin(Float(time) * 3 + Float(index) * 0.55)
        if index == 0 { return 0.30 * wave }
        let t = Float(index) / Float(max(count - 1, 1))
        return (0.27 + (0.14 - 0.27) * t) * wave
    }

    private func tint(_ node: SCNNode, index: Int, count: Int, head: Bool) {
        let t = CGFloat(index) / CGFloat(max(count - 1, 1))
        let band: CGFloat = index % 3 == 2 ? 0.78 : 1
        let color = UIColor(
            red: (0.62 - 0.34 * t) * band,
            green: (0.94 - 0.40 * t) * band,
            blue: (0.38 + 0.22 * t) * band,
            alpha: 1
        )
        let material = node.geometry?.materials.first ?? glossMaterial(color)
        if head {
            material.diffuse.contents = UIColor(red: 0.78, green: 0.96, blue: 0.48, alpha: 1)
            material.emission.contents = snapshotAliveEmission()
        } else {
            material.diffuse.contents = color
            material.emission.contents = color.withAlphaComponent(0.14)
        }
        node.geometry?.materials = [material]
    }

    private func snapshotAliveEmission() -> UIColor {
        if snakeAlive {
            return Theme.limeUI.withAlphaComponent(0.28)
        }
        return UIColor(red: 1, green: 0.28, blue: 0.28, alpha: 1)
    }

    private func placeFace(_ snapshot: RenderSnapshot, points: [SIMD3<Float>]) {
        guard let head = points.first else {
            for node in eyeNodes + pupilNodes { node.isHidden = true }
            tongueNode.isHidden = true
            return
        }
        let forward = facing(snapshot)
        var up = SIMD3<Float>(0, 1, 0)
        if abs(forward.y) > 0.95 { up = SIMD3<Float>(1, 0, 0) }
        let side = simd_normalize(simd_cross(forward, up))
        let lift = simd_normalize(simd_cross(side, forward))
        let sockets = [
            forward * 0.20 + side * 0.105 + lift * 0.055,
            forward * 0.20 - side * 0.105 + lift * 0.055,
        ]
        for (index, socket) in sockets.enumerated() where index < eyeNodes.count && index < pupilNodes.count {
            eyeNodes[index].isHidden = false
            pupilNodes[index].isHidden = false
            eyeNodes[index].simdPosition = head + socket
            pupilNodes[index].simdPosition = head + socket + forward * 0.04
        }
        let flick = 0.04 + 0.14 * max(0, sin(Float(time) * 5.2))
        tongueNode.isHidden = !snapshot.alive
        tongueNode.simdPosition = head + forward * (0.30 + flick * 0.5)
        orient(tongueNode, along: forward)
        tongueNode.simdScale = SIMD3<Float>(1, max(0.35, flick / 0.16), 1)
    }

    private func facing(_ snapshot: RenderSnapshot) -> SIMD3<Float> {
        let current = worldPoint(snapshot.snake[0], grid: snapshot.grid)
        let fromCell = snapshot.previous.first ?? snapshot.snake[0]
        let from = worldPoint(fromCell, grid: snapshot.grid)
        let travel = SIMD3<Float>(current.x - from.x, current.y - from.y, current.z - from.z)
        if simd_length(travel) > 0.05 {
            return simd_normalize(travel)
        }
        let direction = snapshot.direction
        return SIMD3<Float>(Float(direction.x), Float(direction.y), Float(direction.z))
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
            let squash: Float = pellet.kind == .apple ? 0.88 : 1
            node.scale = SCNVector3(pulse, pulse * squash, pulse)
            if let beacon = node.childNode(withName: "beacon", recursively: false) {
                let height = max(0.2, node.position.y + half)
                beacon.position = SCNVector3(0, -height * 0.5, 0)
                (beacon.geometry as? SCNCylinder)?.height = CGFloat(height)
            }
            if let shadow = node.childNode(withName: "shadow", recursively: false) {
                let floorY = -half + 0.05
                shadow.position = SCNVector3(0, floorY - node.position.y, 0)
            }
        }
    }

    private func makeFood(_ kind: FoodKind) -> SCNNode {
        let sphere = SCNSphere(radius: kind == .star ? 0.30 : SnakeFood.radius)
        sphere.segmentCount = 24
        let material = glossMaterial(Theme.foodUI(kind))
        material.emission.contents = Theme.foodUI(kind).withAlphaComponent(0.35)
        sphere.materials = [material]
        let node = SCNNode(geometry: sphere)
        let beacon = SCNCylinder(radius: 0.04, height: 1)
        let beam = SCNMaterial()
        beam.lightingModel = .constant
        beam.diffuse.contents = Theme.foodUI(kind).withAlphaComponent(0.28)
        beam.writesToDepthBuffer = false
        beacon.materials = [beam]
        let beamNode = SCNNode(geometry: beacon)
        beamNode.name = "beacon"
        node.addChildNode(beamNode)
        let disc = SCNCylinder(radius: 0.36, height: 0.04)
        let discMaterial = SCNMaterial()
        discMaterial.lightingModel = .constant
        discMaterial.diffuse.contents = Theme.foodUI(kind).withAlphaComponent(0.9)
        disc.materials = [discMaterial]
        let discNode = SCNNode(geometry: disc)
        discNode.name = "shadow"
        node.addChildNode(discNode)
        let light = SCNLight()
        light.type = .omni
        light.intensity = 70
        light.color = Theme.foodUI(kind)
        light.attenuationEndDistance = 3.5
        node.light = light
        if kind == .apple {
            node.addChildNode(appleStem())
        }
        return node
    }

    private func appleStem() -> SCNNode {
        let stem = SCNCylinder(radius: 0.025, height: 0.14)
        stem.radialSegmentCount = 8
        let bark = SCNMaterial()
        bark.lightingModel = .lambert
        bark.diffuse.contents = UIColor(red: 0.35, green: 0.22, blue: 0.12, alpha: 1)
        stem.materials = [bark]
        let node = SCNNode(geometry: stem)
        node.simdPosition = SIMD3<Float>(0, 0.30, 0)
        let leaf = SCNBox(width: 0.10, height: 0.018, length: 0.06, chamferRadius: 0.006)
        let green = SCNMaterial()
        green.lightingModel = .lambert
        green.diffuse.contents = UIColor(red: 0.25, green: 0.62, blue: 0.28, alpha: 1)
        leaf.materials = [green]
        let leafNode = SCNNode(geometry: leaf)
        leafNode.simdPosition = SIMD3<Float>(0.05, 0.04, 0)
        node.addChildNode(leafNode)
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

    private func placeLayers(_ snapshot: RenderSnapshot) {
        let span = Float(max(snapshot.grid - 1, 1))
        guard let head = snapshot.snake.first else {
            snakeLayer.isHidden = true
            foodLayer.isHidden = true
            return
        }
        let headPoint = worldPoint(head, grid: snapshot.grid)
        snakeLayer.isHidden = false
        snakeLayer.position = SCNVector3(0, 0, headPoint.z)
        snakeLayer.scale = SCNVector3(span, span, 1)
        if let food = snapshot.foods.first, food.position.z != head.z {
            let foodPoint = worldPoint(food.position, grid: snapshot.grid)
            foodLayer.isHidden = false
            foodLayer.position = SCNVector3(0, 0, foodPoint.z)
            foodLayer.scale = SCNVector3(span, span, 1)
        } else {
            foodLayer.isHidden = true
        }
    }

    private func placeGuide(_ snapshot: RenderSnapshot, visible: Bool) {
        guideNode?.removeFromParentNode()
        guideNode = nil
        guard visible, let food = snapshot.foods.first, let head = snapshot.snake.first else { return }
        let from = worldPoint(head, grid: snapshot.grid)
        let to = worldPoint(food.position, grid: snapshot.grid)
        let node = cylinder(
            from: SIMD3<Float>(from.x, from.y, from.z),
            to: SIMD3<Float>(to.x, to.y, to.z),
            color: Theme.limeUI.withAlphaComponent(0.95),
            radius: 0.02
        )
        world.addChildNode(node)
        guideNode = node
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

    private func cylinder(from start: SIMD3<Float>, to end: SIMD3<Float>, color: UIColor, radius: Float = 0.045) -> SCNNode {
        let delta = end - start
        let length = simd_length(delta)
        let cylinder = SCNCylinder(radius: CGFloat(radius), height: CGFloat(max(length, 0.001)))
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.emission.contents = color.withAlphaComponent(0.35)
        cylinder.materials = [material]
        let node = SCNNode(geometry: cylinder)
        node.simdPosition = (start + end) * 0.5
        orient(node, along: delta)
        return node
    }

    /// Points local +Y along `delta`. Cones and the tongue are built on that axis.
    private func orient(_ node: SCNNode, along delta: SIMD3<Float>) {
        let length = simd_length(delta)
        guard length > 1e-5 else { return }
        let target = delta / length
        let up = SIMD3<Float>(0, 1, 0)
        if simd_dot(up, target) < -0.999 {
            node.simdOrientation = simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
        } else {
            node.simdOrientation = simd_quatf(from: up, to: target)
        }
    }
}

/// Shared by the snake materials (created in property initializers) and food.
private func sliceNode(_ color: UIColor) -> SCNNode {
    let plane = SCNPlane(width: 1, height: 1)
    let material = SCNMaterial()
    material.lightingModel = .constant
    material.diffuse.contents = color
    material.isDoubleSided = true
    material.writesToDepthBuffer = false
    plane.materials = [material]
    return SCNNode(geometry: plane)
}

private func glossMaterial(_ color: UIColor) -> SCNMaterial {
    let material = SCNMaterial()
    material.lightingModel = .blinn
    material.diffuse.contents = color
    material.specular.contents = UIColor.white
    material.shininess = 0.45
    material.emission.contents = color.withAlphaComponent(0.45)
    return material
}

private func mix(_ a: SCNVector3, _ b: SCNVector3, _ t: Float) -> SCNVector3 {
    SCNVector3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t)
}

private func smooth(_ t: Float) -> Float {
    let x = min(1, max(0, t))
    return x * x * (3 - 2 * x)
}
