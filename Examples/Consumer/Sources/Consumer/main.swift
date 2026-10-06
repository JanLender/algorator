import SwiftUI
import AlgoratorCore
import AlgoratorEditor

// 1. The host registers its own block, with a native handler.
var greetings: [String] = []
let category = BlockCategory(id: "greeter", title: "Greeter", color: BlockColor(hex: 0x4C97FF))
let vocabulary = Vocabulary([
    .statement("greeter.greet", category: category, title: "greet %name", inputs: [.value("name", .text)]) { inputs, context in
        greetings.append("Hello, \(inputs.text("name"))!")
        context.note("greeted")
        return [:]
    },
])

// 2. A script using it and a built-in reporter: greet (join "Algo" "rator"), return greeted = true.
let script = Script(name: "Welcome", outputs: [Param(name: "greeted", type: .bool)], body: [
    Block(kind: "greeter.greet", inputs: ["name": .reporter(
        Block(kind: "operator.join", inputs: ["a": .literal("Algo"), "b": .literal("rator")]))]),
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
print("greetings: \(greetings)")
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
      greetings == ["Hello, Algorator!"], reloaded == document else {
    fatalError("the consumer example did not behave as expected")
}
print("OK")
