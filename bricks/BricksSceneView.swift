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
        private typealias ChunkKey = SIMD3<Int>
        private let chunkSize = 16
        private var renderedChunks: [ChunkKey: [SIMD3<Int>: SIMD3<Float>]] = [:]
        private var renderedModelRevision = -1
        private var renderedCellSize: Float?
        private var renderedGridSpacing: Double?
        private var renderedBrickGridStep: Int?
        private var renderedOrigin = SIMD3<Double>(repeating: 0)
        private var previousOrigin = SIMD3<Double>(repeating: .nan)
        private var lastDrawCell: SIMD3<Int>?
        private var lastDrawScreenPoint: CGPoint?
        private var drawingLayerY: Int?
        private enum TwoFingerMode { case viewTilt, pan }
        private var twoFingerMode: TwoFingerMode?
        private var rotationAccumulator: CGFloat = 0
        private var isTwisting = false
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
            updateChunkNodes(world: world, cellSize: world.cellSize)
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
            if let fixedSize = editor?.gridScaleMode.fixedSize {
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

        private func updateChunkNodes(world: WorldState, cellSize: Float) {
            guard let scene = view?.scene else { return }
            let originChanged = previousOrigin != renderedOrigin
            let cellSizeChanged = renderedCellSize != cellSize
            guard renderedModelRevision != world.modelRevision || originChanged || cellSizeChanged else {
                updateChunkMaterialScale(cellSize: cellSize)
                return
            }

            let voxels = world.voxelSnapshot()
            var chunks: [ChunkKey: [SIMD3<Int>: SIMD3<Float>]] = [:]
            for (cell, color) in voxels {
                chunks[chunkKey(for: cell), default: [:]][cell] = color
            }
            let removed = Set(renderedChunks.keys).subtracting(chunks.keys)
            for key in removed {
                scene.rootNode.childNode(withName: chunkNodeName(key), recursively: false)?.removeFromParentNode()
            }
            for (key, cells) in chunks where originChanged || cellSizeChanged || renderedChunks[key] != cells {
                scene.rootNode.childNode(withName: chunkNodeName(key), recursively: false)?.removeFromParentNode()
                if let node = makeChunkNode(key: key, cells: cells, allVoxels: voxels, cellSize: cellSize) {
                    scene.rootNode.addChildNode(node)
                }
            }
            renderedChunks = chunks
            renderedModelRevision = world.modelRevision
            renderedCellSize = cellSize
            previousOrigin = renderedOrigin
            updateChunkMaterialScale(cellSize: cellSize)
        }

        private func makeChunkNode(
            key: ChunkKey,
            cells: [SIMD3<Int>: SIMD3<Float>],
            allVoxels: [SIMD3<Int>: SIMD3<Float>],
            cellSize: Float
        ) -> SCNNode? {
            let directions: [(SIMD3<Int>, SIMD3<Float>, [SIMD3<Float>])] = [
                (SIMD3(1, 0, 0), SIMD3(1, 0, 0), [SIMD3(1,0,0), SIMD3(1,1,0), SIMD3(1,1,1), SIMD3(1,0,1)]),
                (SIMD3(-1, 0, 0), SIMD3(-1, 0, 0), [SIMD3(0,0,1), SIMD3(0,1,1), SIMD3(0,1,0), SIMD3(0,0,0)]),
                (SIMD3(0, 1, 0), SIMD3(0, 1, 0), [SIMD3(0,1,1), SIMD3(1,1,1), SIMD3(1,1,0), SIMD3(0,1,0)]),
                (SIMD3(0, -1, 0), SIMD3(0, -1, 0), [SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(1,0,1), SIMD3(0,0,1)]),
                (SIMD3(0, 0, 1), SIMD3(0, 0, 1), [SIMD3(1,0,1), SIMD3(1,1,1), SIMD3(0,1,1), SIMD3(0,0,1)]),
                (SIMD3(0, 0, -1), SIMD3(0, 0, -1), [SIMD3(0,0,0), SIMD3(0,1,0), SIMD3(1,1,0), SIMD3(1,0,0)])
            ]
            var vertices: [SCNVector3] = []
            var normals: [SCNVector3] = []
            var texcoords: [CGPoint] = []
            var indices: [UInt32] = []
            for cell in cells.keys {
                for (neighbor, normal, corners) in directions where allVoxels[cell &+ neighbor] == nil {
                    let base = UInt32(vertices.count)
                    for corner in corners {
                        let p = SIMD3<Float>(Float(cell.x), Float(cell.y), Float(cell.z)) + corner
                        vertices.append(SCNVector3(p.x * cellSize, p.y * cellSize, p.z * cellSize))
                        normals.append(SCNVector3(normal.x, normal.y, normal.z))
                        if normal.x != 0 {
                            texcoords.append(CGPoint(x: CGFloat(p.z), y: CGFloat(p.y)))
                        } else if normal.y != 0 {
                            texcoords.append(CGPoint(x: CGFloat(p.x), y: CGFloat(p.z)))
                        } else {
                            texcoords.append(CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))
                        }
                    }
                    indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
                }
            }
            guard !indices.isEmpty else { return nil }
            let geometry = SCNGeometry(
                sources: [
                    SCNGeometrySource(vertices: vertices),
                    SCNGeometrySource(normals: normals),
                    SCNGeometrySource(textureCoordinates: texcoords)
                ],
                elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
            )
            geometry.materials = [chunkMaterial()]
            let node = SCNNode(geometry: geometry)
            node.name = chunkNodeName(key)
            node.position = scnVector(-renderedOrigin)
            return node
        }

        private func chunkMaterial() -> SCNMaterial {
            let material = SCNMaterial()
            material.diffuse.contents = brickGridImage
            material.diffuse.wrapS = .repeat
            material.diffuse.wrapT = .repeat
            let step = max(1, renderedBrickGridStep ?? 1)
            material.diffuse.contentsTransform = SCNMatrix4MakeScale(1 / Float(step), 1 / Float(step), 1)
            material.lightingModel = .lambert
            return material
        }

        private func updateChunkMaterialScale(cellSize: Float) {
            guard let scene = view?.scene else { return }
            let step = max(1, Int(((editor?.visibleGridSizeMeters ?? Double(cellSize)) / Double(cellSize)).rounded()))
            guard renderedBrickGridStep != step else { return }
            renderedBrickGridStep = step
            for key in renderedChunks.keys {
                scene.rootNode.childNode(withName: chunkNodeName(key), recursively: false)?
                    .geometry?.firstMaterial?.diffuse.contentsTransform = SCNMatrix4MakeScale(1 / Float(step), 1 / Float(step), 1)
            }
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
            // Chunk geometry contains many model elements, so per-brick highlighting
            // will move to a lightweight overlay instead of duplicating chunk meshes.
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
                lastDrawScreenPoint = nil
                drawingLayerY = nil
                applyTool(at: recognizer.location(in: view), world: world, beginsStroke: true)
            case .changed:
                applyTool(at: recognizer.location(in: view), world: world, beginsStroke: false)
            case .ended:
                applyTool(at: recognizer.location(in: view), world: world, beginsStroke: false)
                world.endTransaction()
                lastDrawCell = nil
                lastDrawScreenPoint = nil
                drawingLayerY = nil
            case .cancelled, .failed:
                world.cancelTransaction()
                lastDrawCell = nil
                lastDrawScreenPoint = nil
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
            if let previous = lastDrawCell {
                let jump = max(abs(anchor.x - previous.x), abs(anchor.z - previous.z)) / step
                if jump > 12 {
                    lastDrawScreenPoint = point
                    return
                }
            }
            let cells = lastDrawCell.map { interpolatedCells(from: $0, to: anchor, step: step) } ?? [anchor]
            draw(cells: cells, in: world)
            lastDrawCell = anchor
            lastDrawScreenPoint = point
        }

        private func draw(cells: [SIMD3<Int>], in world: WorldState) {
            let step = brushStep(world: world)
            _ = world.place(cells.map { cell in
                Brick(
                    pos: cell,
                    size: SIMD3(repeating: step),
                    color: SIMD3(0.2, 0.55, 0.95)
                )
            })
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
            let size = editor?.isBrushSizeLocked == true
                ? editor?.lockedBrushSizeMeters ?? Double(world.cellSize)
                : editor?.visibleGridSizeMeters ?? Double(world.cellSize)
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
            let step = brushStep(world: world)
            _ = world.eraseCube(origin: quantized(cell: cell, step: step), size: step)
        }

        @objc private func onTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
            guard let view, let camera else { return }
            if recognizer.state == .began, recognizer.numberOfTouches == 2 {
                let first = recognizer.location(ofTouch: 0, in: view)
                let second = recognizer.location(ofTouch: 1, in: view)
                twoFingerMode = hypot(first.x - second.x, first.y - second.y) < 110 ? .viewTilt : .pan
                isTwisting = false
                rotationAccumulator = 0
            }
            let delta = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)
            guard !isTwisting else { return }
            switch twoFingerMode {
            case .viewTilt:
                camera.orbit(
                    horizontal: Double(delta.x) * 0.005,
                    vertical: Double(delta.y) * 0.005
                )
            case .pan:
                camera.pan(screenX: Double(delta.x), screenY: Double(delta.y))
            case nil:
                break
            }
            if recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed {
                twoFingerMode = nil
                isTwisting = false
                rotationAccumulator = 0
            }
        }

        @objc private func onRotation(_ recognizer: UIRotationGestureRecognizer) {
            guard let camera else { return }
            if recognizer.state == .began {
                rotationAccumulator = 0
                isTwisting = false
            }
            guard recognizer.state == .changed else {
                if recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed {
                    rotationAccumulator = 0
                    isTwisting = false
                }
                return
            }
            rotationAccumulator += recognizer.rotation
            if abs(rotationAccumulator) >= 0.08 { isTwisting = true }
            if isTwisting { camera.rotate(horizontal: Double(recognizer.rotation)) }
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
            guard let view, let world else { return nil }
            for hit in view.hitTest(point) {
                guard isModelNode(hit.node) else { continue }
                let offset = hit.worldNormal * -(world.cellSize * 0.05)
                return world.brick(atGrid: worldCell(from: hit.worldCoordinates + offset))?.id
            }
            return nil
        }

        private func placementCell(at point: CGPoint) -> SIMD3<Int>? {
            guard let view, let world else { return nil }
            for hit in view.hitTest(point) {
                if isModelNode(hit.node) {
                    let offset = hit.worldNormal * (world.cellSize * 0.05)
                    return worldCell(from: hit.worldCoordinates + offset)
                }
                if hit.node.name == "ground" {
                    return gridPosition(at: point, planeY: 0)
                }
            }
            return gridPosition(at: point, planeY: 0)
        }

        private func eraserCell(at point: CGPoint) -> SIMD3<Int>? {
            guard let view, let world else { return nil }
            for hit in view.hitTest(point) where isModelNode(hit.node) {
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
                Int(round((Double(planeY) + renderedOrigin.y) / Double(world.cellSize))),
                Int(floor((Double(local.z) + renderedOrigin.z) / Double(world.cellSize)))
            )
        }

        private func scnVector(_ value: SIMD3<Double>) -> SCNVector3 {
            SCNVector3(Float(value.x), Float(value.y), Float(value.z))
        }

        private func isModelNode(_ node: SCNNode) -> Bool {
            node.name?.hasPrefix("chunk_") == true
        }

        private func chunkKey(for cell: SIMD3<Int>) -> ChunkKey {
            SIMD3(floorDiv(cell.x, chunkSize), floorDiv(cell.y, chunkSize), floorDiv(cell.z, chunkSize))
        }

        private func floorDiv(_ value: Int, _ divisor: Int) -> Int {
            let quotient = value / divisor
            let remainder = value % divisor
            return remainder < 0 ? quotient - 1 : quotient
        }

        private func chunkNodeName(_ key: ChunkKey) -> String {
            "chunk_\(key.x)_\(key.y)_\(key.z)"
        }
    }
}
