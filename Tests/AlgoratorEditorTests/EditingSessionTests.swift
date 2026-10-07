import XCTest
import AlgoratorCore
import TicketDemo
@testable import AlgoratorEditor

/// The M4 pieces that need no view: slot editing rules, undo, palette drags, script management.
final class EditingSessionTests: XCTestCase {
    private let controller = DragController(engine: Fixture.engine())
    private let utc = TimeZone(secondsFromGMT: 0)!
    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    // MARK: Slot editing

    func testTypedTextBecomesALiteralOfTheSlotsEditor() {
        let cases: [(String, SlotEditor, Input)] = [
            ("high", .text, .literal("high")),
            ("", .text, .literal("")),
            ("12", .text, .literal("12")),                 // a text field keeps text
            ("12", .number, .literal(12)),
            (" 2,5 ", .number, .literal(2.5)),
            ("", .number, .literal(0)),
            ("  ", .number, .literal(0)),
            ("abc", .number, .literal("abc")),             // kept, and flagged by validation
        ]
        for (text, editor, expected) in cases {
            XCTAssertEqual(SlotEditing.input(fromText: text, editor: editor), expected, "“\(text)” in \(editor)")
        }
    }

    func testEditorStartsFromTheCurrentLiteral() {
        XCTAssertEqual(SlotEditing.text(of: .literal("high")), "high")
        XCTAssertEqual(SlotEditing.text(of: .literal(2.5)), "2.5")
        XCTAssertEqual(SlotEditing.text(of: .literal(3)), "3")
        XCTAssertEqual(SlotEditing.text(of: .variable("x")), "")
        XCTAssertEqual(SlotEditing.text(of: .empty), "")
        XCTAssertEqual(SlotEditing.text(of: nil), "")
    }

    func testBoolSlotsToggle() {
        XCTAssertEqual(SlotEditing.toggled(.literal(false)), .literal(true))
        XCTAssertEqual(SlotEditing.toggled(.literal(true)), .literal(false))
        XCTAssertEqual(SlotEditing.toggled(.literal("true")), .literal(false))
        XCTAssertEqual(SlotEditing.toggled(nil), .literal(true))
        XCTAssertEqual(SlotEditing.toggled(.empty), .literal(true))
    }

    func testDatePickersReadAndWriteLiterals() {
        let noon = Date(timeIntervalSince1970: 1_791_108_000)   // 2026-10-04 10:00:00Z
        XCTAssertEqual(SlotEditing.input(from: noon.addingTimeInterval(42), editor: .timestamp, timeZone: utc), .literal(.timestamp(noon)),
                       "whole minutes")
        XCTAssertEqual(SlotEditing.input(from: noon, editor: .date, timeZone: utc), .literal(.date(LocalDate(iso: "2026-10-04")!)))
        XCTAssertEqual(SlotEditing.input(from: noon.addingTimeInterval(42), editor: .time, timeZone: utc),
                       .literal(.time(LocalTime(iso: "10:00")!)))

        XCTAssertEqual(SlotEditing.date(of: .literal(.timestamp(noon)), now: .distantPast, timeZone: utc), noon)
        XCTAssertEqual(SlotEditing.date(of: .literal(.date(LocalDate(iso: "2026-10-04")!)), now: .distantPast, timeZone: utc),
                       noon.addingTimeInterval(-10 * 3600))
        XCTAssertEqual(SlotEditing.date(of: .literal(.time(LocalTime(iso: "10:00")!)), now: noon.addingTimeInterval(500), timeZone: utc),
                       noon, "a time is shown on today's date")
        XCTAssertEqual(SlotEditing.date(of: nil, now: noon, timeZone: utc), noon)
        XCTAssertEqual(SlotEditing.date(of: .literal("nonsense"), now: noon, timeZone: utc), noon)
    }

    // MARK: Undo and redo

