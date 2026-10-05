import XCTest
import AlgoratorCore

final class CoercionTests: XCTestCase {

    // MARK: toNumber

    func testToNumber() {
        let cases: [(Value, Double)] = [
            (.number(3.5), 3.5),
            ("42", 42), ("  42  ", 42), ("\t7\n", 7),
            ("3.14", 3.14), ("3,14", 3.14), ("-2,5", -2.5), ("+4", 4), (".5", 0.5), ("5.", 5),
            ("1e3", 1000), ("1.5E-1", 0.15),
            ("", 0), ("   ", 0), ("abc", 0), ("12abc", 0), ("1,234.5", 0), ("1.2.3", 0), ("--1", 0),
            ("e3", 0), (".", 0), ("-", 0), ("0x10", 0), ("inf", 0), ("nan", 0), ("Infinity", 0), ("1e999", 0),
            (true, 1), (false, 0),
            (date("2026-10-04"), 0), (time("09:30"), 0), (stamp("2026-10-04T10:00:00Z"), 0),
            (ref("ticket", "7"), 0), (.list(["1", "2"]), 0), (.list([]), 0),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(Coercion.toNumber(value), expected, "\(value)")
        }
    }

    func testNumericDistinguishesNonNumbers() {
        XCTAssertEqual(Coercion.numeric("0"), 0)
        XCTAssertEqual(Coercion.numeric(true), 1)
        XCTAssertNil(Coercion.numeric(""))
        XCTAssertNil(Coercion.numeric("   "))
        XCTAssertNil(Coercion.numeric("abc"))
        XCTAssertNil(Coercion.numeric(ref("ticket", "7")))
        XCTAssertNil(Coercion.numeric(date("2026-10-04")))
        XCTAssertNil(Coercion.numeric(.list([1])))
    }

    // MARK: toText

    func testToText() {
        let cases: [(Value, String)] = [
            ("hello", "hello"), ("", ""),
            (3, "3"), (3.0, "3"), (-0.0, "0"), (3.5, "3.5"), (-12, "-12"), (0.1, "0.1"),
            (1_000_000, "1000000"), (.number(1e21), "1e+21"),
            (.number(.nan), "NaN"), (.number(.infinity), "Infinity"), (.number(-.infinity), "-Infinity"),
            (true, "true"), (false, "false"),
            (date("2026-01-05"), "2026-01-05"),
            (time("09:30"), "09:30"), (time("09:30:00"), "09:30"), (time("09:30:07"), "09:30:07"),
            (stamp("2026-10-04T10:00:00Z"), "2026-10-04T12:00:00+02:00"),   // summer time
            (stamp("2026-01-15T23:30:00Z"), "2026-01-16T00:30:00+01:00"),   // winter time, next day
            (stamp("2026-10-04T10:00:00.250Z"), "2026-10-04T12:00:00.250+02:00"),
            (ref("ticket", "T-1"), "T-1"),
            (.list([]), ""), (.list(["a", 2, true]), "a\n2\ntrue"),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(Coercion.toText(value, in: env), expected, "\(value)")
        }
    }

    func testToTextTimestampUsesEnvironmentZone() {
        let value = stamp("2026-10-04T10:00:00Z")
        XCTAssertEqual(Coercion.toText(value, in: utcEnv), "2026-10-04T10:00:00+00:00")
        let newYork = RunEnvironment(timeZone: TimeZone(identifier: "America/New_York")!, now: { fixedNow })
        XCTAssertEqual(Coercion.toText(value, in: newYork), "2026-10-04T06:00:00-04:00")
    }

    // MARK: toBool

    func testToBool() {
        let cases: [(Value, Bool)] = [
            (true, true), (false, false),
            ("", false), ("0", false), ("false", false), ("FALSE", false), ("False", false),
            ("true", true), ("1", true), ("no", true), (" ", true), ("0.0", true), (" false", true),
            (0, false), (-0.0, false), (1, true), (-3.5, true),
            (.list([]), false), (.list([""]), true),
            (ref("user", ""), false), (ref("user", "u1"), true),
            (date("2026-10-04"), true), (time("00:00"), true), (stamp("1970-01-01T00:00:00Z"), true),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(Coercion.toBool(value), expected, "\(value)")
        }
    }

    // MARK: Temporal conversions

