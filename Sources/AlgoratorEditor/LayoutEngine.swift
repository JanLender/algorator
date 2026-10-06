import Foundation
import AlgoratorCore

/// Computes where everything goes. A pure function of the script, the vocabulary and the metrics: no views,
/// no state. Blocks are first laid out at the origin and then translated into place.
public struct LayoutEngine {
    public var vocabulary: Vocabulary
    public var document: Document
    public var metrics: LayoutMetrics
    /// Gives reference literals their labels; without it they show their ids.
    public var references: ReferenceProvider?
    /// The zone timestamp literals are displayed in.
    public var timeZone: TimeZone

    public init(vocabulary: Vocabulary, document: Document, metrics: LayoutMetrics = .standard,
                references: ReferenceProvider? = nil, timeZone: TimeZone = .current) {
        self.vocabulary = vocabulary
        self.document = document
        self.metrics = metrics
        self.references = references
        self.timeZone = timeZone
    }

    // MARK: Script

    public func layout(_ script: Script) -> LayoutTree {
        let pad = metrics.canvasPadding
        let entry = entry(script, at: CGPoint(x: pad, y: pad))
        let body = region(script.body, owner: nil, name: "body", in: script, at: CGPoint(x: pad, y: entry.frame.maxY),
                          minWidth: entry.frame.width)
        let extent = body.blocks.reduce(entry.frame.union(body.frame)) { $0.union($1.bounds) }
        return LayoutTree(size: CGSize(width: extent.maxX + pad, height: extent.maxY + pad + metrics.notchDepth),
                          entry: entry, body: body)
    }

    private func entry(_ script: Script, at origin: CGPoint) -> EntryLayout {
        let m = metrics
        let top = origin.y + m.hatBumpHeight + m.padV
        var x = origin.x + m.padH
        func center(_ size: CGSize) -> CGRect {
            defer { x += size.width + m.gap }
            return CGRect(x: x, y: top + (m.minRowHeight - size.height) / 2, width: size.width, height: size.height)
        }
        func chip(_ name: String) -> ChipLayout {
            let width = m.measure(name, .field).width + 2 * m.reporterPadH
            return ChipLayout(name: name, frame: center(CGSize(width: width, height: m.fieldHeight)))
        }
        let title = LabelLayout(text: script.name, frame: center(m.measure(script.name, .title)), role: .title)
        let parameters = script.parameters.map { chip($0.name) }
        var arrow: LabelLayout?
        if !script.outputs.isEmpty {
            arrow = LabelLayout(text: "→", frame: center(m.measure("→", .label)), role: .label)
        }
        let outputs = script.outputs.map { chip($0.name) }
        let width = max(x - m.gap + m.padH - origin.x, m.hatBumpWidth + 2 * m.cornerRadius + m.notchX)
        let frame = CGRect(x: origin.x, y: origin.y, width: width, height: m.hatBumpHeight + m.minRowHeight + 2 * m.padV)
        return EntryLayout(frame: frame, title: title, parameters: parameters, arrow: arrow, outputs: outputs)
    }

    // MARK: Regions and stack blocks

    private func region(_ blocks: [Block], owner: String?, name: String, in script: Script, at origin: CGPoint,
                        minWidth: CGFloat) -> RegionLayout {
        var y = origin.y
        var layouts: [BlockLayout] = []
        for block in blocks {
            let layout = stack(block, in: script).offset(origin.x, y)
            y += layout.frame.height
            layouts.append(layout)
        }
        let width = layouts.reduce(minWidth) { max($0, $1.frame.width) }
        let frame = CGRect(x: origin.x, y: origin.y, width: width, height: max(y - origin.y, metrics.emptyMouthHeight))
        return RegionLayout(ownerID: owner, name: name, frame: frame, blocks: layouts)
    }

    /// A block in a stack position, at the origin.
    func stack(_ block: Block, in script: Script) -> BlockLayout {
        let m = metrics
        let definition = vocabulary[block.kind]
        let regionNames: [String]
        let shape: BlockShape
        if let definition {
            shape = definition.shape.isStack ? definition.shape : .statement
            regionNames = definition.regions
        } else {
            // Unknown kind: keep whatever regions the document has visible.
            regionNames = block.regions.keys.sorted()
            shape = regionNames.isEmpty ? .statement : .cBlock
        }

        let (pieces, content) = rows(of: block, in: script, at: CGPoint(x: m.padH, y: m.padV))
        let width = max(content.width + 2 * m.padH, regionNames.isEmpty ? m.minStackWidth : m.minCBlockWidth)
        let header = CGRect(x: 0, y: 0, width: width, height: content.height + 2 * m.padV)
        var layout = BlockLayout(id: block.id, kind: block.kind, shape: shape, isKnown: definition != nil,
                                 color: definition?.category.color ?? LayoutEngine.unknownColor, frame: header,
                                 header: header, pieces: pieces, regions: [], dividers: [], footer: nil)
        guard !regionNames.isEmpty else { return layout }

        var y = header.maxY
        for (index, name) in regionNames.enumerated() {
            if index > 0 {
                let size = m.measure(name, .label)
                let label = LabelLayout(text: name, role: .label,
                                        at: CGPoint(x: m.padH, y: y + (m.dividerHeight - size.height) / 2), size: size)
                layout.dividers.append(DividerLayout(frame: CGRect(x: 0, y: y, width: width, height: m.dividerHeight),
                                                     label: label))
                y += m.dividerHeight
            }
            let mouth = region(block.regions[name] ?? [], owner: block.id, name: name, in: script,
                               at: CGPoint(x: m.armWidth, y: y), minWidth: width - m.armWidth)
            layout.regions.append(mouth)
            y = mouth.frame.maxY
        }
        let footer = CGRect(x: 0, y: y, width: width, height: m.footerHeight)
        layout.footer = footer
        layout.frame = CGRect(x: 0, y: 0, width: width, height: footer.maxY)
        return layout
    }