    /// Every kind of edit, applied through the bridge, then undone and redone.
    @MainActor
    func testUndoAndRedoRoundTripForEachEdit() throws {
        let stack = Fixture.stack, slots = Fixture.slots
        let bound = Script(id: "s", name: "Main", body: [Block(id: "o", kind: "t.one", bindings: ["r": "r"])])
        var renamed = stack
        renamed.name = "Renamed"
        renamed.parameters = [Param(name: "p", type: .number)]
        let edits: [(String, Document, Document)] = [
            ("insert", Document(scripts: [stack]),
             Document(scripts: [try XCTUnwrap(stack.inserting(.stack([Fixture.say("n")]), at: .region(owner: "b2", name: "else", index: 0)))])),
            ("move", Document(scripts: [stack]),
             Document(scripts: [try XCTUnwrap(stack.moving(blockID: "b3", to: .region(owner: nil, name: "body", index: 0)))])),
            ("remove", Document(scripts: [stack]), Document(scripts: [try XCTUnwrap(stack.removing(blockID: "b2")).script])),
            ("delete", Document(scripts: [stack]), Document(scripts: [try XCTUnwrap(stack.deleting(blockID: "b1"))])),
            ("setInput", Document(scripts: [stack]),
             Document(scripts: [try XCTUnwrap(stack.settingInput(blockID: "b1", name: "text", to: .literal("new")))])),
            ("reporter into slot", Document(scripts: [slots]),
             Document(scripts: [try XCTUnwrap(slots.moving(blockID: "join", to: .slot(blockID: "eq", name: "b")))])),
            ("remove variable", Document(scripts: [slots]),
             Document(scripts: [try XCTUnwrap(slots.removingVariable(blockID: "join", slot: "b")).script])),
            ("setBinding", Document(scripts: [bound]),
             Document(scripts: [try XCTUnwrap(bound.settingBinding(blockID: "o", output: "r", to: "other"))])),
            ("edit script", Document(scripts: [stack]), Document(scripts: [renamed])),
            ("add script", Document(scripts: [stack]), Document(scripts: [stack]).addingScript(id: "new")),
            ("remove script", Document(scripts: [stack, bound]), Document(scripts: [stack, bound]).removingScript(id: "s")),
        ]
        for (name, before, after) in edits {
            XCTAssertNotEqual(before, after, "\(name) changed nothing")
            var document = before
            let bridge = UndoBridge()
            bridge.write = { document = $0 }
            let manager = UndoManager()
            manager.groupsByEvent = false

            manager.beginUndoGrouping()
            bridge.commit(from: document, to: after, name: name, undoManager: manager)
            manager.endUndoGrouping()
            XCTAssertEqual(document, after, name)
            XCTAssertTrue(manager.canUndo, name)
            XCTAssertEqual(manager.undoActionName, name)

            manager.undo()
            XCTAssertEqual(document, before, "undo \(name)")
            XCTAssertTrue(manager.canRedo, name)

            manager.redo()
            XCTAssertEqual(document, after, "redo \(name)")

            manager.undo()
            XCTAssertEqual(document, before, "undo \(name) again")
        }
    }

    @MainActor
    func testSeveralEditsUndoInReverseOrder() {
        let first = Document(scripts: [Fixture.stack])
        let second = first.addingScript(id: "a")
        let third = second.addingScript(id: "b")
        var document = first
        let bridge = UndoBridge()
        bridge.write = { document = $0 }
        let manager = UndoManager()
        manager.groupsByEvent = false
        for next in [second, third] {
            manager.beginUndoGrouping()
            bridge.commit(from: document, to: next, name: "New Script", undoManager: manager)
            manager.endUndoGrouping()
        }
        XCTAssertEqual(document, third)
        manager.undo()
        XCTAssertEqual(document, second)
        manager.undo()
        XCTAssertEqual(document, first)
        XCTAssertFalse(manager.canUndo)
        manager.redo()
        manager.redo()
        XCTAssertEqual(document, third)
    }

    @MainActor
    func testAnEditThatChangesNothingIsNotRecorded() {
        var writes = 0
        let bridge = UndoBridge()
        bridge.write = { _ in writes += 1 }
        let manager = UndoManager()
        let document = Document(scripts: [Fixture.stack])
        bridge.commit(from: document, to: document, name: "Nothing", undoManager: manager)
        XCTAssertEqual(writes, 0)
        XCTAssertFalse(manager.canUndo)

        // Without an undo manager the edit still applies.
        bridge.commit(from: document, to: Document(), name: "Clear", undoManager: nil)
        XCTAssertEqual(writes, 1)
    }

    // MARK: Palette → canvas

