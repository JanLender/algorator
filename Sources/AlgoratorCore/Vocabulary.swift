import Foundation

/// The geometric and semantic kind of a block.
public enum BlockShape: String, Sendable {
    case statement, cBlock, cap, reporter, predicate

    /// Statements, C-blocks and caps stack vertically; reporters and predicates plug into slots.
    public var isStack: Bool { self == .statement || self == .cBlock || self == .cap }
}

/// An sRGB colour, kept UI-framework-free so the core has no UI imports.
public struct BlockColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `BlockColor(hex: 0xFFAB19)`.
    public init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// A palette tab; also gives its blocks their colour.
public struct BlockCategory: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var color: BlockColor

    public init(id: String, title: String, color: BlockColor) {
        self.id = id
        self.title = title
        self.color = color
    }
}

/// What may be plugged into a slot. Only the shape and the reference kind ever block a drop.
public enum SlotShape: Hashable, Sendable {
    /// Hexagonal: predicates only.
    case boolean
    /// Round: a literal, a variable, or any reporter (predicates included, as in Scratch).
    case value
    /// A reference of one kind: a picker literal, or a variable/reporter of that kind.
    case reference(kind: String)
}

/// The inline editor for a slot's literal.
public enum SlotEditor: Hashable, Sendable {
    /// No literal can be typed; the slot takes a variable or a reporter.
    case none
    case text, number, date, time, timestamp, bool
    case dropdown([String])
    /// The host's `ReferenceProvider` picker.
    case reference
    /// Names a variable the block writes to (an existing one, or a new name).
    case variable
    /// Picks one of the document's scripts.
    case script
}

/// One slot of a block.
public struct InputDefinition: Hashable, Sendable {
    public var name: String
    /// Human-readable name, used in validation messages.
    public var label: String
    public var shape: SlotShape
    /// The value types the slot expects; empty means any. A mismatch is only ever a warning.
    public var types: [ValueType]
    /// The literal a freshly created block starts with, and what an empty slot evaluates to.
    public var defaultValue: Value?
    public var editor: SlotEditor
    /// Whether leaving the slot empty is a validation error.
    public var isRequired: Bool

    public init(name: String, label: String? = nil, shape: SlotShape = .value, types: [ValueType] = [],
                defaultValue: Value? = nil, editor: SlotEditor = .text, isRequired: Bool = true) {
        self.name = name
        self.label = label ?? name
        self.shape = shape
        self.types = types
        self.defaultValue = defaultValue
        self.editor = editor
        self.isRequired = isRequired
    }

    /// A round slot. Without a type it accepts anything and is edited as text.
    public static func value(_ name: String, _ type: ValueType? = nil, default defaultValue: Value? = nil) -> InputDefinition {
        guard let type else { return InputDefinition(name: name, defaultValue: defaultValue ?? .text("")) }
        return InputDefinition(name: name, type: type, referenceKind: nil, defaultValue: defaultValue)
    }

    /// A hexagonal slot taking a predicate.
    public static func boolean(_ name: String) -> InputDefinition {
        InputDefinition(name: name, shape: .boolean, types: [.bool], editor: .none)
    }

    /// A slot taking a reference of `kind`, edited with the host's picker.
    public static func reference(_ name: String, kind: String) -> InputDefinition {
        InputDefinition(name: name, shape: .reference(kind: kind), types: [.reference], editor: .reference)
    }

    /// A round slot expecting a map: it has no literal editor, so it takes a variable or a reporter. This is
    /// how a block receives a variable number of named inputs; the handler reads it with `inputs.map(name)`.
    public static func map(_ name: String) -> InputDefinition {
        InputDefinition(name: name, type: .map, referenceKind: nil)
    }

    /// A text slot restricted to fixed options; starts on the first.
    public static func dropdown(_ name: String, options: [String]) -> InputDefinition {
        InputDefinition(name: name, types: [.text], defaultValue: options.first.map(Value.text), editor: .dropdown(options))
    }

