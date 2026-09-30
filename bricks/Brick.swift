import Combine
import Foundation
import simd

struct Brick: Identifiable, Codable, Hashable {
    let id: UUID
    var pos: SIMD3<Int>
    var size: SIMD3<Int>
    var color: SIMD3<Float>

    init(id: UUID = UUID(), pos: SIMD3<Int>, size: SIMD3<Int> = SIMD3(2, 1, 4), color: SIMD3<Float> = SIMD3(0.9, 0.4, 0.2)) {
        self.id = id
        self.pos = pos
        self.size = size
        self.color = color
    }
}

struct WorldDocument: Codable, Equatable {
    static let currentVersion = 1

    var version = currentVersion
    var cellSize: Float
    var bricks: [Brick]
}

enum WorldStateError: LocalizedError {
    case invalidDocument

    var errorDescription: String? {
        "模型文件包含无效尺寸、地下方块或重叠方块"
    }
}

@MainActor
final class WorldState: ObservableObject {
    static let supportedCellSizes: [Float] = [0.2, 0.1, 0.05, 0.025, 0.0125]

    @Published private(set) var bricks: [UUID: Brick] = [:]
    @Published private(set) var cellSize: Float = 0.1
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var occupied: [SIMD3<Int>: UUID] = [:]
    private var undoStack: [WorldDocument] = []
    private var redoStack: [WorldDocument] = []
    private var transactionStart: WorldDocument?
    private let historyLimit = 100

    func canPlace(_ brick: Brick, excluding ignoredID: UUID? = nil) -> Bool {
        guard brick.pos.y >= 0,
              brick.size.x > 0, brick.size.y > 0, brick.size.z > 0 else { return false }

        return cells(of: brick).allSatisfy { cell in
            guard let owner = occupied[cell] else { return true }
            return owner == ignoredID
        }
    }

    @discardableResult
    func place(_ brick: Brick) -> Bool {
        guard bricks[brick.id] == nil, canPlace(brick) else { return false }
        recordUndoPoint()
        insert(brick)
        publishModelChange()
        return true
    }

    @discardableResult
    func move(id: UUID, to position: SIMD3<Int>) -> Bool {
        guard var brick = bricks[id] else { return false }
        guard brick.pos != position else { return true }
        brick.pos = position
        guard canPlace(brick, excluding: id) else { return false }

        recordUndoPoint()
        removeFromOccupancy(id: id)
        bricks[id] = brick
        addToOccupancy(brick)
        publishModelChange()
        return true
    }

    @discardableResult
    func rotateAroundY(id: UUID) -> Bool {
        guard var brick = bricks[id] else { return false }
        (brick.size.x, brick.size.z) = (brick.size.z, brick.size.x)
        guard canPlace(brick, excluding: id) else { return false }

        recordUndoPoint()
        removeFromOccupancy(id: id)
        bricks[id] = brick
        addToOccupancy(brick)
        publishModelChange()
        return true
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        guard bricks[id] != nil else { return false }
        recordUndoPoint()
        removeFromOccupancy(id: id)
        bricks.removeValue(forKey: id)
        publishModelChange()
        return true
    }

    @discardableResult
    func eraseCube(origin: SIMD3<Int>, size: Int) -> Bool {
        guard size > 0 else { return false }
        let eraseCells = Set(
            (origin.x ..< origin.x + size).flatMap { x in
                (origin.y ..< origin.y + size).flatMap { y in
                    (origin.z ..< origin.z + size).map { z in SIMD3(x, y, z) }
                }
            }
        )
        let affectedIDs = Set(eraseCells.compactMap { occupied[$0] })
        guard !affectedIDs.isEmpty else { return false }

        recordUndoPoint()
        var replacements: [Brick] = []
        for id in affectedIDs {
            guard let brick = bricks[id] else { continue }
            removeFromOccupancy(id: id)
            bricks.removeValue(forKey: id)
            for cell in cells(of: brick) where !eraseCells.contains(cell) {
                replacements.append(Brick(pos: cell, size: SIMD3(repeating: 1), color: brick.color))
            }
        }
        for brick in replacements { insert(brick) }
        publishModelChange()
        return true
    }

    func brick(atGrid grid: SIMD3<Int>) -> Brick? {
        guard let id = occupied[grid] else { return nil }
        return bricks[id]
    }

    func beginTransaction() {
        guard transactionStart == nil else { return }
        transactionStart = snapshot
    }

    func endTransaction() {
        guard let start = transactionStart else { return }
        transactionStart = nil
        guard start != snapshot else { return }
        pushUndo(start)
    }

    func cancelTransaction() {
        guard let start = transactionStart else { return }
        transactionStart = nil
        restore(start)
    }

    func undo() {
        endTransaction()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        restore(previous)
        updateHistoryAvailability()
    }