    func testPickingInThePalette() {
        let palette = Fixture.engine([Fixture.open]).palette(category: "t", for: Fixture.open)
        XCTAssertEqual(palette.items.map(\.layout.frame.minY), [16, 60, 104, 148, 192, 230])
        XCTAssertEqual(HitTest.pick(at: point(20, 20), in: palette)?.layout.kind, "t.say")
        XCTAssertEqual(HitTest.pick(at: point(20, 70), in: palette)?.layout.kind, "t.stop")
        XCTAssertEqual(HitTest.pick(at: point(24, 240), in: palette)?.layout.kind, "t.it")
        XCTAssertNil(HitTest.pick(at: point(20, 52), in: palette), "the gap between two prototypes")
        XCTAssertNil(HitTest.pick(at: point(250, 20), in: palette))
    }

    func testDraggingAStatementFromThePalette() throws {
        let palette = Fixture.engine([Fixture.open]).palette(category: "t", for: Fixture.open)
        let item = try XCTUnwrap(HitTest.pick(at: point(20, 20), in: palette))
        var state = controller.begin(item, into: Fixture.open, grabOffset: CGSize(width: 4, height: 4), at: point(-200, 30))
        XCTAssertTrue(state.isNew)
        XCTAssertNil(state.target, "still over the palette")
        XCTAssertEqual(state.remaining, Fixture.open)
        guard case .stack(let blocks) = state.item.payload else { return XCTFail("not a stack") }
        XCTAssertEqual(blocks.map(\.kind), ["t.say"])
        XCTAssertFalse(blocks[0].id.hasPrefix("palette:"), "the copy has an id of its own")
        XCTAssertEqual(blocks[0].inputs, ["text": .literal("")])

        state = controller.move(state, to: point(34, 186))   // ghost corner at the "else" mouth
        XCTAssertEqual(state.target, .region(owner: "b2", name: "else", index: 0))
        let script = try XCTUnwrap(controller.drop(state))
        XCTAssertEqual(script.block(id: "b2")?.regions["else"], blocks)
        XCTAssertNil(controller.discard(state), "abandoning a fresh block changes nothing")

        // Two drags of the same prototype give two different blocks.
        let again = controller.begin(item, into: script, grabOffset: .zero, at: point(0, 0))
        XCTAssertNotEqual(again.item.payload, state.item.payload)
    }

    func testDraggingReportersAndVariablesFromThePalette() throws {
        let script = Fixture.slots
        let engine = Fixture.engine([script])
        let me = try XCTUnwrap(engine.palette(category: "t", for: script).items.first { $0.layout.kind == "t.me" })
        var state = DragController(engine: engine).begin(me, into: script, grabOffset: .zero, at: point(94, 222))
        XCTAssertEqual(state.target, .slot(blockID: "greet", name: "who"))
        guard case .reporter(let block) = state.item.payload else { return XCTFail("not a reporter") }
        XCTAssertEqual(try XCTUnwrap(DragController(engine: engine).drop(state)).block(id: "greet")?.inputs["who"], .reporter(block))
        state = DragController(engine: engine).move(state, to: point(61, 156))
        XCTAssertNil(state.target, "a reporter does not fit the hexagon")

        // The variables tab offers the script's variables as chips.
        let variables = engine.palette(category: "variables", for: script)
        XCTAssertEqual(variables.items.map(\.source).dropFirst(), [.variable("p")])
        let chip = try XCTUnwrap(variables.items.last)
        let dragged = DragController(engine: engine).begin(chip, into: script, grabOffset: .zero, at: point(94, 222))
        XCTAssertEqual(dragged.item, DraggedItem(payload: .variable("p"), type: .reference, referenceKind: "user"))
        XCTAssertEqual(try XCTUnwrap(DragController(engine: engine).drop(dragged)).block(id: "greet")?.inputs["who"], .variable("p"))
    }

    func testDroppingOnThePaletteDeletesWhatWasTakenFromTheScript() throws {
        let state = try XCTUnwrap(controller.begin(at: point(40, 130), in: Fixture.stack))
        XCTAssertFalse(state.isNew)
        let script = try XCTUnwrap(controller.discard(state))
        XCTAssertNil(script.block(id: "b3"))
        XCTAssertEqual(script.body.map(\.id), ["b1", "b2", "b4"])

        let copied = try XCTUnwrap(controller.begin(at: point(65, 45), in: Fixture.slots))
        XCTAssertTrue(copied.isNew, "a parameter chip is copied")
        XCTAssertNil(controller.discard(copied))
    }

