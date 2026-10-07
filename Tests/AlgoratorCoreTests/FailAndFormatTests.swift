import XCTest
import AlgoratorCore
import TicketDemo

/// SPEC-templates §2: `fail with` ends the whole run as failed.
final class FailTests: XCTestCase {
    private let host = TestHost()

    private func fail(_ id: String, _ message: Input = .literal("")) -> Block { stmt(id, BuiltIn.fail, ["message": message]) }
    private func script(_ body: [Block], id: String = "main", outputs: [Param] = []) -> Script {
        Script(id: id, name: id.capitalized, outputs: outputs, body: body)
    }

    func testDefinition() {
        let definition = Vocabulary()[BuiltIn.fail]
        XCTAssertEqual(definition?.shape, .cap)
        XCTAssertEqual(definition?.category.id, "control")
        XCTAssertEqual(definition?.title, "fail with %message")
        XCTAssertEqual(definition?.inputs.map(\.name), ["message"])
        XCTAssertEqual(definition?.inputs.first?.types, [.text])
        XCTAssertEqual(definition?.inputs.first?.defaultValue, "")
    }

    func testFailEndsTheRunAsFailedWithItsMessage() {
        let result = host.run(script([
            log("before", lit("kept")),
            fail("f", lit("Nothing to do")),
            log("after", lit("unreachable")),
        ], outputs: [Param(name: "out", type: .text)]))
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.message, "Nothing to do")
        XCTAssertEqual(result.outputs, ["out": .empty])
        XCTAssertEqual(result.trace.map(\.blockID), ["before", "f"], "nothing after it runs")
        XCTAssertEqual(result.trace.last, StepOutcome(blockID: "f", scriptID: "main", depth: 0, label: "fail with Nothing to do",
                                                      succeeded: false, message: "Nothing to do"))
        XCTAssertEqual(host.logged, ["kept"], "what already happened is not rolled back")
    }

    func testItBehavesExactlyLikeAThrowingHandler() {
        let failed = host.run(script([fail("x", lit("boom"))]))
        let thrown = host.run(script([stmt("x", "test.fail", ["message": lit("boom")])]))
        XCTAssertEqual(failed.status, thrown.status)
        XCTAssertEqual(failed.message, thrown.message)
        XCTAssertEqual(failed.trace.map(\.succeeded), thrown.trace.map(\.succeeded))
        XCTAssertEqual(failed.trace.map(\.message), thrown.trace.map(\.message))
    }

    func testAnEmptyMessageFallsBack() {
        for message: Input in [.literal(""), .empty, .variable("unset")] {
            let result = host.run(script([fail("f", message)]))
            XCTAssertEqual(result.message, "The script failed", "\(message)")
            XCTAssertEqual(result.trace.last?.message, "The script failed")
        }
        XCTAssertEqual(host.run(script([stmt("f", BuiltIn.fail)])).message, "The script failed", "no input at all")
        XCTAssertEqual(host.run(script([fail("f", lit(" "))])).message, " ", "only the empty text is replaced")
    }

    func testTheMessageMayBeComputed() {
        let message = rep("operator.join", ["a": lit("Missing: "), "b": variable("what")])
        let result = host.run(script([set("s", "what", lit("title")), fail("f", message)]))
        XCTAssertEqual(result.message, "Missing: title")
        XCTAssertEqual(host.run(script([fail("f", lit(42))])).message, "42")
    }

    func testFailInsideANestedRegion() {
        let result = host.run(script([
            ifThen("outer", yes, then: [
                ifElse("inner", no, then: [], else: [fail("f", lit("deep")), log("a", lit("x"))]),
                log("b", lit("x")),
            ]),
            log("c", lit("x")),
        ]))
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.trace.map(\.blockID), ["outer", "inner", "f"])
        XCTAssertEqual(result.trace.map(\.succeeded), [true, true, false])
        XCTAssertEqual(host.logged, [])
    }

    func testAFailingCalleeFailsItsCaller() {
        let callee = script([log("c1", lit("in callee")), fail("c2", lit("callee gave up")), log("c3", lit("x"))], id: "callee",
                            outputs: [Param(name: "out", type: .text)])
        let result = host.run(script([
            call("call", "callee", bindings: ["out": "v"]),
            log("after", lit("unreachable")),
        ]), others: [callee])
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.message, "callee gave up")
        XCTAssertEqual(result.trace.map(\.blockID), ["call", "c1", "c2"], "the trace shows both scripts")
        XCTAssertEqual(result.trace.map(\.depth), [0, 1, 1])
        XCTAssertEqual(result.trace.map(\.succeeded), [true, true, false])
        XCTAssertEqual(host.logged, ["in callee"], "the caller does not continue")
    }

    func testItCannotBeCaught() {
        // There is no construct that could: a failure three calls deep still ends everything.
        let c = script([fail("f", lit("bottom"))], id: "c")
        let b = script([call("to-c", "c"), log("b-after", lit("x"))], id: "b")
        let a = script([call("to-b", "b"), log("a-after", lit("x"))], id: "a")
        let result = host.run(script([call("to-a", "a"), log("after", lit("x"))]), others: [a, b, c])
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.trace.map(\.blockID), ["to-a", "to-b", "to-c", "f"])
        XCTAssertEqual(host.logged, [])
    }

    func testValidationHasNothingSpecialToSay() {
        XCTAssertEqual(host.issues(script([fail("f", lit("x"))])).map(\.message), [])
        XCTAssertEqual(host.issues(script([fail("f")])).map(\.message), [], "the message has a default")
        XCTAssertEqual(host.issues(script([fail("f", variable("nope"))])).map(\.message), ["The variable “nope” is never set"])
    }

    // MARK: The demo guard (SPEC-templates §6)

    func testTheDemoGuardRefusesATicketWithoutATitle() throws {
        let directory = TicketDirectory.sample(now: fixedNow)
        let interpreter = Interpreter(document: try AcceptanceDocument.load(), vocabulary: TicketVocabulary.make(directory: directory),
                                      environment: env)
        let refused = interpreter.run(scriptID: AcceptanceDocument.escalateTicketID, arguments: ["ticket": ref("ticket", "T-4")])
        XCTAssertEqual(refused.status, .failed)
        XCTAssertEqual(refused.message, "The ticket has no title")
        XCTAssertEqual(refused.trace.map(\.blockID), ["fetch", "guard", "refuse"])
        XCTAssertEqual(refused.trace.map(\.label), ["fetch ticket T-4", "if true then", "fail with The ticket has no title"])
        XCTAssertEqual(refused.trace.map(\.succeeded), [true, true, false])
        XCTAssertEqual(refused.outputs, ["escalated": .empty])
        XCTAssertEqual(directory.notifications, [])

        // Through `call script`: the second acceptance script fails with it.
        let viaCall = interpreter.run(scriptID: AcceptanceDocument.allClearID, arguments: ["ticket": ref("ticket", "T-4")])
        XCTAssertEqual(viaCall.status, .failed)
        XCTAssertEqual(viaCall.trace.map(\.blockID), ["call-escalate", "fetch", "guard", "refuse"])
        XCTAssertEqual(directory.notifications, [], "ops are not told anything")

        // A ticket with a title passes the guard.
        let fine = interpreter.run(scriptID: AcceptanceDocument.escalateTicketID, arguments: ["ticket": ref("ticket", "T-3")])
        XCTAssertEqual(fine.status, .returned)
        XCTAssertEqual(fine.trace.map(\.label).prefix(2), ["fetch ticket T-3", "if false then"])
    }
}

