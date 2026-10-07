import Foundation

/// Ids of the built-in blocks the engine itself gives meaning to, and the conventions of their inputs.
public enum BuiltIn {
    public static let `if` = "control.if"
    public static let ifElse = "control.ifElse"
    public static let `return` = "control.return"
    public static let call = "control.call"
    public static let fail = "control.fail"
    /// The `text %template` reporter: a template written inline.
    public static let text = "operators.text"
    public static let templateInput = "template"
    public static let set = "variables.set"
    public static let setEntry = "map.setEntry"
    public static let removeEntry = "map.removeEntry"

    /// `if` / `if/else`: the boolean slot and the region names.
    public static let conditionInput = "condition"
    public static let thenRegion = "then"
    public static let elseRegion = "else"
    /// `fail with`: the slot with the error message.
    public static let messageInput = "message"
    /// What a `fail` with an empty message reports.
    public static let defaultFailureMessage = "The script failed"
    /// `call script`: the slot holding the callee's script id (a text literal) …
    public static let scriptInput = "script"
    /// … and the prefix of the slots carrying its arguments (`"arg.ticket"`).
    public static let argumentPrefix = "arg."
    /// `set variable`, `set entry`, `remove entry`: the slot naming the variable (a text literal) and the slot
    /// with the value.
    public static let nameInput = "name"
    public static let valueInput = "value"
    /// `set entry` / `remove entry`: the slot with the entry's key.
    public static let keyInput = "key"

    /// The script a `call script` block points at.
    public static func callee(of block: Block, in document: Document) -> Script? {
        guard case .literal(.text(let id))? = block.inputs[scriptInput] else { return nil }
        return document.script(id: id)
    }

    /// The variable a `set variable`, `set entry` or `remove entry` block writes.
    public static func setTarget(of block: Block) -> String? {
        guard [set, setEntry, removeEntry].contains(block.kind), case .literal(.text(let name))? = block.inputs[nameInput], !name.isEmpty else { return nil }
        return name
    }
}

extension Vocabulary {
    public static let control = BlockCategory(id: "control", title: "Control", color: BlockColor(hex: 0xFFAB19))
    public static let variables = BlockCategory(id: "variables", title: "Variables", color: BlockColor(hex: 0xFF8C1A))
    public static let operators = BlockCategory(id: "operators", title: "Operators", color: BlockColor(hex: 0x59C059))
    public static let time = BlockCategory(id: "time", title: "Time", color: BlockColor(hex: 0x5CB1D6))
    public static let lists = BlockCategory(id: "lists", title: "Lists", color: BlockColor(hex: 0xFF661A))
    public static let maps = BlockCategory(id: "maps", title: "Maps", color: BlockColor(hex: 0x0FA98C))

    /// The minimal built-in vocabulary: control, variables, operators, time, lists and maps.
    public static let builtIns: [BlockDefinition] = controlBlocks + variableBlocks + operatorBlocks + timeBlocks + listBlocks
        + mapBlocks

    // The interpreter executes these itself; their handlers are never called.
    private static let controlBlocks: [BlockDefinition] = [
        BlockDefinition(id: BuiltIn.if, shape: .cBlock, category: control, title: "if %condition then",
                        inputs: [.boolean(BuiltIn.conditionInput)], regions: [BuiltIn.thenRegion]) { _, _ in [:] },
        BlockDefinition(id: BuiltIn.ifElse, shape: .cBlock, category: control, title: "if %condition then",
                        inputs: [.boolean(BuiltIn.conditionInput)],
                        regions: [BuiltIn.thenRegion, BuiltIn.elseRegion]) { _, _ in [:] },
        BlockDefinition(id: BuiltIn.return, shape: .cap, category: control, title: "return") { _, _ in [:] },
        // Ends the whole run as failed, with the message — exactly as a handler throwing `BlockError` does. It
        // passes through `call script` (a failing callee fails its caller) and cannot be caught in a script.
        // The message is a template: `fail with "Ticket {ticket} has no title"`.
        BlockDefinition(id: BuiltIn.fail, shape: .cap, category: control, title: "fail with %message",
                        inputs: [.longText(BuiltIn.messageInput, interpolates: true)]) { _, _ in [:] },
        BlockDefinition(id: BuiltIn.call, shape: .statement, category: control, title: "call %script",
                        inputs: [InputDefinition(name: BuiltIn.scriptInput, types: [.text], editor: .script)]) { _, _ in [:] },
    ]