    func testFreshIDsReachEveryNestedBlock() {
        let original = Fixture.slots.body[0]
        let copy = original.withFreshIDs()
        let before = Set(Script(name: "a", body: [original]).allBlockIDs)
        let after = Set(Script(name: "b", body: [copy]).allBlockIDs)
        XCTAssertEqual(before, ["if", "eq", "join"])
        XCTAssertEqual(after.count, 3)
        XCTAssertTrue(before.isDisjoint(with: after))
        XCTAssertEqual(copy.kind, original.kind)
    }

    // MARK: Scripts

    func testAddingAndRemovingScripts() {
        var document = Document().addingScript(id: "a")
        XCTAssertEqual(document.scripts, [Script(id: "a", name: "Script 1")])
        document = document.addingScript(id: "b")
        XCTAssertEqual(document.scripts.map(\.name), ["Script 1", "Script 2"])
        document = document.removingScript(id: "a").addingScript(id: "c")
        XCTAssertEqual(document.scripts.map(\.name), ["Script 2", "Script 3"], "names do not clash")
        XCTAssertEqual(document.removingScript(id: "nope"), document)
    }

    func testReferenceKindsComeFromTheVocabulary() {
        XCTAssertEqual(Fixture.vocabulary.referenceKinds, ["ticket", "user"])
        XCTAssertEqual(TicketVocabulary.make(directory: .sample(now: Date())).referenceKinds, ["ticket", "user"])
        XCTAssertEqual(Vocabulary().referenceKinds, [])
    }

    // MARK: Acceptance: both scripts built from an empty document, with editor operations only

