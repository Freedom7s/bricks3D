import Combine
import Foundation
import SceneKit
import simd

@MainActor
final class EditorState: ObservableObject {
    enum InteractionMode: String, CaseIterable, Identifiable {
        case camera
        case draw

        var id: Self { self }
        var title: String { self == .camera ? "查看" : "绘画" }
        var symbol: String { self == .camera ? "view.3d" : "pencil.tip" }
    }

    @Published var interactionMode: InteractionMode = .camera
    @Published var selectedID: UUID?
    @Published var defaultSize = SIMD3<Int>(2, 1, 4)
    @Published var defaultColor = SIMD3<Float>(0.9, 0.4, 0.2)
}

@MainActor
final class CameraState: ObservableObject {
    @Published var center = SCNVector3Zero
    @Published var radius: Float = 2.5
    @Published var theta: Float = .pi / 6
    @Published var phi: Float = .pi / 4

    func orbit(horizontal: Float, vertical: Float) {
        phi += horizontal
        theta = min(max(0.08, theta + vertical), .pi - 0.08)
    }

    func zoom(by scale: Float) {
        radius = min(max(0.15, radius / scale), 100)
    }

    func pan(screenX: Float, screenY: Float) {
        let distanceScale = radius * 0.0015
        let right = SCNVector3(cos(phi), 0, -sin(phi))
        let forward = SCNVector3(sin(phi), 0, cos(phi))
        center = center + right * (-screenX * distanceScale) + forward * (screenY * distanceScale)
    }
}
