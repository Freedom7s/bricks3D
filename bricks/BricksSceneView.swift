import SceneKit
import SwiftUI
import UIKit

struct BricksSceneView: UIViewRepresentable {
    @ObservedObject var world: WorldState
    @ObservedObject var editor: EditorState
    @ObservedObject var camera: CameraState

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = SCNScene()
        view.rendersContinuously = false
        view.preferredFramesPerSecond = 60
        view.antialiasingMode = .multisampling2X
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = false
        view.backgroundColor = .systemBackground
        context.coordinator.connect(view: view, world: world, editor: editor, camera: camera)
        context.coordinator.installScene()
        context.coordinator.installGestures()
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.connect(view: uiView, world: world, editor: editor, camera: camera)
        context.coordinator.render()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var view: SCNView?
        private weak var world: WorldState?
        private weak var editor: EditorState?
        private weak var camera: CameraState?

        private let cameraNode = SCNNode()
        private var renderedBricks: [UUID: Brick] = [:]
        private var renderedCellSize: Float?
        private var renderedGridSpacing: Double?
        private var renderedOrigin = SIMD3<Double>(repeating: 0)
        private var previousOrigin = SIMD3<Double>(repeating: .nan)
        private var lastDrawCell: SIMD3<Int>?

        func connect(view: SCNView, world: WorldState, editor: EditorState, camera: CameraState) {
            self.view = view
            self.world = world
            self.editor = editor
            self.camera = camera
        }