    private static let variableBlocks: [BlockDefinition] = [
        BlockDefinition(id: BuiltIn.set, shape: .statement, category: variables, title: "set %name to %value",
                        inputs: [InputDefinition(name: BuiltIn.nameInput, label: "variable", types: [.text], editor: .variable),
                                 .value(BuiltIn.valueInput)]) { _, _ in [:] },
    ]

    private static let operatorBlocks: [BlockDefinition] = {
        func comparison(_ id: String, _ symbol: String, _ test: @escaping @Sendable (ComparisonResult) -> Bool) -> BlockDefinition {
            .predicate("operator.\(id)", category: operators, title: "%a \(symbol) %b", inputs: [.value("a"), .value("b")]) { inputs, _ in
                test(Coercion.compare(inputs["a"], inputs["b"], in: inputs.environment))
            }
        }
        func arithmetic(_ id: String, _ symbol: String, _ operation: @escaping @Sendable (Double, Double) -> Double) -> BlockDefinition {
            .reporter("operator.\(id)", category: operators, title: "%a \(symbol) %b",
                      inputs: [.value("a", .number), .value("b", .number)], result: .number) { inputs, _ in
                // Numbers stay finite: overflow and division by zero give 0.
                let result = operation(inputs.number("a"), inputs.number("b"))
                return .number(result.isFinite ? result : 0)
            }
        }
        return [
            // The general way to write a template inline: `text "Escalated: {title} ({priority})"`. The slot
            // interpolates, so by the time the handler runs the placeholders are already filled in.
            .reporter(BuiltIn.text, category: operators, title: "text %template",
                      inputs: [.longText(BuiltIn.templateInput, interpolates: true)], result: .text) { inputs, _ in
                .text(inputs.text(BuiltIn.templateInput))
            },
            comparison("equals", "=") { $0 == .orderedSame },
            comparison("notEquals", "≠") { $0 != .orderedSame },
            comparison("less", "<") { $0 == .orderedAscending },
            comparison("greater", ">") { $0 == .orderedDescending },
            .predicate("operator.and", category: operators, title: "%a and %b", inputs: [.boolean("a"), .boolean("b")]) { inputs, _ in
                inputs.bool("a") && inputs.bool("b")
            },
            .predicate("operator.or", category: operators, title: "%a or %b", inputs: [.boolean("a"), .boolean("b")]) { inputs, _ in
                inputs.bool("a") || inputs.bool("b")
            },
            .predicate("operator.not", category: operators, title: "not %a", inputs: [.boolean("a")]) { inputs, _ in
                !inputs.bool("a")
            },
            arithmetic("add", "+") { $0 + $1 },
            arithmetic("subtract", "−") { $0 - $1 },
            arithmetic("multiply", "×") { $0 * $1 },
            arithmetic("divide", "÷") { $0 / $1 },
            .reporter("operator.join", category: operators, title: "join %a %b",
                      inputs: [.value("a", .text), .value("b", .text)], result: .text) { inputs, _ in
                .text(inputs.text("a") + inputs.text("b"))
            },
            .predicate("operator.contains", category: operators, title: "%text contains %part",
                       inputs: [.value("text", .text), .value("part", .text)]) { inputs, _ in
                inputs.text("text").range(of: inputs.text("part"), options: .caseInsensitive) != nil
            },
            .predicate("operator.startsWith", category: operators, title: "%text starts with %prefix",
                       inputs: [.value("text", .text), .value("prefix", .text)]) { inputs, _ in
                let prefix = inputs.text("prefix")
                return prefix.isEmpty || inputs.text("text").range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
            },
            .predicate("operator.matches", category: operators, title: "%text matches regex %pattern",
                       inputs: [.value("text", .text), .value("pattern", .text)]) { inputs, _ in
                // An invalid pattern matches nothing rather than failing the run.
                guard let regex = try? NSRegularExpression(pattern: inputs.text("pattern")) else { return false }
                let text = inputs.text("text")
                return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            },
            .predicate("operator.isEmpty", category: operators, title: "%value is empty", inputs: [.value("value")]) { inputs, _ in
                inputs.text("value").isEmpty
            },
            .reporter("operator.length", category: operators, title: "length of %text",
                      inputs: [.value("text", .text)], result: .number) { inputs, _ in
                .number(Double(inputs.text("text").count))
            },
            // Fixed-point text, the same on every machine: `.` as the decimal separator and no grouping.
            .reporter("operator.formatNumber", category: operators, title: "format number %number with %decimals decimals",
                      inputs: [.value("number", .number), .value("decimals", .number, default: 2)], result: .text) { inputs, _ in
                .text(Formatting.fixedPoint(inputs["number"], decimals: inputs.number("decimals")))
            },
        ]
    }()

