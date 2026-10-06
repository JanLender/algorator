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
/// The view holds no editing logic. It turns gestures into calls on `DragController`, `HitTest`,
/// `SlotEditing` and the pure `Script` / `Document` operations, and draws what comes back. Every change
/// goes through `UndoBridge`, so it can be undone from the window's Edit menu.
public struct AlgoratorEditorView: View {
    @Binding private var document: Document
    private let vocabulary: Vocabulary
    private let references: ReferenceProvider?
    private let metrics: LayoutMetrics

    @Environment(\.undoManager) private var undoManager
    @StateObject private var undo = UndoBridge()

    @State private var selectedScript: String?
    @State private var selectedCategory: String?
    @State private var selection: String?
    @State private var drag: DragState?
    /// The pointer during a drag, in the editor's coordinate space.
    @State private var pointer = CGPoint.zero
    /// Origins of the canvas and palette contents in the editor's coordinate space (they move when scrolled).
    @State private var canvasOrigin = CGPoint.zero
    @State private var paletteOrigin = CGPoint.zero
    /// The palette's visible area: dropping there deletes.
    @State private var paletteFrame = CGRect.zero

    @State private var inline: InlineEdit?
    @State private var picker: PickerRequest?
    @State private var showingSettings = false
    /// The pointer over the canvas, in canvas coordinates.
    @State private var hover: CGPoint?
    @FocusState private var canvasFocused: Bool

