import XCTest
import AlgoratorCore
import TicketDemo

final class MapBlockTests: XCTestCase {
    private let host = TestHost()
    private let sample: OrderedMap = ["title": "High", "n": 2]

    private func check(_ kind: String, _ inputs: [String: Value], _ expected: Value, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(host.evaluate(kind, inputs.mapValues { lit($0) }), expected, "\(kind) \(inputs)", file: file, line: line)
    }

    private func script(_ body: [Block], parameters: [Param] = []) -> Script {
        Script(id: "main", name: "Main", parameters: parameters, body: body)
    }

    private func setEntry(_ id: String, _ key: Value, of name: String, to value: Input) -> Block {
        stmt(id, BuiltIn.setEntry, ["key": lit(key), "name": lit(.text(name)), "value": value])
    }

    private func removeEntry(_ id: String, _ key: Value, of name: String) -> Block {
        stmt(id, BuiltIn.removeEntry, ["key": lit(key), "name": lit(.text(name))])
    }

    // MARK: Reporters

    func testTheNineBlocksAreInTheirOwnCategory() {
        let maps = Vocabulary().definitions.filter { $0.category.id == "maps" }
        XCTAssertEqual(maps.map(\.id), ["map.empty", "map.with", "map.without", "map.value", "map.hasKey", "map.keys", "map.count",
                                        "map.setEntry", "map.removeEntry"])
        XCTAssertEqual(maps.map(\.shape), [.reporter, .reporter, .reporter, .reporter, .predicate, .reporter, .reporter,
                                           .statement, .statement])
        XCTAssertEqual(Vocabulary.maps.title, "Maps")
        XCTAssertFalse(Vocabulary().categories.dropLast().map(\.color).contains(Vocabulary.maps.color), "a colour of its own")
    }

    func testEmptyMap() {
        XCTAssertEqual(host.evaluate("map.empty"), .map([:]))
    }

