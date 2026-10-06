import XCTest
import AlgoratorCore
@testable import AlgoratorEditor

final class ScriptEditingTests: XCTestCase {
    private let stack = Fixture.stack
    private let slots = Fixture.slots

    private func ids(_ blocks: [Block]?) -> [String] { (blocks ?? []).map(\.id) }

    // MARK: Finding

    func testBlockAndLocationLookUp() {
        let cases: [(String, DropTarget?)] = [
            ("b1", .region(owner: nil, name: "body", index: 0)),
            ("b2", .region(owner: nil, name: "body", index: 1)),
            ("b3", .region(owner: "b2", name: "then", index: 0)),
            ("b4", .region(owner: nil, name: "body", index: 2)),
            ("nope", nil),
        ]
        for (id, expected) in cases {
            XCTAssertEqual(stack.location(of: id), expected, id)
            XCTAssertEqual(stack.block(id: id)?.id, expected == nil ? nil : id, id)
        }
        XCTAssertEqual(slots.location(of: "eq"), .slot(blockID: "if", name: "condition"))
        XCTAssertEqual(slots.location(of: "join"), .slot(blockID: "eq", name: "a"))
        XCTAssertEqual(slots.block(id: "join")?.kind, "operator.join")
    }

    // MARK: Removing

    func testRemovingAStatementTakesTheOnesBeneathIt() throws {
        let (script, removed) = try XCTUnwrap(stack.removing(blockID: "b2"))
        XCTAssertEqual(ids(script.body), ["b1"])
        guard case .stack(let blocks) = removed else { return XCTFail("not a stack") }
        XCTAssertEqual(ids(blocks), ["b2", "b4"])
        XCTAssertEqual(ids(blocks[0].regions["then"]), ["b3"], "nested blocks travel with their parent")

        let (inner, innerRemoved) = try XCTUnwrap(stack.removing(blockID: "b3"))
        XCTAssertEqual(ids(inner.body), ["b1", "b2", "b4"])
        XCTAssertEqual(inner.block(id: "b2")?.regions["then"], [])
        XCTAssertEqual(innerRemoved, .stack([Fixture.say("b3", "a")]))
    }

    func testRemovingAReporterLeavesTheGivenInput() throws {
        let (plain, removed) = try XCTUnwrap(slots.removing(blockID: "join"))
        XCTAssertEqual(plain.block(id: "eq")?.inputs["a"], .empty)
        guard case .reporter(let block) = removed else { return XCTFail("not a reporter") }
        XCTAssertEqual(block.id, "join")
        XCTAssertNil(plain.block(id: "join"))

        let (restored, _) = try XCTUnwrap(slots.removing(blockID: "join") { parent, slot in .literal(.text("\(parent.id).\(slot)")) })
        XCTAssertEqual(restored.block(id: "eq")?.inputs["a"], .literal("eq.a"))

        let (outer, outerRemoved) = try XCTUnwrap(slots.removing(blockID: "eq"))
        XCTAssertEqual(outer.block(id: "if")?.inputs["condition"], .empty)
        XCTAssertEqual(outerRemoved, .reporter(try XCTUnwrap(slots.block(id: "eq"))), "the nested reporter travels along")
    }

    func testRemovingAVariableChip() throws {
        let (script, removed) = try XCTUnwrap(slots.removingVariable(blockID: "join", slot: "b"))
        XCTAssertEqual(script.block(id: "join")?.inputs["b"], .empty)
        XCTAssertEqual(removed, .variable("x"))
        XCTAssertNil(slots.removingVariable(blockID: "join", slot: "a"), "that slot holds a literal")
        XCTAssertNil(slots.removingVariable(blockID: "nope", slot: "a"))
    }

    func testDeletingTakesOnlyOneBlock() throws {
        XCTAssertEqual(ids(try XCTUnwrap(stack.deleting(blockID: "b1")).body), ["b2", "b4"])
        XCTAssertEqual(ids(try XCTUnwrap(stack.deleting(blockID: "b2")).body), ["b1", "b4"])
        XCTAssertEqual(try XCTUnwrap(slots.deleting(blockID: "join")).block(id: "eq")?.inputs["a"], .empty)
        XCTAssertNil(stack.deleting(blockID: "nope"))
    }

    func testFreedSlotsGoBackToTheirDefaults() throws {
        func emptied(_ block: Block, _ slot: String) -> Input {
            BlockFactory.emptyInput(for: block, slot: slot, in: slots, document: Document(scripts: [slots]), vocabulary: Fixture.vocabulary)
        }
        XCTAssertEqual(try XCTUnwrap(slots.removing(blockID: "join", emptyInput: emptied)).script.block(id: "eq")?.inputs["a"],
                       .literal(""), "a typeable slot gets its default literal back")
        XCTAssertEqual(try XCTUnwrap(slots.removing(blockID: "eq", emptyInput: emptied)).script.block(id: "if")?.inputs["condition"],
                       .empty, "a boolean slot has no literal")
    }

