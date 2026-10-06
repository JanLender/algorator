import Foundation

/// Scratch-style casts: total, pure functions that never raise a type error.
public enum Coercion {

    // MARK: Number

    /// Numbers pass through; text is trimmed and parsed as a decimal (`.` or `,`); `bool` is 1/0; anything else is 0.
    public static func toNumber(_ value: Value) -> Double {
        numeric(value) ?? 0
    }

    /// The number a value denotes, or `nil` when it is not numeric (blank or unparsable text, dates, lists, …).
    public static func numeric(_ value: Value) -> Double? {
        switch value {
        case .number(let number): return number
        case .bool(let bool): return bool ? 1 : 0
        case .text(let text): return parseDecimal(text)
        default: return nil
        }
    }

    static func parseDecimal(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        var sawDigit = false, sawSeparator = false, sawExponent = false
        var previous: Character?
        for character in trimmed {
            switch character {
            case "0"..."9": sawDigit = true
            case "+", "-": guard previous == nil || previous == "e" || previous == "E" else { return nil }
            case ".": guard !sawSeparator, !sawExponent else { return nil }; sawSeparator = true
            case "e", "E": guard sawDigit, !sawExponent else { return nil }; sawExponent = true
            default: return nil
            }
            previous = character
        }
        guard sawDigit, let number = Double(trimmed), number.isFinite else { return nil }
        return number
    }

    // MARK: Text

    /// Canonical text: integral numbers without `.0`, `true`/`false`, `yyyy-MM-dd`, `HH:mm[:ss]`,
    /// ISO 8601 with the environment's zone offset, a reference's id, list items joined by newlines, and a map
    /// as compact JSON with its keys in entry order (`{"title":"High","n":2}`).
    public static func toText(_ value: Value, in environment: RunEnvironment) -> String {
        switch value {
        case .text(let text): return text
        case .number(let number): return text(of: number)
        case .bool(let bool): return bool ? "true" : "false"
        case .date(let date): return date.description
        case .time(let time): return time.description
        case .timestamp(let instant): return ISO.format(instant, in: environment.timeZone)
        case .reference(let reference): return reference.id
        case .list(let items): return items.map { toText($0, in: environment) }.joined(separator: "\n")
        case .map(let map): return JSONText.write(map, in: environment)
        }
    }

