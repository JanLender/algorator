import XCTest
import AlgoratorCore
@testable import AlgoratorEditor

/// Layout is checked against hand-computed frames, using a measurer where every character is 7×14.
final class LayoutTests: XCTestCase {
    private let vocabulary: Vocabulary = {
        let category = BlockCategory(id: "t", title: "T", color: BlockColor(hex: 0x336699))
        return Vocabulary([
            .statement("t.say", category: category, title: "say %text", inputs: [.value("text", .text)]) { _, _ in [:] },
            BlockDefinition(id: "t.stop", shape: .cap, category: category, title: "stop") { _, _ in [:] },
            .statement("t.pair", category: category, title: "pair",
                       outputs: [OutputDefinition("a", .text), OutputDefinition("b", .text)]) { _, _ in [:] },
            .statement("t.one", category: category, title: "one", outputs: [OutputDefinition("r", .text)]) { _, _ in [:] },
            .statement("t.greet", category: category, title: "greet %who", inputs: [.reference("who", kind: "user")]) { _, _ in [:] },
        ])
    }()

    private func engine(_ scripts: [Script] = []) -> LayoutEngine {
        LayoutEngine(vocabulary: vocabulary, document: Document(scripts: scripts), metrics: .fixed(),
                     timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
    private func say(_ id: String, _ text: String) -> Block { Block(id: id, kind: "t.say", inputs: ["text": .literal(.text(text))]) }
    private let empty = Script(id: "s", name: "Main")

    // MARK: A whole script

    func testScriptWithNestedIfElse() {
        let script = Script(id: "s", name: "Main", body: [
            say("b1", "hi"),
            Block(id: "b2", kind: BuiltIn.ifElse, regions: ["then": [say("b3", "a")], "else": []]),
            Block(id: "b4", kind: "t.stop"),
        ])
        let tree = engine([script]).layout(script)

        // Entry: 16 padding, a 14 bump, one 20 row with 6 padding; at least wide enough for the bump.
        XCTAssertEqual(tree.entry.frame, rect(16, 16, 100, 46))
        XCTAssertEqual(tree.entry.title.frame, rect(26, 39, 28, 14))
        XCTAssertEqual(tree.body.frame, rect(16, 62, 110, 186))
        XCTAssertNil(tree.body.ownerID)

        let table: [(String, CGRect)] = tree.allBlocks.map { ($0.id, $0.frame) }
        XCTAssertEqual(table.map(\.0), ["b1", "b2", "b3", "b4"])
        XCTAssertEqual(table.map(\.1), [
            rect(16, 62, 75, 32),      // say "hi": 10 + 21 + 6 + 28 + 10
            rect(16, 94, 110, 122),    // header 32, then 32, divider 24, empty else 20, footer 14
            rect(30, 126, 71, 32),     // indented by the 14 arm
            rect(16, 216, 56, 32),     // minimum stack width
        ])

        let say = tree.body.blocks[0]
        XCTAssertEqual(say.pieces.map(\.frame), [rect(26, 71, 21, 14), rect(53, 68, 28, 20)])
        XCTAssertEqual(say.slots.first?.content, .field("hi"))
        XCTAssertEqual(say.header, say.frame)
        XCTAssertEqual(say.shape, .statement)

        let branch = tree.body.blocks[1]
        XCTAssertEqual(branch.shape, .cBlock)
        XCTAssertEqual(branch.header, rect(16, 94, 110, 32))
        XCTAssertEqual(branch.pieces.map(\.frame), [rect(26, 103, 14, 14), rect(46, 100, 30, 20), rect(82, 103, 28, 14)])
        XCTAssertEqual(branch.slots.first?.content, .hole)
        XCTAssertEqual(branch.slots.first?.shape, .boolean)
        XCTAssertEqual(branch.regions.map(\.name), ["then", "else"])
        XCTAssertEqual(branch.regions.map(\.ownerID), ["b2", "b2"])
        XCTAssertEqual(branch.regions.map(\.frame), [rect(30, 126, 96, 32), rect(30, 182, 96, 20)])
        XCTAssertEqual(branch.dividers.map(\.frame), [rect(16, 158, 110, 24)])
        XCTAssertEqual(branch.dividers.first?.label, LabelLayout(text: "else", frame: rect(26, 163, 28, 14), role: .label))
        XCTAssertEqual(branch.footer, rect(16, 202, 110, 14))

        XCTAssertEqual(tree.body.blocks[2].shape, .cap)
        XCTAssertEqual(tree.size, CGSize(width: 142, height: 268))
    }

    func testEmptyScriptStillHasADropArea() {
        let tree = engine().layout(empty)
        XCTAssertEqual(tree.body.frame, rect(16, 62, 100, 20))
        XCTAssertEqual(tree.body.blocks, [])
    }

    func testEntryShowsParametersAndOutputs() {
        let script = Script(id: "s", name: "Run", parameters: [Param(name: "ticket", type: .reference, referenceKind: "ticket")],
                            outputs: [Param(name: "ok", type: .bool)])
        let entry = engine().layout(script).entry
        XCTAssertEqual(entry.title.frame, rect(26, 39, 21, 14))
        XCTAssertEqual(entry.parameters, [ChipLayout(name: "ticket", frame: rect(53, 36, 58, 20))])
        XCTAssertEqual(entry.arrow?.frame, rect(117, 39, 7, 14))
        XCTAssertEqual(entry.outputs, [ChipLayout(name: "ok", frame: rect(130, 36, 30, 20))])
        XCTAssertEqual(entry.frame, rect(16, 16, 154, 46))
    }

    func testWideChildrenGrowTheCanvasButNotTheirParent() {
        let long = say("wide", String(repeating: "x", count: 30))
        let script = Script(id: "s", name: "Main", body: [Block(id: "c", kind: BuiltIn.if, regions: ["then": [long]])])
        let tree = engine([script]).layout(script)
        let parent = tree.body.blocks[0]
        XCTAssertEqual(parent.frame.width, 110)
        XCTAssertEqual(parent.regions[0].blocks[0].frame, rect(30, 94, 271, 32))
        XCTAssertEqual(parent.regions[0].frame.width, 271)
        XCTAssertEqual(parent.bounds.maxX, 301)
        XCTAssertEqual(tree.size.width, 317)
    }

    // MARK: Reporters in slots

    func testNestedReportersGrowTheirParents() {
        let join = Block(id: "join", kind: "operator.join", inputs: ["a": .literal("a"), "b": .variable("x")])
        let equals = Block(id: "eq", kind: "operator.equals", inputs: ["a": .reporter(join), "b": .literal("1")])
        let branch = Block(id: "if", kind: BuiltIn.if, inputs: ["condition": .reporter(equals)], regions: ["then": []])
        let layout = engine().stack(branch, in: empty)

        // literal 20 → reporter 26 → predicate 32 → header 44
        XCTAssertEqual(layout.header, rect(0, 0, 245, 44))
        XCTAssertEqual(layout.pieces.map(\.frame), [rect(10, 15, 14, 14), rect(30, 6, 171, 32), rect(207, 15, 28, 14)])
        XCTAssertEqual(layout.frame, rect(0, 0, 245, 78))

        guard case .reporter(let predicate)? = layout.slots.first?.content else { return XCTFail("no predicate") }
        XCTAssertEqual(predicate.shape, .predicate)
        XCTAssertEqual(predicate.frame, rect(30, 6, 171, 32))
        XCTAssertEqual(predicate.pieces.map(\.frame), [rect(42, 9, 104, 26), rect(152, 15, 7, 14), rect(165, 12, 24, 20)])

        guard case .reporter(let reporter)? = predicate.slots.first?.content else { return XCTFail("no reporter") }
        XCTAssertEqual(reporter.shape, .reporter)
        XCTAssertEqual(reporter.frame, rect(42, 9, 104, 26))
        XCTAssertEqual(reporter.pieces.map(\.frame), [rect(50, 15, 28, 14), rect(84, 12, 24, 20), rect(114, 12, 24, 20)])
        XCTAssertEqual(reporter.slots.map(\.content), [.field("a"), .variable("x")])
        XCTAssertEqual(reporter.slots.map(\.blockID), ["join", "join"])

        XCTAssertEqual(layout.withDescendants.map(\.id), ["if", "eq", "join"])
    }

    // MARK: Slots

    func testSlotContents() {
        let callee = Script(id: "callee", name: "Callee")
        let cases: [(Block, [SlotContent])] = [
            (Block(kind: "t.say"), [.hole]),
            (say("b", ""), [.field("")]),
            (Block(kind: "t.say", inputs: ["text": .literal(3)]), [.field("3")]),
            (Block(kind: "t.say", inputs: ["text": .literal(.date(LocalDate(iso: "2026-10-04")!))]), [.field("2026-10-04")]),
            (Block(kind: "t.say", inputs: ["text": .literal(.timestamp(Date(timeIntervalSince1970: 1_791_108_000)))]),
             [.field("2026-10-04 10:00")]),
            (say("b", "two\nlines"), [.field("two⏎lines")]),
            (say("b", String(repeating: "x", count: 40)), [.field(String(repeating: "x", count: 31) + "…")]),
            (Block(kind: "t.say", inputs: ["text": .variable("v")]), [.variable("v")]),
            (Block(kind: "t.greet"), [.menu("user", isPlaceholder: true)]),
            (Block(kind: "t.greet", inputs: ["who": .literal(.reference(Reference(kind: "user", id: "u1")))]),
             [.menu("u1", isPlaceholder: false)]),
            (Block(kind: BuiltIn.set), [.menu("variable", isPlaceholder: true), .hole]),
            (Block(kind: BuiltIn.set, inputs: ["name": .literal("x"), "value": .literal(true)]),
             [.menu("x", isPlaceholder: false), .field("true")]),
            (Block(kind: BuiltIn.call), [.menu("script", isPlaceholder: true)]),
            (Block(kind: BuiltIn.call, inputs: ["script": .literal("callee")]), [.menu("Callee", isPlaceholder: false)]),
            (Block(kind: BuiltIn.call, inputs: ["script": .literal("gone")]), [.menu("missing script", isPlaceholder: false)]),
        ]
        for (block, expected) in cases {
            XCTAssertEqual(engine([callee]).stack(block, in: empty).slots.map(\.content), expected, "\(block.kind) \(block.inputs)")
        }
    }

    func testReferenceLiteralsUseTheProvidersLabel() {
        struct Provider: ReferenceProvider {
            func candidates(kind: String, matching: String) -> [ReferenceCandidate] { [ReferenceCandidate(id: "u1", label: "Alice")] }
        }
        var engine = engine()
        engine.references = Provider()
        let known = Block(kind: "t.greet", inputs: ["who": .literal(.reference(Reference(kind: "user", id: "u1")))])
        let gone = Block(kind: "t.greet", inputs: ["who": .literal(.reference(Reference(kind: "user", id: "u9")))])
        XCTAssertEqual(engine.stack(known, in: empty).slots.first?.content, .menu("Alice", isPlaceholder: false))
        XCTAssertEqual(engine.stack(gone, in: empty).slots.first?.content, .menu("u9", isPlaceholder: false))
    }

    func testFieldAndMenuSizes() {
        // field: text + 2×7, at least 24; menu: text + 2×7 + 12 for the arrow; empty boolean: 30.
        XCTAssertEqual(engine().stack(say("b", "hello"), in: empty).slots[0].frame.size, CGSize(width: 49, height: 20))
        XCTAssertEqual(engine().stack(say("b", ""), in: empty).slots[0].frame.size, CGSize(width: 24, height: 20))
        XCTAssertEqual(engine().stack(Block(kind: "t.greet"), in: empty).slots[0].frame.size, CGSize(width: 54, height: 20))
        XCTAssertEqual(engine().stack(Block(kind: BuiltIn.if), in: empty).slots[0].frame.size, CGSize(width: 30, height: 20))
    }

    // MARK: Output bindings

    func testSeveralOutputsGetTheirOwnRow() {
        let layout = engine().stack(Block(id: "p", kind: "t.pair", bindings: ["a": "a", "b": "other"]), in: empty)
        XCTAssertEqual(layout.frame, rect(0, 0, 161, 56))
        XCTAssertEqual(layout.pieces, [
            .label(LabelLayout(text: "pair", frame: rect(10, 9, 28, 14), role: .label)),
            .label(LabelLayout(text: "→", frame: rect(10, 33, 7, 14), role: .label)),
            .binding(BindingLayout(blockID: "p", output: "a", variable: "a", text: "a", frame: rect(23, 30, 33, 20))),
            .binding(BindingLayout(blockID: "p", output: "b", variable: "other", text: "b → other", frame: rect(62, 30, 89, 20))),
        ])
    }

    func testOneOutputSharesTheTitleRow() {
        let layout = engine().stack(Block(id: "o", kind: "t.one"), in: empty)
        XCTAssertEqual(layout.frame, rect(0, 0, 121, 32))
        XCTAssertEqual(layout.pieces.last, .binding(BindingLayout(blockID: "o", output: "r", variable: "", text: "r → …",
                                                                  frame: rect(50, 6, 61, 20))))
    }

    // MARK: Dynamic signatures

    func testReturnAndCallFollowTheirScripts() {
        let callee = Script(id: "callee", name: "Callee", parameters: [Param(name: "n", type: .number)],
                            outputs: [Param(name: "ok", type: .bool)])
        let returning = engine().stack(Block(kind: BuiltIn.return, inputs: ["ok": .literal(true)]), in: callee)
        XCTAssertEqual(returning.shape, .cap)
        XCTAssertEqual(returning.pieces.map(\.frame.minX), [10, 58, 78])
        XCTAssertEqual(returning.slots.map(\.content), [.menu("true", isPlaceholder: false)])

        let call = Block(id: "c", kind: BuiltIn.call, inputs: ["script": .literal("callee"), "arg.n": .literal(5)],
                         bindings: ["ok": "ok"])
        let calling = engine([callee]).stack(call, in: empty)
        XCTAssertEqual(calling.slots.map(\.name), ["script", "arg.n"])
        XCTAssertEqual(calling.slots.map(\.content), [.menu("Callee", isPlaceholder: false), .field("5")])
        XCTAssertEqual(calling.pieces.count, 6)   // call, script, n, arg, →, binding
    }

    // MARK: Unknown and misplaced blocks

    func testUnknownKindsStayVisibleWithTheirRegions() {
        let statement = engine().stack(Block(id: "u", kind: "vendor.gone", inputs: ["x": .literal("kept")]), in: empty)
        XCTAssertFalse(statement.isKnown)
        XCTAssertEqual(statement.shape, .statement)
        XCTAssertEqual(statement.pieces, [.label(LabelLayout(text: "unknown: vendor.gone", frame: rect(10, 9, 140, 14), role: .label))])

        let loop = engine().stack(Block(id: "l", kind: "vendor.loop", regions: ["body": [say("inner", "a")]]), in: empty)
        XCTAssertFalse(loop.isKnown)
        XCTAssertEqual(loop.shape, .cBlock)
        XCTAssertEqual(loop.regions.map(\.name), ["body"])
        XCTAssertEqual(loop.regions[0].blocks.map(\.id), ["inner"])

        let reporter = engine().stack(Block(kind: "t.say", inputs: ["text": .reporter(Block(id: "r", kind: "vendor.value"))]), in: empty)
        guard case .reporter(let inner)? = reporter.slots.first?.content else { return XCTFail("no reporter") }
        XCTAssertFalse(inner.isKnown)
        XCTAssertEqual(inner.shape, .reporter)
    }

    func testMisplacedBlocksAreDrawnInTheShapeOfTheirPosition() {
        XCTAssertEqual(engine().stack(Block(kind: "time.now"), in: empty).shape, .statement)
        XCTAssertEqual(engine().inline(Block(kind: "t.say"), in: empty).shape, .reporter)
        XCTAssertEqual(engine().inline(Block(kind: "operator.not"), in: empty).shape, .predicate)
    }

    // MARK: Palette

    func testPaletteStacksPrototypesWithGaps() {
        let script = Script(id: "s", name: "Main", parameters: [Param(name: "p", type: .text)],
                            body: [Block(kind: BuiltIn.set, inputs: ["name": .literal("total"), "value": .literal(1)])])
        let palette = engine([script]).palette(category: "t", for: script)
        XCTAssertEqual(palette.items.map(\.layout.kind), ["t.say", "t.stop", "t.pair", "t.one", "t.greet"])
        XCTAssertEqual(palette.items.map(\.layout.frame.minY), [16, 60, 104, 172, 216])
        XCTAssertTrue(palette.items.allSatisfy { $0.layout.frame.minX == 16 })
        XCTAssertEqual(palette.size.height, 264)

        // Prototypes carry default literals and bound outputs.
        guard case .block(let pair) = palette.items[2].source else { return XCTFail("not a block") }
        XCTAssertEqual(pair.bindings, ["a": "a", "b": "b"])
        guard case .block(let sayBlock) = palette.items[0].source else { return XCTFail("not a block") }
        XCTAssertEqual(sayBlock.inputs, ["text": .literal("")])

        let variables = engine([script]).palette(category: "variables", for: script)
        XCTAssertEqual(variables.items.map(\.source), [
            .block(Block(id: "palette:variables.set", kind: BuiltIn.set, inputs: ["value": .literal("")])),
            .variable("p"), .variable("total"),
        ])
        XCTAssertEqual(variables.items[1].layout.frame, rect(16, 60, 23, 20))
    }

    func testPaletteOffersACallPerScript() {
        let scripts = [Script(id: "a", name: "A"), Script(id: "b", name: "B", outputs: [Param(name: "r", type: .text)])]
        let palette = engine(scripts).palette(category: "control", for: scripts[0])
        XCTAssertEqual(palette.items.map(\.layout.id),
                       ["palette:control.if", "palette:control.ifElse", "palette:control.return", "palette:control.call:a",
                        "palette:control.call:b"])
        guard case .block(let call) = palette.items[4].source else { return XCTFail("not a block") }
        XCTAssertEqual(call.inputs, ["script": .literal("b")])
        XCTAssertEqual(call.bindings, ["r": "r"])
    }

    func testLayoutIsDeterministic() {
        let script = Script(id: "s", name: "Main", body: [say("b1", "hi"), Block(id: "b2", kind: BuiltIn.if, regions: ["then": [say("b3", "a")]])])
        XCTAssertEqual(engine([script]).layout(script), engine([script]).layout(script))
    }
}