    func testAcceptanceScriptsCanBeBuiltFromAnEmptyDocument() throws {
        let directory = TicketDirectory.sample(now: Date(timeIntervalSince1970: 1_791_108_000))
        let vocabulary = TicketVocabulary.make(directory: directory)
        var document = Document().addingScript(id: "escalate-ticket").addingScript(id: "escalate-all-clear")
            .addingScript(id: "escalate-with-details")

        // What "Edit Script…" does.
        document.scripts[0].name = "Escalate ticket"
        document.scripts[0].parameters = [Param(name: "ticket", type: .reference, referenceKind: "ticket")]
        document.scripts[0].outputs = [Param(name: "escalated", type: .bool)]
        document.scripts[1].name = "Escalate all-clear"
        document.scripts[1].parameters = [Param(name: "ticket", type: .reference, referenceKind: "ticket")]
        document.scripts[2].name = "Escalate with details"
        document.scripts[2].parameters = [Param(name: "ticket", type: .reference, referenceKind: "ticket")]
        document.scripts[2].outputs = [Param(name: "escalated", type: .bool)]

        /// One drag from the palette, checked against the same rules the editor applies on drop.
        func drop(_ kind: String, calling callee: String? = nil, at target: DropTarget, into index: Int) throws -> String {
            let script = document.scripts[index]
            let block = BlockFactory.make(kind: kind, calling: callee, in: script, document: document, vocabulary: vocabulary)
            let isStack = vocabulary[kind]?.shape.isStack ?? true
            let item: DraggedItem = isStack ? .stack([block], vocabulary: vocabulary) : .reporter(block, vocabulary: vocabulary)
            try check(item, fits: target, in: script)
            document = document.replacing(try XCTUnwrap(script.inserting(item.payload, at: target), "\(kind) → \(target)"))
            return block.id
        }
        func chip(_ name: String, into block: String, _ slot: String, of index: Int) throws {
            let script = document.scripts[index]
            XCTAssertTrue(script.variableNames.contains(name), "no chip “\(name)” in the variables tab")
            let item = DraggedItem.variable(name, in: script, document: document, vocabulary: vocabulary)
            try check(item, fits: .slot(blockID: block, name: slot), in: script)
            document = document.replacing(try XCTUnwrap(script.inserting(item.payload, at: .slot(blockID: block, name: slot))))
        }
        func check(_ item: DraggedItem, fits target: DropTarget, in script: Script) throws {
            guard case .slot(let blockID, let name) = target else { return }
            let owner = try XCTUnwrap(script.block(id: blockID))
            let slot = try XCTUnwrap(vocabulary.signature(of: owner, in: script, document: document)?.input(name))
            XCTAssertTrue(item.fits(shape: slot.shape, editor: slot.editor), "\(item.payload) does not fit \(blockID).\(name)")
        }
        func type(_ text: String, into block: String, _ slot: String, of index: Int) throws {
            let script = document.scripts[index]
            let owner = try XCTUnwrap(script.block(id: block))
            let editor = try XCTUnwrap(vocabulary.signature(of: owner, in: script, document: document)?.input(slot)).editor
            XCTAssertTrue(editor == .text || editor == .number, "\(block).\(slot) is not typeable")
            document = document.replacing(try XCTUnwrap(script.settingInput(blockID: block, name: slot,
                                                                            to: SlotEditing.input(fromText: text, editor: editor))))
        }
        func body(_ index: Int) -> DropTarget { .region(owner: nil, name: "body", index: index) }
        func slot(_ block: String, _ name: String) -> DropTarget { .slot(blockID: block, name: name) }

        // Escalate ticket
        let fetch = try drop("ticket.fetch", at: body(0), into: 0)
        try chip("ticket", into: fetch, "ticket", of: 0)
        let guardBlock = try drop(BuiltIn.if, at: body(1), into: 0)
        let noTitle = try drop("operator.isEmpty", at: slot(guardBlock, "condition"), into: 0)
        try chip("title", into: noTitle, "value", of: 0)
        let refuse = try drop(BuiltIn.fail, at: .region(owner: guardBlock, name: "then", index: 0), into: 0)
        try type("The ticket has no title", into: refuse, "message", of: 0)
        let decide = try drop(BuiltIn.ifElse, at: body(2), into: 0)
        let or = try drop("operator.or", at: slot(decide, "condition"), into: 0)
        let isHigh = try drop("operator.equals", at: slot(or, "a"), into: 0)
        try chip("priority", into: isHigh, "a", of: 0)
        try type("high", into: isHigh, "b", of: 0)
        let isOld = try drop("operator.less", at: slot(or, "b"), into: 0)
        let plusTwo = try drop("time.addDays", at: slot(isOld, "a"), into: 0)
        try type("2", into: plusTwo, "amount", of: 0)
        try chip("opened", into: plusTwo, "to", of: 0)
        _ = try drop("time.now", at: slot(isOld, "b"), into: 0)
        let notify = try drop("ticket.notify", at: .region(owner: decide, name: "then", index: 0), into: 0)
        try chip("assignee", into: notify, "user", of: 0)
        let join = try drop("operator.join", at: slot(notify, "message"), into: 0)
        try type("Escalated: ", into: join, "a", of: 0)
        try chip("title", into: join, "b", of: 0)
        let label = try drop("ticket.addLabel", at: .region(owner: decide, name: "then", index: 1), into: 0)
        try type("escalated", into: label, "label", of: 0)
        try chip("ticket", into: label, "ticket", of: 0)
        let yes = try drop(BuiltIn.return, at: .region(owner: decide, name: "then", index: 2), into: 0)
        document = document.replacing(try XCTUnwrap(document.scripts[0].settingInput(
            blockID: yes, name: "escalated", to: SlotEditing.toggled(document.scripts[0].block(id: yes)?.inputs["escalated"]))))
        _ = try drop(BuiltIn.return, at: .region(owner: decide, name: "else", index: 0), into: 0)

        // Escalate all-clear
        let call = try drop(BuiltIn.call, calling: "escalate-ticket", at: body(0), into: 1)
        try chip("ticket", into: call, "arg.ticket", of: 1)
        let branch = try drop(BuiltIn.ifElse, at: body(1), into: 1)
        let was = try drop("operator.equals", at: slot(branch, "condition"), into: 1)
        try chip("escalated", into: was, "a", of: 1)
        try type("true", into: was, "b", of: 1)
        let ops = Input.literal(.reference(Reference(kind: "user", id: "ops")))   // picked in the reference popover
        for (region, message) in [("then", "A ticket was escalated"), ("else", "All clear")] {
            let tell = try drop("ticket.notify", at: .region(owner: branch, name: region, index: 0), into: 1)
            document = document.replacing(try XCTUnwrap(document.scripts[1].settingInput(blockID: tell, name: "user", to: ops)))
            try type(message, into: tell, "message", of: 1)
        }

        // Escalate with details (SPEC-maps §4): three `set entry` blocks in a row build the map.
        /// Choosing a name in the "New variable" box of a variable picker.
        func name(_ variable: String, in block: String, of index: Int) throws {
            let script = document.scripts[index]
            let owner = try XCTUnwrap(script.block(id: block))
            XCTAssertEqual(vocabulary.signature(of: owner, in: script, document: document)?.input(BuiltIn.nameInput)?.editor, .variable)
            document = document.replacing(try XCTUnwrap(script.settingInput(blockID: block, name: BuiltIn.nameInput,
                                                                            to: .literal(.text(variable)))))
        }
        let fetchDetails = try drop("ticket.fetch", at: body(0), into: 2)
        try chip("ticket", into: fetchDetails, "ticket", of: 2)
        for (index, key) in ["title", "priority", "assignee"].enumerated() {
            let entry = try drop(BuiltIn.setEntry, at: body(index + 1), into: 2)
            try type(key, into: entry, "key", of: 2)
            try name("details", in: entry, of: 2)
            try chip(key, into: entry, "value", of: 2)
        }
        let review = try drop("ticket.reviewDetails", at: body(4), into: 2)
        try chip("details", into: review, "details", of: 2)          // the map variable now has a chip
        let logDetails = try drop("ticket.logDetails", at: body(5), into: 2)
        try chip("reviewed", into: logDetails, "details", of: 2)
        let done = try drop(BuiltIn.return, at: body(6), into: 2)
        let wasReviewed = try drop("map.value", at: slot(done, "escalated"), into: 2)
        try type("reviewed", into: wasReviewed, "key", of: 2)
        try chip("reviewed", into: wasReviewed, "map", of: 2)

        // It validates, and behaves exactly like the hand-written document.
        XCTAssertEqual(Validator.validate(document, vocabulary: vocabulary), [])
        let environment = RunEnvironment(timeZone: utc, now: { Date(timeIntervalSince1970: 1_791_108_000) })
        for ticket in ["T-1", "T-2", "T-3"] {
            let arguments: [String: Value] = ["ticket": .reference(Reference(kind: "ticket", id: ticket))]
            let built = Interpreter(document: document, vocabulary: vocabulary, environment: environment)
                .run(scriptID: "escalate-all-clear", arguments: arguments)
            let reference = Interpreter(document: try AcceptanceDocument.load(), vocabulary: vocabulary, environment: environment)
                .run(scriptID: AcceptanceDocument.allClearID, arguments: arguments)
            XCTAssertEqual(built.status, reference.status, ticket)
            XCTAssertEqual(built.trace.map(\.label), reference.trace.map(\.label), ticket)
            XCTAssertTrue(built.trace.allSatisfy(\.succeeded), ticket)

            let builtDetails = Interpreter(document: document, vocabulary: vocabulary, environment: environment)
                .run(scriptID: "escalate-with-details", arguments: arguments)
            let referenceDetails = Interpreter(document: try AcceptanceDocument.load(), vocabulary: vocabulary, environment: environment)
                .run(scriptID: AcceptanceDocument.detailsID, arguments: arguments)
            XCTAssertEqual(builtDetails.status, .returned, ticket)
            XCTAssertEqual(builtDetails.outputs, referenceDetails.outputs, ticket)
            XCTAssertEqual(builtDetails.trace.map(\.label), referenceDetails.trace.map(\.label), ticket)
            XCTAssertEqual(builtDetails.trace.count, 7, ticket)
        }
    }
}

private extension Script {
    var allBlockIDs: [String] {
        func ids(_ block: Block) -> [String] {
            [block.id]
                + block.inputs.values.flatMap { input -> [String] in
                    if case .reporter(let reporter) = input { return ids(reporter) } else { return [] }
                }
                + block.regions.values.flatMap { $0.flatMap(ids) }
        }
        return body.flatMap(ids)
    }
}
