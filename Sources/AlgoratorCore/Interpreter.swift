import Foundation

/// How a run ended.
public enum RunStatus: String, Sendable {
    /// Fell off the end of the script.
    case completed
    /// Ended by a `return`.
    case returned
    case failed
    case cancelled
}

/// What one executed statement did. Reporters are evaluated as part of the statement that uses them.
public struct StepOutcome: Equatable, Sendable {
    public var blockID: String
    public var scriptID: String
    /// 0 in the script that was run, 1 in a script it called, …
    public var depth: Int
    /// The block's title with the evaluated inputs filled in, e.g. `fetch ticket T-1`.
    public var label: String
    public var succeeded: Bool
    /// Why the step failed.
    public var message: String?
    /// Remarks the handler attached with `RunContext.note`.
    public var note: String?

    public init(blockID: String, scriptID: String, depth: Int, label: String, succeeded: Bool,
                message: String? = nil, note: String? = nil) {
        self.blockID = blockID
        self.scriptID = scriptID
        self.depth = depth
        self.label = label
        self.succeeded = succeeded
        self.message = message
        self.note = note
    }
}

/// The result of running a script.
public struct RunResult: Equatable, Sendable {
    public var status: RunStatus
    /// One value per declared output of the script (empty unless a `return` set it).
    public var outputs: [String: Value]
    /// One entry per executed statement, in execution order. Ends at the failing step when the run failed.
    public var trace: [StepOutcome]
    /// Why the run failed.
    public var message: String?

    public init(status: RunStatus, outputs: [String: Value] = [:], trace: [StepOutcome] = [], message: String? = nil) {
        self.status = status
        self.outputs = outputs
        self.trace = trace
        self.message = message
    }
}

/// Runs scripts of a document: synchronously, on the calling thread.
public struct Interpreter {
    public var document: Document
    public var vocabulary: Vocabulary
    public var environment: RunEnvironment

    public init(document: Document, vocabulary: Vocabulary, environment: RunEnvironment = RunEnvironment()) {
        self.document = document
        self.vocabulary = vocabulary
        self.environment = environment
    }

    /// Runs the script with the given id. `arguments` are keyed by parameter name; missing ones are empty.
    public func run(scriptID: String, arguments: [String: Value] = [:]) -> RunResult {
        guard let script = document.script(id: scriptID) else {
            return RunResult(status: .failed, outputs: [:], trace: [], message: "There is no script with id “\(scriptID)”")
        }
        let run = Run(document: document, vocabulary: vocabulary, environment: environment)
        do {
            let result = try run.call(script, arguments: arguments, depth: 0)
            return RunResult(status: result.returned ? .returned : .completed, outputs: result.outputs, trace: run.trace)
        } catch {
            let outputs = script.outputs.reduce(into: [String: Value]()) { $0[$1.name] = .empty }
            switch error {
            case Abort.failed(let message):
                return RunResult(status: .failed, outputs: outputs, trace: run.trace, message: message)
            default:
                return RunResult(status: .cancelled, outputs: outputs, trace: run.trace)
            }
        }
    }
}

/// Unwinds a run whose outcome is already recorded in the trace.
private enum Abort: Error {
    case failed(String)
    case cancelled
}

private enum Flow {
    case next
    case returned([String: Value])
}

/// The variables of one script invocation.
private final class Frame {
    let script: Script
    let depth: Int
    var variables: [String: Value] = [:]

    init(script: Script, depth: Int) {
        self.script = script
        self.depth = depth
    }
}

private final class Run {
    let document: Document
    let vocabulary: Vocabulary
    let environment: RunEnvironment
    var trace: [StepOutcome] = []
    /// Index of the step that handler notes are attached to.
    private var currentStep = 0

    init(document: Document, vocabulary: Vocabulary, environment: RunEnvironment) {
        self.document = document
        self.vocabulary = vocabulary
        self.environment = environment
    }

    func call(_ script: Script, arguments: [String: Value], depth: Int) throws -> (returned: Bool, outputs: [String: Value]) {
        let frame = Frame(script: script, depth: depth)
        for parameter in script.parameters {
            frame.variables[parameter.name] = arguments[parameter.name] ?? .empty
        }
        var outputs = script.outputs.reduce(into: [String: Value]()) { $0[$1.name] = .empty }
        guard case .returned(let values) = try execute(script.body, frame) else { return (false, outputs) }
        for name in outputs.keys { outputs[name] = values[name] ?? .empty }
        return (true, outputs)
    }

    private func execute(_ blocks: [Block], _ frame: Frame) throws -> Flow {
        for block in blocks {
            if environment.isCancelled() { throw Abort.cancelled }
            if case .returned(let values) = try execute(block, frame) { return .returned(values) }
        }
        return .next
    }