    private static let space = "algorator.editor"
    private enum DragSource {
        case canvas
        case palette(PaletteLayout)
    }

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
            paletteColumn
                .frame(width: 290)
            Divider()
            VStack(spacing: 0) {
                scriptBar
                Divider()
                if let script {
                    TopLeadingScrollView { canvas(script) }
                        .background(Color(nsColor: .textBackgroundColor))
                        .focusable()
                        .focused($canvasFocused)
                        .focusEffectDisabled()
                        .onKeyPress(keys: [.delete, .deleteForward]) { _ in deleteSelection(in: script) }
                } else {
                    emptyDocument
                }
            }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(CanvasOriginKey.self) { canvasOrigin = $0 }
        .onPreferenceChange(PaletteOriginKey.self) { paletteOrigin = $0 }
        .onPreferenceChange(PaletteFrameKey.self) { paletteFrame = $0 }
        .overlay { ghost }
    }

    // MARK: Applying edits

    private func apply(_ edited: Document, _ name: String) {
        let binding = $document
        undo.write = { binding.wrappedValue = $0 }
        undo.commit(from: document, to: edited, name: name, undoManager: undoManager)
    }

    private func apply(_ edited: Script?, _ name: String) {
        if let edited { apply(document.replacing(edited), name) }
    }

    private func deleteSelection(in script: Script) -> KeyPress.Result {
        guard let selection else { return .ignored }
        apply(script.deleting(blockID: selection) {
            BlockFactory.emptyInput(for: $0, slot: $1, in: script, document: document, vocabulary: vocabulary)
        }, "Delete Block")
        self.selection = nil
        return .handled
    }

    // MARK: Palette

    private var paletteColumn: some View {
        TopLeadingScrollView {
            if let script {
                let palette = engine.palette(category: category, for: script)
                PaletteCanvasView(palette: palette, renderer: BlockRenderer(metrics: metrics))
                    .background(originReader(PaletteOriginKey.self))
                    .gesture(dragGesture(script, from: .palette(palette)))
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.35))
        .background(GeometryReader { proxy in
            Color.clear.preference(key: PaletteFrameKey.self, value: proxy.frame(in: .named(Self.space)))
        })
        .overlay {
            // Blocks taken out of the script are thrown away when dropped here.
            if let drag, !drag.isNew, paletteFrame.contains(pointer) {
                ZStack {
                    Color.red.opacity(0.22)
                    Image(systemName: "trash").font(.system(size: 34, weight: .medium)).foregroundStyle(.red)
                }
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: Canvas

    private func canvas(_ script: Script) -> some View {
        // While dragging, the canvas shows the script without the dragged blocks.
        let shown = drag?.remaining ?? script
        let issues = Validator.validate(shown, in: document, vocabulary: vocabulary)
        let renderer = BlockRenderer(metrics: metrics, issues: BlockRenderer.worstIssues(issues), selection: selection)
        return ScriptCanvasView(tree: drag?.tree ?? engine.layout(script), renderer: renderer, indicator: drag?.indicator)
            .background(originReader(CanvasOriginKey.self))
            .overlay(alignment: .topLeading) { inlineField(script) }
            .popover(item: $picker, attachmentAnchor: .rect(.rect(picker?.frame ?? .zero)), arrowEdge: .bottom) { request in
                PickerPopover(request: request, script: script, document: document, references: references) { input in
                    choose(input, for: request, in: script)
                }
            }
            .gesture(dragGesture(script, from: .canvas))
            .simultaneousGesture(SpatialTapGesture().onEnded { tapped(at: $0.location, in: script) })
            .onContinuousHover { phase in
                if case .active(let location) = phase { hover = location } else { hover = nil }
            }
            .overlay(alignment: .topLeading) { issueBubble(issues, in: script) }
    }

    /// The validation messages of the block under the pointer.
    @ViewBuilder private func issueBubble(_ issues: [Issue], in script: Script) -> some View {
        if drag == nil, inline == nil, let hover, let id = blockID(at: hover, in: script) {
            let messages = issues.filter { $0.blockID == id }
            if !messages.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(messages.enumerated()), id: \.offset) { _, issue in
                        Label(issue.message, systemImage: issue.severity == .error ? "exclamationmark.octagon.fill"
                                                                                  : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.severity == .error ? Color.red : Color.orange, .primary)
                    }
                }
                .font(.system(size: 11))
                .padding(7)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                .fixedSize()
                .offset(x: hover.x + 14, y: hover.y + 18)
                .allowsHitTesting(false)
            }
        }
    }

    private func blockID(at point: CGPoint, in script: Script) -> String? {
        switch HitTest.pick(at: point, in: engine.layout(script)) {
        case .block(let id, _)?: return id
        case .slot(let slot)?: return slot.blockID
        case .variable(let blockID, _, _, _)?: return blockID
        case .binding(let binding)?: return binding.blockID
        case .parameter?, nil: return nil
        }
    }

    private func originReader<Key: PreferenceKey>(_ key: Key.Type) -> some View where Key.Value == CGPoint {
        GeometryReader { proxy in
            Color.clear.preference(key: key, value: proxy.frame(in: .named(Self.space)).origin)
        }
    }

    // MARK: Dragging

    private func dragGesture(_ script: Script, from source: DragSource) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let controller = DragController(engine: engine)
                if drag == nil {
                    commitInline(in: script)
                    selection = nil
                    switch source {
                    case .canvas:
                        drag = controller.begin(at: onCanvas(value.startLocation), in: script)
                    case .palette(let palette):
                        let start = CGPoint(x: value.startLocation.x - paletteOrigin.x, y: value.startLocation.y - paletteOrigin.y)
                        guard let item = HitTest.pick(at: start, in: palette) else { break }
                        let origin = item.layout.frame.origin
                        drag = controller.begin(item, into: script,
                                                grabOffset: CGSize(width: start.x - origin.x, height: start.y - origin.y),
                                                at: onCanvas(value.startLocation))
                    }
                }
                if let state = drag {
                    drag = controller.move(state, to: onCanvas(value.location))
                    pointer = value.location
                }
            }
            .onEnded { _ in
                guard let state = drag else { return }
                drag = nil
                let controller = DragController(engine: engine)
                if paletteFrame.contains(pointer) {
                    apply(controller.discard(state), "Delete Blocks")
                } else {
                    apply(controller.drop(state), state.isNew ? "Add Block" : "Move Blocks")
                }
            }
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

    // MARK: Clicking: selection and slot editors

    private func tapped(at point: CGPoint, in script: Script) {
        commitInline(in: script)
        canvasFocused = true
        switch HitTest.pick(at: point, in: engine.layout(script)) {
        case .block(let id, _)?:
            selection = id
        case .slot(let slot)?:
            selection = nil
            open(slot, in: script)
        case .binding(let binding)?:
            selection = nil
            picker = PickerRequest(kind: .binding(output: binding.output, current: binding.variable),
                                   blockID: binding.blockID, slot: binding.output, frame: binding.frame)
        case .variable?, .parameter?, nil:
            selection = nil
        }
    }

    private func open(_ slot: SlotLayout, in script: Script) {
        let input = script.block(id: slot.blockID)?.inputs[slot.name]
        func request(_ kind: PickerRequest.Kind) {
            picker = PickerRequest(kind: kind, blockID: slot.blockID, slot: slot.name, frame: slot.frame)
        }
        switch slot.editor {
        case .none:
            break
        case .text, .number:
            inline = InlineEdit(slot: slot, text: SlotEditing.text(of: input))
        case .bool:
            apply(script.settingInput(blockID: slot.blockID, name: slot.name, to: SlotEditing.toggled(input)), "Change Value")
        case .date, .time, .timestamp:
            request(.date(editor: slot.editor, start: SlotEditing.date(of: input)))
        case .dropdown(let options):
            request(.options(options))
        case .reference:
            if case .reference(let kind) = slot.shape { request(.reference(kind: kind)) }
        case .variable:
            request(.variable)
        case .script:
            request(.script)
        }
    }

    private func choose(_ choice: PickerPopover.Choice, for request: PickerRequest, in script: Script) {
        picker = nil
        switch choice {
        case .input(let input):
            apply(script.settingInput(blockID: request.blockID, name: request.slot, to: input), "Change Value")
        case .binding(let variable):
            apply(script.settingBinding(blockID: request.blockID, output: request.slot, to: variable), "Change Variable")
        }
    }

    @ViewBuilder private func inlineField(_ script: Script) -> some View {
        if let editing = inline {
            InlineField(text: Binding(get: { inline?.text ?? "" }, set: { inline?.text = $0 }),
                        width: max(editing.slot.frame.width + 24, 90), height: editing.slot.frame.height,
                        fontSize: metrics.fontSize,
                        commit: { commitInline(in: script) }, cancel: { inline = nil })
                .offset(x: editing.slot.frame.minX, y: editing.slot.frame.minY)
                .id(editing.slot.blockID + editing.slot.name)
        }
    }

    private func commitInline(in script: Script) {
        guard let editing = inline else { return }
        inline = nil
        apply(script.settingInput(blockID: editing.slot.blockID, name: editing.slot.name,
                                  to: SlotEditing.input(fromText: editing.text, editor: editing.slot.editor)), "Change Value")
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

    private var scriptBar: some View {
        HStack(spacing: 8) {
            if let script {
                Picker("Script", selection: Binding(get: { script.id }, set: { selectedScript = $0; selection = nil })) {
                    ForEach(document.scripts) { Text($0.name).tag($0.id) }
                }
                .frame(maxWidth: 280)
                Button {
                    showingSettings = true
                } label: {
                    Label("Edit Script…", systemImage: "slider.horizontal.3")
                }
                .help("Name, parameters and outputs of this script")
                .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                    ScriptSettingsView(script: script, referenceKinds: vocabulary.referenceKinds,
                                       canDelete: document.scripts.count > 1) { edited in
                        showingSettings = false
                        apply(edited, "Edit Script")
                    } delete: {
                        showingSettings = false
                        selectedScript = nil
                        apply(document.removingScript(id: script.id), "Delete Script")
                    }
                }
            }
            Button(action: addScript) {
                Label("New Script", systemImage: "plus")
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyDocument: some View {
        VStack(spacing: 12) {
            Text("This document has no scripts yet.").foregroundStyle(.secondary)
            Button("New Script", action: addScript)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addScript() {
        let id = UUID().uuidString
        apply(document.addingScript(id: id), "New Script")
        selectedScript = id
        selection = nil
        showingSettings = true
    }
}

private struct CanvasOriginKey: PreferenceKey {
    static let defaultValue = CGPoint.zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
}

private struct PaletteOriginKey: PreferenceKey {
    static let defaultValue = CGPoint.zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
}

private struct PaletteFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
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
