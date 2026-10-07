import XCTest
import AlgoratorCore
import TicketDemo
@testable import AlgoratorEditor

/// SPEC-templates §5: multi-line text slots, and the template blocks in the editor.
final class TemplateEditorTests: XCTestCase {
    private let script = Script(id: "s", name: "Main")
    private func text(_ template: String, id: String = "t") -> Block {
        Block(id: id, kind: BuiltIn.text, inputs: ["template": .literal(.text(template))])
    }
    private func shown(_ template: String) -> SlotContent? { Fixture.engine().inline(text(template), in: script).slots.first?.content }

    // MARK: Palette

    func testPaletteListsTextAndItStartsEmpty() {
        let operators = Fixture.engine([script]).palette(category: "operators", for: script)
        XCTAssertEqual(operators.items.first?.layout.kind, BuiltIn.text, "first among the operators")
        guard case .block(let block)? = operators.items.first?.source else { return XCTFail("not a block") }
        XCTAssertEqual(block.inputs, ["template": .literal("")])
        XCTAssertEqual(operators.items.first?.layout.shape, .reporter)
        XCTAssertEqual(operators.items.first?.layout.slots.map(\.editor), [.longText])
    }

    // MARK: Layout of a long-text literal

    func testAMultiLineLiteralShowsItsFirstLine() {
        let cases: [(String, String)] = [
            ("one line", "one line"),
            ("", ""),
            ("first\nsecond\nthird", "first…"),
            ("{code} {name}\n\n{description}", "{code} {name}…"),
            ("\nstarts with a break", "…"),
            ("trailing\n", "trailing…"),
            ("windows\r\nline ends", "windows…"),
            (String(repeating: "x", count: 40), String(repeating: "x", count: 31) + "…"),                 // the usual length cut
            (String(repeating: "x", count: 40) + "\nmore", String(repeating: "x", count: 31) + "…"),      // both: one ellipsis
        ]
        for (template, expected) in cases {
            XCTAssertEqual(shown(template), .field(expected), "“\(template)”")
        }
    }

    func testLayoutOfABlockWithAMultiLineTemplate() {
        // text [Hello {name}…]: "text" is 28 wide, the field holds 13 characters (91 + 14), padding 8.
        let layout = Fixture.engine().inline(text("Hello {name}\nSecond line that is much longer than the first"), in: script)
        XCTAssertEqual(layout.frame, CGRect(x: 0, y: 0, width: 155, height: 26), "one row high, however many lines the text has")
        XCTAssertEqual(layout.pieces.map(\.frame), [CGRect(x: 8, y: 6, width: 28, height: 14), CGRect(x: 42, y: 3, width: 105, height: 20)])
        XCTAssertEqual(layout.slots.first?.content, .field("Hello {name}…"))
        XCTAssertEqual(layout.slots.first?.editor, .longText)

        // The same on a cap: fail with [first line…]
        let fail = Fixture.engine().stack(Block(id: "f", kind: BuiltIn.fail, inputs: ["message": .literal("No title\nfor {ticket}")]), in: script)
        XCTAssertEqual(fail.frame.height, 32)
        XCTAssertEqual(fail.slots.first?.content, .field("No title…"))
    }

    func testAnOrdinaryTextSlotStillMarksLineBreaks() {
        // Unchanged for the single-line editor: every break is shown, nothing is hidden after the first line.
        XCTAssertEqual(Fixture.engine().stack(Fixture.say("b", "two\nlines"), in: script).slots.first?.content, .field("two⏎lines"))
    }

    func testALongTextSlotTakesChipsAndReportersLikeAnyOther() {
        let layout = Fixture.engine().layout(Script(id: "s", name: "Main", body: [Block(id: "f", kind: BuiltIn.fail, inputs: ["message": .literal("")])]))
        let slot = layout.body.blocks[0].slots[0]
        let point = CGPoint(x: slot.frame.midX, y: slot.frame.midY)
        XCTAssertEqual(HitTest.dropTarget(at: point, dragged: Fixture.untyped, in: layout), .slot(blockID: "f", name: "message"))
        XCTAssertEqual(HitTest.dropTarget(at: point, dragged: Fixture.reporter, in: layout), .slot(blockID: "f", name: "message"))
        XCTAssertEqual(HitTest.pick(at: point, in: layout), .slot(slot), "a click opens its editor")
    }

    // MARK: Editing: commit and cancel, without a view

    private let holder = Script(id: "s", name: "Main", parameters: [Param(name: "name", type: .text)], body: [
        Block(id: "f", kind: BuiltIn.fail, inputs: ["message": .literal("Old\nmessage")]),
    ])

    func testEditingStartsFromTheWholeLiteral() {
        let edit = LiteralEdit(blockID: "f", slot: "message", editor: .longText, in: holder)
        XCTAssertEqual(edit.original, "Old\nmessage", "the full text, not the truncated one on the block")
        XCTAssertEqual(edit.text, edit.original)
        XCTAssertTrue(edit.isMultiline)
        XCTAssertFalse(LiteralEdit(blockID: "f", slot: "message", editor: .text, in: holder).isMultiline)
        XCTAssertEqual(LiteralEdit(blockID: "f", slot: "absent", editor: .longText, in: holder).text, "")
        XCTAssertEqual(LiteralEdit(blockID: "gone", slot: "message", editor: .longText, in: holder).text, "")
    }

