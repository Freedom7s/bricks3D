//
//  Brick.swift
//  bricks
//
//  Created by Dn.A on 5/10/2025.
//


import Foundation
import simd
import Combine 

/// 以“格”为单位（整数）的砖块
struct Brick: Identifiable, Codable, Hashable {
    let id: UUID
    var pos: SIMD3<Int>      // 砖块锚点位置（格）
    var size: SIMD3<Int>     // 砖块尺寸（格）
    var color: SIMD3<Float>  // 0...1

    init(id: UUID = UUID(), pos: SIMD3<Int>, size: SIMD3<Int> = SIMD3(2,1,4), color: SIMD3<Float> = SIMD3(0.9,0.4,0.2)) {
        self.id = id
        self.pos = pos
        self.size = size
        self.color = color
    }
}

/// 世界状态：网格大小 + 砖块集合 + 占用集
final class WorldState: ObservableObject {
    @Published private(set) var bricks: [UUID: Brick] = [:]
    let cellSize: Float = 0.1  // 每格 0.1 米，随你改

    // 占用结构：被占用的格坐标集合（仅示例，先简单做）
    private var occupied: Set<SIMD3<Int>> = []

    func canPlace(_ b: Brick) -> Bool {
        for p in iterCells(of: b) where occupied.contains(p) { return false }
        return true
    }

    func place(_ b: Brick) {
        bricks[b.id] = b
        for p in iterCells(of: b) { occupied.insert(p) }
    }

    func remove(id: UUID) {
        guard let b = bricks.removeValue(forKey: id) else { return }
        for p in iterCells(of: b) { occupied.remove(p) }
    }

    func brick(atGrid grid: SIMD3<Int>) -> Brick? {
        // 简化：遍历查找（砖块数量不大时OK；后续可映射格->砖ID）
        for b in bricks.values {
            let minP = b.pos
            let maxP = b.pos &+ (b.size &- SIMD3(1,1,1))
            if grid.x >= minP.x && grid.x <= maxP.x &&
               grid.y >= minP.y && grid.y <= maxP.y &&
               grid.z >= minP.z && grid.z <= maxP.z {
                return b
            }
        }
        return nil
    }

    // 遍历砖块占用的所有格
    private func iterCells(of b: Brick) -> [SIMD3<Int>] {
        var cells: [SIMD3<Int>] = []
        for x in b.pos.x ..< b.pos.x + b.size.x {
            for y in b.pos.y ..< b.pos.y + b.size.y {
                for z in b.pos.z ..< b.pos.z + b.size.z {
                    cells.append(SIMD3(x,y,z))
                }
            }
        }
        return cells
    }

    // 简易存档
    func save(to url: URL) throws {
        let data = try JSONEncoder().encode(Array(bricks.values))
        try data.write(to: url)
    }
    func load(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let arr = try JSONDecoder().decode([Brick].self, from: data)
        bricks.removeAll(); occupied.removeAll()
        for b in arr { place(b) }
    }
}
