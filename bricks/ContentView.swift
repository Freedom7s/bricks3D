//
//  ContentView.swift
//  bricks
//
//  Created by Dn.A on 5/10/2025.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var world = WorldState()

    // 新增：默认砖配置
    @State private var defaultSize = SIMD3<Int>(2,1,4)
    @State private var defaultColor = SIMD3<Float>(0.9,0.4,0.2)

    var body: some View {
        ZStack(alignment: .top) {
            BricksSceneView(world: world,
                            defaultSize: defaultSize,
                            defaultColor: defaultColor)
                .ignoresSafeArea()

            // 顶部工具条
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button("保存") { saveWorld() }
                    Button("加载") { loadWorld() }
                }
                .padding(8)
                .background(.ultraThinMaterial, in: Capsule())

                // 尺寸选择（简单示例）
                HStack(spacing: 6) {
                    Text("尺寸")
                    ForEach([
                        SIMD3<Int>(2,1,2),
                        SIMD3<Int>(2,1,4),
                        SIMD3<Int>(2,2,2),
                        SIMD3<Int>(4,2,4)
                    ], id: \.self) { s in
                        Button("\(s.x)×\(s.y)×\(s.z)") { defaultSize = s }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(s == defaultSize ? Color.blue.opacity(0.2) : Color.clear)
                            .clipShape(Capsule())
                    }
                }
                .padding(8)
                .background(.ultraThinMaterial, in: Capsule())

                // 颜色选择（3 个预设）
                HStack(spacing: 6) {
                    Text("颜色")
                    let colors: [SIMD3<Float>] = [
                        SIMD3(0.9,0.4,0.2),
                        SIMD3(0.2,0.6,0.9),
                        SIMD3(0.8,0.8,0.3)
                    ]
                    ForEach(0..<colors.count, id: \.self) { i in
                        let c = colors[i]
                        Button("") { defaultColor = c }
                            .frame(width: 24, height: 24)
                            .background(Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)))
                            .clipShape(Circle())
                            .overlay(
                                Circle().stroke(Color.white, lineWidth: (c == defaultColor) ? 3 : 1)
                            )
                    }
                }
                .padding(8)
                .background(.ultraThinMaterial, in: Capsule())

                Spacer()
            }
            .padding(.top, 20)
        }
    }

    private func docURL(_ name: String) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent(name)
    }
    private func saveWorld() {
        do { try world.save(to: docURL("world.json")) } catch { print("save error:", error) }
    }
    private func loadWorld() {
        do { try world.load(from: docURL("world.json")) } catch { print("load error:", error) }
    }
}


#Preview { ContentView() }
