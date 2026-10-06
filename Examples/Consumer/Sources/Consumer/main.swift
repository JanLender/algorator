import SwiftUI
import os
import AlgoratorCore
import AlgoratorEditor

// 1. The host registers its own blocks, with native handlers. A handler is `@Sendable` (it runs on whatever
//    thread runs the interpreter), so the state it writes to is behind a lock.
let greetings = OSAllocatedUnfairLock(initialState: [String]())
let category = BlockCategory(id: "greeter", title: "Greeter", color: BlockColor(hex: 0x4C97FF))
let vocabulary = Vocabulary([
    .statement("greeter.greet", category: category, title: "greet %name", inputs: [.value("name", .text)]) { inputs, context in
        greetings.withLock { $0.append("Hello, \(inputs.text("name"))!") }
        context.note("greeted")
        return [:]
    },
    // One map slot instead of a variable number of slots: the handler gets the named values in order.
    .statement("greeter.announce", category: category, title: "announce %facts", inputs: [.map("facts")]) { inputs, _ in
        let facts = inputs.map("facts").entries.map { "\($0.key)=\(Coercion.toText($0.value, in: inputs.environment))" }
        greetings.withLock { $0.append(facts.joined(separator: ", ")) }
        return [:]
    },
])

// 2. A script using them and some built-ins: greet (join "Algo" "rator"), build a map, announce it, return.
let script = Script(name: "Welcome", outputs: [Param(name: "greeted", type: .bool)], body: [
    Block(kind: "greeter.greet", inputs: ["name": .reporter(
        Block(kind: "operator.join", inputs: ["a": .literal("Algo"), "b": .literal("rator")]))]),
    // Build a map entry by entry, then hand the variable to the block.
    Block(kind: BuiltIn.setEntry, inputs: ["key": .literal("library"), "name": .literal("facts"), "value": .literal("Algorator")]),
    Block(kind: BuiltIn.setEntry, inputs: ["key": .literal("blocks"), "name": .literal("facts"), "value": .literal(9)]),
    Block(kind: "greeter.announce", inputs: ["facts": .variable("facts")]),
    Block(kind: BuiltIn.return, inputs: ["greeted": .literal(true)]),
])
let document = Document(scripts: [script])

// 3. Validate, run, and round-trip through JSON — the interpreter needs AlgoratorCore only.
let issues = Validator.validate(document, vocabulary: vocabulary)
let result = Interpreter(document: document, vocabulary: vocabulary).run(scriptID: script.id)
let reloaded = try Document(json: try document.jsonData())

print("issues: \(issues.count)")
print("status: \(result.status.rawValue), outputs: \(result.outputs)")
print("trace: \(result.trace.map(\.label))")
print("greetings: \(greetings.withLock { $0 })")
print("round-trips: \(reloaded == document)")

// 4. The editor: lay the script out and embed the view. (Nothing is shown; this proves it links.)
let tree = LayoutEngine(vocabulary: vocabulary, document: document).layout(script)
print("canvas: \(Int(tree.size.width))×\(Int(tree.size.height)) for \(tree.allBlocks.count) blocks")

struct HostView: View {
    @State private var document: Document
    let vocabulary: Vocabulary

    init(document: Document, vocabulary: Vocabulary) {
        self._document = State(initialValue: document)
        self.vocabulary = vocabulary
    }

    var body: some View {
        AlgoratorEditorView(document: $document, vocabulary: vocabulary)
    }
}
_ = HostView(document: document, vocabulary: vocabulary)

guard issues.isEmpty, result.status == .returned, result.outputs["greeted"] == .bool(true),
      greetings.withLock({ $0 }) == ["Hello, Algorator!", "library=Algorator, blocks=9"], reloaded == document else {
    fatalError("the consumer example did not behave as expected")
}
print("OK")