    private func execute(_ block: Block, _ frame: Frame) throws -> Flow {
        let step = trace.count
        trace.append(StepOutcome(blockID: block.id, scriptID: frame.script.id, depth: frame.depth, label: block.kind,
                                 succeeded: true))
        let outerStep = currentStep
        currentStep = step
        defer { currentStep = outerStep }
        do {
            return try perform(block, frame, step: step)
        } catch let abort as Abort {
            // A step further down already recorded the failure; the trace ends there.
            throw abort
        } catch is Cancelled {
            trace[step].succeeded = false
            trace[step].message = "Cancelled"
            throw Abort.cancelled
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            trace[step].succeeded = false
            trace[step].message = message
            throw Abort.failed(message)
        }
    }

    private func perform(_ block: Block, _ frame: Frame, step: Int) throws -> Flow {
        guard let definition = vocabulary[block.kind],
              let signature = vocabulary.signature(of: block, in: frame.script, document: document) else {
            throw BlockError("Unknown block kind “\(block.kind)”")
        }
        guard definition.shape.isStack else {
            throw BlockError("“\(block.kind)” produces a value and cannot be used as a statement")
        }
        let inputs = try evaluate(signature.inputs, of: block, frame)
        trace[step].label = Run.label(signature.title, inputs)

        switch block.kind {
        case BuiltIn.if, BuiltIn.ifElse:
            let region = inputs.bool(BuiltIn.conditionInput) ? BuiltIn.thenRegion : BuiltIn.elseRegion
            return try execute(block.regions[region] ?? [], frame)

        case BuiltIn.return:
            return .returned(inputs.values)

        case BuiltIn.call:
            guard let callee = BuiltIn.callee(of: block, in: document) else {
                throw BlockError("The called script does not exist")
            }
            trace[step].label = Run.label(signature.title, inputs, overriding: [BuiltIn.scriptInput: callee.name])
            guard frame.depth < environment.maxCallDepth else {
                throw BlockError("Scripts are nested more than \(environment.maxCallDepth) calls deep — is “\(callee.name)” calling itself?")
            }
            let arguments = callee.parameters.reduce(into: [String: Value]()) {
                $0[$1.name] = inputs[BuiltIn.argumentPrefix + $1.name]
            }
            bind(try call(callee, arguments: arguments, depth: frame.depth + 1).outputs, of: block, frame)

        case BuiltIn.set:
            guard let name = BuiltIn.setTarget(of: block) else { throw BlockError("No variable is chosen") }
            frame.variables[name] = inputs[BuiltIn.valueInput]

        default:
            bind(try definition.handler(inputs, context(frame)), of: block, frame)
            // A host-defined cap ends the script like `return`, with no outputs.
            if definition.shape == .cap { return .returned([:]) }
        }
        return .next
    }

    private func bind(_ outputs: [String: Value], of block: Block, _ frame: Frame) {
        for (output, variable) in block.bindings where !variable.isEmpty {
            frame.variables[variable] = outputs[output] ?? .empty
        }
    }

    private func context(_ frame: Frame) -> RunContext {
        let step = currentStep
        return RunContext(environment: environment, depth: frame.depth) { [unowned self] note in
            trace[step].note = trace[step].note.map { $0 + "\n" + note } ?? note
        }
    }

    // MARK: Inputs and reporters

    private func evaluate(_ definitions: [InputDefinition], of block: Block, _ frame: Frame) throws -> BlockInputs {
        var values: [String: Value] = [:]
        var kinds: [String: String] = [:]
        for definition in definitions {
            values[definition.name] = try evaluate(block.inputs[definition.name] ?? .empty, definition, frame)
            if case .reference(let kind) = definition.shape { kinds[definition.name] = kind }
        }
        return BlockInputs(values: values, environment: environment, referenceKinds: kinds)
    }

    private func evaluate(_ input: Input, _ definition: InputDefinition, _ frame: Frame) throws -> Value {
        switch input {
        case .empty: return definition.defaultValue ?? (definition.shape == .boolean ? .bool(false) : .empty)
        case .literal(let value): return value
        case .variable(let name): return frame.variables[name] ?? .empty
        case .reporter(let block): return try report(block, frame)
        }
    }

    private func report(_ block: Block, _ frame: Frame) throws -> Value {
        guard let definition = vocabulary[block.kind] else {
            throw BlockError("Unknown block kind “\(block.kind)”")
        }
        guard !definition.shape.isStack else {
            throw BlockError("“\(block.kind)” is a statement and cannot be used as a value")
        }
        let inputs = try evaluate(definition.inputs, of: block, frame)
        let result = try definition.handler(inputs, context(frame))[BlockDefinition.resultKey] ?? .empty
        return definition.shape == .predicate ? .bool(Coercion.toBool(result)) : result
    }

    // MARK: Labels

    static func label(_ title: [TitlePart], _ inputs: BlockInputs, overriding: [String: String] = [:]) -> String {
        title.map { part -> String in
            switch part {
            case .text(let text): return text
            case .slot(let name):
                let text = overriding[name] ?? inputs.text(name)
                let line = text.replacingOccurrences(of: "\n", with: ", ")
                if line.isEmpty { return "\"\"" }
                return line.count > 40 ? line.prefix(39) + "…" : line
            }
        }.joined(separator: " ")
    }
}
