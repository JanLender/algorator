import XCTest
import AlgoratorCore
@testable import AlgoratorEditor

/// The whole drag pipeline without a view: pick up at a point, move the pointer, drop.
final class DragControllerTests: XCTestCase {
    private let controller = DragController(engine: Fixture.engine())
    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
    private func ids(_ blocks: [Block]?) -> [String] { (blocks ?? []).map(\.id) }

    /// Moves the pointer so that the ghost's top-left corner is at `origin`.
    private func moved(_ state: DragState, ghostAt origin: CGPoint) -> DragState {
        controller.move(state, to: CGPoint(x: origin.x + state.grabOffset.width, y: origin.y + state.grabOffset.height))
    }

    func testPickingUpAStatementCarriesTheOnesBeneath() throws {
        let state = try XCTUnwrap(controller.begin(at: point(20, 70), in: Fixture.stack))
        XCTAssertEqual(state.item.payload, .stack(Fixture.stack.body))
        XCTAssertTrue(state.item.endsWithCap)
        XCTAssertEqual(state.remaining.body, [])
        XCTAssertEqual(state.grabOffset, CGSize(width: 4, height: 8))
        XCTAssertEqual(state.ghostOrigin, point(16, 62))
        XCTAssertEqual(state.ghost.map(\.id), ["b1", "b2", "b4"])
        XCTAssertEqual(state.ghost.map(\.frame.origin), [point(0, 0), point(0, 32), point(0, 154)], "laid out from the origin")
        XCTAssertEqual(state.tree.body.blocks, [], "the canvas shows the script without them")
    }

    func testNothingToPickUp() {
        XCTAssertNil(controller.begin(at: point(500, 500), in: Fixture.stack), "empty canvas")
        XCTAssertNil(controller.begin(at: point(60, 75), in: Fixture.stack), "a literal is edited, not dragged")
        XCTAssertNil(controller.begin(at: point(30, 45), in: Fixture.stack), "the entry block stays put")
    }

    func testMovingAStatementOutOfAMouth() throws {
        var state = try XCTUnwrap(controller.begin(at: point(40, 130), in: Fixture.stack))
        XCTAssertEqual(state.item.payload, .stack([Fixture.say("b3", "a")]))
        XCTAssertEqual(state.target, .region(owner: "b2", name: "then", index: 0), "released at once, it goes back")
        XCTAssertEqual(controller.drop(state), Fixture.stack)

        state = moved(state, ghostAt: point(16, 94))
        XCTAssertEqual(state.target, .region(owner: nil, name: "body", index: 1))
        XCTAssertEqual(state.indicator, .insertion(CGRect(x: 16, y: 92, width: 71, height: 4)))
        let script = try XCTUnwrap(controller.drop(state))
        XCTAssertEqual(ids(script.body), ["b1", "b3", "b2", "b4"])
        XCTAssertEqual(script.block(id: "b2")?.regions["then"], [])
    }

    func testDroppingNowhereCancels() throws {
        var state = try XCTUnwrap(controller.begin(at: point(40, 130), in: Fixture.stack))
        state = moved(state, ghostAt: point(600, 30))
        XCTAssertNil(state.target)
        XCTAssertNil(state.indicator)
        XCTAssertNil(controller.drop(state), "the caller keeps the script it had")
    }

    func testTargetsAreComputedWithoutTheDraggedBlocks() throws {
        // Dragging b2 (with the cap beneath it) leaves only b1; the stack ends in a cap, so it fits only at the end.
        var state = try XCTUnwrap(controller.begin(at: point(20, 100), in: Fixture.stack))
        XCTAssertEqual(ids(state.remaining.body), ["b1"])
        state = moved(state, ghostAt: point(16, 62))
        XCTAssertNil(state.target, "b1 would follow the cap")
        state = moved(state, ghostAt: point(16, 200))
        XCTAssertEqual(state.target, .region(owner: nil, name: "body", index: 1))
        XCTAssertEqual(controller.drop(state), Fixture.stack)
    }

    func testMovingTheCapIntoTheEmptyMouth() throws {
        var state = try XCTUnwrap(controller.begin(at: point(20, 230), in: Fixture.stack))
        state = moved(state, ghostAt: point(30, 182))
        XCTAssertEqual(state.target, .region(owner: "b2", name: "else", index: 0))
        let script = try XCTUnwrap(controller.drop(state))
        XCTAssertEqual(ids(script.body), ["b1", "b2"])
        XCTAssertEqual(ids(script.block(id: "b2")?.regions["else"]), ["b4"])
    }

