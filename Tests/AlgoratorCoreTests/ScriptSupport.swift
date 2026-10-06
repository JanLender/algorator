import Foundation
import AlgoratorCore

// Terse builders for hand-made scripts.

func lit(_ value: Value) -> Input { .literal(value) }
func variable(_ name: String) -> Input { .variable(name) }
func rep(_ kind: String, _ inputs: [String: Input] = [:], id: String = UUID().uuidString) -> Input {
    .reporter(Block(id: id, kind: kind, inputs: inputs))
}

func stmt(_ id: String, _ kind: String, _ inputs: [String: Input] = [:], bindings: [String: String] = [:]) -> Block {
    Block(id: id, kind: kind, inputs: inputs, bindings: bindings)
}
func set(_ id: String, _ name: String, _ value: Input) -> Block {
    stmt(id, BuiltIn.set, ["name": lit(.text(name)), "value": value])
}
func log(_ id: String, _ value: Input) -> Block { stmt(id, "test.log", ["value": value]) }
func ifThen(_ id: String, _ condition: Input, then: [Block]) -> Block {
    Block(id: id, kind: BuiltIn.if, inputs: ["condition": condition], regions: ["then": then])
}
func ifElse(_ id: String, _ condition: Input, then: [Block], else otherwise: [Block]) -> Block {
    Block(id: id, kind: BuiltIn.ifElse, inputs: ["condition": condition], regions: ["then": then, "else": otherwise])
}
func ret(_ id: String, _ outputs: [String: Input] = [:]) -> Block { stmt(id, BuiltIn.return, outputs) }
func call(_ id: String, _ script: String, _ arguments: [String: Input] = [:], bindings: [String: String] = [:]) -> Block {
    var inputs: [String: Input] = ["script": lit(.text(script))]
    for (name, input) in arguments { inputs[BuiltIn.argumentPrefix + name] = input }
    return stmt(id, BuiltIn.call, inputs, bindings: bindings)
}

let yes = rep("operator.equals", ["a": lit(1), "b": lit(1)])
let no = rep("operator.equals", ["a": lit(1), "b": lit(2)])

/// A vocabulary with observable side effects, for interpreter and validation tests. Its handlers capture only
/// the lock-guarded log, as real host handlers must.
final class TestHost: Sendable {
    private let log = Locked<[Value]>([])
    let vocabulary: Vocabulary

    var logged: [Value] { log.value }

    init() {
        let log = self.log
        let category = BlockCategory(id: "test", title: "Test", color: BlockColor(hex: 0x888888))
        vocabulary = Vocabulary([
            .statement("test.log", category: category, title: "log %value", inputs: [.value("value")]) { inputs, _ in
                log.update { $0.append(inputs["value"]) }
                return [:]
            },
            .statement("test.fail", category: category, title: "fail %message", inputs: [.value("message", .text)]) { inputs, _ in
                throw BlockError(inputs.text("message"))
            },
            .statement("test.cancel", category: category, title: "cancel") { _, _ in throw Cancelled() },
            .statement("test.pair", category: category, title: "make pair",
                       outputs: [OutputDefinition("first", .number), OutputDefinition("second", .text)]) { _, context in
                context.note("made a pair")
                context.note("at depth \(context.depth)")
                return ["first": 1, "second": "two"]
            },
            .statement("test.defaults", category: category, title: "defaults %count %flag",
                       inputs: [.value("count", .number, default: 7), .boolean("flag")]) { inputs, _ in
                log.update { $0 += [inputs["count"], inputs["flag"]] }
                return [:]
            },
            .reporter("test.user", category: category, title: "current user", result: .reference, referenceKind: "user") { _, _ in
                .reference(Reference(kind: "user", id: "u1"))
            },
            .reporter("test.boom", category: category, title: "boom", result: .text) { _, _ in
                throw BlockError("reporter exploded")
            },
            .statement("test.needsUser", category: category, title: "greet %user", inputs: [.reference("user", kind: "user")]) { _, _ in [:] },
            BlockDefinition(id: "test.stop", shape: .cap, category: category, title: "stop") { _, _ in [:] },
        ])
    }

    func run(_ script: Script, others: [Script] = [], arguments: [String: Value] = [:],
             environment: RunEnvironment = env) -> RunResult {
        Interpreter(document: Document(scripts: [script] + others), vocabulary: vocabulary, environment: environment)
            .run(scriptID: script.id, arguments: arguments)
    }

    func issues(_ script: Script, others: [Script] = []) -> [Issue] {
        Validator.validate(Document(scripts: [script] + others), vocabulary: vocabulary).filter { $0.scriptID == script.id }
    }

    /// Evaluates one reporter by returning it from a script.
    func evaluate(_ kind: String, _ inputs: [String: Input] = [:], environment: RunEnvironment = env) -> Value {
        let script = Script(id: "eval", name: "Eval", outputs: [Param(name: "result", type: .text)],
                            body: [ret("r", ["result": rep(kind, inputs)])])
        return run(script, environment: environment).outputs["result"] ?? .empty
    }
}
