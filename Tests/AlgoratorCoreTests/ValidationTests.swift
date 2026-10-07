import XCTest
import AlgoratorCore
import TicketDemo

final class ValidationTests: XCTestCase {
    private let host = TestHost()

    private func script(_ body: [Block], parameters: [Param] = [], outputs: [Param] = []) -> Script {
        Script(id: "main", name: "Main", parameters: parameters, outputs: outputs, body: body)
    }

    /// `severity blockID: message` for compact assertions.
    private func issues(_ script: Script, others: [Script] = []) -> [String] {
        host.issues(script, others: others).map { "\($0.severity) \($0.blockID): \($0.message)" }
    }

    func testAcceptanceDocumentIsCleanAndValidationHasNoSideEffects() throws {
        let directory = TicketDirectory.sample(now: fixedNow)
        let document = try AcceptanceDocument.load()
        XCTAssertEqual(Validator.validate(document, vocabulary: TicketVocabulary.make(directory: directory)), [])
        XCTAssertEqual(directory.notifications, [])
        XCTAssertEqual(directory.tickets["T-1"]?.labels, [])
    }

    func testValidScriptHasNoIssues() {
        XCTAssertEqual(issues(script([
            set("s", "x", lit(1)),
            ifElse("i", yes, then: [log("a", variable("x"))], else: [log("b", variable("p"))]),
            ret("r", ["out": variable("x")]),
        ], parameters: [Param(name: "p", type: .text)], outputs: [Param(name: "out", type: .number)])), [])
    }

    // MARK: Unknown kinds, missing scripts, shapes

    func testUnknownBlockKinds() {
        XCTAssertEqual(issues(script([
            stmt("u1", "vendor.gone", ["x": lit("kept")]),
            log("l", rep("vendor.alsoGone", id: "u2")),
            Block(id: "u3", kind: "vendor.loop", regions: ["body": [stmt("u4", "vendor.inner")]]),
        ])), [
            "error u1: Unknown block kind “vendor.gone”",
            "error u2: Unknown block kind “vendor.alsoGone”",
            "error u3: Unknown block kind “vendor.loop”",
            "error u4: Unknown block kind “vendor.inner”",
        ])
    }

    func testMissingCalledScript() {
        XCTAssertEqual(issues(script([call("c", "nowhere")])), ["error c: The called script does not exist"])
        XCTAssertEqual(issues(script([stmt("c", BuiltIn.call)])), ["error c: The called script does not exist"])
    }

    func testCallArgumentsAndOutputsFollowTheCallee() {
        let callee = Script(id: "callee", name: "Callee",
                            parameters: [Param(name: "who", type: .reference, referenceKind: "user"), Param(name: "n", type: .number)],
                            outputs: [Param(name: "boss", type: .reference, referenceKind: "user")])
        XCTAssertEqual(issues(script([
            call("ok", "callee", ["who": rep("test.user"), "n": lit(1)], bindings: ["boss": "boss"]),
            stmt("uses", "test.needsUser", ["user": variable("boss")]),
            call("bad", "callee", ["who": lit(ref("ticket", "T-1"))]),
        ]), others: [callee]), [
            "error bad: “who” needs a user, not a ticket",
        ])
        XCTAssertEqual(issues(script([call("empty", "callee")]), others: [callee]), ["error empty: “who” is empty"])
    }

    func testMisplacedShapes() {
        XCTAssertEqual(issues(script([
            stmt("s", "time.now"),
            log("l", .reporter(stmt("inner", "test.cancel"))),
            ifThen("i", rep("time.now"), then: []),
            ifThen("j", variable("p"), then: []),
            ifThen("k", lit("true"), then: []),
        ], parameters: [Param(name: "p", type: .bool)])), [
            "error s: “now” produces a value and cannot stand on its own",
            "error l: “cancel” is a statement and cannot be used as a value",
            "error i: “condition” needs a condition block",
            "error j: “condition” needs a condition block",
            "error k: “condition” needs a condition block",
        ])
    }

    func testPredicatesMayFillValueSlots() {
        XCTAssertEqual(issues(script([set("s", "flag", yes), log("l", yes)])), [])
    }

    // MARK: Variables

    func testVariableReadBeforeItCanBeBound() {
        XCTAssertEqual(issues(script([
            log("early", variable("x")),
            set("s", "x", variable("x")),
            log("late", variable("x")),
            log("typo", rep("operator.join", ["a": variable("nope"), "b": lit("")], id: "j")),
        ])), [
            "error early: The variable “x” is read before it can be set",
            "error s: The variable “x” is read before it can be set",
            "error j: The variable “nope” is never set",
        ])
    }

