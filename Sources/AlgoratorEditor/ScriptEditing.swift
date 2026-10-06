import Foundation
import AlgoratorCore

/// Where something can be dropped: between statements of a region, or into a slot.
public enum DropTarget: Hashable, Sendable {
    /// Before the block at `index` of a region (`index == count` appends). `owner` is `nil` for the script body.
    case region(owner: String?, name: String, index: Int)
    case slot(blockID: String, name: String)
}

/// What is being dragged, with what hit-testing needs to know about it.
public struct DraggedItem: Equatable {
    public enum Payload: Equatable {
        /// A statement together with the statements beneath it.
        case stack([Block])
        case reporter(Block)
        case variable(String)
    }

    public var payload: Payload
    public var isPredicate = false
    /// A stack ending in a cap can only go where nothing follows.
    public var endsWithCap = false
    /// The statically known type of a reporter or variable; `nil` when unknown.
    public var type: ValueType?
    public var referenceKind: String?

    public var isStack: Bool {
        if case .stack = payload { return true } else { return false }
    }

    public static func stack(_ blocks: [Block], vocabulary: Vocabulary) -> DraggedItem {
        let last = blocks.last.flatMap { vocabulary[$0.kind] }
        return DraggedItem(payload: .stack(blocks), endsWithCap: last?.shape == .cap)
    }

    public static func reporter(_ block: Block, vocabulary: Vocabulary) -> DraggedItem {
        let definition = vocabulary[block.kind]
        return DraggedItem(payload: .reporter(block), isPredicate: definition?.shape == .predicate,
                           type: definition?.result, referenceKind: definition?.resultReferenceKind)
    }

    public static func variable(_ name: String, in script: Script, document: Document, vocabulary: Vocabulary) -> DraggedItem {
        let known = Validator.variableTypes(of: script, in: document, vocabulary: vocabulary)[name]
        return DraggedItem(payload: .variable(name), type: known?.type, referenceKind: known?.referenceKind)
    }

    /// Whether a slot of this shape and editor takes the item. Only shape and reference kind ever refuse.
    public func fits(shape: SlotShape, editor: SlotEditor) -> Bool {
        guard !isStack, editor != .variable, editor != .script else { return false }
        switch shape {
        case .boolean: return isPredicate
        case .value: return true
        case .reference(let kind): return type == nil || (type == .reference && referenceKind == kind)
        }
    }
}

// Editing operations: pure transformations from one script to another. Each returns `nil` when it does not
// apply (unknown id, index out of range, wrong payload for the target), leaving the caller's script untouched.
extension Script {
    /// The block with this id, wherever it is nested.
    public func block(id: String) -> Block? {
        func search(_ blocks: [Block]) -> Block? {
            for block in blocks {
                if block.id == id { return block }
                for input in block.inputs.values {
                    if case .reporter(let reporter) = input, let found = search([reporter]) { return found }
                }
                for region in block.regions.values {
                    if let found = search(region) { return found }
                }
            }
            return nil
        }
        return search(body)
    }

    /// Where the block sits: its index in a region, or the slot it fills.
    public func location(of id: String) -> DropTarget? {
        func search(_ blocks: [Block], owner: String?, region: String) -> DropTarget? {
            for (index, block) in blocks.enumerated() {
                if block.id == id { return .region(owner: owner, name: region, index: index) }
                if let found = searchInside(block) { return found }
            }
            return nil
        }
        func searchInside(_ block: Block) -> DropTarget? {
            for name in block.inputs.keys.sorted() {
                guard case .reporter(let reporter)? = block.inputs[name] else { continue }
                if reporter.id == id { return .slot(blockID: block.id, name: name) }
                if let found = searchInside(reporter) { return found }
            }
            for name in block.regions.keys.sorted() {
                if let found = search(block.regions[name] ?? [], owner: block.id, region: name) { return found }
            }
            return nil
        }
        return search(body, owner: nil, region: "body")
    }

    /// Applies `change` to the block with this id.
    public func updating(blockID: String, _ change: (inout Block) -> Void) -> Script? {
        func update(_ block: inout Block) -> Bool {
            if block.id == blockID {
                change(&block)
                return true
            }
            for name in block.inputs.keys {
                guard case .reporter(var reporter)? = block.inputs[name], update(&reporter) else { continue }
                block.inputs[name] = .reporter(reporter)
                return true
            }
            for name in block.regions.keys {
                guard var region = block.regions[name], update(&region) else { continue }
                block.regions[name] = region
                return true
            }
            return false
        }
        func update(_ blocks: inout [Block]) -> Bool {
            for index in blocks.indices where update(&blocks[index]) { return true }
            return false
        }
        var copy = self
        return update(&copy.body) ? copy : nil
    }

    private func updatingRegion(owner: String?, name: String, _ change: (inout [Block]) -> Bool) -> Script? {
        guard let owner else {
            var copy = self
            return change(&copy.body) ? copy : nil
        }
        var applied = false
        let result = updating(blockID: owner) { block in
            var region = block.regions[name] ?? []
            applied = change(&region)
            if applied { block.regions[name] = region }
        }
        return applied ? result : nil
    }