    // MARK: Inserting

    func testInsertingAStackIntoRegions() throws {
        let new = DraggedItem.Payload.stack([Fixture.say("n1"), Fixture.say("n2")])
        let cases: [(DropTarget, [String], String?, [String])] = [
            (.region(owner: nil, name: "body", index: 0), ["n1", "n2", "b1", "b2", "b4"], nil, []),
            (.region(owner: nil, name: "body", index: 2), ["b1", "b2", "n1", "n2", "b4"], nil, []),
            (.region(owner: nil, name: "body", index: 3), ["b1", "b2", "b4", "n1", "n2"], nil, []),
            (.region(owner: "b2", name: "then", index: 0), ["b1", "b2", "b4"], "then", ["n1", "n2", "b3"]),
            (.region(owner: "b2", name: "then", index: 1), ["b1", "b2", "b4"], "then", ["b3", "n1", "n2"]),
            (.region(owner: "b2", name: "else", index: 0), ["b1", "b2", "b4"], "else", ["n1", "n2"]),
        ]
        for (target, body, region, inside) in cases {
            let script = try XCTUnwrap(stack.inserting(new, at: target), "\(target)")
            XCTAssertEqual(ids(script.body), body, "\(target)")
            if let region { XCTAssertEqual(ids(script.block(id: "b2")?.regions[region]), inside, "\(target)") }
        }
    }

    func testInsertingIntoSlotsReplacesTheirContent() throws {
        let reporter = Block(id: "r", kind: "operator.join")
        let intoLiteral = try XCTUnwrap(slots.inserting(.reporter(reporter), at: .slot(blockID: "eq", name: "b")))
        XCTAssertEqual(intoLiteral.block(id: "eq")?.inputs["b"], .reporter(reporter))
        let intoHole = try XCTUnwrap(slots.inserting(.variable("v"), at: .slot(blockID: "greet", name: "who")))
        XCTAssertEqual(intoHole.block(id: "greet")?.inputs["who"], .variable("v"))
        let intoNested = try XCTUnwrap(slots.inserting(.variable("v"), at: .slot(blockID: "join", name: "a")))
        XCTAssertEqual(intoNested.block(id: "join")?.inputs["a"], .variable("v"))
    }

    func testInsertingRefusesWhatDoesNotApply() {
        let statements = DraggedItem.Payload.stack([Fixture.say("n")])
        XCTAssertNil(stack.inserting(statements, at: .region(owner: nil, name: "body", index: 4)), "index out of range")
        XCTAssertNil(stack.inserting(statements, at: .region(owner: nil, name: "body", index: -1)))
        XCTAssertNil(stack.inserting(statements, at: .region(owner: "nope", name: "then", index: 0)), "unknown owner")
        XCTAssertNil(stack.inserting(statements, at: .slot(blockID: "b1", name: "text")), "a stack does not fit a slot")
        XCTAssertNil(stack.inserting(.variable("v"), at: .region(owner: nil, name: "body", index: 0)))
        XCTAssertNil(stack.inserting(.variable("v"), at: .slot(blockID: "nope", name: "text")))
    }

    // MARK: Moving

    func testMoving() throws {
        // b3 out of the "then" mouth to the top of the script.
        let lifted = try XCTUnwrap(stack.moving(blockID: "b3", to: .region(owner: nil, name: "body", index: 0)))
        XCTAssertEqual(ids(lifted.body), ["b3", "b1", "b2", "b4"])
        XCTAssertEqual(lifted.block(id: "b2")?.regions["then"], [])

        // b1 (carrying b2 and b4) cannot go anywhere inside itself: once removed, b2 is no longer a target.
        XCTAssertNil(stack.moving(blockID: "b1", to: .region(owner: "b2", name: "else", index: 0)))

        // A reporter from one slot to another.
        let swapped = try XCTUnwrap(slots.moving(blockID: "join", to: .slot(blockID: "eq", name: "b")))
        XCTAssertEqual(swapped.block(id: "eq")?.inputs["a"], .empty)
        XCTAssertEqual(swapped.block(id: "join")?.inputs["a"], .literal("a"))
        XCTAssertEqual(swapped.location(of: "join"), .slot(blockID: "eq", name: "b"))
    }

    func testRemovingThenInsertingAtTheSamePlaceIsTheIdentity() throws {
        for id in ["b1", "b2", "b3", "b4"] {
            let target = try XCTUnwrap(stack.location(of: id))
            XCTAssertEqual(stack.moving(blockID: id, to: target), stack, id)
        }
        for id in ["eq", "join"] {
            let target = try XCTUnwrap(slots.location(of: id))
            XCTAssertEqual(slots.moving(blockID: id, to: target), slots, id)
        }
    }

