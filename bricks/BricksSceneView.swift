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
        private var renderedBrickGridStep: Int?
        private var renderedOrigin = SIMD3<Double>(repeating: 0)
        private var previousOrigin = SIMD3<Double>(repeating: .nan)
        private var lastDrawCell: SIMD3<Int>?
        private var drawingLayerY: Int?
        private enum TwoFingerMode { case viewTilt, pan }
        private var twoFingerMode: TwoFingerMode?
        private lazy var brickGridImage = makeBrickGridImage()

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

            let rotation = UIRotationGestureRecognizer(target: self, action: #selector(onRotation(_:)))
            rotation.delegate = self

            let eraserToggle = UITapGestureRecognizer(target: self, action: #selector(onTwoFingerDoubleTap(_:)))
            eraserToggle.numberOfTouchesRequired = 2
            eraserToggle.numberOfTapsRequired = 2

            [tap, oneFingerPan, twoFingerPan, pinch, rotation, eraserToggle].forEach(view.addGestureRecognizer)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            let supported: (UIGestureRecognizer) -> Bool = {
                $0 is UIPinchGestureRecognizer
                    || $0 is UIRotationGestureRecognizer
                    || ($0 as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2
            }
            return supported(gestureRecognizer) && supported(otherGestureRecognizer)
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
            cameraNode.look(
                at: scnVector(center),
                up: SCNVector3(0, 1, 0),
                localFront: SCNVector3(0, 0, -1)
            )
        }

        private func updateGrid(cellSize: Float) {
            guard let scene = view?.scene, let camera else { return }
            let spacing = displayGridSpacing(radius: camera.radius, minimum: Double(cellSize))
            let effectiveSpacing: Double
            if let fixedSize = editor?.brushSizeMode.fixedSize {
                effectiveSpacing = fixedSize
            } else {
                effectiveSpacing = spacing
            }
            let requestedSide = max(20.0, camera.radius * 12)
            var repeatCount = Int(ceil(requestedSide / effectiveSpacing))
            if repeatCount.isMultiple(of: 2) == false { repeatCount += 1 }
            let side = Double(repeatCount) * effectiveSpacing
            let recreate = renderedGridSpacing != effectiveSpacing
                || scene.rootNode.childNode(withName: "ground", recursively: false) == nil

            let ground: SCNNode
            if recreate {
                scene.rootNode.childNode(withName: "ground", recursively: false)?.removeFromParentNode()
                let plane = SCNPlane(width: side, height: side)
                let material = SCNMaterial()
                material.diffuse.contents = gridTileImage()
                material.diffuse.wrapS = .repeat
                material.diffuse.wrapT = .repeat
                let repeats = Float(side / effectiveSpacing)
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
                    let repeats = Float(side / effectiveSpacing)
                    plane.firstMaterial?.diffuse.contentsTransform = SCNMatrix4MakeScale(repeats, repeats, 1)
                }
            }

            let snappedCenter = SIMD3(
                (camera.center.x / effectiveSpacing).rounded() * effectiveSpacing,
                0,
                (camera.center.z / effectiveSpacing).rounded() * effectiveSpacing
            ) - renderedOrigin
            ground.position = SCNVector3(Float(snappedCenter.x), -0.0005, Float(snappedCenter.z))
            renderedGridSpacing = effectiveSpacing
            if editor?.visibleGridSizeMeters != effectiveSpacing {
                editor?.visibleGridSizeMeters = effectiveSpacing
            }
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
            let gridStep = max(1, Int(((editor?.visibleGridSizeMeters ?? Double(cellSize)) / Double(cellSize)).rounded()))
            for id in renderedBricks.keys where bricks[id] == nil {
                scene.rootNode.childNode(withName: nodeName(id), recursively: false)?.removeFromParentNode()
            }

            let originChanged = previousOrigin != renderedOrigin
            for (id, brick) in bricks where originChanged
                || renderedBricks[id] != brick
                || renderedCellSize != cellSize
                || renderedBrickGridStep != gridStep {
                scene.rootNode.childNode(withName: nodeName(id), recursively: false)?.removeFromParentNode()
                scene.rootNode.addChildNode(makeNode(for: brick, cellSize: cellSize, gridStep: gridStep))
            }
            renderedBricks = bricks
            renderedCellSize = cellSize
            renderedBrickGridStep = gridStep
            previousOrigin = renderedOrigin
        }

        private func makeNode(for brick: Brick, cellSize: Float, gridStep: Int) -> SCNNode {
            let width = CGFloat(Float(brick.size.x) * cellSize)
            let height = CGFloat(Float(brick.size.y) * cellSize)
            let length = CGFloat(Float(brick.size.z) * cellSize)
            let box = SCNBox(width: width, height: height, length: length, chamferRadius: 0)
            let xy = brickMaterial(
                horizontalCells: brick.size.x,
                verticalCells: brick.size.y,
                gridStep: gridStep
            )
            let zy = brickMaterial(
                horizontalCells: brick.size.z,
                verticalCells: brick.size.y,
                gridStep: gridStep
            )
            let xz = brickMaterial(
                horizontalCells: brick.size.x,
                verticalCells: brick.size.z,
                gridStep: gridStep
            )
            box.materials = [xy, zy, xy.copy() as! SCNMaterial, zy.copy() as! SCNMaterial, xz, xz.copy() as! SCNMaterial]

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

        private func brickMaterial(horizontalCells: Int, verticalCells: Int, gridStep: Int) -> SCNMaterial {
            let material = SCNMaterial()
            material.diffuse.contents = brickGridImage
            material.diffuse.wrapS = .repeat
            material.diffuse.wrapT = .repeat
            material.diffuse.contentsTransform = SCNMatrix4MakeScale(
                max(1, Float(horizontalCells) / Float(gridStep)),
                max(1, Float(verticalCells) / Float(gridStep)),
                1
            )
            material.lightingModel = .lambert
            return material
        }

        private func makeBrickGridImage() -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
                UIColor.systemBlue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
                UIColor.label.withAlphaComponent(0.32).setStroke()
                context.cgContext.setLineWidth(2)
                context.cgContext.move(to: CGPoint(x: 1, y: 0))
                context.cgContext.addLine(to: CGPoint(x: 1, y: 64))
                context.cgContext.move(to: CGPoint(x: 0, y: 1))
                context.cgContext.addLine(to: CGPoint(x: 64, y: 1))
                context.cgContext.strokePath()
            }
        }

        private func updateSelection(_ selectedID: UUID?) {
            guard let scene = view?.scene else { return }
            for id in renderedBricks.keys {
                let node = scene.rootNode.childNode(withName: nodeName(id), recursively: false)
                node?.geometry?.materials.forEach {
                    $0.emission.contents = id == selectedID
                        ? UIColor.systemYellow.withAlphaComponent(0.4)
                        : UIColor.clear
                }
            }
        }

        @objc private func onTap(_ recognizer: UITapGestureRecognizer) {
            guard let view, let world, let editor else { return }
            let point = recognizer.location(in: view)
            if editor.interactionMode == .camera {
                let id = brickID(at: point)
                editor.selectedID = editor.selectedID == id ? nil : id
            } else {
                world.beginTransaction()
                applyTool(at: point, world: world, beginsStroke: true)
                world.endTransaction()
            }
        }

        @objc private func onOneFingerPan(_ recognizer: UIPanGestureRecognizer) {
            guard let view, let world, let editor, let camera else { return }
            if editor.interactionMode == .camera {
                let delta = recognizer.translation(in: view)
                recognizer.setTranslation(.zero, in: view)
                camera.pan(screenX: Double(delta.x), screenY: Double(delta.y))
                return
            }

            switch recognizer.state {
            case .began:
                world.beginTransaction()
                lastDrawCell = nil
                drawingLayerY = nil
                applyTool(at: recognizer.location(in: view), world: world, beginsStroke: true)
            case .changed:
                applyTool(at: recognizer.location(in: view), world: world, beginsStroke: false)
            case .ended:
                applyTool(at: recognizer.location(in: view), world: world, beginsStroke: false)
                world.endTransaction()
                lastDrawCell = nil
                drawingLayerY = nil
            case .cancelled, .failed:
                world.cancelTransaction()
                lastDrawCell = nil
                drawingLayerY = nil
            default:
                break
            }
        }

        private func applyTool(at point: CGPoint, world: WorldState, beginsStroke: Bool) {
            if editor?.drawingTool == .eraser {
                erase(at: point, world: world)
            } else {
                drawStroke(at: point, world: world, beginsStroke: beginsStroke)
            }
        }

        private func drawStroke(at point: CGPoint, world: WorldState, beginsStroke: Bool) {
            let step = brushStep(world: world)
            let cell: SIMD3<Int>?
            if beginsStroke {
                cell = placementCell(at: point)
            } else if let layer = drawingLayerY {
                cell = gridPosition(at: point, planeY: Float(layer) * world.cellSize)
            } else {
                cell = placementCell(at: point)
            }
            guard let cell else { return }
            let anchor = quantized(cell: cell, step: step)
            if drawingLayerY == nil { drawingLayerY = anchor.y }
            let cells = lastDrawCell.map { interpolatedCells(from: $0, to: anchor, step: step) } ?? [anchor]
            draw(cells: cells, in: world)
            lastDrawCell = anchor
        }

        private func draw(cells: [SIMD3<Int>], in world: WorldState) {
            let step = brushStep(world: world)
            for cell in cells {
                _ = world.place(Brick(
                    pos: cell,
                    size: SIMD3(repeating: step),
                    color: SIMD3(0.2, 0.55, 0.95)
                ))
            }
        }

        private func interpolatedCells(from start: SIMD3<Int>, to end: SIMD3<Int>, step: Int) -> [SIMD3<Int>] {
            let dx = (end.x - start.x) / step
            let dz = (end.z - start.z) / step
            let steps = max(abs(dx), abs(dz))
            guard steps > 0 else { return [end] }
            return (0...steps).map { index in
                let t = Double(index) / Double(steps)
                return SIMD3(
                    start.x + Int((Double(dx) * t).rounded()) * step,
                    start.y,
                    start.z + Int((Double(dz) * t).rounded()) * step
                )
            }
        }

        private func brushStep(world: WorldState) -> Int {
            let size = editor?.brushSizeMode.fixedSize
                ?? editor?.visibleGridSizeMeters
                ?? Double(world.cellSize)
            return max(1, Int((size / Double(world.cellSize)).rounded()))
        }

        private func quantized(cell: SIMD3<Int>, step: Int) -> SIMD3<Int> {
            SIMD3(
                Int(floor(Double(cell.x) / Double(step))) * step,
                Int(floor(Double(cell.y) / Double(step))) * step,
                Int(floor(Double(cell.z) / Double(step))) * step
            )
        }

        private func erase(at point: CGPoint, world: WorldState) {
            guard let cell = eraserCell(at: point) else { return }
            let step = max(1, Int(((editor?.visibleGridSizeMeters ?? Double(world.cellSize)) / Double(world.cellSize)).rounded()))
            _ = world.eraseCube(origin: quantized(cell: cell, step: step), size: step)
        }

        @objc private func onTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
            guard let view, let camera else { return }
            if recognizer.state == .began, recognizer.numberOfTouches == 2 {
                let first = recognizer.location(ofTouch: 0, in: view)
                let second = recognizer.location(ofTouch: 1, in: view)
                twoFingerMode = hypot(first.x - second.x, first.y - second.y) < 110 ? .viewTilt : .pan
            }
            let delta = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)
            switch twoFingerMode {
            case .viewTilt:
                camera.pan(screenX: Double(delta.x), screenY: 0)
                camera.orbit(horizontal: 0, vertical: Double(delta.y) * 0.005)
            case .pan:
                camera.pan(screenX: Double(delta.x), screenY: Double(delta.y))
            case nil:
                break
            }
            if recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed {
                twoFingerMode = nil
            }
        }

        @objc private func onRotation(_ recognizer: UIRotationGestureRecognizer) {
            guard recognizer.state == .changed, let camera else { return }
            camera.rotate(horizontal: Double(recognizer.rotation))
            recognizer.rotation = 0
        }

        @objc private func onTwoFingerDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let editor else { return }
            editor.interactionMode = .draw
            editor.drawingTool = editor.drawingTool == .brush ? .eraser : .brush
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

        private func placementCell(at point: CGPoint) -> SIMD3<Int>? {
            guard let view, let world else { return nil }
            for hit in view.hitTest(point) {
                if hit.node.name?.hasPrefix("brick_") == true {
                    let offset = hit.worldNormal * (world.cellSize * 0.05)
                    return worldCell(from: hit.worldCoordinates + offset)
                }
                if hit.node.name == "ground" {
                    return worldCell(from: hit.worldCoordinates)
                }
            }
            return gridPosition(at: point, planeY: 0)
        }

        private func eraserCell(at point: CGPoint) -> SIMD3<Int>? {
            guard let view, let world else { return nil }
            for hit in view.hitTest(point) where hit.node.name?.hasPrefix("brick_") == true {
                let offset = hit.worldNormal * (world.cellSize * 0.05)
                return worldCell(from: hit.worldCoordinates - offset)
            }
            return nil
        }

        private func worldCell(from scenePosition: SCNVector3) -> SIMD3<Int> {
            guard let world else { return .zero }
            let size = Double(world.cellSize)
            return SIMD3(
                Int(floor((Double(scenePosition.x) + renderedOrigin.x) / size)),
                Int(floor((Double(scenePosition.y) + renderedOrigin.y) / size)),
                Int(floor((Double(scenePosition.z) + renderedOrigin.z) / size))
            )
        }

        private func gridPosition(at point: CGPoint, planeY: Float) -> SIMD3<Int>? {
            guard let view, let world else { return nil }
            let ray = screenPointToRay(view, pt: point)
            guard let local = intersectPlaneY(ray: ray, y: planeY) else { return nil }
            return SIMD3(
                Int(floor((Double(local.x) + renderedOrigin.x) / Double(world.cellSize))),
                Int(floor((Double(local.y) + renderedOrigin.y) / Double(world.cellSize))),
                Int(floor((Double(local.z) + renderedOrigin.z) / Double(world.cellSize)))
            )
        }

        private func scnVector(_ value: SIMD3<Double>) -> SCNVector3 {
            SCNVector3(Float(value.x), Float(value.y), Float(value.z))
        }

        private func nodeName(_ id: UUID) -> String { "brick_\(id.uuidString)" }
    }
}
