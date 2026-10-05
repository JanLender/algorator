import SwiftUI
import AlgoratorCore

/// Draws one script. A thin wrapper: all geometry comes from the `LayoutTree`.
public struct ScriptCanvasView: View {
    public var tree: LayoutTree
    public var renderer: BlockRenderer

    public init(tree: LayoutTree, renderer: BlockRenderer = BlockRenderer()) {
        self.tree = tree
        self.renderer = renderer
    }

    public var body: some View {
        Canvas { context, _ in renderer.draw(tree, in: &context) }
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
public struct AlgoratorEditorView: View {
    @Binding private var document: Document
    private let vocabulary: Vocabulary
    private let references: ReferenceProvider?
    private let metrics: LayoutMetrics

    @State private var selectedScript: String?
    @State private var selectedCategory: String?

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
                    if let script {
                        let issues = Validator.validate(script, in: document, vocabulary: vocabulary)
                        ScriptCanvasView(tree: engine.layout(script),
                                         renderer: BlockRenderer(metrics: metrics, issues: BlockRenderer.worstIssues(issues)))
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

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
