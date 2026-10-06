import Foundation

/// A set of named scripts; the persisted unit. Its JSON form is canonical and round-trips losslessly.
public struct Document: Codable, Equatable, Sendable {
    /// The schema this build writes, and the newest it can read.
    /// Version 2 added map values; a version 1 document is a valid version 2 document.
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var scripts: [Script]

    public init(scripts: [Script] = []) {
        self.schemaVersion = Document.currentSchemaVersion
        self.scripts = scripts
    }

    /// Decodes a document, rejecting one written by a newer schema.
    public init(json: Data) throws {
        self = try JSONDecoder().decode(Document.self, from: json)
    }

    /// Stable JSON (sorted keys, pretty-printed) suitable for diffing.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let found = try container.decode(Int.self, forKey: .schemaVersion)
        guard found <= Document.currentSchemaVersion else {
            throw DocumentError.unsupportedSchemaVersion(found)
        }
        // Migration: versions 1 and 2 differ only in what values may appear, so an older document needs no
        // rewriting; it is simply saved as the current version from now on.
        schemaVersion = Document.currentSchemaVersion
        scripts = try container.decode([Script].self, forKey: .scripts)
    }
}

/// Why a document could not be loaded.
public enum DocumentError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
}

/// A named algorithm: typed parameters, declared outputs and a body of blocks. The unit of reuse.
public struct Script: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Opaque metadata for the host (e.g. a handler name); the engine ignores it.
    public var trigger: String?
    public var parameters: [Param]
    public var outputs: [Param]
    public var body: [Block]

    public init(id: String = UUID().uuidString, name: String, trigger: String? = nil,
                parameters: [Param] = [], outputs: [Param] = [], body: [Block] = []) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.parameters = parameters
        self.outputs = outputs
        self.body = body
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        trigger = try container.decodeIfPresent(String.self, forKey: .trigger)
        parameters = try container.decodeIfPresent([Param].self, forKey: .parameters) ?? []
        outputs = try container.decodeIfPresent([Param].self, forKey: .outputs) ?? []
        body = try container.decodeIfPresent([Block].self, forKey: .body) ?? []
    }
}

/// A script parameter or declared output.
public struct Param: Codable, Equatable, Sendable {
    public var name: String
    public var type: ValueType
    /// The reference kind when `type` is `.reference`.
    public var referenceKind: String?

    public init(name: String, type: ValueType, referenceKind: String? = nil) {
        self.name = name
        self.type = type
        self.referenceKind = referenceKind
    }
}

/// One node of a script's tree. `kind` is a key into the vocabulary; a block whose kind the vocabulary
/// no longer knows is kept as is.
public struct Block: Codable, Equatable, Sendable, Identifiable {
    /// Stable across edits: UI identity, outcomes and validation issues refer to it.
    public var id: String
    public var kind: String
    public var inputs: [String: Input]
    /// Output name → the variable it is bound to.
    public var bindings: [String: String]
    /// Child regions of a C-shaped block (`"then"`, `"else"`, …).
    public var regions: [String: [Block]]

    public init(id: String = UUID().uuidString, kind: String, inputs: [String: Input] = [:],
                bindings: [String: String] = [:], regions: [String: [Block]] = [:]) {
        self.id = id
        self.kind = kind
        self.inputs = inputs
        self.bindings = bindings
        self.regions = regions
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, inputs, bindings, regions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(String.self, forKey: .kind)
        inputs = try container.decodeIfPresent([String: Input].self, forKey: .inputs) ?? [:]
        bindings = try container.decodeIfPresent([String: String].self, forKey: .bindings) ?? [:]
        regions = try container.decodeIfPresent([String: [Block]].self, forKey: .regions) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        if !inputs.isEmpty { try container.encode(inputs, forKey: .inputs) }
        if !bindings.isEmpty { try container.encode(bindings, forKey: .bindings) }
        if !regions.isEmpty { try container.encode(regions, forKey: .regions) }
    }
}

/// What fills a slot: a literal, a variable read, a nested reporter block, or nothing.
public indirect enum Input: Equatable, Sendable {
    case literal(Value)
    case variable(String)
    case reporter(Block)
    case empty
}

// JSON form: {"literal": <value>}, {"variable": "name"}, {"reporter": <block>} or {"empty": true}.
extension Input: Codable {
    private enum CodingKeys: String, CodingKey {
        case literal, variable, reporter, empty
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(Value.self, forKey: .literal) {
            self = .literal(value)
        } else if let name = try container.decodeIfPresent(String.self, forKey: .variable) {
            self = .variable(name)
        } else if let block = try container.decodeIfPresent(Block.self, forKey: .reporter) {
            self = .reporter(block)
        } else if container.contains(.empty) {
            self = .empty
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "An input must be a literal, variable, reporter or empty"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .literal(let value): try container.encode(value, forKey: .literal)
        case .variable(let name): try container.encode(name, forKey: .variable)
        case .reporter(let block): try container.encode(block, forKey: .reporter)
        case .empty: try container.encode(true, forKey: .empty)
        }
    }
}
