import AppKit

/// Every dimension the layout uses, plus the text measurer. Layout is a pure function of the script and these.
/// `Sendable`: the measurer is a `@Sendable` closure, so layout may run off the main thread.
public struct LayoutMetrics: Sendable {
    public enum TextRole: Hashable, Sendable {
        /// Words on a block.
        case label
        /// Text inside a literal field, a menu or a chip.
        case field
        /// The script name on the entry block.
        case title
    }

    public var fontSize: CGFloat = 12
    /// Horizontal gap between the pieces of a row; vertical gap between rows.
    public var gap: CGFloat = 6
    public var rowGap: CGFloat = 4
    public var minRowHeight: CGFloat = 20

    // Stack blocks (statement, C-block, cap)
    public var padH: CGFloat = 10
    public var padV: CGFloat = 6
    public var cornerRadius: CGFloat = 4
    public var minStackWidth: CGFloat = 56
    public var minCBlockWidth: CGFloat = 110
    public var notchX: CGFloat = 12
    public var notchSlope: CGFloat = 3
    public var notchWidth: CGFloat = 10
    public var notchDepth: CGFloat = 4
    public var armWidth: CGFloat = 14
    public var emptyMouthHeight: CGFloat = 20
    public var dividerHeight: CGFloat = 24
    public var footerHeight: CGFloat = 14

    // Reporters, predicates and slots
    public var reporterPadH: CGFloat = 8
    public var reporterPadV: CGFloat = 3
    public var predicatePadH: CGFloat = 12
    public var fieldPadH: CGFloat = 7
    public var fieldHeight: CGFloat = 20
    public var fieldMinWidth: CGFloat = 24
    public var menuArrowWidth: CGFloat = 12
    public var emptyBooleanWidth: CGFloat = 30
    /// Literal text longer than this is shown truncated.
    public var maxLiteralCharacters = 32

    // Entry block and canvas
    public var hatBumpHeight: CGFloat = 14
    public var hatBumpWidth: CGFloat = 80
    public var canvasPadding: CGFloat = 16
    public var paletteGap: CGFloat = 12

    public var measure: @Sendable (String, TextRole) -> CGSize

    public init(measure: @escaping @Sendable (String, TextRole) -> CGSize) {
        self.measure = measure
    }

    /// Measures with the system font, matching what the renderer draws.
    public static var standard: LayoutMetrics {
        var metrics = LayoutMetrics { _, _ in .zero }
        let size = metrics.fontSize
        metrics.measure = { text, role in
            let measured = (text as NSString).size(withAttributes: [.font: nsFont(role, size: size)])
            return CGSize(width: ceil(measured.width), height: ceil(measured.height))
        }
        return metrics
    }

    /// Every character is `characterWidth` wide: deterministic, for tests.
    public static func fixed(characterWidth: CGFloat = 7, lineHeight: CGFloat = 14) -> LayoutMetrics {
        LayoutMetrics { text, _ in CGSize(width: CGFloat(text.count) * characterWidth, height: lineHeight) }
    }

    static func weight(_ role: TextRole) -> NSFont.Weight {
        switch role {
        case .label: return .medium
        case .field: return .regular
        case .title: return .bold
        }
    }

    static func nsFont(_ role: TextRole, size: CGFloat) -> NSFont {
        .systemFont(ofSize: size, weight: weight(role))
    }
}
