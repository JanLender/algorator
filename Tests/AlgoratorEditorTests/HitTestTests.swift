import XCTest
import AlgoratorCore
@testable import AlgoratorEditor

/// Table-driven: a layout, a point and a dragged item give a drop target. Frames are listed in `Fixture`.
final class HitTestTests: XCTestCase {
    private let stack = Fixture.engine().layout(Fixture.stack)
    private let open = Fixture.engine().layout(Fixture.open)
    private let slots = Fixture.engine().layout(Fixture.slots)

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
    private func body(_ index: Int) -> DropTarget { .region(owner: nil, name: "body", index: index) }
    private func then(_ index: Int) -> DropTarget { .region(owner: "b2", name: "then", index: index) }
    private let elseStart = DropTarget.region(owner: "b2", name: "else", index: 0)

    // MARK: Between statements

    func testStatementInsertion() {
        let cases: [(CGFloat, CGFloat, DropTarget?)] = [
            (16, 62, body(0)),          // exactly under the entry block
            (20, 70, body(0)),          // nearest wins
            (16, 40, body(0)),          // a little above still snaps
            (16, 94, body(1)),          // between b1 and b2
            (16, 110, body(1)),
            (30, 126, then(0)),         // start of the "then" mouth
            (30, 158, then(1)),         // end of the "then" mouth
            (30, 182, elseStart),       // the empty "else" mouth
            (30, 200, elseStart),       // indented: the mouth, not after the C-block
            (16, 200, body(2)),         // at the left edge: after the C-block
            (16, 216, body(2)),         // between b2 and the cap
            (130, 94, body(1)),         // within reach to the right
            (-20, 94, body(1)),         // and a bit to the left
            (140, 94, nil),             // too far right
            (-30, 94, nil),             // too far left
            (16, 0, nil),               // too far above
            (16, 248, nil),             // nothing may follow the cap
            (16, 400, nil),
        ]
        for (x, y, expected) in cases {
            XCTAssertEqual(HitTest.dropTarget(at: point(x, y), dragged: Fixture.statement, in: stack), expected, "(\(x), \(y))")
        }
    }

    func testAppendingBelowTheScript() {
        let end = body(2)
        let cases: [(CGFloat, CGFloat, DropTarget?)] = [
            (16, 216, end), (16, 230, end), (16, 244, end),
            (16, 300, end), (200, 900, end),       // anywhere below appends
            (-30, 300, nil), (400, 300, nil),      // but not from anywhere sideways
        ]
        for (x, y, expected) in cases {
            XCTAssertEqual(HitTest.dropTarget(at: point(x, y), dragged: Fixture.statement, in: open), expected, "(\(x), \(y))")
        }
    }

    func testEmptyScriptTakesTheFirstBlock() {
        let empty = Fixture.engine().layout(Script(id: "s", name: "Main"))
        XCTAssertEqual(HitTest.dropTarget(at: point(16, 62), dragged: Fixture.statement, in: empty), body(0))
        XCTAssertEqual(HitTest.dropTarget(at: point(40, 300), dragged: Fixture.statement, in: empty), body(0))
        XCTAssertEqual(HitTest.dropTarget(at: point(40, 300), dragged: Fixture.cap, in: empty), body(0))
    }

    func testAStackEndingInACapOnlyGoesWhereNothingFollows() {
        let cases: [(CGFloat, CGFloat, DropTarget?)] = [
            (30, 158, then(1)),         // end of "then"
            (30, 140, then(1)),         // start of "then" is refused, so the end is the nearest valid place
            (30, 126, nil),             // too far from any valid place
            (30, 182, elseStart),       // an empty mouth is its own end
            (16, 62, nil), (16, 94, nil), (16, 216, nil),   // b2 or the cap would follow
            (16, 300, nil),
        ]
        for (x, y, expected) in cases {
            XCTAssertEqual(HitTest.dropTarget(at: point(x, y), dragged: Fixture.cap, in: stack), expected, "(\(x), \(y))")
        }
        XCTAssertEqual(HitTest.dropTarget(at: point(16, 216), dragged: Fixture.cap, in: open), body(2))
        XCTAssertEqual(HitTest.dropTarget(at: point(16, 94), dragged: Fixture.cap, in: open), nil)
    }

    func testStacksNeverTargetSlots() {
        // Right on the boolean hole of "if2": the stack still snaps between statements (here, into the mouth below).
        XCTAssertEqual(HitTest.dropTarget(at: point(61, 156), dragged: Fixture.statement, in: slots),
                       .region(owner: "if2", name: "then", index: 0))
    }

    // MARK: Into slots

    func testSlotTargets() {
        func slot(_ block: String, _ name: String) -> DropTarget { .slot(blockID: block, name: name) }
        let cases: [(CGFloat, CGFloat, DraggedItem, DropTarget?)] = [
            (192, 84, Fixture.reporter, slot("eq", "b")),         // onto a literal: replaces it
            (192, 84, Fixture.predicate, slot("eq", "b")),        // value slots take predicates
            (192, 84, Fixture.untyped, slot("eq", "b")),
            (112, 84, Fixture.reporter, slot("join", "a")),       // two reporters deep
            (142, 84, Fixture.reporter, slot("join", "b")),       // onto a variable chip: replaces it
            (70, 84, Fixture.reporter, nil),                      // on the reporter's own label: occupied
            (170, 84, Fixture.reporter, nil),                     // on the "=" of the predicate
            (28, 84, Fixture.reporter, nil),                      // on the statement's label
            (61, 156, Fixture.predicate, slot("if2", "condition")),
            (61, 156, Fixture.reporter, nil),                     // a hexagon takes only predicates
            (61, 156, Fixture.untyped, nil),
            (94, 222, Fixture.user, slot("greet", "who")),
            (94, 222, Fixture.ticket, nil),                       // wrong reference kind
            (94, 222, Fixture.reporter, nil),                     // text is not a user
            (94, 222, Fixture.predicate, nil),
            (94, 222, Fixture.untyped, slot("greet", "who")),     // unknown type is allowed
            (178, 71, Fixture.reporter, slot("eq", "b")),         // 3 outside the slot: still a hit
            (174, 66, Fixture.reporter, nil),                     // 7 outside: a miss
            (500, 500, Fixture.reporter, nil),
        ]
        for (x, y, item, expected) in cases {
            XCTAssertEqual(HitTest.dropTarget(at: point(x, y), dragged: item, in: slots), expected, "(\(x), \(y)) \(item.payload)")
        }
    }

