import SwiftUI
import SceneKit
import UIKit

struct BricksSceneView: UIViewRepresentable {
    @ObservedObject var world: WorldState
    var defaultSize: SIMD3<Int> = SIMD3(2,1,4)
    var defaultColor: SIMD3<Float> = SIMD3(0.9,0.4,0.2)

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = SCNScene()
        v.rendersContinuously = true
        v.antialiasingMode = .multisampling4X
        v.autoenablesDefaultLighting = false
        v.allowsCameraControl = false

        // 手势
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.onTap(_:)))
        v.addGestureRecognizer(tap)

        let long = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.onLongPress(_:)))
        long.minimumPressDuration = 0.35
        v.addGestureRecognizer(long)

        // 单指编辑
        let pan1 = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.onPanOneFinger(_:)))
        pan1.minimumNumberOfTouches = 1
        pan1.maximumNumberOfTouches = 1
        v.addGestureRecognizer(pan1)

        // 双指相机旋转
        let pan2 = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.onPanTwoFingers(_:)))
        pan2.minimumNumberOfTouches = 2
        v.addGestureRecognizer(pan2)

        // 捏合缩放
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.onPinch(_:)))
        v.addGestureRecognizer(pinch)

        // 注入
        context.coordinator.view = v
        context.coordinator.world = world
        context.coordinator.defaultSize = defaultSize
        context.coordinator.defaultColor = defaultColor

        context.coordinator.setupCameraAndLights()
        context.coordinator.buildGroundGrid()
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.defaultSize = defaultSize
        context.coordinator.defaultColor = defaultColor
        context.coordinator.refreshBricks()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator
    final class Coordinator: NSObject {
        weak var view: SCNView?
        weak var world: WorldState?

        // 从外层传入
        var defaultSize: SIMD3<Int> = SIMD3(2,1,4)
        var defaultColor: SIMD3<Float> = SIMD3(0.9,0.4,0.2)

        // 选中状态
        var selectedID: UUID?
        enum EditMode { case none, moving }
        var mode: EditMode = .none

        // 轨道相机
        var orbitCenter = SCNVector3(0,0,0)
        var orbitRadius: Float = 2.5
        var orbitTheta: Float = Float.pi/6
        var orbitPhi:   Float = Float.pi/4
        private var lastPanPoint: CGPoint?
        private let groundY: Float = 0

        func setupCameraAndLights() {
            guard let scene = view?.scene else { return }
            let cam = SCNNode()
            cam.camera = SCNCamera()
            cam.camera?.zNear = 0.01
            cam.camera?.zFar  = 200
            scene.rootNode.addChildNode(cam)

            let amb = SCNNode()
            amb.light = SCNLight()
            amb.light?.type = .ambient
            amb.light?.intensity = 200
            scene.rootNode.addChildNode(amb)

            let dir = SCNNode()
            dir.light = SCNLight()
            dir.light?.type = .directional
            dir.eulerAngles = SCNVector3(-Float.pi/4, Float.pi/4, 0)
            dir.light?.intensity = 900
            scene.rootNode.addChildNode(dir)

            updateCameraPosition()
        }

        func updateCameraPosition() {
            guard let cam = view?.scene?.rootNode.childNodes.first(where: { $0.camera != nil }) else { return }
            let x = orbitCenter.x + orbitRadius * sin(orbitTheta) * cos(orbitPhi)
            let y = orbitCenter.y + orbitRadius * cos(orbitTheta)
            let z = orbitCenter.z + orbitRadius * sin(orbitTheta) * sin(orbitPhi)
            cam.position = SCNVector3(x, y, z)
            cam.look(at: orbitCenter)
        }

        func buildGroundGrid() {
            guard let scene = view?.scene else { return }
            let plane = SCNPlane(width: 10, height: 10)
            plane.firstMaterial = gridMaterial()
            let n = SCNNode(geometry: plane)
            n.eulerAngles.x = -Float.pi/2
            n.position = SCNVector3(0, groundY, 0)
            n.name = "ground"
            scene.rootNode.addChildNode(n)
        }

        private func gridMaterial() -> SCNMaterial {
            let m = SCNMaterial()
            m.diffuse.contents = gridImage(size: 512, spacing: 16)
            m.isDoubleSided = true
            m.lightingModel = .lambert
            return m
        }

        private func gridImage(size: Int, spacing: Int) -> UIImage {
            UIGraphicsBeginImageContext(CGSize(width: size, height: size))
            let ctx = UIGraphicsGetCurrentContext()!
            UIColor(white: 0.95, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            UIColor(white: 0.8, alpha: 1).setStroke()
            ctx.setLineWidth(1)
            for i in stride(from: 0, to: size, by: spacing) {
                ctx.move(to: CGPoint(x: i, y: 0)); ctx.addLine(to: CGPoint(x: i, y: size))
                ctx.move(to: CGPoint(x: 0, y: i)); ctx.addLine(to: CGPoint(x: size, y: i))
            }
            ctx.strokePath()
            let img = UIGraphicsGetImageFromCurrentImageContext()!
            UIGraphicsEndImageContext()
            return img
        }

        func refreshBricks() {
            guard let scene = view?.scene, let world = world else { return }
            scene.rootNode.childNodes
                .filter { $0.name?.hasPrefix("brick_") == true }
                .forEach { $0.removeFromParentNode() }
            for b in world.bricks.values {
                scene.rootNode.addChildNode(makeNode(for: b, cell: world.cellSize))
            }
            highlightSelection()
        }

        func highlightSelection() {
            guard let scene = view?.scene else { return }
            scene.rootNode.childNodes
                .filter { $0.name?.hasPrefix("brick_") == true }
                .forEach { node in
                    let isSel = node.name?.hasSuffix(selectedID?.uuidString ?? "___") ?? false
                    node.geometry?.firstMaterial?.emission.contents = isSel ? UIColor.white.withAlphaComponent(0.25) : UIColor.clear
                }
        }

        func makeNode(for b: Brick, cell: Float) -> SCNNode {
            let w = CGFloat(Float(b.size.x) * cell)
            let h = CGFloat(Float(b.size.y) * cell)
            let l = CGFloat(Float(b.size.z) * cell)
            let box = SCNBox(width: w, height: h, length: l, chamferRadius: 0)

            let mat = SCNMaterial()
            mat.diffuse.contents = scnColor(b.color)   // 来自 SCNHelpers.swift
            mat.lightingModel = .physicallyBased
            box.materials = [mat]

            let n = SCNNode(geometry: box)
            n.position = SCNVector3(
                Float(b.pos.x) * cell,
                Float(b.pos.y) * cell + Float(h)/2.0,
                Float(b.pos.z) * cell
            )
            n.name = "brick_\(b.id.uuidString)"
            return n
        }

        // MARK: - Gestures

        /// 点选：点到砖则选/反选；点空白则取消选中并在地面放置一块
        @objc func onTap(_ gr: UITapGestureRecognizer) {
            guard let v = view, let world = world else { return }
            let p = gr.location(in: v)

            if let hit = v.hitTest(p, options: [.firstFoundOnly: true]).first,
               let name = hit.node.name, name.hasPrefix("brick_"),
               let idStr = name.split(separator: "_").last,
               let uuid = UUID(uuidString: String(idStr)) {

                selectedID = (selectedID == uuid) ? nil : uuid
                highlightSelection()
                return
            }

            // 点空白：取消选中 + 在地面放置
            selectedID = nil
            highlightSelection()

            let ray = screenPointToRay(v, pt: p)
            guard let worldPos = intersectPlaneY(ray: ray, y: groundY) else { return }
            let grid = snapToGrid(worldPos, cell: world.cellSize)

            let newBrick = Brick(pos: SIMD3(grid.x, 0, grid.z),
                                 size: defaultSize,
                                 color: defaultColor)
            if world.canPlace(newBrick) {
                world.place(newBrick)
                v.scene?.rootNode.addChildNode(makeNode(for: newBrick, cell: world.cellSize))
            }
        }

        /// 长按：演示用，放一个 2x2x2 的蓝砖在 y=1
        @objc func onLongPress(_ gr: UILongPressGestureRecognizer) {
            guard gr.state == .began, let v = view, let world = world else { return }
            let p = gr.location(in: v)
            let ray = screenPointToRay(v, pt: p)
            guard let worldPos = intersectPlaneY(ray: ray, y: groundY) else { return }
            let grid = snapToGrid(worldPos, cell: world.cellSize)
            let b = Brick(pos: SIMD3(grid.x, 1, grid.z),
                          size: SIMD3(2,2,2),
                          color: SIMD3(0.2,0.6,0.9))
            if world.canPlace(b) {
                world.place(b)
                v.scene?.rootNode.addChildNode(makeNode(for: b, cell: world.cellSize))
            }
        }

        // 单指：移动/短划旋转（需已选中）
        var swipeAccum: CGFloat = 0
        @objc func onPanOneFinger(_ gr: UIPanGestureRecognizer) {
            guard let v = view, let world = world, let sel = selectedID, var b = world.bricks[sel] else { return }
            let p = gr.location(in: v)

            switch gr.state {
            case .began:
                mode = .moving

            case .changed:
                // 在当前砖块的 Y 层平移（XZ 吸附）
                let ray = screenPointToRay(v, pt: p)
                let planeY = Float(b.pos.y) * world.cellSize
                guard let wpos = intersectPlaneY(ray: ray, y: planeY) else { return }
                let g = snapToGrid(wpos, cell: world.cellSize)

                var newB = b
                newB.pos.x = g.x
                newB.pos.z = g.z

                if world.canPlace(newB) {
                    world.remove(id: sel)
                    world.place(newB)
                    selectedID = newB.id
                    refreshBricks()
                }

                // 横向短划触发 90° 旋转（Y 轴）
                if abs(swipeAccum) > 60, let cur = selectedID, var rb = world.bricks[cur] {
                    swipeAccum = 0

                    // ✨ 用临时变量交换，避免重叠 inout
                    let t = rb.size.x
                    rb.size.x = rb.size.z
                    rb.size.z = t

                    // 旋转判定时先把旧砖移出占用再检查，否则可能误判冲突
                    world.remove(id: cur)
                    if world.canPlace(rb) {
                        world.place(rb)
                        selectedID = rb.id
                    } else {
                        // 放不下就回退到原砖
                        world.place(b)
                    }
                    refreshBricks()
                }


            default:
                swipeAccum = 0
                mode = .none
                highlightSelection()
            }
        }

        // 双指：相机旋转
        @objc func onPanTwoFingers(_ gr: UIPanGestureRecognizer) {
            guard let v = view else { return }
            let delta = gr.translation(in: v)
            gr.setTranslation(.zero, in: v)

            orbitPhi   += Float(delta.x) * 0.005
            orbitTheta  = min(max(0.1, orbitTheta - Float(delta.y) * 0.005), Float.pi - 0.1)
            updateCameraPosition()
        }

        // 捏合：相机缩放
        @objc func onPinch(_ gr: UIPinchGestureRecognizer) {
            if gr.state == .changed {
                orbitRadius = min(max(0.5, orbitRadius / Float(gr.scale)), 20)
                updateCameraPosition()
                gr.scale = 1
            }
        }
    }
}
