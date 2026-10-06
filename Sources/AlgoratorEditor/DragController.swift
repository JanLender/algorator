import Foundation
import AlgoratorCore

/// A drag in progress. Everything the view needs to draw it, and everything `drop` needs to finish it.
public struct DragState: Equatable {
    public var item: DraggedItem
    /// The script without the dragged blocks; drop targets refer to it.
    public var remaining: Script
    /// The layout of `remaining`.
    public var tree: LayoutTree
    /// The dragged blocks, laid out from the origin.
    public var ghost: [BlockLayout]
    /// From the ghost's top-left corner to the pointer.
    public var grabOffset: CGSize
    /// In canvas coordinates.
    public var pointer: CGPoint
    public var target: DropTarget?

    public var ghostOrigin: CGPoint {
        CGPoint(x: pointer.x - grabOffset.width, y: pointer.y - grabOffset.height)
    }

    public var indicator: DropIndicator? {
        target.flatMap { HitTest.indicator(for: $0, in: tree, width: max(48, min(ghost.first?.frame.width ?? 96, 160))) }
    }
}

/// The drag-and-drop logic, free of views: pick up, track, drop. The view only feeds it pointer positions.
public struct DragController {
    public var engine: LayoutEngine

    public init(engine: LayoutEngine) {
        self.engine = engine
    }

    private func emptyInput(in script: Script) -> (Block, String) -> Input {
        { BlockFactory.emptyInput(for: $0, slot: $1, in: script, document: engine.document, vocabulary: engine.vocabulary) }
    }

    /// Picks up whatever is under `point` (canvas coordinates); `nil` if nothing draggable is there.
    public func begin(at point: CGPoint, in script: Script) -> DragState? {
        let vocabulary = engine.vocabulary
        let item: DraggedItem
        var remaining = script
        let origin: CGPoint
        switch HitTest.pick(at: point, in: engine.layout(script)) {
        case .block(let id, let at)?:
            guard let (rest, payload) = script.removing(blockID: id, emptyInput: emptyInput(in: script)) else { return nil }
            switch payload {
            case .stack(let blocks): item = .stack(blocks, vocabulary: vocabulary)
            case .reporter(let block): item = .reporter(block, vocabulary: vocabulary)
            case .variable(let name): item = .variable(name, in: script, document: engine.document, vocabulary: vocabulary)
            }
            (remaining, origin) = (rest, at)
        case .variable(let blockID, let slot, let name, let at)?:
            guard let (rest, _) = script.removingVariable(blockID: blockID, slot: slot, emptyInput: emptyInput(in: script))
            else { return nil }
            item = .variable(name, in: script, document: engine.document, vocabulary: vocabulary)
            (remaining, origin) = (rest, at)
        case .parameter(let name, let at)?:
            // A copy: the entry block keeps its chip.
            item = .variable(name, in: script, document: engine.document, vocabulary: vocabulary)
            origin = at
        case .slot?, .binding?, nil:
            return nil
        }
        return begin(item, remaining: remaining, in: script,
                     grabOffset: CGSize(width: point.x - origin.x, height: point.y - origin.y), at: point)
    }

    /// Starts dragging an item that is not (or no longer) part of `remaining` — e.g. a fresh block.
    /// - Parameter script: the script the item's own layout is resolved against.
    public func begin(_ item: DraggedItem, remaining: Script, in script: Script, grabOffset: CGSize, at point: CGPoint) -> DragState {
        let ghost: [BlockLayout]
        switch item.payload {
        case .stack(let blocks): ghost = engine.stackLayouts(blocks, in: script)
        case .reporter(let block): ghost = [engine.inline(block, in: script)]
        case .variable(let name): ghost = [engine.chip(variable: name)]
        }
        let state = DragState(item: item, remaining: remaining, tree: engine.layout(remaining), ghost: ghost,
                              grabOffset: grabOffset, pointer: point, target: nil)
        return move(state, to: point)
    }

    /// Follows the pointer and recomputes the drop target.
    public func move(_ state: DragState, to point: CGPoint) -> DragState {
        var state = state
        state.pointer = point
        // A stack snaps by its top-left corner, like a puzzle piece; a reporter goes where the pointer is.
        state.target = HitTest.dropTarget(at: state.item.isStack ? state.ghostOrigin : point, dragged: state.item,
                                          in: state.tree)
        return state
    }

    /// The script after the drop; `nil` when there is no target (the drag is cancelled and nothing changes).
    public func drop(_ state: DragState) -> Script? {
        state.target.flatMap { state.remaining.inserting(state.item.payload, at: $0) }
    }
}
