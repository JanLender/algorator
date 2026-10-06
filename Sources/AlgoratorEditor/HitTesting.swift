import Foundation
import AlgoratorCore

/// What lies under a point of the canvas.
public enum Pick: Equatable {
    /// A block of the script (a statement or a reporter). `origin` is the top-left of its frame.
    case block(id: String, origin: CGPoint)
    /// A variable chip sitting in a slot.
    case variable(blockID: String, slot: String, name: String, origin: CGPoint)
    /// A parameter chip on the entry block.
    case parameter(name: String, origin: CGPoint)
    /// A literal or an empty slot.
    case slot(SlotLayout)
    /// An output's `→ [variable ▾]` chip.
    case binding(BindingLayout)
}

/// Where a pending drop will land, for drawing.
public enum DropIndicator: Equatable {
    /// A bar between statements.
    case insertion(CGRect)
    /// A slot to highlight.
    case slot(SlotLayout)
}

/// Pure functions from a point and a layout to what is there. No views, no state.
public enum HitTest {
    /// How far (vertically) a dragged stack snaps to an insertion point.
    public static let snapDistance: CGFloat = 28
    /// How far left and right of a region's edge a dragged stack still snaps to it.
    public static let snapLeft: CGFloat = 40
    public static let snapRight: CGFloat = 120
    /// Slots are a little easier to hit than they look.
    public static let slotSlop: CGFloat = 4

    // MARK: Dropping

    /// Where `dragged` would land if released at `point`.
    /// - Parameter point: for a stack, the top-left corner of the dragged stack; for a reporter or a variable,
    ///   the pointer.
    /// - Parameter tree: the layout of the script *without* the dragged blocks.
    public static func dropTarget(at point: CGPoint, dragged: DraggedItem, in tree: LayoutTree) -> DropTarget? {
        dragged.isStack ? insertion(at: point, dragged, tree) : slot(at: point, dragged, tree)?.target
    }

    private static func insertion(at point: CGPoint, _ dragged: DraggedItem, _ tree: LayoutTree) -> DropTarget? {
        var best: (target: DropTarget, score: CGFloat)?
        func visit(_ region: RegionLayout) {
            for index in 0...region.blocks.count where allows(dragged, at: index, in: region) {
                let anchor = anchor(index, in: region)
                let dx = point.x - anchor.x, dy = point.y - anchor.y
                guard abs(dy) <= snapDistance, dx >= -snapLeft, dx <= snapRight else { continue }
                let score = abs(dy) + abs(dx) * 0.3
                if best == nil || score < best!.score {
                    best = (.region(owner: region.ownerID, name: region.name, index: index), score)
                }
            }
            for block in region.blocks { block.regions.forEach(visit) }
        }
        visit(tree.body)
        if let best { return best.target }

        // Anywhere below the script appends to it.
        let end = tree.body.blocks.count
        let last = anchor(end, in: tree.body)
        if point.y > last.y, point.x >= last.x - snapLeft, point.x <= last.x + 3 * snapRight,
           allows(dragged, at: end, in: tree.body) {
            return .region(owner: nil, name: tree.body.name, index: end)
        }
        return nil
    }

    /// Nothing may follow a cap: not in the region, and not within the dragged stack.
    private static func allows(_ dragged: DraggedItem, at index: Int, in region: RegionLayout) -> Bool {
        if region.blocks[..<index].contains(where: { $0.shape == .cap }) { return false }
        return !dragged.endsWithCap || index == region.blocks.count
    }

    /// The top-left corner a stack inserted at `index` would get.
    private static func anchor(_ index: Int, in region: RegionLayout) -> CGPoint {
        let y = index < region.blocks.count ? region.blocks[index].frame.minY
                                            : (region.blocks.last?.frame.maxY ?? region.frame.minY)
        return CGPoint(x: region.frame.minX, y: y)
    }

