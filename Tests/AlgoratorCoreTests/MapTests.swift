import XCTest
import AlgoratorCore
import TicketDemo

final class OrderedMapTests: XCTestCase {

    func testSettingAppendsOrReplacesInPlace() {
        var map = OrderedMap()
        XCTAssertTrue(map.isEmpty)
        map.set("title", "Low")
        map.set("n", 1)
        map.set("flag", true)
        XCTAssertEqual(map.keys, ["title", "n", "flag"])
        map.set("title", "High")
        XCTAssertEqual(map.keys, ["title", "n", "flag"], "replacing keeps the position")
        XCTAssertEqual(map["title"], "High")
        XCTAssertEqual(map.count, 3)
        XCTAssertNil(map["absent"])
        XCTAssertTrue(map.contains("n"))
        XCTAssertFalse(map.contains("N"), "keys are case-sensitive")
        XCTAssertFalse(map.contains(" n"), "and not trimmed")
    }

    func testRemoving() {
        var map: OrderedMap = ["a": 1, "b": 2, "c": 3]
        map.remove("b")
        XCTAssertEqual(map.keys, ["a", "c"])
        map.remove("nope")
        XCTAssertEqual(map.keys, ["a", "c"])
        map.set("b", 9)
        XCTAssertEqual(map.keys, ["a", "c", "b"], "a removed key comes back at the end")
    }

    func testDuplicateKeysInInputKeepTheFirstPositionAndTheLastValue() {
        let map = OrderedMap([.init(key: "a", value: 1), .init(key: "b", value: 2), .init(key: "a", value: 3)])
        XCTAssertEqual(map.entries, [.init(key: "a", value: 3), .init(key: "b", value: 2)])
        let literal: OrderedMap = ["x": 1, "x": 2]
        XCTAssertEqual(literal.entries, [.init(key: "x", value: 2)])
    }

    func testValueSemantics() {
        let original: OrderedMap = ["a": 1, "inner": .map(["deep": "x"])]
        var copy = original
        copy.set("a", 2)
        copy.set("b", 3)
        copy.remove("inner")
        XCTAssertEqual(original, ["a": 1, "inner": .map(["deep": "x"])])
        XCTAssertEqual(copy, ["a": 2, "b": 3])

        // The non-mutating forms leave the receiver alone.
        let extended = original.setting("c", true)
        let reduced = original.removing("a")
        XCTAssertEqual(original.keys, ["a", "inner"])
        XCTAssertEqual(extended.keys, ["a", "inner", "c"])
        XCTAssertEqual(reduced.keys, ["inner"])

        // Inside a Value, too.
        let held = Value.map(original)
        var changed = original
        changed.set("a", 99)
        XCTAssertEqual(held, .map(["a": 1, "inner": .map(["deep": "x"])]))
    }

    func testEqualityAndHashingAreExactIncludingOrder() {
        let ab: OrderedMap = ["a": 1, "b": 2], ba: OrderedMap = ["b": 2, "a": 1]
        XCTAssertEqual(ab, ["a": 1, "b": 2])
        XCTAssertNotEqual(ab, ba)
        XCTAssertEqual(Set([ab, ab, ba]).count, 2)
        XCTAssertEqual(Value.map(ab).type, .map)
    }
}

final class MapCoercionTests: XCTestCase {
    private let sample: OrderedMap = ["title": "High", "n": 2]

    // MARK: toText

