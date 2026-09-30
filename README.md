# bricks3D

bricks3D is an experimental voxel modeling app for iPhone and iPad. It explores a direct way to build 3D forms by drawing on an adaptive spatial grid: zoom in for finer cells, draw directly onto existing geometry, and erase volume at the same scale shown by the grid.

The project is under active development. The interaction model, rendering architecture, and document format may change.

## Current features

- Direct voxel drawing on the ground plane and on existing blocks
- Brush and eraser tools
- Brush size that follows the visible grid or stays locked to a chosen scale
- Automatic and fixed grid scales
- Adaptive model precision when zooming in
- Undo and redo
- Local JSON save and load
- Floating world origin for stable camera movement over a large canvas
- Chunk-based surface rendering with hidden internal faces removed
- Scale indicator with real-world units

## Controls

### View mode

| Gesture | Action |
| --- | --- |
| One-finger drag | Pan the view |
| Two-finger drag with fingers close together | Orbit around the model |
| Two-finger drag with fingers farther apart | Pan the view |
| Pinch | Zoom |
| Two-finger twist | Rotate the horizontal viewing angle |

### Draw mode

| Gesture | Action |
| --- | --- |
| One-finger tap or drag | Draw or erase on the active layer |
| Two-finger double-tap | Toggle between brush and eraser |
| Two-finger gestures | Navigate without leaving draw mode |

The brush and eraser follow the current visible grid by default. Enable the size lock to keep their physical size unchanged while zooming.

## Requirements

- Xcode 26 or later
- iOS 26 SDK
- Swift 5

The project targets both iPhone and iPad. A physical device is recommended for evaluating multi-touch interaction.

## Build and run

1. Clone the repository:

   ```sh
   git clone https://github.com/Freedom7s/bricks3D.git
   cd bricks3D
   ```

2. Open `bricks.xcodeproj` in Xcode.
3. Select the `bricks` scheme.
4. Choose an iPhone, iPad, or compatible simulator.
5. Set your development team if you are deploying to a physical device.
6. Build and run.

## Architecture

The app currently uses:

- **SwiftUI** for the application interface and toolbars
- **SceneKit** for 3D rendering and hit testing
- **WorldState** for model storage, occupancy checks, persistence, and edit history
- **EditorState** for tools, grid scale, and interaction modes
- **CameraState** for orbit, pan, and zoom state
- **16 × 16 × 16 chunks** for rendering voxel surfaces with far fewer SceneKit nodes

Model data, editor state, camera state, and rendering are kept separate so the storage and renderer can evolve independently.

## Performance work

The original prototype created one SceneKit node for every drawn block. The current renderer groups voxels into chunks and emits only exposed faces, reducing node count and avoiding internal geometry.

Planned performance work includes:

- Greedy meshing within each dirty chunk
- Incremental dirty-chunk updates without scanning the entire model
- Background mesh generation with main-thread geometry swaps
- Delta-based undo and redo instead of complete world snapshots
- Frustum culling and distance-based level of detail
- Bitmask and palette-based voxel storage
- RLE compression for document persistence
- Evaluation of a sparse voxel octree for very large worlds

## Project status and known limitations

- Chunk rendering is implemented, but full greedy meshing and dynamic LOD are not yet complete.
- Very large edit histories can still consume substantial memory because undo currently stores world snapshots.
- Model files are saved locally as `world.json` in the app's Documents directory.
- The interface is currently primarily in Chinese.
- Selection highlighting is being redesigned for chunk-rendered geometry.
- SceneKit is used for the current prototype; the renderer may move to Metal as the project grows.

## Repository structure

```text
bricks/
├── bricks.xcodeproj/
└── bricks/
    ├── AppState.swift
    ├── Brick.swift
    ├── BricksSceneView.swift
    ├── ContentView.swift
    ├── SCNHelpers.swift
    └── bricksApp.swift
```

## Contributing

Issues and pull requests are welcome. When reporting interaction problems, please include:

- Device model and iOS version
- Whether the issue occurs in View or Draw mode
- The gesture being performed
- Approximate model size or drawing duration
- A screen recording when possible