    /// Statements stacked from the origin, as they are drawn while being dragged.
    func stackLayouts(_ blocks: [Block], in script: Script) -> [BlockLayout] {
        region(blocks, owner: nil, name: "drag", in: script, at: .zero, minWidth: 0).blocks
    }

    // MARK: Reporters

    /// A block in a slot, at the origin.
    func inline(_ block: Block, in script: Script) -> BlockLayout {
        let m = metrics
        let definition = vocabulary[block.kind]
        let shape: BlockShape = definition?.shape == .predicate ? .predicate : .reporter
        let padH = shape == .predicate ? m.predicatePadH : m.reporterPadH
        let (pieces, content) = rows(of: block, in: script, at: CGPoint(x: padH, y: m.reporterPadV))
        let frame = CGRect(x: 0, y: 0, width: content.width + 2 * padH, height: content.height + 2 * m.reporterPadV)
        return BlockLayout(id: block.id, kind: block.kind, shape: shape, isKnown: definition != nil,
                           color: definition?.category.color ?? LayoutEngine.unknownColor, frame: frame, header: frame,
                           pieces: pieces, regions: [], dividers: [], footer: nil)
    }

    /// A variable chip as it appears in the palette, at the origin.
    func chip(variable name: String) -> BlockLayout {
        let m = metrics
        let size = m.measure(name, .field)
        let frame = CGRect(x: 0, y: 0, width: size.width + 2 * m.reporterPadH, height: m.fieldHeight)
        let label = LabelLayout(text: name, role: .field,
                                at: CGPoint(x: m.reporterPadH, y: (m.fieldHeight - size.height) / 2), size: size)
        return BlockLayout(id: "variable:\(name)", kind: LayoutEngine.variableChipKind, shape: .reporter, isKnown: true,
                           color: Vocabulary.variables.color, frame: frame, header: frame, pieces: [.label(label)],
                           regions: [], dividers: [], footer: nil)
    }

    // MARK: Rows of pieces

    private enum Part {
        case label(String)
        case slot(InputDefinition)
        case binding(OutputDefinition)
    }

    /// The pieces of a block's header, placed from `origin`, and the size they take.
    private func rows(of block: Block, in script: Script, at origin: CGPoint) -> ([PieceLayout], CGSize) {
        var rows: [[Part]]
        if let signature = vocabulary.signature(of: block, in: script, document: document) {
            rows = [signature.title.map { part -> Part in
                switch part {
                case .text(let text): return .label(text)
                case .slot(let name): return signature.input(name).map(Part.slot) ?? .label("%\(name)")
                }
            }]
            let bindings = [Part.label("→")] + signature.outputs.map(Part.binding)
            // One output fits on the title row; several get a row of their own.
            if signature.outputs.count == 1 { rows[0] += bindings } else if signature.outputs.count > 1 { rows.append(bindings) }
        } else {
            rows = [[.label("unknown: \(block.kind)")]]
        }

        var pieces: [PieceLayout] = []
        var y = origin.y
        var width: CGFloat = 0
        for row in rows {
            let unplaced = row.map { piece($0, of: block, in: script) }
            let height = unplaced.reduce(metrics.minRowHeight) { max($0, $1.frame.height) }
            var x = origin.x
            for piece in unplaced {
                pieces.append(piece.offset(x, y + (height - piece.frame.height) / 2))
                x += piece.frame.width + metrics.gap
            }
            width = max(width, x - metrics.gap - origin.x)
            y += height + metrics.rowGap
        }
        return (pieces, CGSize(width: width, height: y - metrics.rowGap - origin.y))
    }