/// SPEC-templates §4: the two formatting reporters. Table-driven, fixed zone (Prague) and clock.
final class FormattingTests: XCTestCase {
    private let host = TestHost()

    private func format(_ value: Value, _ pattern: Value, in environment: RunEnvironment = env) -> Value {
        host.evaluate("time.format", ["value": lit(value), "pattern": lit(pattern)], environment: environment)
    }

    func testFormatTemporalValues() {
        let noon = stamp("2026-10-04T10:00:00Z")          // 12:00 in Prague (summer time)
        let winter = stamp("2026-01-05T23:30:00Z")        // 00:30 next day in Prague (winter time)
        let cases: [(Value, String, String)] = [
            (noon, "yyyy-MM-dd", "2026-10-04"),
            (noon, "HH:mm", "12:00"),
            (noon, "d. M. yyyy", "4. 10. 2026"),
            (noon, "yyyy-MM-dd'T'HH:mm:ss", "2026-10-04T12:00:00"),
            (noon, "EEEE, d MMMM yyyy", "Sunday, 4 October 2026"),      // English, whatever the machine speaks
            (noon, "h:mm a", "12:00 PM"),
            (noon, "xxx", "+02:00"),
            (winter, "yyyy-MM-dd HH:mm", "2026-01-06 00:30"),           // the day is the zone's, not UTC's
            (winter, "xxx", "+01:00"),
            (date("2026-10-04"), "d. M. yyyy", "4. 10. 2026"),
            (date("2026-01-05"), "EEE dd MMM", "Mon 05 Jan"),
            (date("2026-10-04"), "HH:mm", "00:00"),                     // a date has no time: midnight
            (time("09:05"), "HH:mm", "09:05"),
            (time("21:05:07"), "h:mm:ss a", "9:05:07 PM"),
            (time("09:05"), "yyyy-MM-dd", "2000-01-01"),                // a time has no date: the reference day
            (noon, "", ""),
            (noon, "'literal'", "literal"),
        ]
        for (value, pattern, expected) in cases {
            XCTAssertEqual(format(value, .text(pattern)), .text(expected), "\(value) as “\(pattern)”")
        }
    }

