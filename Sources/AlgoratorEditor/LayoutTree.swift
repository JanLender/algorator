import Foundation
import AlgoratorCore

/// The frames of everything in one script, in canvas coordinates (origin top-left). Pure data: the
/// renderer draws it and hit-testing reads it.
public struct LayoutTree: Equatable, Sendable {
    public var size: CGSize
    public var entry: EntryLayout
    /// The script's body: the root region, directly under the entry block.
    public var body: RegionLayout
}

/// The hat block: the script's name, parameters and declared outputs.
public struct EntryLayout: Equatable, Sendable {
    public var frame: CGRect
    public var title: LabelLayout
    public var parameters: [ChipLayout]
    /// The `→` before the outputs; `nil` when the script declares none.
    public var arrow: LabelLayout?
    public var outputs: [ChipLayout]
}

/// A small named pill: a parameter or output on the entry block.
public struct ChipLayout: Equatable, Sendable {
    public var name: String
    public var frame: CGRect
}

/// A vertical run of stack blocks: the script body, or one mouth of a C-block.
public struct RegionLayout: Equatable, Sendable {
    /// The C-block owning the region; `nil` for the script body.
    public var ownerID: String?
    public var name: String
    /// The mouth. At least `emptyMouthHeight` tall, even when empty.
    public var frame: CGRect
    public var blocks: [BlockLayout]
}

public struct BlockLayout: Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: String
    /// The shape it is drawn with — decided by where it sits, so a misplaced block still shows.
    public var shape: BlockShape
    /// False for a kind the vocabulary does not know: drawn visibly broken.
    public var isKnown: Bool
    public var color: BlockColor
    /// A stack block's bars (not children that stick out to the right); a reporter's whole outline.
    public var frame: CGRect
    /// The top bar holding the pieces. Equal to `frame` unless the block has regions.
    public var header: CGRect
    public var pieces: [PieceLayout]
    public var regions: [RegionLayout]
    /// The bars between regions (`else`).
    public var dividers: [DividerLayout]
    /// The bottom bar of a C-block.
    public var footer: CGRect?
}

public struct DividerLayout: Equatable, Sendable {
    public var frame: CGRect
    public var label: LabelLayout
}

public enum PieceLayout: Equatable, Sendable {
    case label(LabelLayout)
    case slot(SlotLayout)
    case binding(BindingLayout)
}

public struct LabelLayout: Equatable, Sendable {
    public var text: String
    public var frame: CGRect
    public var role: LayoutMetrics.TextRole
}

public struct SlotLayout: Equatable, Sendable {
    public var blockID: String
    public var name: String
    public var frame: CGRect
    public var shape: SlotShape
    public var editor: SlotEditor
    public var content: SlotContent
}

public indirect enum SlotContent: Equatable, Sendable {
    /// Nothing in it, and nothing to type.
    case hole
    /// A white, typeable literal.
    case field(String)
    /// A picker-style literal (dropdown, reference, variable name, script, bool).
    case menu(String, isPlaceholder: Bool)
    /// A variable chip.
    case variable(String)
    case reporter(BlockLayout)
}

/// The `→ [variable ▾]` chip of one output.
public struct BindingLayout: Equatable, Sendable {
    public var blockID: String
    public var output: String
    /// The bound variable; empty when the output is not bound.
    public var variable: String
    public var text: String
    public var frame: CGRect
}

/// The palette flyout of one category.
public struct PaletteLayout: Equatable, Sendable {
    public var size: CGSize
    public var items: [PaletteItem]
}

public struct PaletteItem: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// A fresh block to drop in.
        case block(Block)
        /// A variable chip to drop into a slot.
        case variable(String)
    }

    public var source: Source
    public var layout: BlockLayout
}

// MARK: Traversal and translation

extension LayoutTree {
    /// Every block, parents before children, top to bottom.
    public var allBlocks: [BlockLayout] { body.blocks.flatMap(\.withDescendants) }
}

extension BlockLayout {
    public var slots: [SlotLayout] {
        pieces.compactMap { if case .slot(let slot) = $0 { return slot } else { return nil } }
    }

    /// This block, the reporters in its slots, and the blocks in its regions (recursively).
    public var withDescendants: [BlockLayout] {
        var result = [self]
        for slot in slots {
            if case .reporter(let reporter) = slot.content { result += reporter.withDescendants }
        }
        for region in regions { result += region.blocks.flatMap(\.withDescendants) }
        return result
    }

    /// The frame including everything nested, however far it sticks out.
    var bounds: CGRect {
        regions.flatMap(\.blocks).reduce(frame) { $0.union($1.bounds) }
    }

    func offset(_ dx: CGFloat, _ dy: CGFloat) -> BlockLayout {
        var copy = self
        copy.frame = frame.offsetBy(dx: dx, dy: dy)
        copy.header = header.offsetBy(dx: dx, dy: dy)
        copy.footer = footer?.offsetBy(dx: dx, dy: dy)
        copy.pieces = pieces.map { $0.offset(dx, dy) }
        copy.regions = regions.map { $0.offset(dx, dy) }
        copy.dividers = dividers.map {
            DividerLayout(frame: $0.frame.offsetBy(dx: dx, dy: dy), label: $0.label.offset(dx, dy))
        }
        return copy
    }
}

extension RegionLayout {
    func offset(_ dx: CGFloat, _ dy: CGFloat) -> RegionLayout {
        RegionLayout(ownerID: ownerID, name: name, frame: frame.offsetBy(dx: dx, dy: dy),
                     blocks: blocks.map { $0.offset(dx, dy) })
    }
}

extension LabelLayout {
    func offset(_ dx: CGFloat, _ dy: CGFloat) -> LabelLayout {
        LabelLayout(text: text, frame: frame.offsetBy(dx: dx, dy: dy), role: role)
    }
}

extension PieceLayout {
    var frame: CGRect {
        switch self {
        case .label(let label): return label.frame
        case .slot(let slot): return slot.frame
        case .binding(let binding): return binding.frame
        }
    }

    func offset(_ dx: CGFloat, _ dy: CGFloat) -> PieceLayout {
        switch self {
        case .label(let label):
            return .label(label.offset(dx, dy))
        case .slot(var slot):
            slot.frame = slot.frame.offsetBy(dx: dx, dy: dy)
            if case .reporter(let reporter) = slot.content { slot.content = .reporter(reporter.offset(dx, dy)) }
            return .slot(slot)
        case .binding(var binding):
            binding.frame = binding.frame.offsetBy(dx: dx, dy: dy)
            return .binding(binding)
        }
    }
}