    /// One piece at the origin.
    private func piece(_ part: Part, of block: Block, in script: Script) -> PieceLayout {
        let m = metrics
        switch part {
        case .label(let text):
            return .label(LabelLayout(text: text, role: .label, at: .zero, size: m.measure(text, .label)))

        case .binding(let output):
            let variable = block.bindings[output.name] ?? ""
            let text = variable == output.name ? variable : "\(output.name) → \(variable.isEmpty ? "…" : variable)"
            let width = m.measure(text, .field).width + 2 * m.fieldPadH + m.menuArrowWidth
            return .binding(BindingLayout(blockID: block.id, output: output.name, variable: variable, text: text,
                                          frame: CGRect(x: 0, y: 0, width: width, height: m.fieldHeight)))

        case .slot(let definition):
            var slot = SlotLayout(blockID: block.id, name: definition.name, frame: .zero, shape: definition.shape,
                                  editor: definition.editor, content: .hole)
            func size(_ width: CGFloat) -> CGRect { CGRect(x: 0, y: 0, width: max(width, m.fieldMinWidth), height: m.fieldHeight) }
            func menu(_ text: String, isPlaceholder: Bool) {
                slot.content = .menu(text, isPlaceholder: isPlaceholder)
                slot.frame = size(m.measure(text, .field).width + 2 * m.fieldPadH + m.menuArrowWidth)
            }
            switch block.inputs[definition.name] ?? .empty {
            case .reporter(let reporter):
                let layout = inline(reporter, in: script)
                slot.content = .reporter(layout)
                slot.frame = layout.frame
            case .variable(let name):
                slot.content = .variable(name)
                slot.frame = size(m.measure(name, .field).width + 2 * m.reporterPadH)
            case .literal(let value):
                let text = display(value, in: definition)
                if definition.usesMenu {
                    menu(text, isPlaceholder: false)
                } else {
                    slot.content = .field(text)
                    slot.frame = size(m.measure(text, .field).width + 2 * m.fieldPadH)
                }
            case .empty:
                if definition.shape == .boolean {
                    slot.frame = size(m.emptyBooleanWidth)
                } else if definition.usesMenu {
                    menu(definition.placeholder, isPlaceholder: true)
                } else {
                    slot.frame = size(0)
                }
            }
            return .slot(slot)
        }
    }

    /// How a literal reads on a block.
    func display(_ value: Value, in definition: InputDefinition) -> String {
        let environment = RunEnvironment(timeZone: timeZone)
        var text: String
        switch value {
        case .reference(let reference):
            text = references?.label(kind: reference.kind, id: reference.id) ?? reference.id
        case .timestamp:
            let date = Coercion.toDate(value, in: environment)?.description ?? ""
            let time = Coercion.toTime(value, in: environment)?.description ?? ""
            text = "\(date) \(time)"
        case .text(let id) where definition.editor == .script:
            text = document.script(id: id)?.name ?? "missing script"
        default:
            text = Coercion.toText(value, in: environment)
        }
        text = text.replacingOccurrences(of: "\n", with: "⏎")
        return text.count > metrics.maxLiteralCharacters ? text.prefix(metrics.maxLiteralCharacters - 1) + "…" : text
    }

    // MARK: Palette

    /// The flyout for one category: prototype blocks, and for the variables category the script's variable chips.
    public func palette(category: String, for script: Script) -> PaletteLayout {
        let pad = metrics.canvasPadding
        var items: [PaletteItem] = []
        var y = pad
        var width: CGFloat = 0
        func add(_ source: PaletteItem.Source, _ layout: BlockLayout) {
            let placed = layout.offset(pad, y)
            items.append(PaletteItem(source: source, layout: placed))
            y = placed.frame.maxY + metrics.paletteGap
            width = max(width, placed.bounds.maxX)
        }
        for block in BlockFactory.prototypes(category: category, in: script, document: document, vocabulary: vocabulary) {
            let isStack = vocabulary[block.kind]?.shape.isStack ?? true
            add(.block(block), isStack ? stack(block, in: script) : inline(block, in: script))
        }
        if category == Vocabulary.variables.id {
            for name in script.variableNames { add(.variable(name), chip(variable: name)) }
        }
        return PaletteLayout(size: CGSize(width: width + pad, height: y - metrics.paletteGap + pad), items: items)
    }

    static let unknownColor = BlockColor(hex: 0x8E8E93)
    static let variableChipKind = "$variable"
}

private extension LabelLayout {
    init(text: String, role: LayoutMetrics.TextRole, at origin: CGPoint, size: CGSize) {
        self.init(text: text, frame: CGRect(origin: origin, size: size), role: role)
    }
}

extension InputDefinition {
    /// Literals of these editors are picked, not typed, and are drawn as a menu.
    var usesMenu: Bool {
        switch editor {
        case .dropdown, .reference, .variable, .script, .bool: return true
        default: return false
        }
    }

    var placeholder: String {
        switch (editor, shape) {
        case (.reference, .reference(let kind)): return kind
        case (.variable, _): return "variable"
        case (.script, _): return "script"
        default: return ""
        }
    }
}