    private static let timeBlocks: [BlockDefinition] = {
        let moment = InputDefinition(name: "to", types: [.date, .timestamp], editor: .timestamp)
        func shift(_ id: String, _ unit: String, seconds: Double) -> BlockDefinition {
            .reporter("time.\(id)", category: time, title: "add %amount \(unit) to %to",
                      inputs: [.value("amount", .number, default: 1), InputDefinition(name: "to", types: [.timestamp, .time], editor: .timestamp)],
                      result: nil) { inputs, _ in
                TimeMath.shift(inputs["to"], bySeconds: inputs.number("amount") * seconds, in: inputs.environment)
            }
        }
        return [
            .reporter("time.now", category: time, title: "now", result: .timestamp) { _, context in .timestamp(context.now) },
            .reporter("time.today", category: time, title: "today", result: .date) { inputs, context in
                Coercion.convert(.timestamp(context.now), to: .date, in: inputs.environment)
            },
            .reporter("time.dateOf", category: time, title: "date of %timestamp",
                      inputs: [.value("timestamp", .timestamp)], result: .date) { inputs, _ in
                inputs.date("timestamp").map(Value.date) ?? .empty
            },
            .reporter("time.timeOf", category: time, title: "time of %timestamp",
                      inputs: [.value("timestamp", .timestamp)], result: .time) { inputs, _ in
                inputs.time("timestamp").map(Value.time) ?? .empty
            },
            .reporter("time.makeTimestamp", category: time, title: "timestamp from %date at %time",
                      inputs: [.value("date", .date), .value("time", .time)], result: .timestamp) { inputs, _ in
                guard let date = inputs.date("date"), let time = inputs.time("time"),
                      let instant = Coercion.timestamp(date: date, time: time, in: inputs.environment) else { return .empty }
                return .timestamp(instant)
            },
            .reporter("time.addDays", category: time, title: "add %amount days to %to",
                      inputs: [.value("amount", .number, default: 1), moment], result: nil) { inputs, _ in
                TimeMath.shift(inputs["to"], byDays: inputs.number("amount"), in: inputs.environment)
            },
            shift("addHours", "hours", seconds: 3600),
            shift("addMinutes", "minutes", seconds: 60),
            // A Unicode (TR35) pattern such as `yyyy-MM-dd`, `HH:mm` or `d. M. yyyy`, in the fixed `en_US_POSIX`
            // locale so the result does not depend on the machine. A timestamp is shown in the environment's zone.
            .reporter("time.format", category: time, title: "format %value as %pattern",
                      inputs: [InputDefinition(name: "value", types: [.timestamp, .date, .time], editor: .timestamp),
                               .value("pattern", .text, default: "yyyy-MM-dd")], result: .text) { inputs, _ in
                .text(Formatting.temporal(inputs["value"], pattern: inputs.text("pattern"), in: inputs.environment))
            },
        ]
    }()

    private static let listBlocks: [BlockDefinition] = [
        .reporter("list.split", category: lists, title: "split %text by %separator",
                  inputs: [.value("text", .text), .value("separator", .text, default: ",")], result: .list) { inputs, _ in
            let text = inputs.text("text"), separator = inputs.text("separator")
            if text.isEmpty { return .list([]) }
            if separator.isEmpty { return .list([.text(text)]) }
            return .list(text.components(separatedBy: separator).map(Value.text))
        },
        .reporter("list.join", category: lists, title: "join %list with %separator",
                  inputs: [.value("list", .list), .value("separator", .text, default: ", ")], result: .text) { inputs, _ in
            .text(inputs.list("list").map { Coercion.toText($0, in: inputs.environment) }.joined(separator: inputs.text("separator")))
        },
        // 1-based, as in Scratch; out of range gives the empty value.
        .reporter("list.item", category: lists, title: "item %index of %list",
                  inputs: [.value("index", .number, default: 1), .value("list", .list)], result: nil) { inputs, _ in
            let items = inputs.list("list"), index = inputs.number("index").rounded()
            guard index >= 1, index <= Double(items.count) else { return .empty }
            return items[Int(index) - 1]
        },
        .reporter("list.length", category: lists, title: "length of %list",
                  inputs: [.value("list", .list)], result: .number) { inputs, _ in
            .number(Double(inputs.list("list").count))
        },
        .predicate("list.contains", category: lists, title: "%list contains %item",
                   inputs: [.value("list", .list), .value("item")]) { inputs, _ in
            inputs.list("list").contains { Coercion.equal($0, inputs["item"], in: inputs.environment) }
        },
    ]
}