    /// The slot matching a declared type (a script parameter, a declared output, …).
    public init(name: String, label: String? = nil, type: ValueType, referenceKind: String?, defaultValue: Value? = nil) {
        let editor: SlotEditor
        var fallback: Value?
        switch type {
        case .text: editor = .text; fallback = .text("")
        case .number: editor = .number; fallback = .number(0)
        case .bool: editor = .bool; fallback = .bool(false)
        case .date: editor = .date
        case .time: editor = .time
        case .timestamp: editor = .timestamp
        case .reference: editor = .reference
        case .list, .map: editor = .none
        }
        self.init(name: name, label: label, shape: type == .reference ? .reference(kind: referenceKind ?? "") : .value,
                  types: [type], defaultValue: defaultValue ?? fallback, editor: editor)
    }
}

/// A named value a statement block produces; the user binds it to a variable.
public struct OutputDefinition: Hashable, Sendable {
    public var name: String
    public var type: ValueType
    public var referenceKind: String?

    public init(_ name: String, _ type: ValueType, referenceKind: String? = nil) {
        self.name = name
        self.type = type
        self.referenceKind = referenceKind
    }
}

/// A piece of a block's title: fixed words, or the slot shown at that position.
public enum TitlePart: Hashable, Sendable {
    case text(String)
    case slot(String)

    /// Parses a template such as `"fetch ticket %ticket"`; `%name` (letters, digits, `_`) marks a slot.
    public static func parse(_ template: String) -> [TitlePart] {
        var parts: [TitlePart] = []
        var text = ""
        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { parts.append(.text(trimmed)) }
            text = ""
        }
        var rest = Substring(template)
        while let character = rest.first {
            rest = rest.dropFirst()
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if character == "%", !name.isEmpty {
                flush()
                parts.append(.slot(String(name)))
                rest = rest.dropFirst(name.count)
            } else {
                text.append(character)
            }
        }
        flush()
        return parts
    }
}

/// The evaluated inputs of one block invocation, with Scratch-style typed accessors that never fail.
public struct BlockInputs: Sendable {
    public let values: [String: Value]
    public let environment: RunEnvironment
    let referenceKinds: [String: String]

    /// The raw value; the empty value when the slot is unknown.
    public subscript(name: String) -> Value { values[name] ?? .empty }

    public func text(_ name: String) -> String { Coercion.toText(self[name], in: environment) }
    public func number(_ name: String) -> Double { Coercion.toNumber(self[name]) }
    public func bool(_ name: String) -> Bool { Coercion.toBool(self[name]) }
    public func date(_ name: String) -> LocalDate? { Coercion.toDate(self[name], in: environment) }
    public func time(_ name: String) -> LocalTime? { Coercion.toTime(self[name], in: environment) }
    public func timestamp(_ name: String) -> Date? { Coercion.toTimestamp(self[name], in: environment) }
    public func list(_ name: String) -> [Value] { Coercion.toList(self[name]) }
    /// The map in the slot; anything that is not a map (or JSON object text) is the empty map.
    public func map(_ name: String) -> OrderedMap { Coercion.toMap(self[name]) }
    /// The reference in the slot; a non-reference value becomes a reference of the slot's declared kind.
    public func reference(_ name: String) -> Reference {
        Coercion.toReference(self[name], kind: referenceKinds[name] ?? "", in: environment)
    }
}

/// What a handler can see of the run it is part of.
///
/// A context belongs to **one invocation** of a handler: do not keep it after the handler returns (notes
/// added later are dropped). During the invocation it may be used from any thread, e.g. a worker the handler
/// waits for.
///
/// `@unchecked Sendable`: everything is immutable except the collected notes, which are guarded by a lock.
public final class RunContext: @unchecked Sendable {
    public let environment: RunEnvironment
    /// 0 in the script that was run, 1 in a script it called, …
    public let depth: Int
    private let lock = NSLock()
    private var notes: [String] = []
    private var isClosed = false

    init(environment: RunEnvironment, depth: Int) {
        self.environment = environment
        self.depth = depth
    }

