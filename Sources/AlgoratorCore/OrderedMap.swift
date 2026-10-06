import Foundation

/// An ordered map of named values: what a block takes when it needs a variable number of named inputs.
///
/// Keys are text, compared exactly (case-sensitive, untrimmed) and unique. Entries keep their insertion
/// order: setting an existing key replaces its value in place, setting a new one appends. It is a plain
/// value: changing a copy never affects the original.
///
/// `==` is exact, **including entry order** (as for any Swift value). `Coercion.compare` — and therefore
/// the `=` block — treats two maps with the same entries in a different order as equal.
public struct OrderedMap: Hashable, Sendable {
    public struct Entry: Hashable, Sendable, Codable {
        public var key: String
        public var value: Value

        public init(key: String, value: Value) {
            self.key = key
            self.value = value
        }
    }

    /// The entries in order. Keys are unique.
    public private(set) var entries: [Entry] = []

    public init() {}

    /// Builds a map entry by entry: a repeated key keeps its first position and takes its last value.
    public init(_ entries: [Entry]) {
        for entry in entries { set(entry.key, entry.value) }
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public var keys: [String] { entries.map(\.key) }

    /// The value for a key, or `nil` when the key is absent.
    public subscript(key: String) -> Value? {
        entries.first { $0.key == key }?.value
    }

    public func contains(_ key: String) -> Bool {
        entries.contains { $0.key == key }
    }

    /// Replaces the value of an existing key (keeping its position) or appends a new entry.
    public mutating func set(_ key: String, _ value: Value) {
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index].value = value
        } else {
            entries.append(Entry(key: key, value: value))
        }
    }

    /// Removes the entry with this key; does nothing when it is absent.
    public mutating func remove(_ key: String) {
        entries.removeAll { $0.key == key }
    }

    /// A new map with the key set; this one is unchanged.
    public func setting(_ key: String, _ value: Value) -> OrderedMap {
        var copy = self
        copy.set(key, value)
        return copy
    }

    /// A new map without the key; this one is unchanged.
    public func removing(_ key: String) -> OrderedMap {
        var copy = self
        copy.remove(key)
        return copy
    }
}

extension OrderedMap: ExpressibleByDictionaryLiteral {
    /// `["title": "High", "n": 2]`, in the order written.
    public init(dictionaryLiteral elements: (String, Value)...) {
        self.init(elements.map { Entry(key: $0.0, value: $0.1) })
    }
}