        func installScene() {
            guard let scene = view?.scene else { return }
            cameraNode.name = "camera"
            cameraNode.camera = SCNCamera()
            cameraNode.camera?.zNear = 0.005
            cameraNode.camera?.zFar = 1_000
            scene.rootNode.addChildNode(cameraNode)

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 300
            scene.rootNode.addChildNode(ambient)

            let sun = SCNNode()
            sun.light = SCNLight()
            sun.light?.type = .directional
            sun.light?.intensity = 850
            sun.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi / 4, 0)
            scene.rootNode.addChildNode(sun)
            render()
        }

        func installGestures() {
            guard let view else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))

            let oneFingerPan = UIPanGestureRecognizer(target: self, action: #selector(onOneFingerPan(_:)))
            oneFingerPan.minimumNumberOfTouches = 1
            oneFingerPan.maximumNumberOfTouches = 1

            let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(onTwoFingerPan(_:)))
            twoFingerPan.minimumNumberOfTouches = 2
            twoFingerPan.maximumNumberOfTouches = 2
            twoFingerPan.delegate = self

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
            pinch.delegate = self

            [tap, oneFingerPan, twoFingerPan, pinch].forEach(view.addGestureRecognizer)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            let pair = [gestureRecognizer, otherGestureRecognizer]
            return pair.contains { $0 is UIPinchGestureRecognizer }
                && pair.contains { ($0 as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2 }
        }

        func render() {
            guard let world, let editor else { return }
            updateFloatingOrigin()
            updateCamera()
            updateGrid(cellSize: world.cellSize)
            updateBrickNodes(world.bricks, cellSize: world.cellSize)
            updateSelection(editor.selectedID)
            view?.setNeedsDisplay()
        }

        private func updateFloatingOrigin() {
            guard let camera else { return }
            let quantum = 10.0
            renderedOrigin = SIMD3(
                (camera.center.x / quantum).rounded(.down) * quantum,
                0,
                (camera.center.z / quantum).rounded(.down) * quantum
            )
        }

        private func updateCamera() {
            guard let camera else { return }
            let center = camera.center - renderedOrigin
            let position = SIMD3(
                center.x + camera.radius * sin(camera.theta) * cos(camera.phi),
                center.y + camera.radius * cos(camera.theta),
                center.z + camera.radius * sin(camera.theta) * sin(camera.phi)
            )
            cameraNode.position = scnVector(position)
            cameraNode.look(at: scnVector(center))
        }

        private func updateGrid(cellSize: Float) {
            guard let scene = view?.scene, let camera else { return }
            let spacing = displayGridSpacing(radius: camera.radius, minimum: Double(cellSize))
            let requestedSide = max(20.0, camera.radius * 12)
            var repeatCount = Int(ceil(requestedSide / spacing))
            if repeatCount.isMultiple(of: 2) == false { repeatCount += 1 }
            let side = Double(repeatCount) * spacing
            let recreate = renderedGridSpacing != spacing
                || scene.rootNode.childNode(withName: "ground", recursively: false) == nil

            let ground: SCNNode
            if recreate {
                scene.rootNode.childNode(withName: "ground", recursively: false)?.removeFromParentNode()
                let plane = SCNPlane(width: side, height: side)
                let material = SCNMaterial()
                material.diffuse.contents = gridTileImage()
                material.diffuse.wrapS = .repeat
                material.diffuse.wrapT = .repeat
                let repeats = Float(side / spacing)
                material.diffuse.contentsTransform = SCNMatrix4MakeScale(repeats, repeats, 1)
                material.isDoubleSided = true
                material.lightingModel = .constant
                plane.materials = [material]
                ground = SCNNode(geometry: plane)
                ground.name = "ground"
                ground.eulerAngles.x = -.pi / 2
                scene.rootNode.addChildNode(ground)
            } else {
                ground = scene.rootNode.childNode(withName: "ground", recursively: false)!
                if let plane = ground.geometry as? SCNPlane {
                    plane.width = side
                    plane.height = side
                    let repeats = Float(side / spacing)
                    plane.firstMaterial?.diffuse.contentsTransform = SCNMatrix4MakeScale(repeats, repeats, 1)
                }
            }

            let snappedCenter = SIMD3(
                (camera.center.x / spacing).rounded() * spacing,
                0,
                (camera.center.z / spacing).rounded() * spacing
            ) - renderedOrigin
            ground.position = SCNVector3(Float(snappedCenter.x), -0.0005, Float(snappedCenter.z))
            renderedGridSpacing = spacing
        }

        private func displayGridSpacing(radius: Double, minimum: Double) -> Double {
            let target = max(minimum, radius / 18)
            let magnitude = pow(10, floor(log10(target)))
            for multiplier in [1.0, 2.0, 5.0, 10.0] {
                let candidate = multiplier * magnitude
                if candidate >= target { return candidate }
            }
            return 10 * magnitude
        }

        private func gridTileImage() -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
                UIColor.secondarySystemBackground.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
                UIColor.separator.withAlphaComponent(0.75).setStroke()
                context.cgContext.setLineWidth(1)
                context.cgContext.move(to: CGPoint(x: 0.5, y: 0))
                context.cgContext.addLine(to: CGPoint(x: 0.5, y: 64))
                context.cgContext.move(to: CGPoint(x: 0, y: 0.5))
                context.cgContext.addLine(to: CGPoint(x: 64, y: 0.5))
                context.cgContext.strokePath()
            }
        }

        private func updateBrickNodes(_ bricks: [UUID: Brick], cellSize: Float) {
            guard let scene = view?.scene else { return }
            for id in renderedBricks.keys where bricks[id] == nil {
                scene.rootNode.childNode(withName: nodeName(id), recursively: false)?.removeFromParentNode()
            }

            let originChanged = previousOrigin != renderedOrigin
            for (id, brick) in bricks where originChanged
                || renderedBricks[id] != brick
                || renderedCellSize != cellSize {
                scene.rootNode.childNode(withName: nodeName(id), recursively: false)?.removeFromParentNode()
                scene.rootNode.addChildNode(makeNode(for: brick, cellSize: cellSize))
            }
            renderedBricks = bricks
            renderedCellSize = cellSize
            previousOrigin = renderedOrigin
        }

        private func makeNode(for brick: Brick, cellSize: Float) -> SCNNode {
            let width = CGFloat(Float(brick.size.x) * cellSize)
            let height = CGFloat(Float(brick.size.y) * cellSize)
            let length = CGFloat(Float(brick.size.z) * cellSize)
            let box = SCNBox(width: width, height: height, length: length, chamferRadius: 0)
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.systemBlue
            material.lightingModel = .lambert
            box.materials = [material]

            let worldPosition = SIMD3<Double>(
                (Double(brick.pos.x) + Double(brick.size.x) / 2) * Double(cellSize),
                (Double(brick.pos.y) + Double(brick.size.y) / 2) * Double(cellSize),
                (Double(brick.pos.z) + Double(brick.size.z) / 2) * Double(cellSize)
            )
            let node = SCNNode(geometry: box)
            node.name = nodeName(brick.id)
            node.position = scnVector(worldPosition - renderedOrigin)
            return node
        }

        private func updateSelection(_ selectedID: UUID?) {
            guard let scene = view?.scene else { return }
            for id in renderedBricks.keys {
                let node = scene.rootNode.childNode(withName: nodeName(id), recursively: false)
                node?.geometry?.firstMaterial?.emission.contents = id == selectedID
                    ? UIColor.systemYellow.withAlphaComponent(0.4)
                    : UIColor.clear
            }
        }

        @objc private func onTap(_ recognizer: UITapGestureRecognizer) {
            guard let view, let world, let editor else { return }
            let point = recognizer.location(in: view)
            if editor.interactionMode == .camera {
                let id = brickID(at: point)
                editor.selectedID = editor.selectedID == id ? nil : id
            } else if let cell = gridPosition(at: point, planeY: 0) {
                draw(cells: [cell], in: world)
            }
        }

        @objc private func onOneFingerPan(_ recognizer: UIPanGestureRecognizer) {
            guard let view, let world, let editor, let camera else { return }
            if editor.interactionMode == .camera {
                let delta = recognizer.translation(in: view)
                recognizer.setTranslation(.zero, in: view)
                camera.orbit(horizontal: -Double(delta.x) * 0.005, vertical: -Double(delta.y) * 0.005)
                return
            }

            switch recognizer.state {
            case .began:
                world.beginTransaction()
                lastDrawCell = nil
                drawStroke(at: recognizer.location(in: view), world: world)
            case .changed:
                drawStroke(at: recognizer.location(in: view), world: world)
            case .ended:
                drawStroke(at: recognizer.location(in: view), world: world)
                world.endTransaction()
                lastDrawCell = nil
            case .cancelled, .failed:
                world.cancelTransaction()
                lastDrawCell = nil
            default:
                break
            }
        }

        private func drawStroke(at point: CGPoint, world: WorldState) {
            guard let cell = gridPosition(at: point, planeY: 0) else { return }
            let cells = lastDrawCell.map { interpolatedCells(from: $0, to: cell) } ?? [cell]
            draw(cells: cells, in: world)
            lastDrawCell = cell
        }

        private func draw(cells: [SIMD3<Int>], in world: WorldState) {
            for cell in cells where world.brick(atGrid: SIMD3(cell.x, 0, cell.z)) == nil {
                _ = world.place(Brick(
                    pos: SIMD3(cell.x, 0, cell.z),
                    size: SIMD3(repeating: 1),
                    color: SIMD3(0.2, 0.55, 0.95)
                ))
            }
        }

        private func interpolatedCells(from start: SIMD3<Int>, to end: SIMD3<Int>) -> [SIMD3<Int>] {
            let dx = end.x - start.x
            let dz = end.z - start.z
            let steps = max(abs(dx), abs(dz))
            guard steps > 0 else { return [end] }
            return (0...steps).map { index in
                let t = Double(index) / Double(steps)
                return SIMD3(
                    Int((Double(start.x) + Double(dx) * t).rounded()),
                    0,
                    Int((Double(start.z) + Double(dz) * t).rounded())
                )
            }
        }

        @objc private func onTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
            guard let view, let camera else { return }
            let delta = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)
            camera.pan(screenX: Double(delta.x), screenY: Double(delta.y))
        }

        @objc private func onPinch(_ recognizer: UIPinchGestureRecognizer) {
            guard recognizer.state == .changed, let camera else { return }
            camera.zoom(by: Double(recognizer.scale))
            world?.refineForZoom(radius: camera.radius)
            recognizer.scale = 1
        }

        private func brickID(at point: CGPoint) -> UUID? {
            guard let view else { return nil }
            for hit in view.hitTest(point) {
                guard let name = hit.node.name, name.hasPrefix("brick_") else { continue }
                return UUID(uuidString: String(name.dropFirst("brick_".count)))
            }
            return nil
        }

        private func gridPosition(at point: CGPoint, planeY: Float) -> SIMD3<Int>? {
            guard let view, let world else { return nil }
            let ray = screenPointToRay(view, pt: point)
            guard let local = intersectPlaneY(ray: ray, y: planeY) else { return nil }
            return SIMD3(
                Int(floor((Double(local.x) + renderedOrigin.x) / Double(world.cellSize))),
                0,
                Int(floor((Double(local.z) + renderedOrigin.z) / Double(world.cellSize)))
            )
        }

        private func scnVector(_ value: SIMD3<Double>) -> SCNVector3 {
            SCNVector3(Float(value.x), Float(value.y), Float(value.z))
        }

        private func nodeName(_ id: UUID) -> String { "brick_\(id.uuidString)" }
    }
}
