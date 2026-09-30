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
        view.rendersContinuously = true
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = false
        view.backgroundColor = UIColor.systemBackground

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
        private var renderedBrickCellSize: Float?
        private var movingID: UUID?
        private var dragOffset = SIMD2<Int>(repeating: 0)

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
            cameraNode.camera?.zFar = 500
            scene.rootNode.addChildNode(cameraNode)

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 260
            scene.rootNode.addChildNode(ambient)

            let directional = SCNNode()
            directional.light = SCNLight()
            directional.light?.type = .directional
            directional.light?.intensity = 900
            directional.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi / 4, 0)
            scene.rootNode.addChildNode(directional)

            render()
        }

        func installGestures() {
            guard let view else { return }

            let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(onLongPress(_:)))
            longPress.minimumPressDuration = 0.4
            tap.require(toFail: longPress)

            let oneFingerPan = UIPanGestureRecognizer(target: self, action: #selector(onOneFingerPan(_:)))
            oneFingerPan.minimumNumberOfTouches = 1
            oneFingerPan.maximumNumberOfTouches = 1

            let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(onTwoFingerPan(_:)))
            twoFingerPan.minimumNumberOfTouches = 2
            twoFingerPan.maximumNumberOfTouches = 2
            twoFingerPan.delegate = self

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
            pinch.delegate = self

            [tap, longPress, oneFingerPan, twoFingerPan, pinch].forEach(view.addGestureRecognizer)
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
            updateCamera()
            updateGridIfNeeded(cellSize: world.cellSize)
            updateBrickNodes(world.bricks)
            updateSelection(editor.selectedID)
        }

        private func updateCamera() {
            guard let camera else { return }
            let x = camera.center.x + camera.radius * sin(camera.theta) * cos(camera.phi)
            let y = camera.center.y + camera.radius * cos(camera.theta)
            let z = camera.center.z + camera.radius * sin(camera.theta) * sin(camera.phi)
            cameraNode.position = SCNVector3(x, y, z)
            cameraNode.look(at: camera.center)
        }

        private func updateGridIfNeeded(cellSize: Float) {
            guard renderedCellSize != cellSize, let scene = view?.scene else { return }
            scene.rootNode.childNode(withName: "ground", recursively: false)?.removeFromParentNode()

            let side: CGFloat = 100
            let plane = SCNPlane(width: side, height: side)
            let material = SCNMaterial()
            material.diffuse.contents = gridTileImage()
            material.diffuse.wrapS = .repeat
            material.diffuse.wrapT = .repeat
            let repeats = Float(side) / cellSize
            material.diffuse.contentsTransform = SCNMatrix4MakeScale(repeats, repeats, 1)
            material.isDoubleSided = true
            material.lightingModel = .constant
            plane.materials = [material]

            let ground = SCNNode(geometry: plane)
            ground.name = "ground"
            ground.eulerAngles.x = -.pi / 2
            ground.position.y = -0.0005
            scene.rootNode.addChildNode(ground)
            renderedCellSize = cellSize
        }

        private func gridTileImage() -> UIImage {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
            return renderer.image { context in
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

        private func updateBrickNodes(_ bricks: [UUID: Brick]) {
            guard let scene = view?.scene, let cellSize = world?.cellSize else { return }

            for id in renderedBricks.keys where bricks[id] == nil {
                scene.rootNode.childNode(withName: nodeName(id), recursively: false)?.removeFromParentNode()
            }

            for (id, brick) in bricks where renderedBricks[id] != brick || renderedBrickCellSize != cellSize {
                scene.rootNode.childNode(withName: nodeName(id), recursively: false)?.removeFromParentNode()
                scene.rootNode.addChildNode(makeNode(for: brick, cellSize: cellSize))
            }
            renderedBricks = bricks
            renderedBrickCellSize = cellSize
        }

        private func makeNode(for brick: Brick, cellSize: Float) -> SCNNode {
            let width = CGFloat(Float(brick.size.x) * cellSize)
            let height = CGFloat(Float(brick.size.y) * cellSize)
            let length = CGFloat(Float(brick.size.z) * cellSize)
            let box = SCNBox(width: width, height: height, length: length, chamferRadius: 0)
            let material = SCNMaterial()
            material.diffuse.contents = scnColor(brick.color)
            material.lightingModel = .physicallyBased
            box.materials = [material]

            let node = SCNNode(geometry: box)
            node.name = nodeName(brick.id)
            node.position = SCNVector3(
                (Float(brick.pos.x) + Float(brick.size.x) / 2) * cellSize,
                (Float(brick.pos.y) + Float(brick.size.y) / 2) * cellSize,
                (Float(brick.pos.z) + Float(brick.size.z) / 2) * cellSize
            )
            return node
        }

        private func updateSelection(_ selectedID: UUID?) {
            guard let scene = view?.scene else { return }
            for (id, _) in renderedBricks {
                let node = scene.rootNode.childNode(withName: nodeName(id), recursively: false)
                node?.geometry?.firstMaterial?.emission.contents = id == selectedID
                    ? UIColor.systemYellow.withAlphaComponent(0.45)
                    : UIColor.clear
            }
        }

        @objc private func onTap(_ recognizer: UITapGestureRecognizer) {
            guard let view, let world, let editor else { return }
            let point = recognizer.location(in: view)
            if let id = brickID(at: point) {
                editor.selectedID = editor.selectedID == id ? nil : id
                return
            }

            editor.selectedID = nil
            guard editor.interactionMode == .draw,
                  let position = gridPosition(at: point, planeY: 0) else { return }
            let brick = Brick(
                pos: SIMD3(position.x, 0, position.z),
                size: editor.defaultSize,
                color: editor.defaultColor
            )
            if world.place(brick) { editor.selectedID = brick.id }
        }

        @objc private func onLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began,
                  editor?.interactionMode == .draw,
                  let view,
                  let id = brickID(at: recognizer.location(in: view)) else { return }
            editor?.selectedID = id
            _ = world?.rotateAroundY(id: id)
        }

        @objc private func onOneFingerPan(_ recognizer: UIPanGestureRecognizer) {
            guard let view, let world, let editor, let camera else { return }
            if editor.interactionMode == .camera {
                let delta = recognizer.translation(in: view)
                recognizer.setTranslation(.zero, in: view)
                camera.orbit(horizontal: Float(delta.x) * 0.005, vertical: -Float(delta.y) * 0.005)
                return
            }

            switch recognizer.state {
            case .began:
                movingID = brickID(at: recognizer.location(in: view))
                editor.selectedID = movingID
                if let id = movingID, let brick = world.bricks[id] {
                    let planeY = Float(brick.pos.y) * world.cellSize
                    if let grid = gridPosition(at: recognizer.location(in: view), planeY: planeY) {
                        dragOffset = SIMD2(brick.pos.x - grid.x, brick.pos.z - grid.z)
                    } else {
                        dragOffset = .zero
                    }
                    world.beginTransaction()
                }
            case .changed:
                guard let id = movingID, let brick = world.bricks[id] else { return }
                let planeY = Float(brick.pos.y) * world.cellSize
                guard let grid = gridPosition(at: recognizer.location(in: view), planeY: planeY) else { return }
                _ = world.move(
                    id: id,
                    to: SIMD3(grid.x + dragOffset.x, brick.pos.y, grid.z + dragOffset.y)
                )
            case .ended:
                world.endTransaction()
                movingID = nil
            case .cancelled, .failed:
                world.cancelTransaction()
                movingID = nil
            default:
                break
            }
        }

        @objc private func onTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
            guard let view, let camera else { return }
            let delta = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)
            camera.pan(screenX: Float(delta.x), screenY: Float(delta.y))
        }

        @objc private func onPinch(_ recognizer: UIPinchGestureRecognizer) {
            guard recognizer.state == .changed, let camera else { return }
            camera.zoom(by: Float(recognizer.scale))
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
            guard let position = intersectPlaneY(ray: ray, y: planeY) else { return nil }
            return snapToGrid(position, cell: world.cellSize)
        }

        private func nodeName(_ id: UUID) -> String { "brick_\(id.uuidString)" }
    }
}