// In documents a map is an array of {"key", "value"} pairs, because JSON object key order is not guaranteed.
extension OrderedMap: Codable {
    public init(from decoder: Decoder) throws {
        // A hand-edited document may repeat a key: the last value wins, in the first one's position.
        self.init(try decoder.singleValueContainer().decode([Entry].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }
}

/// Compact JSON text for maps (`Coercion.toText` / `Coercion.toMap`). Hand-written because Foundation's
/// JSON types do not keep the order of object keys.
enum JSONText {
    // MARK: Writing

    static func write(_ value: Value, in environment: RunEnvironment) -> String {
        switch value {
        case .text(let text): return quote(text)
        case .number(let number): return number.isFinite ? Coercion.text(of: number) : "null"
        case .bool(let bool): return bool ? "true" : "false"
        case .date, .time, .timestamp, .reference: return quote(Coercion.toText(value, in: environment))
        case .list(let items): return "[" + items.map { write($0, in: environment) }.joined(separator: ",") + "]"
        case .map(let map): return write(map, in: environment)
        }
    }

    static func write(_ map: OrderedMap, in environment: RunEnvironment) -> String {
        "{" + map.entries.map { quote($0.key) + ":" + write($0.value, in: environment) }.joined(separator: ",") + "}"
    }

    private static func quote(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    // MARK: Reading

    /// The map a JSON object text denotes; `nil` unless the whole text is one valid JSON object.
    static func readObject(_ text: String) -> OrderedMap? {
        var reader = Reader(scalars: Array(text.unicodeScalars))
        reader.skipWhitespace()
        guard reader.peek == "{", case .map(let map)? = reader.value() else { return nil }
        reader.skipWhitespace()
        return reader.isAtEnd ? map : nil
    }

    private struct Reader {
        let scalars: [Unicode.Scalar]
        var index = 0

        var isAtEnd: Bool { index >= scalars.count }
        var peek: Unicode.Scalar? { isAtEnd ? nil : scalars[index] }

        mutating func skipWhitespace() {
            while let scalar = peek, scalar == " " || scalar == "\n" || scalar == "\t" || scalar == "\r" { index += 1 }
        }

        mutating func take(_ scalar: Unicode.Scalar) -> Bool {
            guard peek == scalar else { return false }
            index += 1
            return true
        }

        mutating func take(word: String) -> Bool {
            let wanted = Array(word.unicodeScalars)
            guard index + wanted.count <= scalars.count, Array(scalars[index..<index + wanted.count]) == wanted else { return false }
            index += wanted.count
            return true
        }

        /// Any JSON value. Depth is bounded so hostile text cannot overflow the stack.
        mutating func value(depth: Int = 0) -> Value? {
            guard depth < 200 else { return nil }
            skipWhitespace()
            switch peek {
            case "{": return object(depth: depth)
            case "[": return array(depth: depth)
            case "\"": return string().map(Value.text)
            case "t": return take(word: "true") ? .bool(true) : nil
            case "f": return take(word: "false") ? .bool(false) : nil
            case "n": return take(word: "null") ? .empty : nil
            default: return number()
            }
        }

        private mutating func object(depth: Int) -> Value? {
            index += 1
            var map = OrderedMap()
            skipWhitespace()
            if take("}") { return .map(map) }
            while true {
                skipWhitespace()
                guard let key = string() else { return nil }
                skipWhitespace()
                guard take(":"), let value = value(depth: depth + 1) else { return nil }
                map.set(key, value)
                skipWhitespace()
                if take("}") { return .map(map) }
                guard take(",") else { return nil }
            }
        }

        private mutating func array(depth: Int) -> Value? {
            index += 1
            var items: [Value] = []
            skipWhitespace()
            if take("]") { return .list(items) }
            while true {
                guard let value = value(depth: depth + 1) else { return nil }
                items.append(value)
                skipWhitespace()
                if take("]") { return .list(items) }
                guard take(",") else { return nil }
            }
        }

        private mutating func string() -> String? {
            guard take("\"") else { return nil }
            var result = String.UnicodeScalarView()
            while let scalar = peek {
                index += 1
                switch scalar {
                case "\"":
                    return String(result)
                case "\\":
                    guard let escape = peek else { return nil }
                    index += 1
                    switch escape {
                    case "\"", "\\", "/": result.append(escape)
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "r": result.append("\r")
                    case "b": result.append("\u{8}")
                    case "f": result.append("\u{c}")
                    case "u":
                        guard let unit = hex4() else { return nil }
                        var code = unit
                        if (0xD800...0xDBFF).contains(unit) {
                            // A surrogate pair: 😀.
                            guard take("\\"), take("u"), let low = hex4(), (0xDC00...0xDFFF).contains(low) else { return nil }
                            code = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let decoded = Unicode.Scalar(code) else { return nil }
                        result.append(decoded)
                    default: return nil
                    }
                default:
                    guard scalar.value >= 0x20 else { return nil }
                    result.append(scalar)
                }
            }
            return nil
        }

        private mutating func hex4() -> UInt32? {
            guard index + 4 <= scalars.count else { return nil }
            let digits = String(String.UnicodeScalarView(scalars[index..<index + 4]))
            index += 4
            return UInt32(digits, radix: 16)
        }

        /// `-? digits (. digits)? ([eE] [+-]? digits)?`
        private mutating func number() -> Value? {
            let start = index
            func isDigit(_ scalar: Unicode.Scalar?) -> Bool { scalar.map { ("0"..."9").contains($0) } ?? false }
            _ = take("-")
            guard isDigit(peek) else { return nil }
            while isDigit(peek) { index += 1 }
            if take(".") {
                guard isDigit(peek) else { return nil }
                while isDigit(peek) { index += 1 }
            }
            if peek == "e" || peek == "E" {
                index += 1
                if !take("+") { _ = take("-") }
                guard isDigit(peek) else { return nil }
                while isDigit(peek) { index += 1 }
            }
            guard let number = Double(String(String.UnicodeScalarView(scalars[start..<index]))), number.isFinite else { return nil }
            return .number(number)
        }
    }
}