    /// Takes a block out. A statement takes the statements beneath it along (as when dragging in Scratch);
    /// a reporter leaves `emptyInput(parent, slot)` behind.
    public func removing(blockID: String, emptyInput: (Block, String) -> Input = { _, _ in .empty })
        -> (script: Script, removed: DraggedItem.Payload)? {
        switch location(of: blockID) {
        case .region(let owner, let name, let index)?:
            var removed: [Block] = []
            let script = updatingRegion(owner: owner, name: name) { blocks in
                removed = Array(blocks[index...])
                blocks.removeSubrange(index...)
                return true
            }
            return script.map { ($0, .stack(removed)) }
        case .slot(let parent, let name)?:
            var removed: Block?
            let script = updating(blockID: parent) { block in
                if case .reporter(let reporter)? = block.inputs[name] { removed = reporter }
                block.inputs[name] = emptyInput(block, name)
            }
            guard let script, let removed else { return nil }
            return (script, .reporter(removed))
        case nil:
            return nil
        }
    }

    /// Takes just one block out, leaving the statements beneath it in place (Delete on a selected block).
    public func deleting(blockID: String, emptyInput: (Block, String) -> Input = { _, _ in .empty }) -> Script? {
        guard case .region(let owner, let name, let index)? = location(of: blockID) else {
            return removing(blockID: blockID, emptyInput: emptyInput)?.script
        }
        return updatingRegion(owner: owner, name: name) { blocks in
            blocks.remove(at: index)
            return true
        }
    }

    /// Takes a variable chip out of a slot.
    public func removingVariable(blockID: String, slot: String, emptyInput: (Block, String) -> Input = { _, _ in .empty })
        -> (script: Script, removed: DraggedItem.Payload)? {
        var name: String?
        let script = updating(blockID: blockID) { block in
            guard case .variable(let variable)? = block.inputs[slot] else { return }
            name = variable
            block.inputs[slot] = emptyInput(block, slot)
        }
        guard let script, let name else { return nil }
        return (script, .variable(name))
    }

    /// Puts a payload at a target: a stack into a region, a reporter or variable into a slot (replacing what
    /// was there).
    public func inserting(_ payload: DraggedItem.Payload, at target: DropTarget) -> Script? {
        switch (payload, target) {
        case (.stack(let blocks), .region(let owner, let name, let index)):
            return updatingRegion(owner: owner, name: name) { region in
                guard (0...region.count).contains(index) else { return false }
                region.insert(contentsOf: blocks, at: index)
                return true
            }
        case (.reporter(let block), .slot(let parent, let name)):
            return updating(blockID: parent) { $0.inputs[name] = .reporter(block) }
        case (.variable(let variable), .slot(let parent, let name)):
            return updating(blockID: parent) { $0.inputs[name] = .variable(variable) }
        default:
            return nil
        }
    }

    /// `removing` followed by `inserting`. The target refers to the script *without* the moved blocks.
    public func moving(blockID: String, to target: DropTarget, emptyInput: (Block, String) -> Input = { _, _ in .empty }) -> Script? {
        guard let (remaining, payload) = removing(blockID: blockID, emptyInput: emptyInput) else { return nil }
        return remaining.inserting(payload, at: target)
    }

    public func settingInput(blockID: String, name: String, to input: Input) -> Script? {
        updating(blockID: blockID) { $0.inputs[name] = input }
    }

    /// Binds an output to a variable; an empty name unbinds it.
    public func settingBinding(blockID: String, output: String, to variable: String) -> Script? {
        updating(blockID: blockID) { $0.bindings[output] = variable.isEmpty ? nil : variable }
    }
}

extension Block {
    /// A copy with new ids for the block and everything nested in it.
    public func withFreshIDs() -> Block {
        var copy = self
        copy.id = UUID().uuidString
        copy.inputs = inputs.mapValues { input in
            if case .reporter(let reporter) = input { return .reporter(reporter.withFreshIDs()) }
            return input
        }
        copy.regions = regions.mapValues { $0.map { $0.withFreshIDs() } }
        return copy
    }
}

extension Vocabulary {
    /// Every reference kind the vocabulary mentions, sorted.
    public var referenceKinds: [String] {
        var kinds = Set<String>()
        for definition in definitions {
            for input in definition.inputs {
                if case .reference(let kind) = input.shape { kinds.insert(kind) }
            }
            kinds.formUnion(definition.outputs.compactMap(\.referenceKind))
            if let kind = definition.resultReferenceKind { kinds.insert(kind) }
        }
        return kinds.sorted()
    }
}

extension Document {
    /// The document with a new, empty script appended. Its name does not clash with an existing one.
    public func addingScript(id: String = UUID().uuidString) -> Document {
        var copy = self
        var number = scripts.count + 1
        while copy.scripts.contains(where: { $0.name == "Script \(number)" }) { number += 1 }
        copy.scripts.append(Script(id: id, name: "Script \(number)"))
        return copy
    }

    public func removingScript(id: String) -> Document {
        var copy = self
        copy.scripts.removeAll { $0.id == id }
        return copy
    }

    /// The document with one script replaced (matched by id).
    public func replacing(_ script: Script) -> Document {
        var copy = self
        if let index = copy.scripts.firstIndex(where: { $0.id == script.id }) { copy.scripts[index] = script }
        return copy
    }
}

extension BlockFactory {
    /// What a slot goes back to when its reporter or variable is dragged out: its default literal, or empty.
    public static func emptyInput(for block: Block, slot name: String, in script: Script, document: Document,
                                  vocabulary: Vocabulary) -> Input {
        guard let slot = vocabulary.signature(of: block, in: script, document: document)?.input(name) else { return .empty }
        return defaultInput(slot)
    }

    static func defaultInput(_ slot: InputDefinition) -> Input {
        guard let value = slot.defaultValue, slot.shape == .value else { return .empty }
        switch slot.editor {
        case .none, .variable, .script, .reference: return .empty
        default: return .literal(value)
        }
    }
}
