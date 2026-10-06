import Foundation

/// A problem found by `Validator`. Errors mean the script is wrong; warnings mean the runtime will coerce.
public struct Issue: Equatable, Sendable {
    public enum Severity: String, Sendable {
        case error, warning
    }

    public var scriptID: String
    public var blockID: String
    public var severity: Severity
    public var message: String

    public init(scriptID: String, blockID: String, severity: Severity, message: String) {
        self.scriptID = scriptID
        self.blockID = blockID
        self.severity = severity
        self.message = message
    }
}

/// Static checks over a document. Side-effect free: no handler is ever called.
public enum Validator {
    /// All issues of all scripts, in document order.
    public static func validate(_ document: Document, vocabulary: Vocabulary) -> [Issue] {
        document.scripts.flatMap { validate($0, in: document, vocabulary: vocabulary) }
    }

    /// The issues of one script.
    public static func validate(_ script: Script, in document: Document, vocabulary: Vocabulary) -> [Issue] {
        var pass = Pass(script: script, document: document, vocabulary: vocabulary)
        pass.declare(script.body)
        var bound = Set(script.parameters.map(\.name))
        pass.walk(script.body, &bound)
        return pass.issues
    }

    /// What is statically known about each variable of a script (parameters, output bindings, `set` targets).
    public static func variableTypes(of script: Script, in document: Document, vocabulary: Vocabulary) -> [String: VariableType] {
        var pass = Pass(script: script, document: document, vocabulary: vocabulary)
        pass.declare(script.body)
        return pass.variables
    }
}

/// What is statically known about a variable. A `nil` type means "unknown" (written by `set`, or by
/// outputs of differing types).
public struct VariableType: Equatable, Sendable {
    public var type: ValueType?
    public var referenceKind: String?

    public init(type: ValueType? = nil, referenceKind: String? = nil) {
        self.type = type
        self.referenceKind = referenceKind
    }
}

private struct Pass {
    let script: Script
    let document: Document
    let vocabulary: Vocabulary
    var issues: [Issue] = []
    var variables: [String: VariableType] = [:]

    init(script: Script, document: Document, vocabulary: Vocabulary) {
        self.script = script
        self.document = document
        self.vocabulary = vocabulary
        for parameter in script.parameters {
            variables[parameter.name] = VariableType(type: parameter.type, referenceKind: parameter.referenceKind)
        }
    }

    private mutating func report(_ block: Block, _ severity: Issue.Severity, _ message: String) {
        issues.append(Issue(scriptID: script.id, blockID: block.id, severity: severity, message: message))
    }

    // MARK: Pass 1 — which variables exist, and their types

    mutating func declare(_ blocks: [Block]) {
        for block in blocks {
            if let name = BuiltIn.setTarget(of: block) {
                // `set` can store anything; `set entry` and `remove entry` always leave a map.
                declare(name, VariableType(type: block.kind == BuiltIn.set ? nil : .map))
            }
            if let signature = vocabulary.signature(of: block, in: script, document: document) {
                for (output, name) in block.bindings where !name.isEmpty {
                    let definition = signature.outputs.first { $0.name == output }
                    declare(name, VariableType(type: definition?.type, referenceKind: definition?.referenceKind))
                }
            }
            for region in block.regions.values { declare(region) }
        }
    }

    private mutating func declare(_ name: String, _ type: VariableType) {
        if let existing = variables[name], existing != type {
            variables[name] = VariableType()
        } else {
            variables[name] = type
        }
    }

    // MARK: Pass 2 — statements in order, tracking which variables may be bound

    mutating func walk(_ blocks: [Block], _ bound: inout Set<String>) {
        for block in blocks {
            let definition = vocabulary[block.kind]
            if let definition, !definition.shape.isStack {
                report(block, .error, "“\(title(definition))” produces a value and cannot stand on its own")
            }
            check(block, bound)

            // Flow-insensitive on branches: bound in any region counts as possibly bound afterwards.
            var after = bound
            for name in definition?.regions ?? block.regions.keys.sorted() {
                var inside = bound
                walk(block.regions[name] ?? [], &inside)
                after.formUnion(inside)
            }
            bound = after
            bound.formUnion(block.bindings.values.filter { !$0.isEmpty })
            if let name = BuiltIn.setTarget(of: block) { bound.insert(name) }
        }
    }

