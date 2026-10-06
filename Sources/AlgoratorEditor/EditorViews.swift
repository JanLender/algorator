import SwiftUI
import AlgoratorCore

/// Draws one script. A thin wrapper: all geometry comes from the `LayoutTree`.
public struct ScriptCanvasView: View {
    public var tree: LayoutTree
    public var renderer: BlockRenderer
    public var indicator: DropIndicator?

    public init(tree: LayoutTree, renderer: BlockRenderer = BlockRenderer(), indicator: DropIndicator? = nil) {
        self.tree = tree
        self.renderer = renderer
        self.indicator = indicator
    }

    public var body: some View {
        Canvas { context, _ in
            renderer.draw(tree, in: &context)
            if let indicator { renderer.draw(indicator, in: &context) }
        }
        .frame(width: tree.size.width, height: tree.size.height)
    }
}

/// Draws the palette flyout of one category.
public struct PaletteCanvasView: View {
    public var palette: PaletteLayout
    public var renderer: BlockRenderer

    public init(palette: PaletteLayout, renderer: BlockRenderer = BlockRenderer()) {
        self.palette = palette
        self.renderer = renderer
    }

    public var body: some View {
        Canvas { context, _ in renderer.draw(palette, in: &context) }
            .frame(width: palette.size.width, height: palette.size.height)
    }
}

/// The editor: category tabs and palette on the left, one script on a canvas on the right.
///
/// The view holds no editing logic. It turns gestures into calls on `DragController` (which uses the pure
/// `HitTest` and `Script` operations) and draws what comes back.
public struct AlgoratorEditorView: View {
    @Binding private var document: Document
    private let vocabulary: Vocabulary
    private let references: ReferenceProvider?
    private let metrics: LayoutMetrics

    @State private var selectedScript: String?
    @State private var selectedCategory: String?
    @State private var drag: DragState?
    /// The canvas content's origin in the editor's coordinate space (changes as the canvas scrolls).
    @State private var canvasOrigin = CGPoint.zero

    private static let space = "algorator.editor"

    public init(document: Binding<Document>, vocabulary: Vocabulary, references: ReferenceProvider? = nil,
                metrics: LayoutMetrics = .standard) {
        self._document = document
        self.vocabulary = vocabulary
        self.references = references
        self.metrics = metrics
    }

    private var script: Script? {
        document.scripts.first { $0.id == selectedScript } ?? document.scripts.first
    }

    private var category: String {
        selectedCategory ?? vocabulary.categories.first?.id ?? ""
    }

    private var engine: LayoutEngine {
        LayoutEngine(vocabulary: vocabulary, document: document, metrics: metrics, references: references)
    }

    public var body: some View {
        HStack(spacing: 0) {
            categoryTabs
                .frame(width: 124)
            Divider()
            TopLeadingScrollView {
                if let script {
                    PaletteCanvasView(palette: engine.palette(category: category, for: script),
                                      renderer: BlockRenderer(metrics: metrics))
                }
            }
            .frame(width: 290)
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.35))
            Divider()
            VStack(spacing: 0) {
                scriptSelector
                Divider()
                TopLeadingScrollView {
                    if let script { canvas(script) }
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(CanvasOriginKey.self) { canvasOrigin = $0 }
        .overlay { ghost }
    }

    // MARK: Canvas and dragging

    private func canvas(_ script: Script) -> some View {
        // While dragging, the canvas shows the script without the dragged blocks.
        let shown = drag?.remaining ?? script
        let issues = Validator.validate(shown, in: document, vocabulary: vocabulary)
        return ScriptCanvasView(tree: drag?.tree ?? engine.layout(script),
                                renderer: BlockRenderer(metrics: metrics, issues: BlockRenderer.worstIssues(issues)),
                                indicator: drag?.indicator)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: CanvasOriginKey.self, value: proxy.frame(in: .named(Self.space)).origin)
            })
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
                .onChanged { value in
                    let controller = DragController(engine: engine)
                    if drag == nil { drag = controller.begin(at: onCanvas(value.startLocation), in: script) }
                    if let state = drag { drag = controller.move(state, to: onCanvas(value.location)) }
                }
                .onEnded { _ in
                    if let state = drag, let edited = DragController(engine: engine).drop(state) {
                        document = document.replacing(edited)
                    }
                    drag = nil
                })
    }

    private func onCanvas(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - canvasOrigin.x, y: point.y - canvasOrigin.y)
    }

    /// The dragged blocks, floating above the whole editor.
    @ViewBuilder private var ghost: some View {
        if let drag {
            Canvas { context, _ in
                let origin = CGPoint(x: canvasOrigin.x + drag.ghostOrigin.x, y: canvasOrigin.y + drag.ghostOrigin.y)
                BlockRenderer(metrics: metrics).draw(ghost: drag.ghost, at: origin, in: &context)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: Chrome

    private var categoryTabs: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(vocabulary.categories) { item in
                    Button {
                        selectedCategory = item.id
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(item.color.swiftUI).frame(width: 14, height: 14)
                                .overlay(Circle().stroke(item.color.darker.swiftUI, lineWidth: 1))
                            Text(item.title).font(.system(size: 12, weight: item.id == category ? .semibold : .regular))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(item.id == category ? Color.accentColor.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
        }
    }

    private var scriptSelector: some View {
        HStack {
            Picker("Script", selection: Binding(get: { script?.id ?? "" }, set: { selectedScript = $0 })) {
                ForEach(document.scripts) { Text($0.name).tag($0.id) }
            }
            .frame(maxWidth: 280)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct CanvasOriginKey: PreferenceKey {
    static let defaultValue = CGPoint.zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
}

/// Scrolls both ways and pins content smaller than the viewport to the top-left (a plain two-axis
/// `ScrollView` centres it).
struct TopLeadingScrollView<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                content.frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
            }
        }
    }
}