    static func text(of number: Double) -> String {
        if number.isNaN { return "NaN" }
        if number.isInfinite { return number < 0 ? "-Infinity" : "Infinity" }
        if number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }
        return "\(number)"
    }

    // MARK: Bool

    /// `""`, `"0"`, `"false"` (any case), `0`, an empty list, an empty map and an empty reference id are false;
    /// everything else is true.
    public static func toBool(_ value: Value) -> Bool {
        switch value {
        case .bool(let bool): return bool
        case .text(let text): return !(text.isEmpty || text == "0" || text.lowercased() == "false")
        case .number(let number): return number != 0
        case .list(let items): return !items.isEmpty
        case .map(let map): return !map.isEmpty
        case .reference(let reference): return !reference.id.isEmpty
        case .date, .time, .timestamp: return true
        }
    }

    // MARK: Temporal

    /// A date as is, a timestamp's day in the environment's zone, or ISO text (a date or a timestamp).
    public static func toDate(_ value: Value, in environment: RunEnvironment) -> LocalDate? {
        switch value {
        case .date(let date): return date
        case .timestamp(let instant): return ISO.localDate(of: instant, in: environment.timeZone)
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let date = LocalDate(iso: trimmed) { return date }
            return ISO.parseTimestamp(trimmed, defaultZone: environment.timeZone)
                .flatMap { ISO.localDate(of: $0, in: environment.timeZone) }
        default: return nil
        }
    }

    /// A time as is, a timestamp's time of day in the environment's zone, or ISO text (a time or a timestamp).
    public static func toTime(_ value: Value, in environment: RunEnvironment) -> LocalTime? {
        switch value {
        case .time(let time): return time
        case .timestamp(let instant): return ISO.localTime(of: instant, in: environment.timeZone)
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let time = LocalTime(iso: trimmed) { return time }
            return ISO.parseTimestamp(trimmed, defaultZone: environment.timeZone)
                .flatMap { ISO.localTime(of: $0, in: environment.timeZone) }
        default: return nil
        }
    }

    /// A timestamp as is, a date's midnight in the environment's zone, or ISO text (a timestamp or a date).
    public static func toTimestamp(_ value: Value, in environment: RunEnvironment) -> Date? {
        switch value {
        case .timestamp(let instant): return instant
        case .date(let date): return timestamp(date: date, time: LocalTime(hour: 0, minute: 0)!, in: environment)
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let instant = ISO.parseTimestamp(trimmed, defaultZone: environment.timeZone) { return instant }
            return LocalDate(iso: trimmed).flatMap { toTimestamp(.date($0), in: environment) }
        default: return nil
        }
    }

    /// The instant at which the environment's zone shows `date` and `time`.
    public static func timestamp(date: LocalDate, time: LocalTime, in environment: RunEnvironment) -> Date? {
        ISO.instant(date, time, in: environment.timeZone)
    }

    // MARK: Map

    /// A map as is; text that is a valid JSON object is parsed (arrays become lists, objects maps, `null` the
    /// empty value); anything else is the empty map.
    ///
    /// `toMap(.text(toText(map)))` gives the map back when its values survive JSON (text, number, bool, list,
    /// map). Dates, times, timestamps and references come back as text.
    public static func toMap(_ value: Value) -> OrderedMap {
        switch value {
        case .map(let map): return map
        case .text(let text): return JSONText.readObject(text) ?? OrderedMap()
        default: return OrderedMap()
        }
    }

    // MARK: List, reference

    /// A list as is; empty text is the empty list; any other value is a one-item list.
    public static func toList(_ value: Value) -> [Value] {
        switch value {
        case .list(let items): return items
        case .text(""): return []
        default: return [value]
        }
    }

    /// A reference as is; any other value becomes a reference of `kind` whose id is the value's text.
    public static func toReference(_ value: Value, kind: String, in environment: RunEnvironment) -> Reference {
        if case .reference(let reference) = value { return reference }
        return Reference(kind: kind, id: toText(value, in: environment))
    }

    // MARK: Generic

    /// Casts to `type`. Where no conversion exists (e.g. a number to a date) the result is the empty value.
    public static func convert(_ value: Value, to type: ValueType, referenceKind: String? = nil,
                               in environment: RunEnvironment) -> Value {
        switch type {
        case .text: return .text(toText(value, in: environment))
        case .number: return .number(toNumber(value))
        case .bool: return .bool(toBool(value))
        case .date: return toDate(value, in: environment).map(Value.date) ?? .empty
        case .time: return toTime(value, in: environment).map(Value.time) ?? .empty
        case .timestamp: return toTimestamp(value, in: environment).map(Value.timestamp) ?? .empty
        case .reference: return .reference(toReference(value, kind: referenceKind ?? "", in: environment))
        case .list: return .list(toList(value))
        case .map: return .map(toMap(value))
        }
    }

    // MARK: Compare

    /// Orders two values: chronologically when either is temporal and the other converts, numerically when
    /// both are numeric, references by kind and id, otherwise as case-insensitive text. Two maps are equal when
    /// they have the same keys with `compare`-equal values, in any order.
    public static func compare(_ a: Value, _ b: Value, in environment: RunEnvironment) -> ComparisonResult {
        if let result = temporalCompare(a, b, in: environment) { return result }
        if case .reference(let x) = a, case .reference(let y) = b {
            return x.kind == y.kind ? order(x.id, y.id) : order(x.kind, y.kind)
        }
        if let x = numeric(a), let y = numeric(b) { return order(x, y) }
        let textA = toText(a, in: environment), textB = toText(b, in: environment)
        guard case .map(let x) = a, case .map(let y) = b else {
            return textA.compare(textB, options: .caseInsensitive)
        }
        if x.count == y.count, x.entries.allSatisfy({ entry in y[entry.key].map { equal(entry.value, $0, in: environment) } ?? false }) {
            return .orderedSame
        }
        // Different maps order by their text; when only letter case tells them apart (keys are exact), by that.
        let result = textA.compare(textB, options: .caseInsensitive)
        return result == .orderedSame ? order(textA, textB) : result
    }

    /// `compare(a, b) == .orderedSame`.
    public static func equal(_ a: Value, _ b: Value, in environment: RunEnvironment) -> Bool {
        compare(a, b, in: environment) == .orderedSame
    }

    private static func temporalCompare(_ a: Value, _ b: Value, in environment: RunEnvironment) -> ComparisonResult? {
        let temporal: Set<ValueType> = [.date, .time, .timestamp]
        let target: ValueType
        switch (temporal.contains(a.type), temporal.contains(b.type)) {
        case (false, false): return nil
        case (true, false): target = a.type
        case (false, true): target = b.type
        case (true, true):
            // Mixed temporal types meet at the coarser one, so the result does not depend on argument order.
            if a.type == b.type { target = a.type }
            else if a.type == .timestamp { target = b.type }
            else if b.type == .timestamp { target = a.type }
            else { return nil }
        }
        switch target {
        case .date:
            guard let x = toDate(a, in: environment), let y = toDate(b, in: environment) else { return nil }
            return order(x, y)
        case .time:
            guard let x = toTime(a, in: environment), let y = toTime(b, in: environment) else { return nil }
            return order(x, y)
        default:
            guard let x = toTimestamp(a, in: environment), let y = toTimestamp(b, in: environment) else { return nil }
            return order(x, y)
        }
    }

    private static func order<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
}
