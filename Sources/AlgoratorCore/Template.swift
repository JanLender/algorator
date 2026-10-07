import Foundation

/// A text with `{name}` placeholders that are replaced by the values of variables.
///
/// Deliberately not a template language: it only substitutes values into text. Conditions and loops are
/// blocks; formatting is done by the `format …` reporters.
///
/// - `{name}` is replaced by the text of the variable `name`; a variable that is not set gives the empty text.
///   The name is everything between the braces except `{` and `}`, with surrounding whitespace trimmed.
/// - `{{` is a literal `{` and `}}` a literal `}`.
/// - Anything else is left as written: an empty `{}`, a `{` without a matching `}`, a stray `}`.
///
/// Parsing and rendering are total (they never fail), and rendering is a single pass: text produced by a
/// substituted value is not scanned again.
public struct Template: Equatable, Sendable {
    public enum Part: Equatable, Sendable {
        case text(String)
        /// A variable name, already trimmed.
        case placeholder(String)
    }

    public let parts: [Part]

    /// Parses the template. Never fails.
    public init(_ text: String) {
        var parts: [Part] = []
        var literal = ""
        func flush() {
            if !literal.isEmpty { parts.append(.text(literal)) }
            literal = ""
        }
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            switch character {
            case "{" where next == "{":
                literal.append("{")
                index += 2
            case "}" where next == "}":
                literal.append("}")
                index += 2
            case "{":
                // A placeholder runs to the next brace, which must be a closing one.
                guard let end = characters[(index + 1)...].firstIndex(where: { $0 == "{" || $0 == "}" }), characters[end] == "}" else {
                    literal.append(character)
                    index += 1
                    continue
                }
                let name = String(characters[(index + 1)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if name.isEmpty {
                    literal.append(contentsOf: characters[index...end])
                } else {
                    flush()
                    parts.append(.placeholder(name))
                }
                index = end + 1
            default:
                literal.append(character)
                index += 1
            }
        }
        flush()
        self.parts = parts
    }

    /// The variable names the template reads, in order of appearance (a repeated name appears once).
    public var placeholders: [String] {
        var seen = Set<String>()
        return parts.compactMap { part -> String? in
            guard case .placeholder(let name) = part, seen.insert(name).inserted else { return nil }
            return name
        }
    }

    /// Substitutes the variables' texts (`Coercion.toText`) for the placeholders.
    public func render(_ variables: [String: Value], in environment: RunEnvironment) -> String {
        parts.map { part -> String in
            switch part {
            case .text(let text): return text
            case .placeholder(let name): return Coercion.toText(variables[name] ?? .empty, in: environment)
            }
        }.joined()
    }
}
