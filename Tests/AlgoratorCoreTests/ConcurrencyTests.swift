import XCTest
import AlgoratorCore
import TicketDemo

/// SPEC-maps §9: the core is thread-agnostic, and its public types are `Sendable` — checked, not assumed.
final class ConcurrencyTests: XCTestCase {

    // MARK: Sendable, at compile time

    /// Compiles only if every listed type really is `Sendable`.
    func testPublicTypesAreSendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(Document.self)
        requireSendable(Script.self)
        requireSendable(Block.self)
        requireSendable(Input.self)
        requireSendable(Param.self)
        requireSendable(Value.self)
        requireSendable(ValueType.self)
        requireSendable(OrderedMap.self)
        requireSendable(OrderedMap.Entry.self)
        requireSendable(Reference.self)
        requireSendable(LocalDate.self)
        requireSendable(LocalTime.self)
        requireSendable(DocumentError.self)
        requireSendable(BlockShape.self)
        requireSendable(BlockColor.self)
        requireSendable(BlockCategory.self)
        requireSendable(SlotShape.self)
        requireSendable(SlotEditor.self)
        requireSendable(InputDefinition.self)
        requireSendable(OutputDefinition.self)
        requireSendable(TitlePart.self)
        requireSendable(BlockDefinition.self)
        requireSendable(BlockHandler.self)
        requireSendable(BlockSignature.self)
        requireSendable(Vocabulary.self)
        requireSendable(Interpreter.self)
        requireSendable(BlockInputs.self)
        requireSendable(RunContext.self)
        requireSendable(RunEnvironment.self)
        requireSendable(RunStatus.self)
        requireSendable(RunResult.self)
        requireSendable(StepOutcome.self)
        requireSendable(Issue.self)
        requireSendable(Issue.Severity.self)
        requireSendable(VariableType.self)
        requireSendable(Cancelled.self)
        requireSendable(BlockError.self)
        requireSendable(ReferenceCandidate.self)
        requireSendable(TicketDirectory.self)   // the demo's host state, behind a lock
    }

    // MARK: One interpreter, many threads

    /// A vocabulary whose handlers capture nothing mutable, so every run must give exactly the same result.
    private static let vocabulary: Vocabulary = {
        let category = BlockCategory(id: "c", title: "C", color: BlockColor(hex: 0))
        return Vocabulary([
            .statement("c.work", category: category, title: "work %n", inputs: [.value("n", .number)],
                       outputs: [OutputDefinition("square", .number)]) { inputs, context in
                context.note("squared \(inputs.text("n")) at depth \(context.depth)")
                context.note("second note")
                return ["square": .number(inputs.number("n") * inputs.number("n"))]
            },
            .reporter("c.tag", category: category, title: "tag %text", inputs: [.value("text", .text)], result: .text) { inputs, context in
                context.note("tagged")
                return .text("<" + inputs.text("text") + ">")
            },
        ])
    }()

    /// `main(n)` calls `helper(n)` (which works, builds a map and returns it), then branches and returns.
    private static let document: Document = {
        let helper = Script(id: "helper", name: "Helper", parameters: [Param(name: "n", type: .number)],
                            outputs: [Param(name: "facts", type: .map)], body: [
            stmt("h-work", "c.work", ["n": variable("n")], bindings: ["square": "square"]),
            stmt("h-entry-1", BuiltIn.setEntry, ["key": lit("n"), "name": lit("facts"), "value": variable("n")]),
            stmt("h-entry-2", BuiltIn.setEntry, ["key": lit("square"), "name": lit("facts"), "value": variable("square")]),
            ret("h-return", ["facts": variable("facts")]),
        ])
        let main = Script(id: "main", name: "Main", parameters: [Param(name: "n", type: .number)],
                          outputs: [Param(name: "summary", type: .text), Param(name: "facts", type: .map)], body: [
            call("call", "helper", ["n": variable("n")], bindings: ["facts": "facts"]),
            ifElse("branch", rep("operator.greater", ["a": rep("map.value", ["key": lit("square"), "map": variable("facts")]), "b": lit(50)]),
                   then: [set("big", "size", rep("c.tag", ["text": lit("big")]))],
                   else: [set("small", "size", rep("c.tag", ["text": lit("small")]))]),
            ret("return", ["summary": rep("operator.join", ["a": variable("size"), "b": variable("n")]), "facts": variable("facts")]),
        ])
        return Document(scripts: [main, helper])
    }()

    func testOneInterpreterRunsFromManyTasksAtOnce() async {
        let interpreter = Interpreter(document: Self.document, vocabulary: Self.vocabulary, environment: env)

        // The single-threaded truth, for ten different arguments.
        let expected = (0..<10).map { interpreter.run(scriptID: "main", arguments: ["n": .number(Double($0))]) }
        XCTAssertEqual(expected[3].status, .returned)
        XCTAssertEqual(expected[3].outputs, ["summary": "<small>3", "facts": .map(["n": 3, "square": 9])])
        XCTAssertEqual(expected[9].outputs["summary"], "<big>9")
        XCTAssertEqual(expected[3].trace.map(\.blockID), ["call", "h-work", "h-entry-1", "h-entry-2", "h-return", "branch", "small", "return"])
        XCTAssertEqual(expected[3].trace[1].note, "squared 3 at depth 1\nsecond note")
        XCTAssertEqual(expected[3].trace[6].note, "tagged", "a reporter's note lands on its statement")

        // The same interpreter value, handed to 50 concurrent tasks.
        let results = await withTaskGroup(of: (Int, RunResult).self) { group -> [(Int, RunResult)] in
            for index in 0..<50 {
                group.addTask {
                    (index, interpreter.run(scriptID: "main", arguments: ["n": .number(Double(index % 10))]))
                }
            }
            var collected: [(Int, RunResult)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        XCTAssertEqual(results.count, 50)
        for (index, result) in results {
            XCTAssertEqual(result, expected[index % 10], "run \(index)")
        }
    }

    func testConcurrentRunsAgainstSharedHostState() async {
        // The demo's directory is shared by every run; its lock keeps the totals exact.
        let directory = TicketDirectory.sample(now: fixedNow)
        let document = (try? AcceptanceDocument.load()) ?? Document()
        let interpreter = Interpreter(document: document, vocabulary: TicketVocabulary.make(directory: directory), environment: env)
        let statuses = await withTaskGroup(of: RunStatus.self) { group -> [RunStatus] in
            for index in 0..<50 {
                group.addTask {
                    let ticket = Value.reference(Reference(kind: "ticket", id: index % 2 == 0 ? "T-1" : "T-2"))
                    return interpreter.run(scriptID: AcceptanceDocument.detailsID, arguments: ["ticket": ticket]).status
                }
            }
            var collected: [RunStatus] = []
            for await status in group { collected.append(status) }
            return collected
        }
        XCTAssertEqual(statuses, Array(repeating: .returned, count: 50))
        let log = directory.log
        XCTAssertEqual(log.count, 200, "four lines per run, none lost")
        // Each run writes its four lines in one call, so they are never interleaved.
        for start in stride(from: 0, to: log.count, by: 4) {
            XCTAssertTrue(log[start].hasPrefix("title: "), log[start])
            XCTAssertTrue(log[start + 1].hasPrefix("priority: "), log[start + 1])
            XCTAssertTrue(log[start + 2].hasPrefix("assignee: "), log[start + 2])
            XCTAssertEqual(log[start + 3], "reviewed: true")
        }
    }

    // MARK: RunContext

    func testNotesFromWorkerThreadsAreAllKept() {
        let category = BlockCategory(id: "c", title: "C", color: BlockColor(hex: 0))
        let vocabulary = Vocabulary([
            .statement("c.fanOut", category: category, title: "fan out") { _, context in
                // A handler that waits for workers which all report through the same context.
                DispatchQueue.concurrentPerform(iterations: 200) { index in context.note("note \(index)") }
                return [:]
            },
        ])
        let script = Script(id: "s", name: "S", body: [stmt("f", "c.fanOut")])
        let result = Interpreter(document: Document(scripts: [script]), vocabulary: vocabulary, environment: env).run(scriptID: "s")
        let notes = Set((result.trace.first?.note ?? "").split(separator: "\n").map(String.init))
        XCTAssertEqual(notes, Set((0..<200).map { "note \($0)" }))
    }

    func testAContextKeptAfterTheHandlerReturnsCannotTouchTheTrace() {
        let kept = Locked<RunContext?>(nil)
        let category = BlockCategory(id: "c", title: "C", color: BlockColor(hex: 0))
        let vocabulary = Vocabulary([
            .statement("c.keep", category: category, title: "keep") { _, context in
                context.note("during")
                kept.update { $0 = context }
                return [:]
            },
        ])
        let script = Script(id: "s", name: "S", body: [stmt("k", "c.keep")])
        let result = Interpreter(document: Document(scripts: [script]), vocabulary: vocabulary, environment: env).run(scriptID: "s")
        kept.value?.note("too late")
        XCTAssertEqual(result.trace.first?.note, "during")
        XCTAssertEqual(kept.value?.depth, 0, "its immutable parts stay readable")
    }
}