    func testToDate() {
        XCTAssertEqual(Coercion.toDate(date("2026-10-04"), in: env), LocalDate(iso: "2026-10-04"))
        XCTAssertEqual(Coercion.toDate("2026-10-04", in: env), LocalDate(iso: "2026-10-04"))
        XCTAssertEqual(Coercion.toDate(" 2026-10-04 ", in: env), LocalDate(iso: "2026-10-04"))
        // 23:30Z is already the next day in Prague, but not in UTC.
        XCTAssertEqual(Coercion.toDate(stamp("2026-10-04T23:30:00Z"), in: env), LocalDate(iso: "2026-10-05"))
        XCTAssertEqual(Coercion.toDate(stamp("2026-10-04T23:30:00Z"), in: utcEnv), LocalDate(iso: "2026-10-04"))
        XCTAssertEqual(Coercion.toDate("2026-10-04T23:30:00Z", in: env), LocalDate(iso: "2026-10-05"))
        for value: Value in ["", "yesterday", "2026-02-30", 5, true, time("09:30"), ref("t", "2026-10-04"), .list([])] {
            XCTAssertNil(Coercion.toDate(value, in: env), "\(value)")
        }
    }

    func testToTime() {
        XCTAssertEqual(Coercion.toTime(time("09:30:05"), in: env), LocalTime(hour: 9, minute: 30, second: 5))
        XCTAssertEqual(Coercion.toTime("09:30", in: env), LocalTime(hour: 9, minute: 30))
        XCTAssertEqual(Coercion.toTime(stamp("2026-10-04T10:15:00Z"), in: env), LocalTime(hour: 12, minute: 15))
        XCTAssertEqual(Coercion.toTime(stamp("2026-01-15T10:15:00Z"), in: env), LocalTime(hour: 11, minute: 15))
        for value: Value in ["", "9:30", "24:00", "noon", 930, date("2026-10-04"), .list([])] {
            XCTAssertNil(Coercion.toTime(value, in: env), "\(value)")
        }
    }

    func testToTimestamp() {
        let noonPrague = fixedNow
        XCTAssertEqual(Coercion.toTimestamp(.timestamp(noonPrague), in: env), noonPrague)
        XCTAssertEqual(Coercion.toTimestamp("2026-10-04T10:00:00Z", in: env), noonPrague)
        XCTAssertEqual(Coercion.toTimestamp("2026-10-04T12:00:00+02:00", in: env), noonPrague)
        XCTAssertEqual(Coercion.toTimestamp("2026-10-04T12:00:00+0200", in: env), noonPrague)
        XCTAssertEqual(Coercion.toTimestamp("2026-10-04T05:00:00-05", in: env), noonPrague)
        XCTAssertEqual(Coercion.toTimestamp("2026-10-04 12:00", in: env), noonPrague, "no zone means the environment's")
        XCTAssertEqual(Coercion.toTimestamp("2026-10-04T10:00", in: utcEnv), noonPrague)
        XCTAssertEqual(Coercion.toTimestamp("2026-10-04T10:00:00.500Z", in: env), noonPrague.addingTimeInterval(0.5))
        // A date is its midnight in the environment's zone.
        XCTAssertEqual(Coercion.toTimestamp(date("2026-10-04"), in: env), noonPrague.addingTimeInterval(-12 * 3600))
        XCTAssertEqual(Coercion.toTimestamp("2026-10-04", in: utcEnv), noonPrague.addingTimeInterval(-10 * 3600))
        for value: Value in ["", "soon", "2026-10-04T25:00:00Z", "2026-10-04X10:00", "2026-10-04T10:00:00+2", 0,
                             time("09:30"), true, .list([])] {
            XCTAssertNil(Coercion.toTimestamp(value, in: env), "\(value)")
        }
    }

    func testCombineDateAndTime() {
        let summer = Coercion.timestamp(date: LocalDate(iso: "2026-10-04")!, time: LocalTime(iso: "12:00")!, in: env)
        XCTAssertEqual(summer, fixedNow)
        let winter = Coercion.timestamp(date: LocalDate(iso: "2026-01-15")!, time: LocalTime(iso: "12:00")!, in: env)
        XCTAssertEqual(winter.map { Coercion.toText(.timestamp($0), in: utcEnv) }, "2026-01-15T11:00:00+00:00")
    }

    // MARK: toList, toReference, convert

    func testToList() {
        XCTAssertEqual(Coercion.toList(.list(["a", 1])), ["a", 1])
        XCTAssertEqual(Coercion.toList(""), [])
        XCTAssertEqual(Coercion.toList("a"), ["a"])
        XCTAssertEqual(Coercion.toList(0), [0])
        XCTAssertEqual(Coercion.toList(ref("user", "u1")), [ref("user", "u1")])
    }

    func testToReference() {
        XCTAssertEqual(Coercion.toReference(ref("user", "u1"), kind: "ticket", in: env), Reference(kind: "user", id: "u1"))
        XCTAssertEqual(Coercion.toReference("T-1", kind: "ticket", in: env), Reference(kind: "ticket", id: "T-1"))
        XCTAssertEqual(Coercion.toReference(7, kind: "ticket", in: env), Reference(kind: "ticket", id: "7"))
        XCTAssertEqual(Coercion.toReference("", kind: "ticket", in: env), Reference(kind: "ticket", id: ""))
    }

