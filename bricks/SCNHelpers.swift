import SceneKit
import UIKit   // iOS 平台用 UIKit；如果是 macOS，改成 AppKit 并把 UIColor 换成 NSColor

// MARK: - SCNVector3 运算扩展
extension SCNVector3 {
    static func - (lhs: SCNVector3, rhs: SCNVector3) -> SCNVector3 {
        SCNVector3(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
    }

    static func + (lhs: SCNVector3, rhs: SCNVector3) -> SCNVector3 {
        SCNVector3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }

    static func * (lhs: SCNVector3, rhs: Float) -> SCNVector3 {
        SCNVector3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
    }

    func length() -> Float {
        sqrt(x * x + y * y + z * z)
    }

    func normalized() -> SCNVector3 {
        let l = max(1e-6, length())
        return SCNVector3(x / l, y / l, z / l)
    }
}

// MARK: - 射线投射与网格吸附

/// 屏幕点 → 世界射线（near / far 反投影）
func screenPointToRay(_ view: SCNView, pt: CGPoint) -> (o: SCNVector3, d: SCNVector3) {
    let near = view.unprojectPoint(SCNVector3(Float(pt.x), Float(pt.y), 0))
    let far  = view.unprojectPoint(SCNVector3(Float(pt.x), Float(pt.y), 1))
    return (near, (far - near).normalized())
}

/// 与 Y 平面求交
func intersectPlaneY(ray: (o: SCNVector3, d: SCNVector3), y: Float) -> SCNVector3? {
    let denom = ray.d.y
    guard abs(denom) > 1e-6 else { return nil }
    let t = (y - ray.o.y) / denom
    return t > 0 ? ray.o + ray.d * t : nil
}

/// 吸附到整数网格
func snapToGrid(_ world: SCNVector3, cell: Float) -> SIMD3<Int> {
    SIMD3(
        Int(round(world.x / cell)),
        Int(round(world.y / cell)),
        Int(round(world.z / cell))
    )
}

// MARK: - 颜色转换
func scnColor(_ c: SIMD3<Float>) -> UIColor {
    UIColor(red: CGFloat(c.x),
            green: CGFloat(c.y),
            blue: CGFloat(c.z),
            alpha: 1.0)
}
