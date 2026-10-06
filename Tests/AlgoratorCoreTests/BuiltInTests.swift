import XCTest
import AlgoratorCore

final class BuiltInTests: XCTestCase {
    private let host = TestHost()

    private func check(_ kind: String, _ inputs: [String: Value], _ expected: Value,
                       file: StaticString = #filePath, line: UInt = #line) {
        let result = host.evaluate(kind, inputs.mapValues { lit($0) })
        XCTAssertEqual(result, expected, "\(kind) \(inputs)", file: file, line: line)
    }

    func testEveryBuiltInIsRegisteredOnce() {
        let ids = Vocabulary.builtIns.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(Vocabulary().categories.map(\.id), ["control", "variables", "operators", "time", "lists", "maps"])
        XCTAssertEqual(Vocabulary(includeBuiltIns: false).definitions.count, 0)
    }

    // MARK: Operators

    func testComparisons() {
        check("operator.equals", ["a": "High", "b": "high"], true)
        check("operator.equals", ["a": "2", "b": 2], true)
        check("operator.equals", ["a": "a", "b": "b"], false)
        check("operator.notEquals", ["a": "a", "b": "b"], true)
        check("operator.notEquals", ["a": 1, "b": "1"], false)
        check("operator.less", ["a": 2, "b": 10], true)
        check("operator.less", ["a": "2", "b": "10"], true)
        check("operator.less", ["a": 10, "b": 10], false)
        check("operator.greater", ["a": "b", "b": "a"], true)
        check("operator.greater", ["a": date("2026-10-04"), "b": "2026-10-05"], false)
        check("operator.less", ["a": stamp("2026-10-04T09:00:00Z"), "b": stamp("2026-10-04T10:00:00Z")], true)
    }

    func testLogic() {
        XCTAssertEqual(host.evaluate("operator.and", ["a": yes, "b": yes]), true)
        XCTAssertEqual(host.evaluate("operator.and", ["a": yes, "b": no]), false)
        XCTAssertEqual(host.evaluate("operator.or", ["a": no, "b": yes]), true)
        XCTAssertEqual(host.evaluate("operator.or", ["a": no, "b": no]), false)
        XCTAssertEqual(host.evaluate("operator.not", ["a": no]), true)
        XCTAssertEqual(host.evaluate("operator.not", ["a": yes]), false)
        // Empty boolean slots are false.
        XCTAssertEqual(host.evaluate("operator.or"), false)
        XCTAssertEqual(host.evaluate("operator.not"), true)
    }

    func testArithmetic() {
        check("operator.add", ["a": 2, "b": 3], 5)
        check("operator.add", ["a": "2,5", "b": "abc"], 2.5)
        check("operator.subtract", ["a": 2, "b": 3], -1)
        check("operator.multiply", ["a": 4, "b": 2.5], 10)
        check("operator.divide", ["a": 7, "b": 2], 3.5)
        check("operator.divide", ["a": 7, "b": 0], 0)
        check("operator.multiply", ["a": .number(1e200), "b": .number(1e200)], 0)
        // Empty number slots default to 0.
        XCTAssertEqual(host.evaluate("operator.add"), 0)
    }

    func testText() {
        check("operator.join", ["a": "Escalated: ", "b": "Login"], "Escalated: Login")
        check("operator.join", ["a": 1, "b": true], "1true")
        check("operator.contains", ["text": "Hello World", "part": "WORLD"], true)
        check("operator.contains", ["text": "Hello", "part": "xyz"], false)
        check("operator.contains", ["text": "Hello", "part": ""], false)
        check("operator.startsWith", ["text": "Hello", "prefix": "he"], true)
        check("operator.startsWith", ["text": "Hello", "prefix": "lo"], false)
        check("operator.startsWith", ["text": "Hello", "prefix": ""], true)
        check("operator.matches", ["text": "T-123", "pattern": "^T-\\d+$"], true)
        check("operator.matches", ["text": "X-123", "pattern": "^T-\\d+$"], false)
        check("operator.matches", ["text": "abc", "pattern": "("], false)   // invalid pattern never fails the run
        check("operator.isEmpty", ["value": ""], true)
        check("operator.isEmpty", ["value": " "], false)
        check("operator.isEmpty", ["value": .list([])], true)
        check("operator.isEmpty", ["value": ref("user", "")], true)
        check("operator.isEmpty", ["value": 0], false)
        check("operator.length", ["text": "héllo"], 5)
        check("operator.length", ["text": ""], 0)
        check("operator.length", ["text": 1234], 4)
    }

    // MARK: Time

    func testNowAndToday() {
        XCTAssertEqual(host.evaluate("time.now"), .timestamp(fixedNow))
        XCTAssertEqual(host.evaluate("time.today"), date("2026-10-04"))
        // 23:30Z is already tomorrow in Prague.
        let late = RunEnvironment(timeZone: prague, now: { fixedNow.addingTimeInterval(13.5 * 3600) })
        XCTAssertEqual(host.evaluate("time.today", environment: late), date("2026-10-05"))
    }