    /// Checks one block (statement or reporter) and, recursively, the reporters in its slots.
    private mutating func check(_ block: Block, _ bound: Set<String>) {
        guard let signature = vocabulary.signature(of: block, in: script, document: document) else {
            report(block, .error, "Unknown block kind “\(block.kind)”")
            return
        }
        if block.kind == BuiltIn.call, BuiltIn.callee(of: block, in: document) == nil {
            report(block, .error, "The called script does not exist")
            return
        }
        if block.kind == BuiltIn.return {
            for name in block.inputs.keys.sorted() where signature.input(name) == nil && block.inputs[name] != .empty {
                report(block, .error, "return sets “\(name)”, which is not a declared output of “\(script.name)”")
            }
        }
        for slot in signature.inputs {
            let input = block.inputs[slot.name] ?? .empty
            if block.kind == BuiltIn.return, input == .empty {
                report(block, .error, "return does not set the declared output “\(slot.label)”")
                continue
            }
            if isMissing(input, slot) {
                if slot.isRequired { report(block, .error, "“\(slot.label)” is empty") }
                continue
            }
            check(input, in: slot, of: block, bound)
        }
    }

    private func isMissing(_ input: Input, _ slot: InputDefinition) -> Bool {
        switch input {
        case .empty: return slot.defaultValue == nil || slot.shape != .value
        case .literal(.reference(let reference)): return reference.id.isEmpty
        case .literal(.text(let text)): return text.isEmpty && (slot.editor == .variable || slot.editor == .script)
        default: return false
        }
    }

    private mutating func check(_ input: Input, in slot: InputDefinition, of block: Block, _ bound: Set<String>) {
        switch input {
        case .empty:
            break

        case .literal(let value):
            switch slot.shape {
            case .boolean:
                if value.type != .bool { report(block, .error, "“\(slot.label)” needs a condition block") }
            case .reference(let kind):
                guard case .reference(let reference) = value else {
                    report(block, .error, "“\(slot.label)” needs a \(kind)")
                    break
                }
                if reference.kind != kind {
                    report(block, .error, "“\(slot.label)” needs a \(kind), not a \(reference.kind)")
                }
            case .value:
                if case .dropdown(let options) = slot.editor, case .text(let text) = value, !options.contains(text) {
                    report(block, .warning, "“\(text)” is not one of the options of “\(slot.label)”")
                } else if !fits(value, slot.types) {
                    report(block, .warning, "“\(slot.label)” expects \(describe(slot.types)), not \(value.type.rawValue)")
                }
            }

        case .variable(let name):
            if variables[name] == nil {
                report(block, .error, "The variable “\(name)” is never set")
            } else if !bound.contains(name) {
                report(block, .error, "The variable “\(name)” is read before it can be set")
            }
            let known = variables[name] ?? VariableType()
            checkType(known.type, known.referenceKind, isPredicate: false, in: slot, of: block)

        case .reporter(let reporter):
            guard let definition = vocabulary[reporter.kind] else {
                report(reporter, .error, "Unknown block kind “\(reporter.kind)”")
                return
            }
            if definition.shape.isStack {
                report(block, .error, "“\(title(definition))” is a statement and cannot be used as a value")
            } else {
                checkType(definition.result, definition.resultReferenceKind, isPredicate: definition.shape == .predicate,
                          in: slot, of: block)
            }
            check(reporter, bound)
        }
    }

    /// Shape and reference kind are errors; any other mismatch is a warning (the runtime coerces).
    private mutating func checkType(_ type: ValueType?, _ referenceKind: String?, isPredicate: Bool,
                                    in slot: InputDefinition, of block: Block) {
        switch slot.shape {
        case .boolean:
            if !isPredicate { report(block, .error, "“\(slot.label)” needs a condition block") }
        case .reference(let kind):
            guard let type else { return }   // unknown: allowed
            if type != .reference {
                report(block, .error, "“\(slot.label)” needs a \(kind), not \(type.rawValue)")
            } else if referenceKind != kind {
                report(block, .error, "“\(slot.label)” needs a \(kind), not a \(referenceKind ?? "reference")")
            }
        case .value:
            // Everything converts to text, so a text slot never warns.
            guard let type, !slot.types.isEmpty, !slot.types.contains(type), !slot.types.contains(.text) else { return }
            report(block, .warning, "“\(slot.label)” expects \(describe(slot.types)), not \(type.rawValue)")
        }
    }

    /// Whether a literal is of an accepted type, or text that converts to one.
    private func fits(_ value: Value, _ types: [ValueType]) -> Bool {
        if types.isEmpty || types.contains(value.type) || types.contains(.text) { return true }
        guard case .text = value else { return false }
        let environment = RunEnvironment(timeZone: ISO.utc)
        return types.contains { type in
            switch type {
            case .number: return Coercion.numeric(value) != nil
            case .date: return Coercion.toDate(value, in: environment) != nil
            case .time: return Coercion.toTime(value, in: environment) != nil
            case .timestamp: return Coercion.toTimestamp(value, in: environment) != nil
            default: return false
            }
        }
    }

    private func describe(_ types: [ValueType]) -> String {
        types.map(\.rawValue).joined(separator: " or ")
    }

    private func title(_ definition: BlockDefinition) -> String {
        TitlePart.parse(definition.title).compactMap { part -> String? in
            if case .text(let text) = part { return text }
            return nil
        }.joined(separator: " ")
    }
}