    // MARK: Inputs and bindings

    func testSettingInputsAndBindings() throws {
        let typed = try XCTUnwrap(stack.settingInput(blockID: "b3", name: "text", to: .literal("changed")))
        XCTAssertEqual(typed.block(id: "b3")?.inputs["text"], .literal("changed"))
        XCTAssertEqual(typed.block(id: "b1"), stack.block(id: "b1"), "other blocks are untouched")
        XCTAssertNil(stack.settingInput(blockID: "nope", name: "text", to: .empty))

        let script = Script(id: "s", name: "S", body: [Block(id: "o", kind: "t.one", bindings: ["r": "r"])])
        let renamed = try XCTUnwrap(script.settingBinding(blockID: "o", output: "r", to: "result"))
        XCTAssertEqual(renamed.block(id: "o")?.bindings, ["r": "result"])
        XCTAssertEqual(try XCTUnwrap(renamed.settingBinding(blockID: "o", output: "r", to: "")).block(id: "o")?.bindings, [:])
    }

    func testOperationsDoNotMutateTheirInput() {
        let before = stack
        _ = stack.removing(blockID: "b2")
        _ = stack.inserting(.stack([Fixture.say("n")]), at: .region(owner: nil, name: "body", index: 0))
        _ = stack.settingInput(blockID: "b1", name: "text", to: .empty)
        XCTAssertEqual(stack, before)
    }

    func testReplacingAScriptInADocument() {
        let other = Script(id: "other", name: "Other")
        var edited = stack
        edited.name = "Renamed"
        let document = Document(scripts: [stack, other]).replacing(edited)
        XCTAssertEqual(document.scripts.map(\.name), ["Renamed", "Other"])
        XCTAssertEqual(Document(scripts: [other]).replacing(edited).scripts, [other], "an unknown script is not added")
    }

    // MARK: Dragged items

    func testDraggedItemsKnowTheirShape() {
        XCTAssertTrue(Fixture.statement.isStack)
        XCTAssertFalse(Fixture.statement.endsWithCap)
        XCTAssertTrue(Fixture.cap.endsWithCap)
        XCTAssertFalse(Fixture.reporter.isPredicate)
        XCTAssertEqual(Fixture.reporter.type, .text)
        XCTAssertTrue(Fixture.predicate.isPredicate)
        XCTAssertEqual(Fixture.user.referenceKind, "user")

        let script = Script(id: "s", name: "S", parameters: [Param(name: "who", type: .reference, referenceKind: "user")], body: [
            Block(kind: "t.one", bindings: ["r": "text"]),
            Block(kind: BuiltIn.set, inputs: ["name": .literal("loose"), "value": .literal(1)]),
        ])
        func variable(_ name: String) -> DraggedItem {
            .variable(name, in: script, document: Document(scripts: [script]), vocabulary: Fixture.vocabulary)
        }
        XCTAssertEqual(variable("who"), DraggedItem(payload: .variable("who"), type: .reference, referenceKind: "user"))
        XCTAssertEqual(variable("text").type, .text)
        XCTAssertNil(variable("loose").type)
        XCTAssertNil(variable("unheard-of").type)
    }

    func testSlotFit() {
        let user = SlotShape.reference(kind: "user")
        let cases: [(DraggedItem, SlotShape, SlotEditor, Bool)] = [
            (Fixture.reporter, .value, .text, true),
            (Fixture.predicate, .value, .text, true),          // as in Scratch
            (Fixture.untyped, .value, .number, true),          // a type mismatch never blocks a drop
            (Fixture.reporter, .value, .dropdown(["a"]), true),
            (Fixture.reporter, .value, .none, true),
            (Fixture.predicate, .boolean, .none, true),
            (Fixture.reporter, .boolean, .none, false),
            (Fixture.untyped, .boolean, .none, false),
            (Fixture.user, user, .reference, true),
            (Fixture.ticket, user, .reference, false),
            (Fixture.reporter, user, .reference, false),       // known to be text
            (Fixture.predicate, user, .reference, false),
            (Fixture.untyped, user, .reference, true),         // unknown type: allowed, as in validation
            (Fixture.reporter, .value, .variable, false),      // a slot that names a variable takes no blocks
            (Fixture.reporter, .value, .script, false),
            (Fixture.statement, .value, .text, false),
        ]
        for (item, shape, editor, expected) in cases {
            XCTAssertEqual(item.fits(shape: shape, editor: editor), expected, "\(item.payload) → \(shape) \(editor)")
        }
    }
}
