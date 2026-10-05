import Foundation

/// The closed set of value types a slot, parameter or result can declare.
public enum ValueType: String, Codable, Sendable, CaseIterable {
    case text, number, bool, date, time, timestamp, reference, list
}

/// An opaque id of a host object plus its kind (`"ticket"`, `"user"`, …).
public struct Reference: Hashable, Codable, Sendable {
    public var kind: String
    public var id: String

    public init(kind: String, id: String) {
        self.kind = kind
        self.id = id
    }
}

/// A runtime value. Values are dynamically typed and coerced by context (see `Coercion`).
public enum Value: Equatable, Sendable {
    case text(String)
    case number(Double)
    case bool(Bool)
    case date(LocalDate)
    case time(LocalTime)
    /// An absolute instant. Persisted and printed with millisecond precision.
    case timestamp(Date)
    case reference(Reference)
    case list([Value])

    /// What an unset variable reads as: the empty text.
    public static let empty = Value.text("")

    public var type: ValueType {
        switch self {
        case .text: return .text
        case .number: return .number
        case .bool: return .bool
        case .date: return .date
        case .time: return .time
        case .timestamp: return .timestamp
        case .reference: return .reference
        case .list: return .list
        }
    }
}

extension Value: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                 ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

// JSON form: a single-key object naming the type, e.g. {"text": "high"}, {"date": "2026-10-04"},
// {"timestamp": "2026-10-04T10:00:00Z"}, {"reference": {"kind": "ticket", "id": "T-1"}}.
extension Value: Codable {
    private enum CodingKeys: String, CodingKey {
        case text, number, bool, date, time, timestamp, reference, list
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "A value must have exactly one type key"))
        }
        func corrupted(_ what: String) -> DecodingError {
            DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Invalid \(what)")
        }
        switch key {
        case .text: self = .text(try container.decode(String.self, forKey: key))
        case .number: self = .number(try container.decode(Double.self, forKey: key))
        case .bool: self = .bool(try container.decode(Bool.self, forKey: key))
        case .date:
            guard let date = LocalDate(iso: try container.decode(String.self, forKey: key)) else { throw corrupted("date") }
            self = .date(date)
        case .time:
            guard let time = LocalTime(iso: try container.decode(String.self, forKey: key)) else { throw corrupted("time") }
            self = .time(time)
        case .timestamp:
            guard let instant = ISO.parseTimestamp(try container.decode(String.self, forKey: key), defaultZone: ISO.utc)
            else { throw corrupted("timestamp") }
            self = .timestamp(instant)
        case .reference: self = .reference(try container.decode(Reference.self, forKey: key))
        case .list: self = .list(try container.decode([Value].self, forKey: key))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text): try container.encode(text, forKey: .text)
        // JSON has no NaN/Infinity; a non-finite number must not make a document unsaveable.
        case .number(let number): try container.encode(number.isFinite ? number : 0, forKey: .number)
        case .bool(let bool): try container.encode(bool, forKey: .bool)
        case .date(let date): try container.encode(date.description, forKey: .date)
        case .time(let time): try container.encode(time.description, forKey: .time)
        case .timestamp(let instant): try container.encode(ISO.format(instant, in: ISO.utc, zulu: true), forKey: .timestamp)
        case .reference(let reference): try container.encode(reference, forKey: .reference)
        case .list(let items): try container.encode(items, forKey: .list)
        }
    }
}