    /// The innermost free slot under the point that takes the item. A slot already holding a reporter is not
    /// a target: drag that reporter out first.
    private static func slot(at point: CGPoint, _ dragged: DraggedItem, _ tree: LayoutTree) -> (target: DropTarget, slot: SlotLayout)? {
        var best: (slot: SlotLayout, depth: Int, distance: CGFloat)?
        func visit(_ block: BlockLayout, depth: Int) {
            for slot in block.slots {
                if case .reporter(let reporter) = slot.content {
                    visit(reporter, depth: depth + 1)
                    continue
                }
                guard slot.frame.insetBy(dx: -slotSlop, dy: -slotSlop).contains(point),
                      dragged.fits(shape: slot.shape, editor: slot.editor) else { continue }
                let dx = point.x - slot.frame.midX, dy = point.y - slot.frame.midY
                let distance = (dx * dx + dy * dy).squareRoot()
                if best == nil || depth > best!.depth || (depth == best!.depth && distance < best!.distance) {
                    best = (slot, depth, distance)
                }
            }
            for region in block.regions {
                for child in region.blocks { visit(child, depth: depth + 1) }
            }
        }
        for block in tree.body.blocks { visit(block, depth: 0) }
        return best.map { (.slot(blockID: $0.slot.blockID, name: $0.slot.name), $0.slot) }
    }

    /// What to draw for a target; `nil` when the target is not in the layout.
    public static func indicator(for target: DropTarget, in tree: LayoutTree, width: CGFloat = 96) -> DropIndicator? {
        switch target {
        case .region(let owner, let name, let index):
            guard let region = tree.region(owner: owner, name: name), index <= region.blocks.count else { return nil }
            let anchor = anchor(index, in: region)
            return .insertion(CGRect(x: anchor.x, y: anchor.y - 2, width: width, height: 4))
        case .slot(let blockID, let name):
            return tree.allBlocks.first { $0.id == blockID }?.slots.first { $0.name == name }.map(DropIndicator.slot)
        }
    }

    // MARK: Picking

    /// The innermost thing under the point; `nil` over empty canvas.
    public static func pick(at point: CGPoint, in tree: LayoutTree) -> Pick? {
        if let chip = tree.entry.parameters.first(where: { $0.frame.contains(point) }) {
            return .parameter(name: chip.name, origin: chip.frame.origin)
        }
        for block in tree.body.blocks {
            if let pick = pick(at: point, in: block) { return pick }
        }
        return nil
    }

    /// The innermost thing under the point within one block (and everything nested in it).
    public static func pick(at point: CGPoint, in block: BlockLayout) -> Pick? {
        for piece in block.pieces where piece.frame.contains(point) {
            switch piece {
            case .label:
                break
            case .binding(let binding):
                return .binding(binding)
            case .slot(let slot):
                switch slot.content {
                case .reporter(let reporter): return pick(at: point, in: reporter) ?? .block(id: reporter.id, origin: reporter.frame.origin)
                case .variable(let name): return .variable(blockID: slot.blockID, slot: slot.name, name: name, origin: slot.frame.origin)
                default: return .slot(slot)
                }
            }
        }
        for region in block.regions {
            for child in region.blocks {
                if let pick = pick(at: point, in: child) { return pick }
            }
        }
        var bars = [block.header] + block.dividers.map(\.frame) + (block.footer.map { [$0] } ?? [])
        if let mouth = block.regions.first {
            // The arm down the left side of a C-block.
            bars.append(CGRect(x: block.frame.minX, y: block.header.maxY, width: mouth.frame.minX - block.frame.minX,
                               height: block.frame.maxY - block.header.maxY))
        }
        return bars.contains { $0.contains(point) } ? .block(id: block.id, origin: block.frame.origin) : nil
    }
}

extension LayoutTree {
    /// The region with this owner and name (`owner == nil` is the script body).
    public func region(owner: String?, name: String) -> RegionLayout? {
        guard let owner else { return body }
        return allBlocks.first { $0.id == owner }?.regions.first { $0.name == name }
    }
}