    func testFormatFollowsTheEnvironmentZoneOnlyForTimestamps() {
        let noon = stamp("2026-10-04T10:00:00Z")
        XCTAssertEqual(format(noon, "HH:mm", in: utcEnv), "10:00")
        XCTAssertEqual(format(noon, "HH:mm", in: env), "12:00")
        let tokyo = RunEnvironment(timeZone: TimeZone(identifier: "Asia/Tokyo")!, now: { fixedNow })
        XCTAssertEqual(format(noon, "yyyy-MM-dd HH:mm", in: tokyo), "2026-10-04 19:00")
        // Dates and times carry no zone and never shift.
        XCTAssertEqual(format(date("2026-10-04"), "yyyy-MM-dd", in: tokyo), "2026-10-04")
        XCTAssertEqual(format(time("23:30"), "HH:mm", in: tokyo), "23:30")
    }

    func testFormatCoercesWhatIsNotTemporal() {
        let cases: [(Value, String, String)] = [
            ("2026-10-04T10:00:00Z", "d. M. yyyy HH:mm", "4. 10. 2026 12:00"),   // text → timestamp
            ("2026-10-04 12:00", "HH:mm", "12:00"),                            // zoneless text is local
            ("2026-10-04", "d. M. yyyy", "4. 10. 2026"),                       // text → date
            ("09:30", "h:mm a", "9:30 AM"),                                    // text → time
            ("", "yyyy", ""), ("tomorrow", "yyyy", ""), ("2026-13-01", "yyyy", ""),
            (5, "yyyy", ""), (true, "yyyy", ""), (.list([]), "yyyy", ""), (.map(["a": 1]), "yyyy", ""),
            (ref("ticket", "T-1"), "yyyy", ""),
        ]
        for (value, pattern, expected) in cases {
            XCTAssertEqual(format(value, .text(pattern)), .text(expected), "\(value) as “\(pattern)”")
        }
        XCTAssertEqual(host.evaluate("time.format", ["pattern": lit("yyyy")]), "", "an empty value slot")
        XCTAssertEqual(host.evaluate("time.format", ["value": rep("time.now")]), "2026-10-04", "the default pattern")
        XCTAssertEqual(host.evaluate("time.format", ["value": rep("time.today"), "pattern": lit("d. M. yyyy")]), "4. 10. 2026")
    }

    func testFormatNumber() {
        let cases: [(Value, Value, String)] = [
            (3.14159, 2, "3.14"), (3.14159, 0, "3"), (3.14159, 4, "3.1416"), (2, 2, "2.00"), (2, 0, "2"),
            (0, 2, "0.00"), (0.5, 0, "1"), (1.5, 0, "2"), (2.5, 0, "3"), (-2.5, 0, "-3"),       // halves away from zero
            (0.005, 2, "0.01"), (0.004, 2, "0.00"), (-0.004, 2, "0.00"),                        // no "-0.00"
            (-3.14159, 2, "-3.14"), (1234567.891, 2, "1234567.89"), (1234567, 0, "1234567"),    // no grouping
            (0.1, 1, "0.1"), (0.123456789012, 10, "0.1234567890"), (99.999, 2, "100.00"),
            (.number(1e15), 2, "1000000000000000.00"), (.number(1e-7), 3, "0.000"),
            // decimals: rounded, clamped to 0…10
            (1.23456, -3, "1"), (1.23456, 2.4, "1.23"), (1.23456, 2.6, "1.235"), (1.5, 99, "1.5000000000"),
            (1.23456, "3", "1.235"), (1.23456, "abc", "1"),
            // coercion of the number
            ("3,14159", 2, "3.14"), (" 42 ", 1, "42.0"), (true, 1, "1.0"),
            // what is not a number gives the empty text
            ("", 2, ""), ("abc", 2, ""), (date("2026-10-04"), 2, ""), (.list([1]), 2, ""), (.map([:]), 2, ""),
        ]
        for (number, decimals, expected) in cases {
            XCTAssertEqual(host.evaluate("operator.formatNumber", ["number": lit(number), "decimals": lit(decimals)]), .text(expected),
                           "\(number) with \(decimals)")
        }
        XCTAssertEqual(host.evaluate("operator.formatNumber", ["number": lit(7)]), "7.00", "two decimals by default")
        XCTAssertEqual(host.evaluate("operator.formatNumber"), "0.00", "both slots at their defaults")
    }

    func testFormattersAreInTheirCategories() {
        XCTAssertEqual(Vocabulary()["time.format"]?.category.id, "time")
        XCTAssertEqual(Vocabulary()["time.format"]?.result, .text)
        XCTAssertEqual(Vocabulary()["operator.formatNumber"]?.category.id, "operators")
        XCTAssertEqual(Vocabulary()["operator.formatNumber"]?.inputs.map(\.defaultValue), [0, 2])
    }

    func testFormattingDoesNotDependOnTheMachinesLocale() {
        // The formatter's locale is fixed, so this reads the same under any system setting. (The test cannot
        // change the system locale; it pins the expectation that month and day names are English.)
        XCTAssertEqual(format(stamp("2026-03-01T12:00:00Z"), "MMMM EEEE"), "March Sunday")
        XCTAssertEqual(host.evaluate("operator.formatNumber", ["number": lit(1234.5), "decimals": lit(1)]), "1234.5")
    }
}
