import SwiftUI
import AlgoratorCore

/// Scratch-like outlines, derived from layout frames alone.
enum BlockPaths {
    static func path(for block: BlockLayout, _ m: LayoutMetrics) -> Path {
        switch block.shape {
        case .reporter: return capsule(block.frame)
        case .predicate: return hexagon(block.frame, m)
        case .statement, .cBlock, .cap: return stack(block, m)
        }
    }

    static func capsule(_ frame: CGRect) -> Path {
        Path(roundedRect: frame, cornerRadius: frame.height / 2)
    }

    static func hexagon(_ frame: CGRect, _ m: LayoutMetrics) -> Path {
        let tip = min(frame.height / 2, m.predicatePadH)
        var path = Path()
        path.move(to: CGPoint(x: frame.minX + tip, y: frame.minY))
        path.addLine(to: CGPoint(x: frame.maxX - tip, y: frame.minY))
        path.addLine(to: CGPoint(x: frame.maxX, y: frame.midY))
        path.addLine(to: CGPoint(x: frame.maxX - tip, y: frame.maxY))
        path.addLine(to: CGPoint(x: frame.minX + tip, y: frame.maxY))
        path.addLine(to: CGPoint(x: frame.minX, y: frame.midY))
        path.closeSubpath()
        return path
    }

    /// The outline of a slot's hole or literal.
    static func slot(_ slot: SlotLayout, _ m: LayoutMetrics) -> Path {
        slot.shape == .boolean ? hexagon(slot.frame, m) : capsule(slot.frame)
    }

    /// A statement, cap or C-block: bars joined by an arm on the left, with a notch on top of every edge a
    /// block can hang from and a tab under every edge a block can attach to.
    static func stack(_ block: BlockLayout, _ m: LayoutMetrics) -> Path {
        let bars = [block.header] + block.dividers.map(\.frame) + (block.footer.map { [$0] } ?? [])
        let left = block.frame.minX, right = block.frame.maxX, arm = left + m.armWidth
        let r = m.cornerRadius
        var path = Path()

        path.move(to: CGPoint(x: left + r, y: bars[0].minY))
        notch(&path, x: left + m.notchX, y: bars[0].minY, m)
        for (index, bar) in bars.enumerated() {
            // Top-right corner, right side, bottom-right corner.
            path.addArc(tangent1End: CGPoint(x: right, y: bar.minY), tangent2End: CGPoint(x: right, y: bar.maxY), radius: r)
            path.addArc(tangent1End: CGPoint(x: right, y: bar.maxY), tangent2End: CGPoint(x: left, y: bar.maxY), radius: r)
            guard index + 1 < bars.count else { break }
            // Into the mouth: a tab for its first block, down the arm, a notch for its last block's tab.
            let next = bars[index + 1]
            tab(&path, x: arm + m.notchX, y: bar.maxY, m)
            path.addArc(tangent1End: CGPoint(x: arm, y: bar.maxY), tangent2End: CGPoint(x: arm, y: next.minY), radius: r)
            path.addArc(tangent1End: CGPoint(x: arm, y: next.minY), tangent2End: CGPoint(x: right, y: next.minY), radius: r)
            notch(&path, x: arm + m.notchX, y: next.minY, m)
        }
        let bottom = bars[bars.count - 1].maxY
        if block.shape != .cap { tab(&path, x: left + m.notchX, y: bottom, m) }
        path.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: left, y: bars[0].minY), radius: r)
        path.addArc(tangent1End: CGPoint(x: left, y: bars[0].minY), tangent2End: CGPoint(x: right, y: bars[0].minY), radius: r)
        path.closeSubpath()
        return path
    }

    /// The entry block: a hat with a bump on top and a tab underneath.
    static func hat(_ frame: CGRect, _ m: LayoutMetrics) -> Path {
        let r = m.cornerRadius
        let top = frame.minY + m.hatBumpHeight
        var path = Path()
        path.move(to: CGPoint(x: frame.minX, y: top))
        path.addCurve(to: CGPoint(x: frame.minX + m.hatBumpWidth, y: top),
                      control1: CGPoint(x: frame.minX + m.hatBumpWidth * 0.26, y: top - m.hatBumpHeight * 1.4),
                      control2: CGPoint(x: frame.minX + m.hatBumpWidth * 0.74, y: top - m.hatBumpHeight * 1.4))
        path.addArc(tangent1End: CGPoint(x: frame.maxX, y: top), tangent2End: CGPoint(x: frame.maxX, y: frame.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: frame.maxX, y: frame.maxY), tangent2End: CGPoint(x: frame.minX, y: frame.maxY), radius: r)
        tab(&path, x: frame.minX + m.notchX, y: frame.maxY, m)
        path.addArc(tangent1End: CGPoint(x: frame.minX, y: frame.maxY), tangent2End: CGPoint(x: frame.minX, y: top), radius: r)
        path.closeSubpath()
        return path
    }

    /// An indentation in a top edge, drawn left to right.
    private static func notch(_ path: inout Path, x: CGFloat, y: CGFloat, _ m: LayoutMetrics) {
        path.addLine(to: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: x + m.notchSlope, y: y + m.notchDepth))
        path.addLine(to: CGPoint(x: x + m.notchSlope + m.notchWidth, y: y + m.notchDepth))
        path.addLine(to: CGPoint(x: x + 2 * m.notchSlope + m.notchWidth, y: y))
    }

    /// The matching protrusion under a bottom edge, drawn right to left.
    private static func tab(_ path: inout Path, x: CGFloat, y: CGFloat, _ m: LayoutMetrics) {
        path.addLine(to: CGPoint(x: x + 2 * m.notchSlope + m.notchWidth, y: y))
        path.addLine(to: CGPoint(x: x + m.notchSlope + m.notchWidth, y: y + m.notchDepth))
        path.addLine(to: CGPoint(x: x + m.notchSlope, y: y + m.notchDepth))
        path.addLine(to: CGPoint(x: x, y: y))
    }
}
