import XCTest
import AlgoratorCore
import TicketDemo
@testable import AlgoratorEditor

/// Maps in the editor: no new machinery, so these check that the existing one treats them like any other type.
final class MapEditorTests: XCTestCase {
    private let directory = TicketDirectory.sample(now: Date(timeIntervalSince1970: 1_791_108_000))
    private lazy var vocabulary = TicketVocabulary.make(directory: directory)
    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }

    private func engine(_ scripts: [Script]) -> LayoutEngine {
        LayoutEngine(vocabulary: vocabulary, document: Document(scripts: scripts), metrics: .fixed(), timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    // MARK: Palette

    func testPaletteHasAMapsCategoryWithTheNineBlocks() {
        XCTAssertEqual(vocabulary.categories.map(\.title), ["Control", "Variables", "Operators", "Time", "Lists", "Maps", "Tickets"])
        let script = Script(id: "s", name: "Main")
        let palette = engine([script]).palette(category: "maps", for: script)
        XCTAssertEqual(palette.items.map(\.layout.kind), ["map.empty", "map.with", "map.without", "map.value", "map.hasKey", "map.keys",
                                                          "map.count", "map.setEntry", "map.removeEntry"])
        XCTAssertEqual(palette.items.map(\.layout.shape), [.reporter, .reporter, .reporter, .reporter, .predicate, .reporter, .reporter,
                                                           .statement, .statement])
        XCTAssertTrue(palette.items.allSatisfy { $0.layout.color == Vocabulary.maps.color })

        // A fresh `… with … = …`: the map slot is a hole (nothing to type), key and value are typeable.
        guard case .block(let with) = palette.items[1].source else { return XCTFail("not a block") }
        XCTAssertEqual(with.inputs, ["key": .literal(""), "value": .literal("")])
        XCTAssertEqual(palette.items[1].layout.slots.map(\.content), [.hole, .field(""), .field("")])
        XCTAssertEqual(palette.items[1].layout.slots.map(\.editor), [SlotEditor.none, .text, .text])

        // The demo's two map blocks sit with the other ticket blocks.
        let tickets = engine([script]).palette(category: "tickets", for: script).items.map(\.layout.kind)
        XCTAssertTrue(tickets.contains("ticket.logDetails") && tickets.contains("ticket.reviewDetails"))
    }

    func testVariablesTabListsAMapVariable() {
        let script = Script(id: "s", name: "Main", parameters: [Param(name: "given", type: .map)], body: [
            Block(id: "e", kind: BuiltIn.setEntry, inputs: ["key": .literal("a"), "name": .literal("details"), "value": .literal(1)]),
        ])
        let variables = engine([script]).palette(category: "variables", for: script)
        XCTAssertEqual(Array(variables.items.map(\.source).dropFirst()), [.variable("given"), .variable("details")])
        XCTAssertEqual(DraggedItem.variable("details", in: script, document: Document(scripts: [script]), vocabulary: vocabulary).type, .map)
    }

    // MARK: Layout — unchanged machinery

    func testSetEntryBlockLayout() {
        let block = Block(id: "e", kind: BuiltIn.setEntry,
                          inputs: ["key": .literal("title"), "name": .literal("details"), "value": .variable("title")])
        let layout = engine([]).stack(block, in: Script(id: "s", name: "Main"))
        // "set entry" [title] "of" [details ▾] "to" (title): 63, 49, 14, 75, 14, 51 wide with 6 between, 10 padding.
        XCTAssertEqual(layout.frame, rect(0, 0, 316, 32))
        XCTAssertEqual(layout.shape, .statement)
        XCTAssertEqual(layout.pieces.map(\.frame), [rect(10, 9, 63, 14), rect(79, 6, 49, 20), rect(134, 9, 14, 14), rect(154, 6, 75, 20),
                                                    rect(235, 9, 14, 14), rect(255, 6, 51, 20)])
        XCTAssertEqual(layout.slots.map(\.content), [.field("title"), .menu("details", isPlaceholder: false), .variable("title")])
    }

    func testThirdAcceptanceScriptLayout() throws {
        let document = try AcceptanceDocument.load()
        let script = try XCTUnwrap(document.script(id: AcceptanceDocument.detailsID))
        let tree = LayoutEngine(vocabulary: vocabulary, document: document, metrics: .fixed()).layout(script)
        XCTAssertEqual(tree.allBlocks.map(\.id), ["fetch-details", "entry-title", "entry-priority", "entry-assignee", "review", "log",
                                                  "return-reviewed", "was-reviewed"])
        XCTAssertTrue(tree.allBlocks.allSatisfy(\.isKnown))
        // Seven statements stacked without gaps under the entry block; fetch has a second row for its outputs.
        XCTAssertEqual(tree.body.blocks.map(\.frame.minY), [62, 118, 150, 182, 214, 246, 278])
        XCTAssertEqual(tree.body.blocks.map(\.frame.minX), Array(repeating: 16, count: 7))
        XCTAssertEqual(tree.body.blocks.last?.shape, .cap)
        // A map variable in a map slot is an ordinary chip; a literal map would have nothing to edit it with.
        let log = try XCTUnwrap(tree.allBlocks.first { $0.id == "log" })
        XCTAssertEqual(log.slots.map(\.content), [.variable("reviewed")])
        XCTAssertEqual(log.slots.map(\.editor), [SlotEditor.none])
    }

    func testAMapLiteralIsShownAsItsJSONText() {
        let block = Block(kind: "ticket.logDetails", inputs: ["details": .literal(.map(["a": 1, "b": "two"]))])
        XCTAssertEqual(engine([]).stack(block, in: Script(id: "s", name: "Main")).slots.map(\.content), [.field(#"{"a":1,"b":"two"}"#)])
    }

    // MARK: Dropping onto a map slot

    /// `log details ( )` under the entry block: the label is 77 wide, so the hole is at (109, 68, 24, 20).
    private var logScript: Script {
        Script(id: "s", name: "Main", parameters: [Param(name: "m", type: .map), Param(name: "n", type: .number)],
               body: [Block(id: "log", kind: "ticket.logDetails")])
    }

    func testDropsOntoAMapSlot() throws {
        let script = logScript
        let document = Document(scripts: [script])
        let tree = engine([script]).layout(script)
        let hole = try XCTUnwrap(tree.body.blocks.first?.slots.first)
        XCTAssertEqual(hole.frame, rect(109, 68, 24, 20))
        XCTAssertEqual(hole.content, .hole)
        let point = CGPoint(x: hole.frame.midX, y: hole.frame.midY)
        let slot = DropTarget.slot(blockID: "log", name: "details")
        func variable(_ name: String) -> DraggedItem { .variable(name, in: script, document: document, vocabulary: vocabulary) }

        let cases: [(String, DraggedItem, DropTarget?)] = [
            ("a map variable", variable("m"), slot),
            ("a number variable — the wrong type never blocks a drop", variable("n"), slot),
            ("a reporter producing a map", .reporter(Block(kind: "map.empty"), vocabulary: vocabulary), slot),
            ("a reporter producing text", .reporter(Block(kind: "operator.join"), vocabulary: vocabulary), slot),
            ("a predicate — a round slot takes those too", .reporter(Block(kind: "map.hasKey"), vocabulary: vocabulary), slot),
            ("a statement — the wrong shape", .stack([Block(kind: BuiltIn.setEntry)], vocabulary: vocabulary),
             .region(owner: nil, name: "body", index: 0)),
        ]
        for (what, item, expected) in cases {
            XCTAssertEqual(HitTest.dropTarget(at: point, dragged: item, in: tree), expected, what)
        }
        XCTAssertFalse(DraggedItem.stack([Block(kind: BuiltIn.setEntry)], vocabulary: vocabulary).fits(shape: hole.shape, editor: hole.editor))
    }

    func testAWrongTypeInAMapSlotOnlyWarns() throws {
        func issues(after payload: DraggedItem.Payload) throws -> [String] {
            let edited = try XCTUnwrap(logScript.inserting(payload, at: .slot(blockID: "log", name: "details")))
            return Validator.validate(Document(scripts: [edited]), vocabulary: vocabulary).map { "\($0.severity): \($0.message)" }
        }
        XCTAssertEqual(try issues(after: .variable("m")), [])
        XCTAssertEqual(try issues(after: .variable("n")), ["warning: “details” expects map, not number"])
        XCTAssertEqual(try issues(after: .reporter(Block(kind: "map.empty"))), [])
        XCTAssertEqual(Validator.validate(Document(scripts: [logScript]), vocabulary: vocabulary).map(\.message), ["“details” is empty"])
    }

    func testAMapSlotHasNoEditorToOpen() throws {
        // Clicking it does nothing: the editor only reacts to slots whose editor is not `.none`.
        let slot = try XCTUnwrap(engine([logScript]).layout(logScript).body.blocks.first?.slots.first)
        XCTAssertEqual(slot.editor, SlotEditor.none)
        XCTAssertEqual(HitTest.pick(at: CGPoint(x: slot.frame.midX, y: slot.frame.midY), in: engine([logScript]).layout(logScript)), .slot(slot))
    }
}
