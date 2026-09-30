import SwiftUI

struct ContentView: View {
    @StateObject private var world = WorldState()
    @StateObject private var editor = EditorState()
    @StateObject private var camera = CameraState()
    @State private var message: String?

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
        .overlay(alignment: .bottomLeading) {
            scaleIndicator
                .padding(.leading, 18)
                .padding(.bottom, 22)
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

            Label(gridLabel(Float(editor.visibleGridSizeMeters)), systemImage: "grid")
                .font(.caption)

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
        HStack(spacing: 10) {
            Label("单指滑动绘制", systemImage: "hand.draw")
            Button {
                editor.isBrushSizeLocked.toggle()
                if editor.isBrushSizeLocked {
                    editor.lockedBrushSizeMeters = editor.visibleGridSizeMeters
                }
            } label: {
                Label(
                    editor.isBrushSizeLocked ? "大小锁定" : "跟随网格",
                    systemImage: editor.isBrushSizeLocked ? "lock.fill" : "lock.open"
                )
            }
            .buttonStyle(.bordered)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var scaleIndicator: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(gridLabel(Float(editor.visibleGridSizeMeters)))
                .font(.caption2.monospacedDigit())
            HStack(spacing: 0) {
                Rectangle().frame(width: 2, height: 8)
                Rectangle().frame(width: 72, height: 2)
                Rectangle().frame(width: 2, height: 8)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .allowsHitTesting(false)
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