    func testBindingsAndParametersBindVariables() {
        XCTAssertEqual(issues(script([
            log("a", variable("p")),
            log("early", variable("one")),
            stmt("pair", "test.pair", bindings: ["first": "one", "second": ""]),
            log("b", variable("one")),
        ], parameters: [Param(name: "p", type: .text)])), [
            "error early: The variable “one” is read before it can be set",
        ])
    }

    func testBranchesAreFlowInsensitive() {
        XCTAssertEqual(issues(script([
            ifElse("i", yes, then: [
                set("s1", "inThen", lit(1)),
                log("ok-inside", variable("inThen")),
                log("other-branch", variable("inElse")),
            ], else: [
                set("s2", "inElse", lit(2)),
                ifThen("nested", yes, then: [set("s3", "deep", lit(3))]),
            ]),
            log("after-then", variable("inThen")),
            log("after-else", variable("inElse")),
            log("after-deep", variable("deep")),
        ])), [
            "error other-branch: The variable “inElse” is read before it can be set",
        ])
    }

    // MARK: Reference kinds

    func testReferenceKindMismatches() {
        let parameters = [Param(name: "ticket", type: .reference, referenceKind: "ticket"),
                          Param(name: "person", type: .reference, referenceKind: "user"),
                          Param(name: "name", type: .text)]
        XCTAssertEqual(issues(script([
            stmt("ok1", "test.needsUser", ["user": variable("person")]),
            stmt("ok2", "test.needsUser", ["user": lit(ref("user", "u1"))]),
            stmt("ok3", "test.needsUser", ["user": rep("test.user")]),
            set("s", "untyped", lit("u1")),
            stmt("ok4", "test.needsUser", ["user": variable("untyped")]),
            stmt("wrongVariable", "test.needsUser", ["user": variable("ticket")]),
            stmt("wrongLiteral", "test.needsUser", ["user": lit(ref("ticket", "T-1"))]),
            stmt("textVariable", "test.needsUser", ["user": variable("name")]),
            stmt("textLiteral", "test.needsUser", ["user": lit("u1")]),
            stmt("wrongReporter", "test.needsUser", ["user": rep("time.now")]),
        ], parameters: parameters)), [
            "error wrongVariable: “user” needs a user, not a ticket",
            "error wrongLiteral: “user” needs a user, not a ticket",
            "error textVariable: “user” needs a user, not text",
            "error textLiteral: “user” needs a user",
            "error wrongReporter: “user” needs a user, not timestamp",
        ])
    }

    func testWrongReferenceKindInTheAcceptanceScript() throws {
        // Feed the assignee (a user) to `add label … to %ticket`.
        var document = try AcceptanceDocument.load()
        document.scripts[0].body[2].regions["then"]?[1].inputs["ticket"] = .variable("assignee")
        let found = Validator.validate(document, vocabulary: TicketVocabulary.make(directory: .sample(now: fixedNow)))
        XCTAssertEqual(found, [Issue(scriptID: "escalate-ticket", blockID: "label", severity: .error,
                                     message: "“ticket” needs a ticket, not a user")])
    }

    // MARK: Empty inputs

    func testEmptyRequiredInputs() {
        XCTAssertEqual(issues(script([
            ifThen("i", .empty, then: []),
            stmt("u", "test.needsUser"),
            stmt("u2", "test.needsUser", ["user": lit(ref("user", ""))]),
            stmt("named", BuiltIn.set, ["name": lit(""), "value": lit(1)]),
            log("nested", rep("operator.not", id: "n")),
            log("l", rep("list.length", id: "len")),
            // Slots with a default are fine when empty; so is an empty text.
            stmt("d", "test.defaults", ["flag": yes]),
            log("e", lit("")),
        ])), [
            "error i: “condition” is empty",
            "error u: “user” is empty",
            "error u2: “user” is empty",
            "error named: “variable” is empty",
            "error n: “a” is empty",
            "error len: “list” is empty",
        ])
    }

    // MARK: Type warnings