extension Vocabulary {
    /// Maps are values: none of these changes a map in place. The reporters return a new map; the two
    /// statements rebind a variable to a new map.
    private static let mapBlocks: [BlockDefinition] = {
        let variable = InputDefinition(name: BuiltIn.nameInput, label: "variable", types: [.text], editor: .variable)
        return [
            .reporter("map.empty", category: maps, title: "empty map", result: .map) { _, _ in .map(OrderedMap()) },
            .reporter("map.with", category: maps, title: "%map with %key = %value",
                      inputs: [.map("map"), .value("key", .text), .value("value")], result: .map) { inputs, _ in
                .map(inputs.map("map").setting(inputs.text("key"), inputs["value"]))
            },
            .reporter("map.without", category: maps, title: "%map without %key",
                      inputs: [.map("map"), .value("key", .text)], result: .map) { inputs, _ in
                .map(inputs.map("map").removing(inputs.text("key")))
            },
            .reporter("map.value", category: maps, title: "value of %key in %map",
                      inputs: [.value("key", .text), .map("map")], result: nil) { inputs, _ in
                inputs.map("map")[inputs.text("key")] ?? .empty
            },
            .predicate("map.hasKey", category: maps, title: "%map has key %key",
                       inputs: [.map("map"), .value("key", .text)]) { inputs, _ in
                inputs.map("map").contains(inputs.text("key"))
            },
            .reporter("map.keys", category: maps, title: "keys of %map", inputs: [.map("map")], result: .list) { inputs, _ in
                .list(inputs.map("map").keys.map(Value.text))
            },
            .reporter("map.count", category: maps, title: "number of entries in %map",
                      inputs: [.map("map")], result: .number) { inputs, _ in
                .number(Double(inputs.map("map").count))
            },
            // The interpreter executes the two statements itself (they write a variable); their handlers are never called.
            //
            // Sugar over rebinding: afterwards the variable holds a *new* map — its old map with the entry set,
            // or a map with just this entry when the variable was unset or not a map. A map that was already
            // copied into another variable, or passed to a block, is unchanged.
            BlockDefinition(id: BuiltIn.setEntry, shape: .statement, category: maps, title: "set entry %key of %name to %value",
                            inputs: [.value(BuiltIn.keyInput, .text), variable, .value(BuiltIn.valueInput)]) { _, _ in [:] },
            // Likewise rebinds the variable to a new map without the entry; copies held elsewhere are unchanged.
            BlockDefinition(id: BuiltIn.removeEntry, shape: .statement, category: maps, title: "remove entry %key of %name",
                            inputs: [.value(BuiltIn.keyInput, .text), variable]) { _, _ in [:] },
        ]
    }()
}