    func testSlotsInsideRegionsAreTargets() {
        XCTAssertEqual(HitTest.dropTarget(at: point(70, 142), dragged: Fixture.reporter, in: stack),
                       .slot(blockID: "b3", name: "text"))
    }

    // MARK: Indicators

    func testIndicators() {
        XCTAssertEqual(HitTest.indicator(for: body(1), in: stack), .insertion(CGRect(x: 16, y: 92, width: 96, height: 4)))
        XCTAssertEqual(HitTest.indicator(for: body(3), in: stack, width: 50), .insertion(CGRect(x: 16, y: 246, width: 50, height: 4)))
        XCTAssertEqual(HitTest.indicator(for: then(1), in: stack), .insertion(CGRect(x: 30, y: 156, width: 96, height: 4)))
        XCTAssertEqual(HitTest.indicator(for: elseStart, in: stack), .insertion(CGRect(x: 30, y: 180, width: 96, height: 4)))
        XCTAssertNil(HitTest.indicator(for: body(4), in: stack))
        XCTAssertNil(HitTest.indicator(for: .region(owner: "nope", name: "then", index: 0), in: stack))

        guard case .slot(let slot)? = HitTest.indicator(for: .slot(blockID: "if2", name: "condition"), in: slots) else {
            return XCTFail("no slot indicator")
        }
        XCTAssertEqual(slot.frame, CGRect(x: 46, y: 146, width: 30, height: 20))
        XCTAssertNil(HitTest.indicator(for: .slot(blockID: "if2", name: "nope"), in: slots))
    }

    // MARK: Picking

    func testPickingInAStack() {
        func block(_ id: String, _ x: CGFloat, _ y: CGFloat) -> Pick { .block(id: id, origin: point(x, y)) }
        let cases: [(CGFloat, CGFloat, Pick?)] = [
            (20, 70, block("b1", 16, 62)),
            (20, 100, block("b2", 16, 94)),        // header
            (20, 140, block("b2", 16, 94)),        // the arm beside the "then" mouth
            (20, 165, block("b2", 16, 94)),        // the "else" divider
            (20, 210, block("b2", 16, 94)),        // footer
            (40, 130, block("b3", 30, 126)),       // a block inside the mouth
            (120, 190, nil),                       // the empty "else" mouth
            (20, 230, block("b4", 16, 216)),
            (110, 70, nil),                        // right of b1
            (500, 500, nil),
        ]
        for (x, y, expected) in cases {
            XCTAssertEqual(HitTest.pick(at: point(x, y), in: stack), expected, "(\(x), \(y))")
        }
        guard case .slot(let slot)? = HitTest.pick(at: point(60, 75), in: stack) else { return XCTFail("no slot") }
        XCTAssertEqual([slot.blockID, slot.name], ["b1", "text"])
    }

    func testPickingNestedReportersChipsAndParameters() {
        XCTAssertEqual(HitTest.pick(at: point(28, 84), in: slots), .block(id: "if", origin: point(16, 62)))
        XCTAssertEqual(HitTest.pick(at: point(170, 84), in: slots), .block(id: "eq", origin: point(46, 68)))
        XCTAssertEqual(HitTest.pick(at: point(50, 84), in: slots), .block(id: "eq", origin: point(46, 68)), "the hexagon's tip")
        XCTAssertEqual(HitTest.pick(at: point(70, 84), in: slots), .block(id: "join", origin: point(58, 71)))
        XCTAssertEqual(HitTest.pick(at: point(142, 84), in: slots),
                       .variable(blockID: "join", slot: "b", name: "x", origin: point(130, 74)))
        guard case .slot(let literal)? = HitTest.pick(at: point(192, 84), in: slots) else { return XCTFail("no slot") }
        XCTAssertEqual([literal.blockID, literal.name], ["eq", "b"])
        guard case .slot(let hole)? = HitTest.pick(at: point(61, 156), in: slots) else { return XCTFail("no hole") }
        XCTAssertEqual(hole.content, .hole)

        // The parameter chip "p" on the entry block: title "Main" is 28 wide at x 26, the chip follows at 60.
        XCTAssertEqual(HitTest.pick(at: point(65, 45), in: slots), .parameter(name: "p", origin: point(60, 36)))
        XCTAssertNil(HitTest.pick(at: point(30, 45), in: slots), "the script name is not draggable")
    }

    func testPickingABinding() {
        let script = Script(id: "s", name: "Main", body: [Block(id: "o", kind: "t.one", bindings: ["r": "r"])])
        let tree = Fixture.engine().layout(script)
        guard case .binding(let binding)? = HitTest.pick(at: point(70, 78), in: tree) else { return XCTFail("no binding") }
        XCTAssertEqual([binding.blockID, binding.output, binding.variable], ["o", "r", "r"])
    }
}
