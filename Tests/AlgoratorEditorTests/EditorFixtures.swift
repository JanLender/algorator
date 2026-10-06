import Foundation
import AlgoratorCore
@testable import AlgoratorEditor

/// Shared scripts for the editing, hit-testing and drag tests. Frames follow from `LayoutMetrics.fixed()`
/// (every character 7×14) and are spelled out in `LayoutTests`.
enum Fixture {
    static let vocabulary: Vocabulary = {
        let category = BlockCategory(id: "t", title: "T", color: BlockColor(hex: 0x336699))
        return Vocabulary([
            .statement("t.say", category: category, title: "say %text", inputs: [.value("text", .text)]) { _, _ in [:] },
            BlockDefinition(id: "t.stop", shape: .cap, category: category, title: "stop") { _, _ in [:] },
            .statement("t.one", category: category, title: "one", outputs: [OutputDefinition("r", .text)]) { _, _ in [:] },
            .statement("t.greet", category: category, title: "greet %who", inputs: [.reference("who", kind: "user")]) { _, _ in [:] },
            .reporter("t.me", category: category, title: "me", result: .reference, referenceKind: "user") { _, _ in .empty },
            .reporter("t.it", category: category, title: "it", result: .reference, referenceKind: "ticket") { _, _ in .empty },
        ])
    }()

    static func engine(_ scripts: [Script] = []) -> LayoutEngine {
        LayoutEngine(vocabulary: vocabulary, document: Document(scripts: scripts), metrics: .fixed(),
                     timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    static func say(_ id: String, _ text: String = "hi") -> Block {
        Block(id: id, kind: "t.say", inputs: ["text": .literal(.text(text))])
    }

    /// ```
    /// b1  say "hi"            (16, 62, 75, 32)
    /// b2  if ◇ then           (16, 94, 110, 122)   header to y 126
    ///       b3 say "a"        (30, 126, 71, 32)    "then" mouth
    ///     else                divider y 158…182
    ///       (empty)           (30, 182, 96, 20)    "else" mouth
    ///                         footer y 202…216
    /// b4  stop                (16, 216, 56, 32)    a cap
    /// ```
    static let stack = Script(id: "s", name: "Main", body: [
        say("b1"),
        Block(id: "b2", kind: BuiltIn.ifElse, regions: ["then": [say("b3", "a")], "else": []]),
        Block(id: "b4", kind: "t.stop"),
    ])

    /// The same without the cap, so the body can be appended to (body ends at y 216).
    static let open = Script(id: "s", name: "Main", body: Array(stack.body.dropLast()))

    /// ```
    /// if   if ⟨(join "a" (x)) = "1"⟩ then    (16, 62, 245, 78)
    ///        eq    predicate                  (46, 68, 171, 32)   slot b "1": (181, 74, 24, 20)
    ///        join  reporter in eq.a           (58, 71, 104, 26)   slots a: (100, 74, 24, 20), b (chip x): (130, 74, 24, 20)
    /// if2  if ◇ then                          (16, 140, 110, 66)  hole: (46, 146, 30, 20)
    /// greet  greet [user ▾]                   (16, 206, 115, 32)  slot who: (67, 212, 54, 20)
    /// ```
    static let slots = Script(id: "s", name: "Main", parameters: [Param(name: "p", type: .reference, referenceKind: "user")], body: [
        Block(id: "if", kind: BuiltIn.if, inputs: ["condition": .reporter(
            Block(id: "eq", kind: "operator.equals", inputs: [
                "a": .reporter(Block(id: "join", kind: "operator.join", inputs: ["a": .literal("a"), "b": .variable("x")])),
                "b": .literal("1"),
            ]))], regions: ["then": []]),
        Block(id: "if2", kind: BuiltIn.if, regions: ["then": []]),
        Block(id: "greet", kind: "t.greet"),
    ])

    static let statement = DraggedItem.stack([say("new")], vocabulary: vocabulary)
    static let cap = DraggedItem.stack([say("new"), Block(id: "end", kind: "t.stop")], vocabulary: vocabulary)
    static let reporter = DraggedItem.reporter(Block(id: "r", kind: "operator.join"), vocabulary: vocabulary)
    static let predicate = DraggedItem.reporter(Block(id: "q", kind: "operator.not"), vocabulary: vocabulary)
    static let user = DraggedItem.reporter(Block(id: "me", kind: "t.me"), vocabulary: vocabulary)
    static let ticket = DraggedItem.reporter(Block(id: "it", kind: "t.it"), vocabulary: vocabulary)
    static let untyped = DraggedItem(payload: .variable("v"))
}
