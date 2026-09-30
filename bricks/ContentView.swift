import SwiftUI

struct ContentView: View {
    @StateObject private var world = WorldState()
    @StateObject private var editor = EditorState()
    @StateObject private var camera = CameraState()
    @State private var message: String?

    private let sizes = [
        SIMD3<Int>(1, 1, 1),
        SIMD3<Int>(2, 1, 2),
        SIMD3<Int>(2, 1, 4),
        SIMD3<Int>(2, 2, 2)
    ]
    private let colors = [
        SIMD3<Float>(0.9, 0.4, 0.2),
        SIMD3<Float>(0.2, 0.6, 0.9),
        SIMD3<Float>(0.8, 0.8, 0.3)
    ]

    var body: some View {
        ZStack(alignment: .top) {
            BricksSceneView(world: world, editor: editor, camera: camera)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                primaryToolbar
                if editor.interactionMode == .draw { drawingToolbar }
                if let message {
                    Text(message)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.opacity)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
        .onChange(of: world.bricks) { _, bricks in
            if let selectedID = editor.selectedID, bricks[selectedID] == nil {
                editor.selectedID = nil
            }
        }
    }

    private var primaryToolbar: some View {
        HStack(spacing: 8) {
            Picker("交互模式", selection: $editor.interactionMode) {
                ForEach(EditorState.InteractionMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 190)

            Divider().frame(height: 24)

            Button { world.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!world.canUndo)
            .accessibilityLabel("撤销")

            Button { world.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!world.canRedo)
            .accessibilityLabel("重做")

            Menu {
                ForEach(WorldState.supportedCellSizes, id: \.self) { size in
                    Button {
                        world.setCellSize(size)
                    } label: {
                        if abs(world.cellSize - size) < 0.000_001 {
                            Label(gridLabel(size), systemImage: "checkmark")
                        } else {
                            Text(gridLabel(size))
                        }
                    }
                }
            } label: {
                Label(gridLabel(world.cellSize), systemImage: "grid")
            }

            Menu {
                Button("保存") { saveWorld() }
                Button("加载") { loadWorld() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("文件操作")
        }
        .buttonStyle(.bordered)
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var drawingToolbar: some View {
        HStack(spacing: 6) {
            Text("尺寸").font(.caption)
            ForEach(sizes, id: \.self) { size in
                Button("\(size.x)×\(size.y)×\(size.z)") { editor.defaultSize = size }
                    .buttonStyle(.bordered)
                    .tint(size == editor.defaultSize ? .blue : .gray)
            }

            Divider().frame(height: 24)

            ForEach(colors, id: \.self) { color in
                Button { editor.defaultColor = color } label: {
                    Circle()
                        .fill(Color(red: Double(color.x), green: Double(color.y), blue: Double(color.z)))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(.white, lineWidth: color == editor.defaultColor ? 3 : 1))
                }
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func gridLabel(_ size: Float) -> String {
        size >= 0.1 ? String(format: "%.0f cm", size * 100) : String(format: "%.1f cm", size * 100)
    }

    private func documentURL(_ name: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
    }

    private func saveWorld() {
        do {
            try world.save(to: documentURL("world.json"))
            showMessage("已保存模型和网格精度")
        } catch {
            showMessage("保存失败：\(error.localizedDescription)")
        }
    }

    private func loadWorld() {
        do {
            try world.load(from: documentURL("world.json"))
            showMessage("已加载模型和网格精度")
        } catch {
            showMessage("加载失败：\(error.localizedDescription)")
        }
    }

    private func showMessage(_ text: String) {
        withAnimation { message = text }
        Task {
            try? await Task.sleep(for: .seconds(2))
            if message == text { withAnimation { message = nil } }
        }
    }
}

#Preview { ContentView() }