    func redo() {
        endTransaction()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        restore(next)
        updateHistoryAvailability()
    }

    @discardableResult
    func setCellSize(_ newSize: Float, recordsHistory: Bool = true) -> Bool {
        guard newSize > 0, abs(newSize - cellSize) > 0.000_001 else { return false }
        let previous = snapshot
        let scale = cellSize / newSize
        let resampled = bricks.values.map { brick -> Brick in
            var copy = brick
            copy.pos = SIMD3(
                Int((Float(brick.pos.x) * scale).rounded()),
                Int((Float(brick.pos.y) * scale).rounded()),
                Int((Float(brick.pos.z) * scale).rounded())
            )
            copy.size = SIMD3(
                max(1, Int((Float(brick.size.x) * scale).rounded())),
                max(1, Int((Float(brick.size.y) * scale).rounded())),
                max(1, Int((Float(brick.size.z) * scale).rounded()))
            )
            return copy
        }

        var proposedOccupancy: [SIMD3<Int>: UUID] = [:]
        for brick in resampled {
            for cell in cells(of: brick) {
                guard proposedOccupancy[cell] == nil else { return false }
                proposedOccupancy[cell] = brick.id
            }
        }

        cellSize = newSize
        bricks = Dictionary(uniqueKeysWithValues: resampled.map { ($0.id, $0) })
        occupied = proposedOccupancy
        if recordsHistory { pushUndo(previous) }
        publishModelChange()
        return true
    }

    func refineForZoom(radius: Double) {
        let desired: Float
        switch radius {
        case ..<0.35: desired = 0.0125
        case ..<0.75: desired = 0.025
        case ..<1.5: desired = 0.05
        default: desired = 0.1
        }
        guard desired < cellSize else { return }
        _ = setCellSize(desired, recordsHistory: false)
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    func load(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let document: WorldDocument
        if let decoded = try? decoder.decode(WorldDocument.self, from: data) {
            document = decoded
        } else {
            document = WorldDocument(cellSize: 0.1, bricks: try decoder.decode([Brick].self, from: data))
        }

        guard document.cellSize > 0, isValidLayout(document.bricks) else {
            throw WorldStateError.invalidDocument
        }

        let previous = snapshot
        restore(document)
        pushUndo(previous)
    }

    private var snapshot: WorldDocument {
        WorldDocument(cellSize: cellSize, bricks: bricks.values.sorted { $0.id.uuidString < $1.id.uuidString })
    }

    private func recordUndoPoint() {
        guard transactionStart == nil else { return }
        pushUndo(snapshot)
    }

    private func pushUndo(_ state: WorldDocument) {
        undoStack.append(state)
        if undoStack.count > historyLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        updateHistoryAvailability()
    }

    private func restore(_ document: WorldDocument) {
        cellSize = document.cellSize
        bricks = Dictionary(uniqueKeysWithValues: document.bricks.map { ($0.id, $0) })
        rebuildOccupancy()
        publishModelChange()
    }

    private func insert(_ brick: Brick) {
        bricks[brick.id] = brick
        addToOccupancy(brick)
    }

    private func addToOccupancy(_ brick: Brick) {
        for cell in cells(of: brick) { occupied[cell] = brick.id }
    }

    private func removeFromOccupancy(id: UUID) {
        guard let brick = bricks[id] else { return }
        for cell in cells(of: brick) where occupied[cell] == id {
            occupied.removeValue(forKey: cell)
        }
    }

    private func rebuildOccupancy() {
        occupied.removeAll(keepingCapacity: true)
        for brick in bricks.values { addToOccupancy(brick) }
    }

    private func cells(of brick: Brick) -> [SIMD3<Int>] {
        var result: [SIMD3<Int>] = []
        result.reserveCapacity(brick.size.x * brick.size.y * brick.size.z)
        for x in brick.pos.x ..< brick.pos.x + brick.size.x {
            for y in brick.pos.y ..< brick.pos.y + brick.size.y {
                for z in brick.pos.z ..< brick.pos.z + brick.size.z {
                    result.append(SIMD3(x, y, z))
                }
            }
        }
        return result
    }

    private func isValidLayout(_ candidateBricks: [Brick]) -> Bool {
        var seenIDs: Set<UUID> = []
        var seenCells: Set<SIMD3<Int>> = []
        for brick in candidateBricks {
            guard seenIDs.insert(brick.id).inserted,
                  brick.pos.y >= 0,
                  brick.size.x > 0, brick.size.y > 0, brick.size.z > 0 else { return false }
            for cell in cells(of: brick) where !seenCells.insert(cell).inserted {
                return false
            }
        }
        return true
    }

    private func publishModelChange() {
        objectWillChange.send()
        updateHistoryAvailability()
    }

    private func updateHistoryAvailability() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }
}
