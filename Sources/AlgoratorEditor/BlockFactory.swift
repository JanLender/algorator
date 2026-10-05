import Foundation
import AlgoratorCore

/// Makes fresh blocks: what the palette shows and what a drop from it inserts.
public enum BlockFactory {
    /// A block of `kind` whose typeable slots hold their default literals and whose outputs are bound.
    /// - Parameter calleeID: for `call script`, the script to call.
    public static func make(kind: String, calling calleeID: String? = nil, id: String = UUID().uuidString,
                            in script: Script, document: Document, vocabulary: Vocabulary) -> Block {
        var block = Block(id: id, kind: kind)
        if let calleeID { block.inputs[BuiltIn.scriptInput] = .literal(.text(calleeID)) }
        guard let signature = vocabulary.signature(of: block, in: script, document: document) else { return block }
        for slot in signature.inputs where block.inputs[slot.name] == nil {
            guard let value = slot.defaultValue, slot.shape == .value else { continue }
            switch slot.editor {
            case .none, .variable, .script, .reference: continue
            default: block.inputs[slot.name] = .literal(value)
            }
        }
        // Outputs start bound to variables of their own names, so a dropped block is useful at once.
        for output in signature.outputs { block.bindings[output.name] = output.name }
        return block
    }

    /// The prototype blocks of a category, in palette order. `call script` appears once per script of the document.
    public static func prototypes(category: String, in script: Script, document: Document, vocabulary: Vocabulary) -> [Block] {
        vocabulary.definitions.filter { $0.category.id == category }.flatMap { definition -> [Block] in
            guard definition.id == BuiltIn.call else {
                return [make(kind: definition.id, id: "palette:\(definition.id)", in: script, document: document,
                             vocabulary: vocabulary)]
            }
            return document.scripts.map {
                make(kind: definition.id, calling: $0.id, id: "palette:\(definition.id):\($0.id)", in: script,
                     document: document, vocabulary: vocabulary)
            }
        }
    }
}