    func testCommitStoresTheTextWithItsLineBreaks() throws {
        var edit = LiteralEdit(blockID: "f", slot: "message", editor: .longText, in: holder)
        edit.text = "Dear {name},\n\nno title.\n"
        let committed = try XCTUnwrap(edit.committed(to: holder))
        XCTAssertEqual(committed.block(id: "f")?.inputs["message"], .literal("Dear {name},\n\nno title.\n"))
        XCTAssertEqual(holder.block(id: "f")?.inputs["message"], .literal("Old\nmessage"), "the script passed in is untouched")
        XCTAssertEqual(Validator.validate(Document(scripts: [committed]), vocabulary: Fixture.vocabulary), [])
    }

    func testCancelIsDroppingTheEdit() {
        var edit = LiteralEdit(blockID: "f", slot: "message", editor: .longText, in: holder)
        edit.text = "typed and abandoned"
        // Nothing was applied: the edit is a value, and the script only changes through `committed(to:)`.
        XCTAssertEqual(holder.block(id: "f")?.inputs["message"], .literal("Old\nmessage"))
        XCTAssertEqual(edit.original, "Old\nmessage")
    }

    func testCommittingAnUnchangedTextChangesNothing() throws {
        let edit = LiteralEdit(blockID: "f", slot: "message", editor: .longText, in: holder)
        XCTAssertEqual(try XCTUnwrap(edit.committed(to: holder)), holder, "so the editor records no undo step")
    }

    func testCommitWhenTheBlockIsGone() {
        var edit = LiteralEdit(blockID: "f", slot: "message", editor: .longText, in: holder)
        edit.text = "too late"
        XCTAssertNil(edit.committed(to: Script(id: "s", name: "Main")), "e.g. the block was deleted meanwhile")
    }

    func testCommitFollowsTheSlotsEditor() throws {
        let numbers = Script(id: "s", name: "Main", body: [Block(id: "n", kind: "operator.formatNumber", inputs: ["number": .literal(1)])])
        var edit = LiteralEdit(blockID: "n", slot: "number", editor: .number, in: numbers)
        XCTAssertEqual(edit.original, "1")
        edit.text = " 2,5 "
        XCTAssertEqual(try XCTUnwrap(edit.committed(to: numbers)).block(id: "n")?.inputs["number"], .literal(2.5))
        // A long text is always text, even when it looks like a number.
        var long = LiteralEdit(blockID: "f", slot: "message", editor: .longText, in: holder)
        long.text = "42"
        XCTAssertEqual(try XCTUnwrap(long.committed(to: holder)).block(id: "f")?.inputs["message"], .literal("42"))
    }

    @MainActor
    func testOneCommittedEditIsOneUndoStep() throws {
        var document = Document(scripts: [holder])
        let bridge = UndoBridge()
        bridge.write = { document = $0 }
        let manager = UndoManager()
        manager.groupsByEvent = false
        var edit = LiteralEdit(blockID: "f", slot: "message", editor: .longText, in: holder)
        edit.text = "line 1\nline 2\nline 3"       // many keystrokes, many newlines: still one commit
        manager.beginUndoGrouping()
        bridge.commit(from: document, to: document.replacing(try XCTUnwrap(edit.committed(to: holder))), name: "Change Text", undoManager: manager)
        manager.endUndoGrouping()
        XCTAssertEqual(document.scripts[0].block(id: "f")?.inputs["message"], .literal("line 1\nline 2\nline 3"))
        manager.undo()
        XCTAssertEqual(document, Document(scripts: [holder]))
        XCTAssertFalse(manager.canUndo)
    }

    // MARK: The changed acceptance script

    func testFirstAcceptanceScriptUsesATemplateAndAGuard() throws {
        let directory = TicketDirectory.sample(now: Date(timeIntervalSince1970: 1_791_108_000))
        let vocabulary = TicketVocabulary.make(directory: directory)
        let document = try AcceptanceDocument.load()
        XCTAssertEqual(Validator.validate(document, vocabulary: vocabulary), [])
        let tree = LayoutEngine(vocabulary: vocabulary, document: document, metrics: .fixed()).layout(document.scripts[0])
        let message = try XCTUnwrap(tree.allBlocks.first { $0.id == "message" })
        XCTAssertEqual(message.kind, BuiltIn.text)
        XCTAssertEqual(message.slots.map(\.content), [.field("Escalated: {title} ({priority})")])
        let refuse = try XCTUnwrap(tree.allBlocks.first { $0.id == "refuse" })
        XCTAssertEqual(refuse.shape, .cap)
        XCTAssertEqual(refuse.slots.map(\.content), [.field("Ticket {ticket} has no title")])
    }
}
