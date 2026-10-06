import SwiftUI
import os
import AlgoratorCore
import AlgoratorEditor

/// The host's own state. A handler may capture only `Sendable` state, so this guards itself with a lock.
final class Journal: Sendable {
    private let lines = OSAllocatedUnfairLock(initialState: [String]())

    func write(_ line: String) { lines.withLock { $0.append(line) } }
    var all: [String] { lines.withLock { $0 } }
}

/// A reference picker backed by main-actor state: the editor only ever calls it on the main actor, so it
/// need not be `Sendable`.
@MainActor
final class People {
    var names = ["ada": "Ada", "bob": "Bob"]
}

struct PeopleProvider: ReferenceProvider {
    let candidatesByKind: [String: [ReferenceCandidate]]

    @MainActor
    init(people: People) {
        candidatesByKind = ["person": people.names.map { ReferenceCandidate(id: $0.key, label: $0.value) }.sorted { $0.id < $1.id }]
    }

    func candidates(kind: String, matching: String) -> [ReferenceCandidate] {
        (candidatesByKind[kind] ?? []).filter { matching.isEmpty || $0.label.localizedCaseInsensitiveContains(matching) }
    }
}

/// Shows the editor from a main-actor view.
@MainActor
struct HostView: View {
    @State var document: Document
    let vocabulary: Vocabulary
    let people: People

    var body: some View {
        AlgoratorEditorView(document: $document, vocabulary: vocabulary, references: PeopleProvider(people: people))
    }
}

func makeVocabulary(journal: Journal) -> Vocabulary {
    let category = BlockCategory(id: "journal", title: "Journal", color: BlockColor(hex: 0x4C97FF))
    return Vocabulary([
        // Captures only `journal`, which is Sendable.
        .statement("journal.write", category: category, title: "write %facts", inputs: [.map("facts")]) { inputs, context in
            journal.write(inputs.map("facts").entries.map { "\($0.key)=\(Coercion.toText($0.value, in: inputs.environment))" }.joined(separator: " "))
            context.note("written on \(Thread.isMainThread ? "the main thread" : "a background thread")")
            return [:]
        },
    ])
}

func makeDocument() -> Document {
    let helper = Script(id: "double", name: "Double", parameters: [Param(name: "n", type: .number)],
                        outputs: [Param(name: "result", type: .number)], body: [
        Block(kind: BuiltIn.return, inputs: ["result": .reporter(
            Block(kind: "operator.multiply", inputs: ["a": .variable("n"), "b": .literal(2)]))]),
    ])
    let main = Script(id: "main", name: "Main", parameters: [Param(name: "n", type: .number)],
                      outputs: [Param(name: "doubled", type: .number)], body: [
        Block(kind: BuiltIn.call, inputs: [BuiltIn.scriptInput: .literal("double"), BuiltIn.argumentPrefix + "n": .variable("n")],
              bindings: ["result": "doubled"]),
        Block(kind: BuiltIn.setEntry, inputs: ["key": .literal("n"), "name": .literal("facts"), "value": .variable("n")]),
        Block(kind: BuiltIn.setEntry, inputs: ["key": .literal("doubled"), "name": .literal("facts"), "value": .variable("doubled")]),
        Block(kind: "journal.write", inputs: ["facts": .variable("facts")]),
        Block(kind: BuiltIn.return, inputs: ["doubled": .variable("doubled")]),
    ])
    return Document(scripts: [main, helper])
}

@main
struct Consumer6 {
    static func main() async {
        let journal = Journal()
        let vocabulary = makeVocabulary(journal: journal)
        let document = makeDocument()
        precondition(Validator.validate(document, vocabulary: vocabulary).isEmpty, "the document should validate")

        // The vocabulary and the document cross the task boundary; the interpreter runs off the main thread.
        let single = await Task.detached {
            Interpreter(document: document, vocabulary: vocabulary).run(scriptID: "main", arguments: ["n": 21])
        }.value
        print("detached run: \(single.status.rawValue), doubled = \(Coercion.toText(single.outputs["doubled"] ?? .empty, in: RunEnvironment()))")
        print("  note: \(single.trace.compactMap(\.note).joined(separator: "; "))")

        // One interpreter value shared by many concurrent runs.
        let interpreter = Interpreter(document: document, vocabulary: vocabulary)
        let total = await withTaskGroup(of: Double.self) { group -> Double in
            for n in 1...20 {
                group.addTask { Coercion.toNumber(interpreter.run(scriptID: "main", arguments: ["n": .number(Double(n))]).outputs["doubled"] ?? .empty) }
            }
            var sum = 0.0
            for await doubled in group { sum += doubled }
            return sum
        }
        print("20 concurrent runs: sum of doubles = \(Int(total)), journal lines = \(journal.all.count)")

        // The editor, from the main actor. (Nothing is shown; constructing the view proves it type-checks and links.)
        let canvas = await MainActor.run { () -> CGSize in
            let people = People()
            _ = HostView(document: document, vocabulary: vocabulary, people: people).body
            return LayoutEngine(vocabulary: vocabulary, document: document).layout(document.scripts[0]).size
        }
        // Layout is a pure, Sendable function: it may also run off the main actor.
        let offMain = await Task.detached {
            LayoutEngine(vocabulary: vocabulary, document: document, metrics: .fixed()).layout(document.scripts[0]).allBlocks.count
        }.value
        print("canvas \(Int(canvas.width))×\(Int(canvas.height)); \(offMain) blocks laid out off the main actor")

        guard single.status == .returned, single.outputs["doubled"] == .number(42), total == 420, journal.all.count == 21,
              journal.all.contains("n=21 doubled=42"), single.trace.contains(where: { $0.note == "written on a background thread" }) else {
            fatalError("the Swift 6 consumer did not behave as expected")
        }
        print("OK")
    }
}
