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
    @Published var isBrushSizeLocked = true
    @Published var lockedBrushSizeMeters: Double = 0.1
    @Published var visibleGridSizeMeters: Double = 0.1
}

@MainActor
final class CameraState: ObservableObject {
    @Published var center = SIMD3<Double>(repeating: 0)
    @Published var radius: Double = 2.5
    @Published var theta: Double = .pi / 5
    @Published var phi: Double = .pi / 4

    func orbit(horizontal: Double, vertical: Double) {
        phi -= horizontal
        theta = min(max(0.08, theta + vertical), .pi / 2 - 0.04)
    }

    func zoom(by scale: Double) {
        radius = min(max(0.15, radius / scale), 100)
    }

    func pan(screenX: Double, screenY: Double) {
        let distanceScale = radius * 0.0015
        let right = SIMD3<Double>(sin(phi), 0, -cos(phi))
        let forward = SIMD3<Double>(-cos(phi), 0, -sin(phi))
        center += right * (-screenX * distanceScale) + forward * (-screenY * distanceScale)
    }
}
