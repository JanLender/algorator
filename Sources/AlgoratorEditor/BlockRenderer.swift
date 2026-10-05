import SwiftUI
import AlgoratorCore

/// Draws layouts into a `GraphicsContext`. Has no state and reads nothing but its inputs, so the same
/// drawing happens on screen and in a headless `ImageRenderer`.
public struct BlockRenderer {
    public var metrics: LayoutMetrics
    /// The worst validation issue per block id; drawn as a badge.
    public var issues: [String: Issue.Severity]
    public var selection: String?

    public init(metrics: LayoutMetrics = .standard, issues: [String: Issue.Severity] = [:], selection: String? = nil) {
        self.metrics = metrics
        self.issues = issues
        self.selection = selection
    }

    /// Summarises validation issues for `init(issues:)`: an error outranks a warning.
    public static func worstIssues(_ issues: [Issue]) -> [String: Issue.Severity] {
        issues.reduce(into: [:]) { result, issue in
            if result[issue.blockID] != .error { result[issue.blockID] = issue.severity }
        }
    }

    // MARK: Whole layouts

    public func draw(_ tree: LayoutTree, in context: inout GraphicsContext) {
        draw(tree.entry, in: &context)
        for block in tree.body.blocks { draw(block, in: &context) }
    }

    public func draw(_ palette: PaletteLayout, in context: inout GraphicsContext) {
        for item in palette.items { draw(item.layout, in: &context) }
    }

    private func draw(_ entry: EntryLayout, in context: inout GraphicsContext) {
        let color = Vocabulary.control.color
        let path = BlockPaths.hat(entry.frame, metrics)
        context.fill(path, with: .color(color.swiftUI))
        context.stroke(path, with: .color(color.darker.swiftUI), lineWidth: 1)
        text(entry.title, .white, in: &context)
        for chip in entry.parameters { self.chip(chip.name, chip.frame, Vocabulary.variables.color, in: &context) }
        if let arrow = entry.arrow { text(arrow, .white, in: &context) }
        for chip in entry.outputs { self.chip(chip.name, chip.frame, color.darker, in: &context) }
    }

    // MARK: Blocks