    func testToTextIsCompactJSONInEntryOrder() {
        let cases: [(OrderedMap, String)] = [
            ([:], "{}"),
            (sample, #"{"title":"High","n":2}"#),
            (["n": 2, "title": "High"], #"{"n":2,"title":"High"}"#),
            (["a": 2.5, "b": -3, "c": 1_000_000, "d": .number(1e21)], #"{"a":2.5,"b":-3,"c":1000000,"d":1e+21}"#),
            (["t": true, "f": false, "e": ""], #"{"t":true,"f":false,"e":""}"#),
            (["d": date("2026-10-04"), "t": time("09:30"), "s": stamp("2026-10-04T10:00:00Z")],
             #"{"d":"2026-10-04","t":"09:30","s":"2026-10-04T12:00:00+02:00"}"#),   // Prague, like toText
            (["who": ref("user", "alice")], #"{"who":"alice"}"#),
            (["list": .list(["a", 1, true, .list([])])], #"{"list":["a",1,true,[]]}"#),
            (["inner": .map(["deep": .map([:]), "x": 1])], #"{"inner":{"deep":{},"x":1}}"#),
            (["quote\"d": "line\nbreak\ttab\\slash", "ctl": "\u{1}"], #"{"quote\"d":"line\nbreak\ttab\\slash","ctl":"\u0001"}"#),
            (["emoji": "😀", "čeština": "ř"], #"{"emoji":"😀","čeština":"ř"}"#),
            (["bad": .number(.infinity)], #"{"bad":null}"#),
        ]
        for (map, expected) in cases {
            XCTAssertEqual(Coercion.toText(.map(map), in: env), expected)
        }
        XCTAssertEqual(Coercion.toText(.list([.map(sample), "x"]), in: env), "{\"title\":\"High\",\"n\":2}\nx",
                       "a list still joins its items by newlines")
    }

    // MARK: toMap

    func testToMapParsesJSONObjectText() {
        let cases: [(String, OrderedMap)] = [
            ("{}", [:]),
            (" { } ", [:]),
            (#"{"title":"High","n":2}"#, sample),
            ("{ \"title\" : \"High\" ,\n\t\"n\" : 2 }", sample),
            (#"{"n":2,"title":"High"}"#, ["n": 2, "title": "High"]),
            (#"{"a":-2.5,"b":1e3,"c":0,"d":1.5E-1}"#, ["a": -2.5, "b": 1000, "c": 0, "d": 0.15]),
            (#"{"t":true,"f":false,"nothing":null}"#, ["t": true, "f": false, "nothing": .empty]),
            (#"{"list":["a",1,true,[],{"k":null}]}"#, ["list": .list(["a", 1, true, .list([]), .map(["k": .empty])])]),
            (#"{"inner":{"deep":{},"x":1}}"#, ["inner": .map(["deep": .map([:]), "x": 1])]),
            (#"{"esc":"a\"b\\c\/d\n\t\r\b\f","u":"\u00e9\u0041","pair":"\ud83d\ude00"}"#,
             ["esc": "a\"b\\c/d\n\t\r\u{8}\u{c}", "u": "éA", "pair": "😀"]),
            (#"{"a":1,"b":2,"a":3}"#, ["a": 3, "b": 2]),           // duplicate: last value, first position
            (#"{"":1}"#, ["": 1]),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(Coercion.toMap(.text(text)), expected, text)
        }
    }

    func testToMapOfAnythingElseIsTheEmptyMap() {
        XCTAssertEqual(Coercion.toMap(.map(sample)), sample, "a map passes through")
        let notObjects = ["", "   ", "hello", "[]", "[1,2]", "\"text\"", "12", "true", "null",
                          "{", "}", "{\"a\"}", "{\"a\":}", "{\"a\":1,}", "{a:1}", "{'a':1}", "{\"a\":1} extra", "{\"a\":01x}",
                          "{\"a\":\"unterminated}", "{\"a\":\"bad \\x escape\"}", "{\"a\":\"\\ud83d\"}", "{\"a\":1.}", "{\"a\":-}",
                          "{\"a\":tru}", "{\"a\":[1,]}", "{\"a\":1e999}", "{\"a\":\"raw\nnewline\"}"]
        for text in notObjects {
            XCTAssertEqual(Coercion.toMap(.text(text)), [:], text)
        }
        for value: Value in [0, 5, true, date("2026-10-04"), time("09:30"), stamp("2026-10-04T10:00:00Z"), ref("user", "{}"),
                             .list([]), .list([.map(sample)])] {
            XCTAssertEqual(Coercion.toMap(value), [:], "\(value)")
        }
        XCTAssertEqual(Coercion.toMap(.text(String(repeating: "{\"a\":", count: 500) + "1" + String(repeating: "}", count: 500))), [:],
                       "absurd nesting is refused, not crashed on")
    }

    func testTextRoundTrip() {
        let survivors: [OrderedMap] = [
            [:], sample, ["n": 2.5, "t": true, "e": "", "list": .list(["a", 1, .list([false])]), "inner": .map(["x": .map(["y": "z"])])],
            ["weird \"key\"\n": "va\\lue\t", "😀": "ř"],
        ]
        for map in survivors {
            XCTAssertEqual(Coercion.toMap(.text(Coercion.toText(.map(map), in: env))), map)
        }
        // Dates, times, timestamps and references come back as text. Expected.
        let temporal: OrderedMap = ["d": date("2026-10-04"), "t": time("09:30"), "who": ref("user", "alice")]
        XCTAssertEqual(Coercion.toMap(.text(Coercion.toText(.map(temporal), in: env))),
                       ["d": "2026-10-04", "t": "09:30", "who": "alice"])
    }

    // MARK: The other casts

    func testOtherCastsOfAMap() {
        XCTAssertEqual(Coercion.toBool(.map([:])), false)
        XCTAssertEqual(Coercion.toBool(.map(["a": false])), true)
        XCTAssertEqual(Coercion.toNumber(.map(sample)), 0)
        XCTAssertNil(Coercion.numeric(.map(["n": 2])))
        XCTAssertEqual(Coercion.toList(.map(sample)), [.map(sample)], "like any non-list: one item")
        XCTAssertEqual(Coercion.toList(.map([:])), [.map([:])])
        XCTAssertNil(Coercion.toDate(.map(sample), in: env))
        XCTAssertNil(Coercion.toTime(.map(sample), in: env))
        XCTAssertNil(Coercion.toTimestamp(.map(sample), in: env))
        XCTAssertEqual(Coercion.toReference(.map(["a": 1]), kind: "user", in: env), Reference(kind: "user", id: #"{"a":1}"#))
    }

    func testConvertToAndFromMap() {
        XCTAssertEqual(Coercion.convert(.text(#"{"a":1}"#), to: .map, in: env), .map(["a": 1]))
        XCTAssertEqual(Coercion.convert("nonsense", to: .map, in: env), .map([:]))
        XCTAssertEqual(Coercion.convert(5, to: .map, in: env), .map([:]))
        XCTAssertEqual(Coercion.convert(.map(sample), to: .text, in: env), .text(#"{"title":"High","n":2}"#))
        XCTAssertEqual(Coercion.convert(.map(sample), to: .bool, in: env), true)
        XCTAssertEqual(Coercion.convert(.map(sample), to: .number, in: env), 0)
        XCTAssertEqual(Coercion.convert(.map(sample), to: .list, in: env), .list([.map(sample)]))
        XCTAssertEqual(Coercion.convert(.map(sample), to: .date, in: env), .empty)
        // Total over the new type as well.
        for type in ValueType.allCases {
            let converted = Coercion.convert(.map(sample), to: type, referenceKind: "user", in: env)
            XCTAssertTrue(converted.type == type || converted == .empty, "\(type)")
        }
    }

    // MARK: compare

    func testCompareMaps() {
        let asc = ComparisonResult.orderedAscending, same = ComparisonResult.orderedSame
        let cases: [(Value, Value, ComparisonResult)] = [
            // both maps: equal when the same keys hold compare-equal values, in any order
            (.map([:]), .map([:]), same),
            (.map(sample), .map(sample), same),
            (.map(["a": 1, "b": 2]), .map(["b": 2, "a": 1]), same),
            (.map(["a": "HIGH", "n": "2"]), .map(["n": 2, "a": "high"]), same),
            (.map(["d": date("2026-10-04")]), .map(["d": "2026-10-04"]), same),
            (.map(["in": .map(["x": 1, "y": 2])]), .map(["in": .map(["y": 2, "x": 1])]), same),
            // different maps order by their text
            (.map(["a": 1]), .map(["a": 2]), asc),
            (.map(["a": 1]), .map(["b": 1]), asc),
            // … which is plain text order, not "smaller map first": `{"a":1,` sorts before `{"a":1}`, `{"` before `{}`
            (.map(["a": 1, "b": 2]), .map(["a": 1]), asc),
            (.map(["a": 1]), .map([:]), asc),
            (.map(["A": 1]), .map(["a": 1]), asc),          // keys are exact, so these differ
            (.map(["a": 1, "b": 2]), .map(["a": 1, "c": 2]), asc),
            // a map against anything else: text against text, case-insensitively
            (.map(["a": "X"]), #"{"A":"x"}"#, same),
            (.map(sample), #"{"title":"High","n":2}"#, same),
            (.map(["a": 1]), #"{"b":1}"#, asc),
            (.map([:]), "{}", same),
            ("abc", .map([:]), asc),
            (5, .map([:]), asc),                             // "5" < "{}"
            (.map(["a": 1]), .list([.map(["a": 1])]), same), // a one-item list reads as its item
        ]
        for (a, b, expected) in cases {
            XCTAssertEqual(Coercion.compare(a, b, in: env), expected, "\(a) vs \(b)")
            let mirrored: ComparisonResult = expected == same ? same : .orderedDescending
            XCTAssertEqual(Coercion.compare(b, a, in: env), mirrored, "\(b) vs \(a)")
            XCTAssertEqual(Coercion.equal(a, b, in: env), expected == same, "\(a) = \(b)")
        }
    }
}

final class MapDocumentTests: XCTestCase {
    private func document(_ value: Value) -> Document {
        Document(scripts: [Script(id: "s", name: "S", body: [Block(id: "b", kind: "k", inputs: ["m": .literal(value)])])])
    }

    func testMapSerialisesAsAnArrayOfPairs() throws {
        let json = String(decoding: try document(.map(["title": "x", "n": 2])).jsonData(), as: UTF8.self)
        let compact = json.filter { !$0.isWhitespace }
        XCTAssertTrue(compact.contains(#"{"map":[{"key":"title","value":{"text":"x"}},{"key":"n","value":{"number":2}}]}"#), json)
    }

    func testNestedMapsAndListsRoundTripByteIdentically() throws {
        let value = Value.map([
            "zeta": "last alphabetically, first here",
            "alpha": .list([1, .map(["k": true, "a": .list([])]), "x"]),
            "inner": .map(["deep": .map(["deeper": .map([:])]), "when": stamp("2026-10-04T10:00:00Z"), "who": ref("user", "u1")]),
            "": .empty,
        ])
        let original = document(value)
        let json = try original.jsonData()
        let reloaded = try Document(json: json)
        XCTAssertEqual(reloaded, original)
        XCTAssertEqual(try reloaded.jsonData(), json)
        XCTAssertEqual(try original.jsonData(), json, "stable")
        guard case .literal(.map(let map))? = reloaded.scripts[0].body[0].inputs["m"] else { return XCTFail("not a map") }
        XCTAssertEqual(map.keys, ["zeta", "alpha", "inner", ""], "entry order survives; nothing is sorted")
    }

    func testDuplicateKeysInAHandEditedDocument() throws {
        let json = """
        {"schemaVersion":2,"scripts":[{"id":"s","name":"S","body":[{"id":"b","kind":"k","inputs":{"m":{"literal":{"map":[
          {"key":"a","value":{"number":1}}, {"key":"b","value":{"number":2}}, {"key":"a","value":{"text":"last"}}
        ]}}}}]}]}
        """
        let loaded = try Document(json: Data(json.utf8))
        XCTAssertEqual(loaded.scripts[0].body[0].inputs["m"], .literal(.map(["a": "last", "b": 2])))
    }

    func testMalformedMapsAreRejected() {
        for map in [#"{"map":{"a":1}}"#, #"{"map":[{"key":"a"}]}"#, #"{"map":[{"value":{"number":1}}]}"#, #"{"map":"x"}"#] {
            let json = #"{"schemaVersion":2,"scripts":[{"id":"s","name":"S","body":[{"id":"b","kind":"k","inputs":{"m":{"literal":\#(map)}}}]}]}"#
            XCTAssertThrowsError(try Document(json: Data(json.utf8)), map)
        }
    }

    func testSchemaVersionIsTwoAndVersionOneStillLoads() throws {
        XCTAssertEqual(Document.currentSchemaVersion, 2)
        XCTAssertEqual(Document().schemaVersion, 2)
        XCTAssertTrue(String(decoding: try Document().jsonData(), as: UTF8.self).contains(#""schemaVersion" : 2"#))

        // A version 1 document, as M0–M5 wrote it.
        let v1 = """
        {"schemaVersion":1,"scripts":[{"id":"s","name":"Old","parameters":[{"name":"t","type":"reference","referenceKind":"ticket"}],
          "body":[{"id":"b","kind":"ticket.fetch","inputs":{"ticket":{"variable":"t"}},"bindings":{"title":"title"}}]}]}
        """
        let loaded = try Document(json: Data(v1.utf8))
        XCTAssertEqual(loaded.scripts, [Script(id: "s", name: "Old", parameters: [Param(name: "t", type: .reference, referenceKind: "ticket")],
                                               body: [Block(id: "b", kind: "ticket.fetch", inputs: ["ticket": .variable("t")],
                                                            bindings: ["title": "title"])])])
        XCTAssertEqual(loaded.schemaVersion, 2, "it is saved as the current version from now on")
        XCTAssertEqual(try Document(json: try loaded.jsonData()), loaded)
    }

    func testMapTypedParametersAndOutputs() throws {
        let script = Script(id: "s", name: "S", parameters: [Param(name: "details", type: .map)], outputs: [Param(name: "result", type: .map)])
        let json = try Document(scripts: [script]).jsonData()
        XCTAssertTrue(String(decoding: json, as: UTF8.self).contains(#""type" : "map""#))
        XCTAssertEqual(try Document(json: json).scripts, [script])
        XCTAssertEqual(OutputDefinition("out", .map).type, .map)
    }
}

final class MapSlotTests: XCTestCase {
    func testMapSlotIsARoundSlotWithoutALiteralEditor() {
        let slot = InputDefinition.map("params")
        XCTAssertEqual(slot.name, "params")
        XCTAssertEqual(slot.shape, .value)
        XCTAssertEqual(slot.types, [.map])
        XCTAssertEqual(slot.editor, SlotEditor.none)
        XCTAssertNil(slot.defaultValue)
        XCTAssertTrue(slot.isRequired)
    }

    /// A host block with one map slot receives a variable number of named inputs, and may return a map.
    func testAHandlerReceivesAndReturnsMaps() {
        var received: [OrderedMap] = []
        let category = BlockCategory(id: "t", title: "T", color: BlockColor(hex: 0))
        let vocabulary = Vocabulary([
            .statement("t.run", category: category, title: "run with %params", inputs: [.map("params")],
                       outputs: [OutputDefinition("echo", .map)]) { inputs, _ in
                received.append(inputs.map("params"))
                return ["echo": .map(inputs.map("params").setting("seen", true))]
            },
        ])
        func run(_ input: Input) -> Value {
            let script = Script(id: "s", name: "S", parameters: [Param(name: "p", type: .map)], outputs: [Param(name: "out", type: .map)], body: [
                Block(id: "b", kind: "t.run", inputs: ["params": input], bindings: ["echo": "echo"]),
                Block(id: "r", kind: BuiltIn.return, inputs: ["out": .variable("echo")]),
            ])
            return Interpreter(document: Document(scripts: [script]), vocabulary: vocabulary, environment: env)
                .run(scriptID: "s", arguments: ["p": .map(["a": 1, "b": "two"])]).outputs["out"] ?? .empty
        }
        XCTAssertEqual(run(.variable("p")), .map(["a": 1, "b": "two", "seen": true]))
        XCTAssertEqual(run(.literal(.text(#"{"x":[1,2]}"#))), .map(["x": .list([1, 2]), "seen": true]), "JSON object text is a map")
        XCTAssertEqual(run(.literal("not a map")), .map(["seen": true]))
        XCTAssertEqual(run(.empty), .map(["seen": true]), "an empty slot is the empty map")
        XCTAssertEqual(received, [["a": 1, "b": "two"], ["x": .list([1, 2])], [:], [:]])
    }

    func testTypeMismatchOnAMapSlotIsOnlyAWarning() {
        let category = BlockCategory(id: "t", title: "T", color: BlockColor(hex: 0))
        let vocabulary = Vocabulary([
            .statement("t.run", category: category, title: "run with %params", inputs: [.map("params")]) { _, _ in [:] },
        ])
        let script = Script(id: "s", name: "S", parameters: [Param(name: "m", type: .map), Param(name: "n", type: .number)], body: [
            Block(id: "ok", kind: "t.run", inputs: ["params": .variable("m")]),
            Block(id: "wrong", kind: "t.run", inputs: ["params": .variable("n")]),
            Block(id: "literal", kind: "t.run", inputs: ["params": .literal("text")]),
            Block(id: "empty", kind: "t.run"),
            Block(id: "join", kind: "t.run", inputs: ["params": .reporter(Block(id: "j", kind: "operator.join"))]),
        ])
        let issues = Validator.validate(Document(scripts: [script]), vocabulary: vocabulary)
        XCTAssertEqual(issues.map { "\($0.severity) \($0.blockID): \($0.message)" }, [
            "warning wrong: “params” expects map, not number",
            "warning literal: “params” expects map, not text",
            "error empty: “params” is empty",
            "warning join: “params” expects map, not text",
        ])
    }
}
