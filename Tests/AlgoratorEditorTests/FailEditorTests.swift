import XCTest
import SwiftUI
import AlgoratorCore
@testable import AlgoratorEditor

/// `fail` in the editor: a cap like `return`, with the same geometry and the same insertion rules.
final class FailEditorTests: XCTestCase {
    private let script = Script(id: "s", name: "Main")

    func testPaletteListsTheNewBlocks() {
        let engine = Fixture.engine([script])
        XCTAssertEqual(engine.palette(category: "control", for: script).items.map(\.layout.kind),
                       [BuiltIn.if, BuiltIn.ifElse, BuiltIn.return, BuiltIn.fail, BuiltIn.call])
        XCTAssertTrue(engine.palette(category: "operators", for: script).items.map(\.layout.kind).contains("operator.formatNumber"))
        XCTAssertEqual(engine.palette(category: "time", for: script).items.map(\.layout.kind).last, "time.format")

        // Fresh blocks carry their defaults.
        XCTAssertEqual(BlockFactory.make(kind: BuiltIn.fail, in: script, document: Document(), vocabulary: Fixture.vocabulary).inputs,
                       ["message": .literal("")])
        XCTAssertEqual(BlockFactory.make(kind: "operator.formatNumber", in: script, document: Document(), vocabulary: Fixture.vocabulary).inputs,
                       ["number": .literal(0), "decimals": .literal(2)])
        XCTAssertEqual(BlockFactory.make(kind: "time.format", in: script, document: Document(), vocabulary: Fixture.vocabulary).inputs,
                       ["pattern": .literal("yyyy-MM-dd")])
    }

    func testFailHasTheGeometryOfReturn() {
        let engine = Fixture.engine()
        let fail = engine.stack(Block(id: "f", kind: BuiltIn.fail, inputs: ["message": .literal("no")]), in: script)
        let done = engine.stack(Block(id: "r", kind: BuiltIn.return), in: script)
        let statement = engine.stack(Fixture.say("s"), in: script)
        XCTAssertEqual(fail.shape, .cap)
        XCTAssertEqual(done.shape, .cap)
        // "fail with" [no]: 63 + 6 + 28 wide plus padding; one row high.
        XCTAssertEqual(fail.frame, CGRect(x: 0, y: 0, width: 117, height: 32))
        XCTAssertEqual(fail.frame.height, done.frame.height)

        // A cap's outline has a flat bottom; a statement's tab sticks out below its frame.
        let metrics = LayoutMetrics.fixed()
        XCTAssertEqual(BlockPaths.path(for: fail, metrics).boundingRect.maxY, fail.frame.maxY)
        XCTAssertEqual(BlockPaths.path(for: done, metrics).boundingRect.maxY, done.frame.maxY)
        XCTAssertEqual(BlockPaths.path(for: statement, metrics).boundingRect.maxY, statement.frame.maxY + metrics.notchDepth)
        // Both still have the notch on top (same outline at the top edge).
        XCTAssertEqual(BlockPaths.path(for: fail, metrics).boundingRect.minY, 0)
    }

    func testTheCapRulesApplyToFail() {
        let fail = DraggedItem.stack([Block(id: "f", kind: BuiltIn.fail)], vocabulary: Fixture.vocabulary)
        XCTAssertTrue(fail.endsWithCap)
        let open = Fixture.engine().layout(Fixture.open)   // b1, b2 { then: b3 | else: – }
        func target(_ x: CGFloat, _ y: CGFloat) -> DropTarget? { HitTest.dropTarget(at: CGPoint(x: x, y: y), dragged: fail, in: open) }
        XCTAssertEqual(target(16, 216), .region(owner: nil, name: "body", index: 2), "at the end of the script")
        XCTAssertEqual(target(30, 158), .region(owner: "b2", name: "then", index: 1), "at the end of a mouth")
        XCTAssertEqual(target(30, 182), .region(owner: "b2", name: "else", index: 0), "in an empty mouth")
        XCTAssertNil(target(16, 62), "not before other statements")
        XCTAssertNil(target(16, 94))

        // And nothing can be dropped after one that is already there.
        let ended = Script(id: "s", name: "Main", body: [Fixture.say("b1"), Block(id: "f", kind: BuiltIn.fail)])
        let tree = Fixture.engine().layout(ended)
        XCTAssertNil(HitTest.dropTarget(at: CGPoint(x: 16, y: 126), dragged: Fixture.statement, in: tree))
        XCTAssertEqual(HitTest.dropTarget(at: CGPoint(x: 16, y: 94), dragged: Fixture.statement, in: tree),
                       .region(owner: nil, name: "body", index: 1), "before it is fine")
    }
}