    func testTypeMismatchesAreWarnings() {
        let parameters = [Param(name: "when", type: .timestamp), Param(name: "count", type: .number),
                          Param(name: "name", type: .text)]
        XCTAssertEqual(issues(script([
            log("w1", rep("operator.add", ["a": lit("abc"), "b": lit(1)], id: "add1")),
            log("w2", rep("operator.add", ["a": variable("when"), "b": lit(1)], id: "add2")),
            log("w3", rep("operator.add", ["a": rep("time.now"), "b": lit(1)], id: "add3")),
            log("w4", rep("time.addDays", ["amount": lit(1), "to": variable("count")], id: "days")),
            log("w5", rep("list.length", ["list": variable("name")], id: "len")),
            // No warnings: numeric text, a number into text, anything into an untyped slot, unknown types.
            log("ok1", rep("operator.add", ["a": lit("12"), "b": lit("3,5")])),
            log("ok2", rep("operator.join", ["a": variable("count"), "b": variable("when")])),
            log("ok3", rep("operator.equals", ["a": variable("when"), "b": lit(5)])),
            set("s", "unknown", lit("x")),
            log("ok4", rep("operator.add", ["a": variable("unknown"), "b": rep("list.item", ["index": lit(1), "list": lit(.list([]))])])),
            log("ok5", rep("time.addDays", ["amount": lit(1), "to": lit("2026-10-04")])),
            log("ok6", rep("time.addDays", ["amount": lit(1), "to": variable("when")])),
        ], parameters: parameters)), [
            "warning add1: “a” expects number, not text",
            "warning add2: “a” expects number, not timestamp",
            "warning add3: “a” expects number, not timestamp",
            "warning days: “to” expects date or timestamp, not number",
            "warning len: “list” expects list, not text",
        ])
    }

    func testDropdownLiteralOutsideItsOptionsIsAWarning() {
        var vocabulary = host.vocabulary
        let category = BlockCategory(id: "t", title: "T", color: BlockColor(hex: 0))
        vocabulary.register(.statement("test.pick", category: category, title: "pick %level",
                                       inputs: [.dropdown("level", options: ["low", "high"])]) { _, _ in [:] })
        let document = Document(scripts: [script([
            stmt("a", "test.pick", ["level": lit("high")]), stmt("b", "test.pick", ["level": lit("urgent")]),
            stmt("c", "test.pick"),
        ])])
        XCTAssertEqual(Validator.validate(document, vocabulary: vocabulary).map { "\($0.severity) \($0.blockID): \($0.message)" },
                       ["warning b: “urgent” is not one of the options of “level”"])
    }

    // MARK: Return

    func testReturnMustMatchTheDeclaredOutputs() {
        let outputs = [Param(name: "escalated", type: .bool), Param(name: "reason", type: .text)]
        XCTAssertEqual(issues(script([
            ifElse("i", yes, then: [
                ret("complete", ["escalated": lit(true), "reason": lit("old")]),
            ], else: [
                ifElse("j", yes, then: [
                    ret("missing", ["escalated": lit(false)]),
                ], else: [
                    ret("extra", ["escalated": yes, "reason": lit(""), "severity": lit(3), "ignored": .empty]),
                ]),
            ]),
            ret("bare"),
        ], outputs: outputs)), [
            "error missing: return does not set the declared output “reason”",
            "error extra: return sets “severity”, which is not a declared output of “Main”",
            "error bare: return does not set the declared output “escalated”",
            "error bare: return does not set the declared output “reason”",
        ])
    }

    func testReturnInAScriptWithoutOutputs() {
        XCTAssertEqual(issues(script([ret("ok")])), [])
        XCTAssertEqual(issues(script([ret("r", ["x": lit(1)])])),
                       ["error r: return sets “x”, which is not a declared output of “Main”"])
    }

    func testReturnMismatchInTheAcceptanceScript() throws {
        var document = try AcceptanceDocument.load()
        document.scripts[0].outputs.append(Param(name: "reason", type: .text))
        let found = Validator.validate(document, vocabulary: TicketVocabulary.make(directory: .sample(now: fixedNow)))
        XCTAssertEqual(found.map(\.blockID), ["return-true", "return-false"])
        XCTAssertTrue(found.allSatisfy { $0.severity == .error && $0.message.contains("reason") })
    }

    func testIssuesCarryTheirScript() {
        let other = Script(id: "other", name: "Other", body: [stmt("x", "vendor.gone")])
        let all = Validator.validate(Document(scripts: [script([log("l", variable("nope"))]), other]), vocabulary: host.vocabulary)
        XCTAssertEqual(all.map(\.scriptID), ["main", "other"])
        XCTAssertEqual(all.map(\.blockID), ["l", "x"])
    }
}