    func testTimestampParts() {
        check("time.dateOf", ["timestamp": stamp("2026-10-04T23:30:00Z")], date("2026-10-05"))
        check("time.timeOf", ["timestamp": stamp("2026-10-04T23:30:00Z")], time("01:30"))
        check("time.dateOf", ["timestamp": "2026-10-04T12:00:00+02:00"], date("2026-10-04"))
        check("time.dateOf", ["timestamp": "nonsense"], .empty)
        check("time.timeOf", ["timestamp": 5], .empty)
        check("time.makeTimestamp", ["date": date("2026-10-04"), "time": time("12:00")], .timestamp(fixedNow))
        check("time.makeTimestamp", ["date": "2026-10-04", "time": "12:00"], .timestamp(fixedNow))
        check("time.makeTimestamp", ["date": "", "time": time("12:00")], .empty)
    }

    func testAddDays() {
        check("time.addDays", ["amount": 1, "to": date("2026-12-31")], date("2027-01-01"))
        check("time.addDays", ["amount": -1, "to": date("2024-03-01")], date("2024-02-29"))
        check("time.addDays", ["amount": 2, "to": "2026-10-04"], date("2026-10-06"))
        check("time.addDays", ["amount": 2, "to": .timestamp(fixedNow)], .timestamp(fixedNow.addingTimeInterval(2 * 86_400)))
        // Across the end of summer time (2026-10-25) the wall-clock time is kept, so the day is 25 hours long.
        check("time.addDays", ["amount": 1, "to": stamp("2026-10-24T10:00:00Z")], stamp("2026-10-25T11:00:00Z"))
        check("time.addDays", ["amount": 1, "to": "someday"], .empty)
        check("time.addDays", ["amount": 1, "to": time("10:00")], .empty)
    }

    func testAddHoursAndMinutes() {
        check("time.addHours", ["amount": 2, "to": .timestamp(fixedNow)], .timestamp(fixedNow.addingTimeInterval(7200)))
        check("time.addHours", ["amount": -1.5, "to": .timestamp(fixedNow)], .timestamp(fixedNow.addingTimeInterval(-5400)))
        check("time.addMinutes", ["amount": 30, "to": .timestamp(fixedNow)], .timestamp(fixedNow.addingTimeInterval(1800)))
        check("time.addMinutes", ["amount": 45, "to": time("23:30")], time("00:15"))
        check("time.addHours", ["amount": -2, "to": time("01:00")], time("23:00"))
        check("time.addHours", ["amount": 1, "to": "09:30"], time("10:30"))
        // A date is taken at its midnight in the environment's zone.
        check("time.addHours", ["amount": 12, "to": date("2026-10-04")], .timestamp(fixedNow))
        check("time.addMinutes", ["amount": 1, "to": "never"], .empty)
    }

    // MARK: Lists

    func testLists() {
        check("list.split", ["text": "a,b,,c", "separator": ","], .list(["a", "b", "", "c"]))
        check("list.split", ["text": "", "separator": ","], .list([]))
        check("list.split", ["text": "abc", "separator": ""], .list(["abc"]))
        check("list.split", ["text": "a - b", "separator": " - "], .list(["a", "b"]))
        check("list.join", ["list": .list(["a", 2, true]), "separator": "+"], "a+2+true")
        check("list.join", ["list": .list([]), "separator": "+"], "")
        check("list.join", ["list": "solo", "separator": "+"], "solo")
        check("list.item", ["index": 1, "list": .list(["a", "b"])], "a")
        check("list.item", ["index": 2, "list": .list(["a", "b"])], "b")
        check("list.item", ["index": 0, "list": .list(["a", "b"])], .empty)
        check("list.item", ["index": 3, "list": .list(["a", "b"])], .empty)
        check("list.item", ["index": "2", "list": .list(["a", 7])], 7)
        check("list.length", ["list": .list(["a", "b"])], 2)
        check("list.length", ["list": ""], 0)
        check("list.length", ["list": "x"], 1)
        check("list.contains", ["list": .list(["a", "B", 3]), "item": "b"], true)
        check("list.contains", ["list": .list(["a", "B", 3]), "item": "3"], true)
        check("list.contains", ["list": .list(["a"]), "item": "z"], false)
    }

    func testReportersNest() {
        // length of (join "ab" (join "cd" "e")) = 5
        let inner = rep("operator.join", ["a": lit("cd"), "b": lit("e")])
        let outer = rep("operator.join", ["a": lit("ab"), "b": inner])
        XCTAssertEqual(host.evaluate("operator.length", ["text": outer]), 5)
    }

    // MARK: Title templates

    func testTitleParsing() {
        XCTAssertEqual(TitlePart.parse("fetch ticket %ticket"), [.text("fetch ticket"), .slot("ticket")])
        XCTAssertEqual(TitlePart.parse("%a = %b"), [.slot("a"), .text("="), .slot("b")])
        XCTAssertEqual(TitlePart.parse("add %amount days to %to"),
                       [.text("add"), .slot("amount"), .text("days to"), .slot("to")])
        XCTAssertEqual(TitlePart.parse("now"), [.text("now")])
        XCTAssertEqual(TitlePart.parse("100 % sure"), [.text("100 % sure")])
        XCTAssertEqual(TitlePart.parse(""), [])
    }
}