    public var now: Date { environment.now() }
    public var isCancelled: Bool { environment.isCancelled() }

    /// Attaches a human-readable remark to the current step of the trace.
    public func note(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        if !isClosed { notes.append(text) }
    }

    /// Ends the invocation: returns the notes collected so far and ignores any that come later.
    func close() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        isClosed = true
        return notes
    }
}

/// Throw from a handler to end the run as *cancelled* rather than failed.
public struct Cancelled: Error, Sendable {
    public init() {}
}

/// A failure with a message for the trace. Handlers may throw any `Error`; this is a convenience.
public struct BlockError: LocalizedError, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Native code behind a block. Synchronous; statement blocks return their outputs by name,
/// reporters and predicates return theirs under `BlockDefinition.resultKey`.
///
/// A handler runs on whatever thread called `Interpreter.run`, possibly on several threads at once, so it is
/// `@Sendable`: it may capture only `Sendable` state — immutable values, an actor, or an object that guards
/// its own state with a lock.
public typealias BlockHandler = @Sendable (BlockInputs, RunContext) throws -> [String: Value]

/// One kind of block: its look, its slots and the native code it runs.
public struct BlockDefinition: Identifiable, Sendable {
    public static let resultKey = "result"

    public var id: String
    public var shape: BlockShape
    public var category: BlockCategory
    /// A template such as `"fetch ticket %ticket"`; see `TitlePart.parse`.
    public var title: String
    public var inputs: [InputDefinition]
    public var outputs: [OutputDefinition]
    /// Names of a C-block's child regions, in display order.
    public var regions: [String]
    /// The type a reporter produces; `nil` when it depends on the inputs.
    public var result: ValueType?
    public var resultReferenceKind: String?
    public var handler: BlockHandler

    public init(id: String, shape: BlockShape, category: BlockCategory, title: String,
                inputs: [InputDefinition] = [], outputs: [OutputDefinition] = [], regions: [String] = [],
                result: ValueType? = nil, resultReferenceKind: String? = nil, handler: @escaping BlockHandler) {
        self.id = id
        self.shape = shape
        self.category = category
        self.title = title
        self.inputs = inputs
        self.outputs = outputs
        self.regions = regions
        self.result = result
        self.resultReferenceKind = resultReferenceKind
        self.handler = handler
    }

    /// A statement block; the handler returns its outputs by name (`[:]` when it has none).
    public static func statement(_ id: String, category: BlockCategory, title: String, inputs: [InputDefinition] = [],
                                 outputs: [OutputDefinition] = [], handler: @escaping BlockHandler) -> BlockDefinition {
        BlockDefinition(id: id, shape: .statement, category: category, title: title, inputs: inputs, outputs: outputs,
                        handler: handler)
    }

    /// A reporter block; the handler returns the value.
    public static func reporter(_ id: String, category: BlockCategory, title: String, inputs: [InputDefinition] = [],
                                result: ValueType?, referenceKind: String? = nil,
                                handler: @escaping @Sendable (BlockInputs, RunContext) throws -> Value) -> BlockDefinition {
        BlockDefinition(id: id, shape: .reporter, category: category, title: title, inputs: inputs, result: result,
                        resultReferenceKind: referenceKind) { [resultKey: try handler($0, $1)] }
    }

    /// A predicate block; the handler returns the boolean.
    public static func predicate(_ id: String, category: BlockCategory, title: String, inputs: [InputDefinition] = [],
                                 handler: @escaping @Sendable (BlockInputs, RunContext) throws -> Bool) -> BlockDefinition {
        BlockDefinition(id: id, shape: .predicate, category: category, title: title, inputs: inputs, result: .bool) {
            [resultKey: .bool(try handler($0, $1))]
        }
    }
}

/// Supplies the candidates of a reference picker. Implemented by the host.
///
/// The editor calls it **on the main actor only** (while building labels and while a picker is open), so an
/// implementation may read main-actor state and need not be `Sendable`. The interpreter never calls it.
public protocol ReferenceProvider {
    /// Objects of `kind` matching the search text (all of them for an empty text).
    func candidates(kind: String, matching: String) -> [ReferenceCandidate]
    /// The label to show for an id already stored in a document; `nil` when the object no longer exists.
    func label(kind: String, id: String) -> String?
}