    public func draw(_ block: BlockLayout, in context: inout GraphicsContext) {
        let path = BlockPaths.path(for: block, metrics)
        context.fill(path, with: .color(block.color.swiftUI))
        if block.isKnown {
            context.stroke(path, with: .color(block.color.darker.swiftUI), lineWidth: 1)
        } else {
            // Visibly broken: grey with a dashed red outline.
            context.stroke(path, with: .color(.red), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
        if block.id == selection {
            context.stroke(path, with: .color(.yellow), lineWidth: 2.5)
        }

        for piece in block.pieces {
            switch piece {
            case .label(let label): text(label, .white, in: &context)
            case .slot(let slot): draw(slot, on: block, in: &context)
            case .binding(let binding):
                menu(binding.text, binding.frame, block.color, dimmed: binding.variable.isEmpty, in: &context)
            }
        }
        for divider in block.dividers { text(divider.label, .white, in: &context) }
        for region in block.regions {
            for child in region.blocks { draw(child, in: &context) }
        }
        if let severity = issues[block.id] { badge(severity, on: block, in: &context) }
    }

    private func draw(_ slot: SlotLayout, on block: BlockLayout, in context: inout GraphicsContext) {
        switch slot.content {
        case .reporter(let reporter):
            draw(reporter, in: &context)
        case .variable(let name):
            chip(name, slot.frame, Vocabulary.variables.color, in: &context)
        case .hole:
            let path = BlockPaths.slot(slot, metrics)
            context.fill(path, with: .color(block.color.hole.swiftUI))
            context.stroke(path, with: .color(block.color.darker.swiftUI), lineWidth: 1)
        case .field(let string):
            let path = BlockPaths.slot(slot, metrics)
            context.fill(path, with: .color(.white))
            context.stroke(path, with: .color(block.color.darker.swiftUI), lineWidth: 1)
            let label = LabelLayout(text: string, frame: slot.frame.insetBy(dx: metrics.fieldPadH, dy: 0), role: .field)
            text(label, BlockRenderer.fieldText, in: &context)
        case .menu(let string, let isPlaceholder):
            menu(string, slot.frame, block.color, dimmed: isPlaceholder, in: &context)
        }
    }

    // MARK: Parts

    private func chip(_ name: String, _ frame: CGRect, _ color: BlockColor, in context: inout GraphicsContext) {
        let path = BlockPaths.capsule(frame)
        context.fill(path, with: .color(color.swiftUI))
        context.stroke(path, with: .color(color.darker.swiftUI), lineWidth: 1)
        let label = LabelLayout(text: name, frame: frame.insetBy(dx: metrics.reporterPadH, dy: 0), role: .field)
        text(label, .white, in: &context)
    }

    private func menu(_ string: String, _ frame: CGRect, _ color: BlockColor, dimmed: Bool, in context: inout GraphicsContext) {
        let path = BlockPaths.capsule(frame)
        context.fill(path, with: .color(color.darker.swiftUI))
        context.stroke(path, with: .color(color.hole.swiftUI), lineWidth: 1)
        let label = LabelLayout(text: string, frame: frame.insetBy(dx: metrics.fieldPadH, dy: 0), role: .field)
        text(label, .white.opacity(dimmed ? 0.6 : 1), in: &context)
        // The ▾ of a picker.
        let center = CGPoint(x: frame.maxX - metrics.fieldPadH - metrics.menuArrowWidth / 2 + 2, y: frame.midY + 1)
        var arrow = Path()
        arrow.move(to: CGPoint(x: center.x - 3.5, y: center.y - 2.5))
        arrow.addLine(to: CGPoint(x: center.x + 3.5, y: center.y - 2.5))
        arrow.addLine(to: CGPoint(x: center.x, y: center.y + 2.5))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(.white.opacity(0.85)))
    }

    private func badge(_ severity: Issue.Severity, on block: BlockLayout, in context: inout GraphicsContext) {
        let radius: CGFloat = 7
        let center = CGPoint(x: block.header.maxX - 1, y: block.header.minY + 1)
        let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        context.fill(circle, with: .color(severity == .error ? BlockRenderer.error : BlockRenderer.warning))
        context.stroke(circle, with: .color(.white), lineWidth: 1.5)
        context.draw(Text("!").font(.system(size: 10, weight: .heavy)).foregroundColor(severity == .error ? .white : .black),
                     at: center, anchor: .center)
    }

    private func text(_ label: LabelLayout, _ color: Color, in context: inout GraphicsContext) {
        let font = Font.system(size: metrics.fontSize, weight: Font.Weight(LayoutMetrics.weight(label.role)))
        context.draw(Text(label.text).font(font).foregroundColor(color),
                     at: CGPoint(x: label.frame.minX, y: label.frame.midY), anchor: .leading)
    }

    static let fieldText = Color(.sRGB, red: 0.34, green: 0.37, blue: 0.46)
    static let error = Color(.sRGB, red: 0.86, green: 0.15, blue: 0.15)
    static let warning = Color(.sRGB, red: 1.0, green: 0.8, blue: 0.0)
}

extension BlockColor {
    var swiftUI: Color { Color(.sRGB, red: red, green: green, blue: blue) }
    /// Outlines and menus.
    var darker: BlockColor { scaled(0.82) }
    /// Empty slots.
    var hole: BlockColor { scaled(0.68) }

    private func scaled(_ factor: Double) -> BlockColor {
        BlockColor(red: red * factor, green: green * factor, blue: blue * factor)
    }
}

private extension Font.Weight {
    init(_ weight: NSFont.Weight) {
        switch weight {
        case .bold: self = .bold
        case .medium: self = .medium
        default: self = .regular
        }
    }
}