    func testWith() {
        check("map.with", ["map": .map([:]), "key": "a", "value": 1], .map(["a": 1]))
        check("map.with", ["map": .map(sample), "key": "extra", "value": true], .map(["title": "High", "n": 2, "extra": true]))
        check("map.with", ["map": .map(sample), "key": "title", "value": "Low"], .map(["title": "Low", "n": 2]))   // in place
        check("map.with", ["map": .map(sample), "key": "Title", "value": "x"], .map(["title": "High", "n": 2, "Title": "x"]))
        check("map.with", ["map": .map([:]), "key": 7, "value": .list([1])], .map(["7": .list([1])]))              // key is text
        check("map.with", ["map": .map([:]), "key": "in", "value": .map(sample)], .map(["in": .map(sample)]))
        check("map.with", ["map": "not a map", "key": "a", "value": 1], .map(["a": 1]))
        check("map.with", ["map": .text(#"{"x":1}"#), "key": "y", "value": 2], .map(["x": 1, "y": 2]))
        XCTAssertEqual(host.evaluate("map.with", ["key": lit("a"), "value": lit(1)]), .map(["a": 1]), "an empty map slot")
    }

    func testWithout() {
        check("map.without", ["map": .map(sample), "key": "title"], .map(["n": 2]))
        check("map.without", ["map": .map(sample), "key": "absent"], .map(sample))
        check("map.without", ["map": .map(sample), "key": "TITLE"], .map(sample))
        check("map.without", ["map": 5, "key": "a"], .map([:]))
    }

    func testValueOf() {
        check("map.value", ["key": "title", "map": .map(sample)], "High")
        check("map.value", ["key": "n", "map": .map(sample)], 2)
        check("map.value", ["key": "absent", "map": .map(sample)], .empty)
        check("map.value", ["key": "in", "map": .map(["in": .map(sample)])], .map(sample))
        check("map.value", ["key": "x", "map": "nonsense"], .empty)
        check("map.value", ["key": 7, "map": .map(["7": "seven"])], "seven")
    }

    func testHasKeyKeysAndCount() {
        check("map.hasKey", ["map": .map(sample), "key": "n"], true)
        check("map.hasKey", ["map": .map(sample), "key": "N"], false)
        check("map.hasKey", ["map": .map(["e": .empty]), "key": "e"], true)   // present with an empty value
        check("map.hasKey", ["map": "", "key": "n"], false)
        check("map.keys", ["map": .map(sample)], .list(["title", "n"]))
        check("map.keys", ["map": .map(["b": 1, "a": 2])], .list(["b", "a"]))  // entry order, not sorted
        check("map.keys", ["map": .map([:])], .list([]))
        check("map.count", ["map": .map(sample)], 2)
        check("map.count", ["map": .map([:])], 0)
        check("map.count", ["map": "x"], 0)
    }

    func testReportersDoNotChangeTheMapTheyAreGiven() {
        _ = host.run(script([
            log("with", rep("map.with", ["map": variable("m"), "key": lit("added"), "value": lit(1)])),
            log("without", rep("map.without", ["map": variable("m"), "key": lit("title")])),
            log("after", variable("m")),
        ], parameters: [Param(name: "m", type: .map)]), arguments: ["m": .map(sample)])
        XCTAssertEqual(host.logged, [.map(["title": "High", "n": 2, "added": 1]), .map(["n": 2]), .map(sample)])
    }

    func testReportersCompose() {
        // number of entries in ((empty map with "a" = 1) with "b" = 2) = 2
        let one = rep("map.with", ["map": rep("map.empty"), "key": lit("a"), "value": lit(1)])
        let two = rep("map.with", ["map": one, "key": lit("b"), "value": lit(2)])
        XCTAssertEqual(host.evaluate("map.count", ["map": two]), 2)
        XCTAssertEqual(host.evaluate("list.join", ["list": rep("map.keys", ["map": two]), "separator": lit("+")]), "a+b")
    }

    // MARK: The two statements

    func testSetEntryStartsFromTheEmptyMapAndBuildsUp() {
        let result = host.run(script([
            setEntry("s1", "title", of: "details", to: lit("High")),
            setEntry("s2", "n", of: "details", to: lit(2)),
            setEntry("s3", "title", of: "details", to: lit("Low")),
            log("l", variable("details")),
        ]))
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(host.logged, [.map(["title": "Low", "n": 2])], "replacing keeps the position")
        XCTAssertEqual(result.trace.map(\.label), ["set entry title of details to High", "set entry n of details to 2",
                                                   "set entry title of details to Low", #"log {"title":"Low","n":2}"#])
    }

    func testSetEntryOnAVariableThatIsNotAMapStartsOver() {
        _ = host.run(script([
            set("s0", "v", lit("just text")),
            setEntry("s1", "a", of: "v", to: lit(1)),
            log("l1", variable("v")),
            set("s2", "w", lit(.text(#"{"x":1}"#))),
            setEntry("s3", "y", of: "w", to: lit(2)),
            log("l2", variable("w")),
        ]))
        XCTAssertEqual(host.logged, [.map(["a": 1]), .map(["x": 1, "y": 2])], "JSON object text counts as a map")
    }

    func testRemoveEntry() {
        _ = host.run(script([
            removeEntry("r1", "n", of: "m"),
            log("l1", variable("m")),
            removeEntry("r2", "absent", of: "m"),
            log("l2", variable("m")),
            removeEntry("r3", "x", of: "fresh"),
            log("l3", variable("fresh")),
        ], parameters: [Param(name: "m", type: .map)]), arguments: ["m": .map(sample)])
        XCTAssertEqual(host.logged, [.map(["title": "High"]), .map(["title": "High"]), .map([:])])
    }

    /// The statements rebind the variable; a map already copied elsewhere or handed to a block is unchanged.
    func testRebindingDoesNotChangeACopyHeldElsewhere() {
        _ = host.run(script([
            setEntry("s1", "a", of: "m", to: lit(1)),
            set("copy", "kept", variable("m")),                 // a copy in another variable
            log("handed", variable("m")),                       // and one handed to a block
            setEntry("s2", "b", of: "m", to: lit(2)),
            setEntry("s3", "a", of: "m", to: lit("changed")),
            removeEntry("r", "a", of: "kept2"),
            set("copy2", "kept2", variable("m")),
            removeEntry("r2", "a", of: "m"),
            log("kept", variable("kept")),
            log("kept2", variable("kept2")),
            log("m", variable("m")),
        ]))
        XCTAssertEqual(host.logged, [
            .map(["a": 1]),                        // what the block was handed, as it was then
            .map(["a": 1]),                        // the first copy never saw "b" or the change to "a"
            .map(["a": "changed", "b": 2]),        // the second copy never saw the removal
            .map(["b": 2]),
        ])
    }

    func testStatementsWithoutAVariableFail() {
        let result = host.run(script([stmt("s", BuiltIn.setEntry, ["key": lit("a"), "value": lit(1)])]))
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.message, "No variable is chosen")
    }

    // MARK: Validation

    func testSetEntryBindsItsVariableAsAMap() {
        let category = BlockCategory(id: "x", title: "X", color: BlockColor(hex: 0))
        var vocabulary = host.vocabulary
        vocabulary.register(.statement("x.takesMap", category: category, title: "take %m", inputs: [.map("m")]) { _, _ in [:] })
        let script = script([
            log("early", variable("details")),
            setEntry("s", "a", of: "details", to: lit(1)),
            log("late", variable("details")),
            stmt("ok", "x.takesMap", ["m": variable("details")]),
            log("warn", rep("operator.add", ["a": variable("details"), "b": lit(1)], id: "add")),
            removeEntry("r", "a", of: "other"),
            stmt("ok2", "x.takesMap", ["m": variable("other")]),
            stmt("named", BuiltIn.setEntry, ["key": lit("a"), "value": lit(1)]),
            removeEntry("named2", "a", of: ""),
        ])
        let document = Document(scripts: [script])
        XCTAssertEqual(Validator.validate(document, vocabulary: vocabulary).map { "\($0.severity) \($0.blockID): \($0.message)" }, [
            "error early: The variable “details” is read before it can be set",
            "warning add: “a” expects number, not map",
            "error named: “variable” is empty",
            "error named2: “variable” is empty",
        ])
        XCTAssertEqual(Validator.variableTypes(of: script, in: document, vocabulary: vocabulary),
                       ["details": VariableType(type: .map), "other": VariableType(type: .map)])
        XCTAssertEqual(script.variableNames, ["details", "other"], "they show up in the Variables tab")
    }

    func testAVariableAlsoWrittenByPlainSetHasNoKnownType() {
        let script = script([set("s", "v", lit(1)), setEntry("e", "a", of: "v", to: lit(1))])
        XCTAssertEqual(Validator.variableTypes(of: script, in: Document(scripts: [script]), vocabulary: host.vocabulary),
                       ["v": VariableType()])
    }

    // MARK: Third acceptance script (SPEC-maps §4), from hand-written JSON

    private func details(_ ticket: String) throws -> (RunResult, TicketDirectory) {
        let directory = TicketDirectory.sample(now: fixedNow)
        let interpreter = Interpreter(document: try AcceptanceDocument.load(),
                                      vocabulary: TicketVocabulary.make(directory: directory), environment: env)
        return (interpreter.run(scriptID: AcceptanceDocument.detailsID, arguments: ["ticket": ref("ticket", ticket)]), directory)
    }

    func testEscalateWithDetails() throws {
        let (result, directory) = try details("T-1")
        XCTAssertEqual(result.status, .returned)
        XCTAssertEqual(result.outputs, ["escalated": true])
        XCTAssertEqual(result.trace.map(\.blockID), ["fetch-details", "entry-title", "entry-priority", "entry-assignee", "review", "log",
                                                     "return-reviewed"])
        XCTAssertTrue(result.trace.allSatisfy(\.succeeded))
        XCTAssertEqual(Array(result.trace.map(\.label).prefix(4)), [
            "fetch ticket T-1", "set entry title of details to Login page is down", "set entry priority of details to high",
            "set entry assignee of details to alice",
        ])
        XCTAssertEqual(result.trace[4].label, #"review details {"title":"Login page is down","priority…"#)
        XCTAssertEqual(result.trace[5].label, #"log details {"title":"Login page is down","priority…"#)
        XCTAssertEqual(result.trace[6].label, "return escalated true")
        XCTAssertEqual(result.trace[4].note, "Reviewed 3 values")
        XCTAssertEqual(result.trace[5].note, "Logged 4 entries")
        XCTAssertEqual(directory.log, ["title: Login page is down", "priority: high", "assignee: alice", "reviewed: true"],
                       "key order is preserved")
        XCTAssertEqual(directory.notifications, [])
    }

    func testEscalateWithDetailsFailsForAMissingTicket() throws {
        let (result, directory) = try details("T-404")
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.trace.map(\.blockID), ["fetch-details"])
        XCTAssertEqual(directory.log, [])
    }

    func testDemoMapBlocks() {
        let directory = TicketDirectory.sample(now: fixedNow)
        let vocabulary = TicketVocabulary.make(directory: directory)
        let messy: OrderedMap = ["title": "  padded \n", "n": 2, "who": ref("user", "bob"), "tags": .list([" a "])]
        let script = Script(id: "s", name: "S", parameters: [Param(name: "m", type: .map)], outputs: [Param(name: "out", type: .map)], body: [
            stmt("review", "ticket.reviewDetails", ["details": variable("m")], bindings: ["reviewed": "r"]),
            stmt("log", "ticket.logDetails", ["details": variable("r")]),
            ret("return", ["out": variable("r")]),
        ])
        let result = Interpreter(document: Document(scripts: [script]), vocabulary: vocabulary, environment: env)
            .run(scriptID: "s", arguments: ["m": .map(messy)])
        XCTAssertEqual(result.outputs["out"], .map(["title": "padded", "n": 2, "who": ref("user", "bob"), "tags": .list([" a "]), "reviewed": true]),
                       "only text values are trimmed; the rest pass through; the key is added at the end")
        XCTAssertEqual(directory.log, ["title: padded", "n: 2", "who: bob", "tags:  a ", "reviewed: true"])
        XCTAssertEqual(Validator.validate(Document(scripts: [script]), vocabulary: vocabulary), [])
    }
}
