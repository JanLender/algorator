import XCTest
import SwiftUI
import AlgoratorCore
import TicketDemo
@testable import AlgoratorEditor

/// Renders PNGs into `Snapshots/` at the repository root, headless, through the same `BlockRenderer` the
/// editor uses. They are meant to be looked at; the assertions only check that something was drawn.
@MainActor
final class SnapshotTests: XCTestCase {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Snapshots")

    private let directory = TicketDirectory.sample(now: Date(timeIntervalSince1970: 1_791_108_000))
    private lazy var vocabulary = TicketVocabulary.make(directory: directory)

    private func engine(_ document: Document) -> LayoutEngine {
        LayoutEngine(vocabulary: vocabulary, document: document, references: directory,
                     timeZone: TimeZone(identifier: "Europe/Prague")!)
    }

    private func write(_ name: String, size: CGSize, scheme: ColorScheme = .light,
                       draw: @escaping (inout GraphicsContext) -> Void) throws {
        let background = scheme == .dark ? Color(white: 0.12) : Color(white: 0.98)
        let view = Canvas { context, _ in draw(&context) }
            .frame(width: size.width, height: size.height)
            .background(background)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "nothing rendered for \(name)")
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try png.write(to: Self.folder.appendingPathComponent("\(name).png"))
        XCTAssertGreaterThan(png.count, 2_000, "\(name) looks empty")
    }

    private func snapshot(_ name: String, _ script: Script, in document: Document, scheme: ColorScheme = .light) throws {
        let tree = engine(document).layout(script)
        let issues = BlockRenderer.worstIssues(Validator.validate(script, in: document, vocabulary: vocabulary))
        try write(name, size: tree.size, scheme: scheme) { BlockRenderer(issues: issues).draw(tree, in: &$0) }
    }

    func testAcceptanceScripts() throws {
        let document = try AcceptanceDocument.load()
        try snapshot("escalate-ticket", document.scripts[0], in: document)
        try snapshot("escalate-ticket-dark", document.scripts[0], in: document, scheme: .dark)
        try snapshot("escalate-all-clear", document.scripts[1], in: document)
    }

    func testPalettes() throws {
        let document = try AcceptanceDocument.load()
        for category in vocabulary.categories {
            let palette = engine(document).palette(category: category.id, for: document.scripts[0])
            try write("palette-\(category.id)", size: palette.size) { BlockRenderer().draw(palette, in: &$0) }
        }
    }

    /// A drag in progress, as the editor composes it: the remaining script, the drop indicator, the ghost.
    func testDragging() throws {
        let document = try AcceptanceDocument.load()
        let controller = DragController(engine: engine(document))
        let tree = engine(document).layout(document.scripts[0])
        let size = CGSize(width: tree.size.width + 60, height: tree.size.height)

        // "add label" and the return beneath it, lifted and about to snap back under "notify".
        let label = try XCTUnwrap(tree.allBlocks.first { $0.id == "label" })
        var stack = try XCTUnwrap(controller.begin(at: CGPoint(x: label.frame.minX + 8, y: label.frame.minY + 8),
                                                   in: document.scripts[0]))
        stack = controller.move(stack, to: CGPoint(x: label.frame.minX + 44, y: label.frame.minY + 24))
        XCTAssertEqual(stack.target, .region(owner: "decide", name: "then", index: 1))
        try write("drag-stack", size: size) { context in
            BlockRenderer().draw(stack.tree, in: &context)
            if let indicator = stack.indicator { BlockRenderer().draw(indicator, in: &context) }
            BlockRenderer().draw(ghost: stack.ghost, at: stack.ghostOrigin, in: &context)
        }

        // The "join" reporter, hovering over the literal "escalated".
        let join = try XCTUnwrap(tree.allBlocks.first { $0.id == "message" })
        var reporter = try XCTUnwrap(controller.begin(at: CGPoint(x: join.frame.minX + 12, y: join.frame.midY),
                                                      in: document.scripts[0]))
        let literal = try XCTUnwrap(reporter.tree.allBlocks.first { $0.id == "label" }?.slots.first)
        reporter = controller.move(reporter, to: CGPoint(x: literal.frame.midX, y: literal.frame.midY))
        XCTAssertEqual(reporter.target, .slot(blockID: "label", name: "label"))
        try write("drag-reporter", size: size) { context in
            BlockRenderer().draw(reporter.tree, in: &context)
            if let indicator = reporter.indicator { BlockRenderer().draw(indicator, in: &context) }
            BlockRenderer().draw(ghost: reporter.ghost, at: reporter.ghostOrigin, in: &context)
        }
    }

    /// Every shape and slot state in one picture, including broken and invalid blocks.
    func testShapesAndStates() throws {
        func rep(_ kind: String, _ inputs: [String: Input] = [:]) -> Input { .reporter(Block(kind: kind, inputs: inputs)) }
        let truth = rep("operator.equals", ["a": .literal("a"), "b": .literal("a")])
        let script = Script(id: "shapes", name: "Shapes and states",
                            parameters: [Param(name: "ticket", type: .reference, referenceKind: "ticket"),
                                         Param(name: "count", type: .number)],
                            outputs: [Param(name: "done", type: .bool), Param(name: "reason", type: .text)],
                            body: [
            Block(kind: BuiltIn.set, inputs: ["name": .literal("total"), "value": rep("operator.add", [
                "a": .variable("count"), "b": rep("operator.multiply", ["a": .literal(2), "b": .literal(3.5)])])]),
            Block(kind: BuiltIn.set, inputs: ["value": .literal("a literal that is far too long to be shown in full on a block")]),
            Block(kind: "ticket.notify", inputs: ["user": .literal(.reference(Reference(kind: "user", id: "alice"))),
                                                  "message": .literal("")]),
            Block(kind: "ticket.notify"),
            Block(kind: "ticket.fetch", inputs: ["ticket": .variable("ticket")], bindings: ["title": "title", "opened": "since"]),
            Block(kind: BuiltIn.if, inputs: [:], regions: ["then": []]),
            Block(kind: BuiltIn.if, inputs: ["condition": rep("operator.not", ["a": rep("operator.and", ["a": truth])])], regions: ["then": [
                Block(kind: BuiltIn.ifElse, inputs: ["condition": rep("ticket.isOverdue", ["ticket": .variable("ticket")])], regions: [
                    "then": [Block(kind: "ticket.addLabel", inputs: ["label": .literal("late"), "ticket": .variable("ticket")])],
                    "else": [],
                ]),
                Block(kind: BuiltIn.set, inputs: ["name": .literal("when"), "value": rep("time.makeTimestamp", [
                    "date": .literal(.date(LocalDate(iso: "2026-10-04")!)), "time": .literal(.time(LocalTime(iso: "09:30")!))])]),
            ]]),
            Block(kind: BuiltIn.set, inputs: ["name": .literal("n"), "value": rep("list.length", [:])]),
            Block(kind: "vendor.removed", inputs: ["x": .literal("kept")]),
            Block(kind: BuiltIn.set, inputs: ["name": .literal("x"), "value": rep("vendor.gone")]),
            Block(kind: "vendor.loop", regions: ["body": [Block(kind: BuiltIn.set, inputs: ["name": .literal("i"), "value": .variable("undefined")])]]),
            Block(kind: BuiltIn.call, inputs: ["script": .literal("escalate-ticket"), "arg.ticket": .variable("ticket")],
                  bindings: ["escalated": "escalated"]),
            Block(kind: BuiltIn.return, inputs: ["done": .literal(true), "reason": rep("operator.join", ["a": .literal("x"), "b": .variable("title")])]),
        ])
        var document = try AcceptanceDocument.load()
        document.scripts.append(script)
        try snapshot("shapes", script, in: document)
        try snapshot("shapes-dark", script, in: document, scheme: .dark)
    }
}