    func testConvertIsTotal() {
        let samples: [Value] = ["", "abc", "12", 0, 2.5, true, false, date("2026-10-04"), time("09:30"),
                                stamp("2026-10-04T10:00:00Z"), ref("user", "u1"), .list([]), .list(["a", 1])]
        for value in samples {
            for type in ValueType.allCases {
                let converted = Coercion.convert(value, to: type, referenceKind: "user", in: env)
                // Either the requested type, or the empty value where no conversion exists.
                XCTAssertTrue(converted.type == type || converted == .empty, "\(value) → \(type) gave \(converted)")
            }
        }
        XCTAssertEqual(Coercion.convert(5, to: .date, in: env), .empty)
        XCTAssertEqual(Coercion.convert("x", to: .timestamp, in: env), .empty)
        XCTAssertEqual(Coercion.convert("2026-10-04", to: .date, in: env), date("2026-10-04"))
        XCTAssertEqual(Coercion.convert("12", to: .number, in: env), 12)
        XCTAssertEqual(Coercion.convert(12, to: .text, in: env), "12")
        XCTAssertEqual(Coercion.convert("T-1", to: .reference, referenceKind: "ticket", in: env), ref("ticket", "T-1"))
        XCTAssertEqual(Coercion.convert("a", to: .list, in: env), .list(["a"]))
    }

    // MARK: compare

    func testCompare() {
        let asc = ComparisonResult.orderedAscending, same = ComparisonResult.orderedSame
        let cases: [(Value, Value, ComparisonResult)] = [
            // numeric
            (2, 10, asc), ("2", "10", asc), ("2", 10, asc), ("2,5", 2.5, same), (" 3 ", 3, same),
            (true, 1, same), (false, 1, asc), ("1e2", 100, same),
            // text, case-insensitive
            ("apple", "Banana", asc), ("HIGH", "high", same), ("abc", "abd", asc), ("", "a", asc), ("", "", same),
            // whitespace-only and unparsable text is not numeric, so this is text order ("" < "0", "10" < "9a")
            ("", 0, asc), ("   ", 0, asc), ("10", "9a", asc),
            (true, "true", same), (true, "TRUE", same),
            // temporal, same type
            (date("2026-10-03"), date("2026-10-04"), asc), (date("2026-10-04"), date("2026-10-04"), same),
            (time("09:30"), time("10:00"), asc), (time("09:30"), time("09:30:00"), same),
            (stamp("2026-10-04T09:59:59Z"), stamp("2026-10-04T10:00:00Z"), asc),
            (stamp("2026-10-04T12:00:00+02:00"), stamp("2026-10-04T10:00:00Z"), same),
            // temporal against ISO text
            (date("2026-10-04"), "2026-10-05", asc), (date("2026-10-04"), "2026-10-04", same),
            (time("09:30"), "09:45", asc),
            (stamp("2026-10-04T10:00:00Z"), "2026-10-04T12:00:00+02:00", same),
            (stamp("2026-10-04T10:00:00Z"), "2026-10-04 12:30", asc),   // zoneless text is local to Prague
            // a date against a timestamp compares days in the environment's zone
            (date("2026-10-04"), stamp("2026-10-04T15:00:00Z"), same),
            (date("2026-10-04"), stamp("2026-10-04T23:30:00Z"), asc),   // already 2026-10-05 in Prague
            (time("12:00"), stamp("2026-10-04T10:00:00Z"), same),
            // parse failure falls back to text ("2026-10-04" < "tomorrow"; "09:30" < "2026-10-04")
            (date("2026-10-04"), "tomorrow", asc), (time("09:30"), date("2026-10-04"), asc),
            (date("2026-10-04"), 5, asc),
            // references
            (ref("ticket", "a"), ref("ticket", "b"), asc), (ref("ticket", "a"), ref("ticket", "a"), same),
            (ref("ticket", "z"), ref("user", "a"), asc),
            (ref("ticket", "T-1"), "t-1", same), (ref("ticket", "42"), 42, same), (ref("ticket", "a"), "b", asc),
            // lists compare as their text
            (.list(["a", "b"]), "a\nb", same),
        ]
        for (a, b, expected) in cases {
            XCTAssertEqual(Coercion.compare(a, b, in: env), expected, "\(a) vs \(b)")
            XCTAssertEqual(Coercion.compare(b, a, in: env), expected.reversed, "\(b) vs \(a)")
            XCTAssertEqual(Coercion.equal(a, b, in: env), expected == .orderedSame, "\(a) = \(b)")
        }
    }

    func testCompareDependsOnEnvironmentZone() {
        // The same instant falls on different days in different zones.
        let late = stamp("2026-10-04T23:30:00Z")
        XCTAssertEqual(Coercion.compare(date("2026-10-04"), late, in: utcEnv), .orderedSame)
        XCTAssertEqual(Coercion.compare(date("2026-10-04"), late, in: env), .orderedAscending)
    }
}

private extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}