    func testMovingAReporterBetweenSlots() throws {
        // Pick the join up by its label; the slot it leaves gets its default literal back.
        var state = try XCTUnwrap(controller.begin(at: point(70, 84), in: Fixture.slots))
        guard case .reporter(let join) = state.item.payload else { return XCTFail("not a reporter") }
        XCTAssertEqual(join.id, "join")
        XCTAssertEqual(state.remaining.block(id: "eq")?.inputs["a"], .literal(""))
        XCTAssertEqual(state.ghost.map(\.frame), [CGRect(x: 0, y: 0, width: 104, height: 26)])

        // Reporters go where the pointer is. Over the hexagonal hole: refused.
        let hole = try XCTUnwrap(state.tree.allBlocks.first { $0.id == "if2" }?.slots.first)
        state = controller.move(state, to: point(hole.frame.midX, hole.frame.midY))
        XCTAssertNil(state.target)

        // Over the literal "1" (which has moved left, now that the join is gone).
        let literal = try XCTUnwrap(state.tree.allBlocks.first { $0.id == "eq" }?.slots.last)
        XCTAssertEqual(literal.frame, CGRect(x: 101, y: 71, width: 24, height: 20))
        state = controller.move(state, to: point(literal.frame.midX, literal.frame.midY))
        XCTAssertEqual(state.target, .slot(blockID: "eq", name: "b"))
        XCTAssertEqual(state.indicator, .slot(literal))
        let script = try XCTUnwrap(controller.drop(state))
        XCTAssertEqual(script.block(id: "eq")?.inputs, ["a": .literal(""), "b": .reporter(join)])
    }

    func testMovingAVariableChip() throws {
        var state = try XCTUnwrap(controller.begin(at: point(142, 84), in: Fixture.slots))
        XCTAssertEqual(state.item.payload, .variable("x"))
        XCTAssertEqual(state.remaining.block(id: "join")?.inputs["b"], .literal(""))
        XCTAssertEqual(state.ghost.first?.kind, LayoutEngine.variableChipKind)

        let who = try XCTUnwrap(state.tree.allBlocks.first { $0.id == "greet" }?.slots.first)
        state = controller.move(state, to: point(who.frame.midX, who.frame.midY))
        XCTAssertEqual(state.target, .slot(blockID: "greet", name: "who"), "x has no known type, so the reference slot takes it")
        XCTAssertEqual(try XCTUnwrap(controller.drop(state)).block(id: "greet")?.inputs["who"], .variable("x"))
    }

    func testDraggingAParameterChipCopiesIt() throws {
        var state = try XCTUnwrap(controller.begin(at: point(65, 45), in: Fixture.slots))
        XCTAssertEqual(state.item, DraggedItem(payload: .variable("p"), type: .reference, referenceKind: "user"))
        XCTAssertEqual(state.remaining, Fixture.slots, "nothing is removed")

        state = controller.move(state, to: point(94, 222))
        XCTAssertEqual(state.target, .slot(blockID: "greet", name: "who"))
        XCTAssertEqual(try XCTUnwrap(controller.drop(state)).block(id: "greet")?.inputs["who"], .variable("p"))
    }

    func testDraggingAFreshBlockIn() throws {
        let fresh = DraggedItem.stack([Fixture.say("new")], vocabulary: Fixture.vocabulary)
        var state = controller.begin(fresh, remaining: Fixture.open, in: Fixture.open, grabOffset: CGSize(width: 5, height: 5),
                                     at: point(700, 20))
        XCTAssertNil(state.target)
        state = moved(state, ghostAt: point(30, 182))
        XCTAssertEqual(state.target, .region(owner: "b2", name: "else", index: 0))
        XCTAssertEqual(ids(try XCTUnwrap(controller.drop(state)).block(id: "b2")?.regions["else"]), ["new"])
    }

    func testMoveIsAPureFunction() throws {
        let state = try XCTUnwrap(controller.begin(at: point(40, 130), in: Fixture.stack))
        XCTAssertEqual(controller.move(state, to: point(100, 100)), controller.move(state, to: point(100, 100)))
        XCTAssertEqual(controller.move(controller.move(state, to: point(300, 300)), to: state.pointer), state)
    }
}