extension ReferenceProvider {
    public func label(kind: String, id: String) -> String? {
        candidates(kind: kind, matching: "").first { $0.id == id }?.label
    }
}

/// One row of a reference picker.
public struct ReferenceCandidate: Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// The slots, outputs and title of one concrete block. For most blocks this is just its definition;
/// `return` and `call script` take theirs from the script they return from or call.
public struct BlockSignature: Sendable {
    public var title: [TitlePart]
    public var inputs: [InputDefinition]
    public var outputs: [OutputDefinition]

    public func input(_ name: String) -> InputDefinition? { inputs.first { $0.name == name } }
}

/// The blocks available to scripts: the built-ins plus whatever the host registers.
///
/// A value, and `Sendable`: the same vocabulary may be handed to other tasks and used from several threads.
public struct Vocabulary: Sendable {
    public private(set) var definitions: [BlockDefinition] = []
    private var index: [String: Int] = [:]

    /// - Parameter includeBuiltIns: whether to start from `Vocabulary.builtIns` (control, variables, operators, time, lists).
    public init(_ definitions: [BlockDefinition] = [], includeBuiltIns: Bool = true) {
        if includeBuiltIns { Vocabulary.builtIns.forEach { register($0) } }
        definitions.forEach { register($0) }
    }

    /// Adds a definition, replacing an earlier one with the same id.
    public mutating func register(_ definition: BlockDefinition) {
        if let existing = index[definition.id] {
            definitions[existing] = definition
        } else {
            index[definition.id] = definitions.count
            definitions.append(definition)
        }
    }

    public subscript(id: String) -> BlockDefinition? {
        index[id].map { definitions[$0] }
    }

    /// Categories in order of first registration.
    public var categories: [BlockCategory] {
        var seen = Set<String>()
        return definitions.map(\.category).filter { seen.insert($0.id).inserted }
    }

    /// `nil` when the block's kind is unknown.
    public func signature(of block: Block, in script: Script, document: Document) -> BlockSignature? {
        guard let definition = self[block.kind] else { return nil }
        var signature = BlockSignature(title: TitlePart.parse(definition.title), inputs: definition.inputs,
                                       outputs: definition.outputs)
        switch block.kind {
        case BuiltIn.return:
            for output in script.outputs {
                signature.title += [.text(output.name), .slot(output.name)]
                signature.inputs.append(InputDefinition(name: output.name, type: output.type, referenceKind: output.referenceKind))
            }
        case BuiltIn.call:
            guard let callee = BuiltIn.callee(of: block, in: document) else { break }
            for parameter in callee.parameters {
                let name = BuiltIn.argumentPrefix + parameter.name
                signature.title += [.text(parameter.name), .slot(name)]
                signature.inputs.append(InputDefinition(name: name, label: parameter.name, type: parameter.type,
                                                        referenceKind: parameter.referenceKind))
            }
            signature.outputs = callee.outputs.map { OutputDefinition($0.name, $0.type, referenceKind: $0.referenceKind) }
        default:
            break
        }
        return signature
    }
}

extension Document {
    public func script(id: String) -> Script? { scripts.first { $0.id == id } }
    public func script(named name: String) -> Script? { scripts.first { $0.name == name } }
}

extension Script {
    /// The script's variables in order of first appearance: parameters, then output bindings and `set` targets.
    public var variableNames: [String] {
        var names = parameters.map(\.name)
        func visit(_ blocks: [Block]) {
            for block in blocks {
                // Outputs in a stable order (the dictionary has none).
                names += block.bindings.sorted { $0.key < $1.key }.map(\.value)
                if let name = BuiltIn.setTarget(of: block) { names.append(name) }
                for region in block.regions.keys.sorted() { visit(block.regions[region] ?? []) }
            }
        }
        visit(body)
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
