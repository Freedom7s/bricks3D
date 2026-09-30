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
}

@MainActor
final class CameraState: ObservableObject {
    @Published var center = SIMD3<Double>(repeating: 0)
    @Published var radius: Double = 2.5
    @Published var rotation = simd_quatd(angle: .pi / 4, axis: SIMD3(0, 1, 0))
        * simd_quatd(angle: -.pi / 3, axis: SIMD3(1, 0, 0))

    func rotateArcball(from start: SIMD3<Double>, to end: SIMD3<Double>) {
        let dotProduct = min(1, max(-1, simd_dot(start, end)))
        let axis = simd_cross(start, end)
        guard simd_length_squared(axis) > 0.000_000_1 else { return }
        let localRotation = simd_quatd(real: 1 + dotProduct, imag: axis).normalized
        rotation = (rotation * localRotation).normalized
    }

    func zoom(by scale: Double) {
        radius = min(max(0.15, radius / scale), 100)
    }

    func pan(screenX: Double, screenY: Double) {
        let distanceScale = radius * 0.0015
        let right = rotation.act(SIMD3<Double>(1, 0, 0))
        let up = rotation.act(SIMD3<Double>(0, 1, 0))
        center += right * (-screenX * distanceScale) + up * (screenY * distanceScale)
    }
}