/// Formatting for the `format … as …` and `format number …` blocks. Pure, total (what cannot be formatted
/// gives the empty text) and deterministic: the locale is always `en_US_POSIX`, never the machine's.
enum Formatting {
    /// Formats a date, time or timestamp with a Unicode (TR35 / `DateFormatter`) pattern.
    ///
    /// A timestamp is shown in the environment's zone. A date or a time has no zone and is formatted as is; the
    /// fields it lacks read as midnight and as 2000-01-01. Anything else is coerced — to a timestamp, else a
    /// date, else a time — and gives the empty text when none of them works.
    static func temporal(_ value: Value, pattern: String, in environment: RunEnvironment) -> String {
        let instant: Date
        let zone: TimeZone
        switch value {
        case .timestamp(let timestamp):
            (instant, zone) = (timestamp, environment.timeZone)
        case .date(let date):
            guard let midnight = ISO.instant(date, LocalTime(hour: 0, minute: 0)!, in: ISO.utc) else { return "" }
            (instant, zone) = (midnight, ISO.utc)
        case .time(let time):
            guard let reference = LocalDate(year: 2000, month: 1, day: 1), let moment = ISO.instant(reference, time, in: ISO.utc)
            else { return "" }
            (instant, zone) = (moment, ISO.utc)
        default:
            if let timestamp = Coercion.toTimestamp(value, in: environment) {
                return temporal(.timestamp(timestamp), pattern: pattern, in: environment)
            } else if let date = Coercion.toDate(value, in: environment) {
                return temporal(.date(date), pattern: pattern, in: environment)
            } else if let time = Coercion.toTime(value, in: environment) {
                return temporal(.time(time), pattern: pattern, in: environment)
            }
            return ""
        }
        // Made on demand: a formatter is not `Sendable`, so none is kept around.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = ISO.calendar(zone)
        formatter.timeZone = zone
        formatter.dateFormat = pattern
        return formatter.string(from: instant)
    }

    /// Fixed-point text with `.` as the decimal separator and no grouping; halves round away from zero.
    /// `decimals` is rounded and clamped to 0…10. A value that is not numeric gives the empty text.
    static func fixedPoint(_ value: Value, decimals: Double) -> String {
        guard let number = Coercion.numeric(value), number.isFinite else { return "" }
        let places = Int(max(0, min(10, decimals.isFinite ? decimals.rounded() : 0)))
        let scaled = (abs(number) * pow(10, Double(places))).rounded(.toNearestOrAwayFromZero)
        guard scaled.isFinite else { return "" }
        // The scaled value is integral, so "%.0f" prints exactly its digits; then the point is put back.
        var digits = String(format: "%.0f", scaled)
        if digits.count <= places { digits = String(repeating: "0", count: places - digits.count + 1) + digits }
        let whole = digits.dropLast(places), fraction = digits.suffix(places)
        let sign = number < 0 && scaled != 0 ? "-" : ""
        return sign + whole + (places > 0 ? "." + fraction : "")
    }
}

/// Date and time arithmetic for the built-in time blocks. Total: what cannot be shifted gives the empty value.
enum TimeMath {
    /// A date moves by whole calendar days; a timestamp moves by calendar days in the environment's zone
    /// (so it keeps its wall-clock time across a DST change).
    static func shift(_ value: Value, byDays amount: Double, in environment: RunEnvironment) -> Value {
        let days = Int(max(-1e7, min(1e7, amount.rounded())))
        var value = value
        if case .text(let text) = value, let date = LocalDate(iso: text.trimmingCharacters(in: .whitespaces)) {
            value = .date(date)
        }
        if case .date(let date) = value {
            guard let start = ISO.instant(date, LocalTime(hour: 0, minute: 0)!, in: ISO.utc),
                  let shifted = ISO.localDate(of: start.addingTimeInterval(Double(days) * 86_400), in: ISO.utc)
            else { return .empty }
            return .date(shifted)
        }
        guard let instant = Coercion.toTimestamp(value, in: environment),
              let shifted = ISO.calendar(environment.timeZone).date(byAdding: .day, value: days, to: instant)
        else { return .empty }
        return .timestamp(shifted)
    }

    /// A time of day wraps around midnight; a timestamp (or a date, taken at its midnight) moves by exact seconds.
    static func shift(_ value: Value, bySeconds amount: Double, in environment: RunEnvironment) -> Value {
        let seconds = max(-1e12, min(1e12, amount))
        var value = value
        if case .text(let text) = value, let time = LocalTime(iso: text.trimmingCharacters(in: .whitespaces)) {
            value = .time(time)
        }
        if case .time(let time) = value {
            let day = 86_400
            let total = time.hour * 3600 + time.minute * 60 + time.second + Int(seconds.rounded())
            let wrapped = ((total % day) + day) % day
            return LocalTime(hour: wrapped / 3600, minute: wrapped % 3600 / 60, second: wrapped % 60).map(Value.time) ?? .empty
        }
        guard let instant = Coercion.toTimestamp(value, in: environment) else { return .empty }
        return .timestamp(instant.addingTimeInterval(seconds))
    }
}
