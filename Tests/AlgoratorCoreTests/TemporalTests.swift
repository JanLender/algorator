import XCTest
import AlgoratorCore

final class TemporalTests: XCTestCase {

    func testLocalDateValidity() {
        XCTAssertNotNil(LocalDate(year: 2024, month: 2, day: 29))
        XCTAssertNil(LocalDate(year: 2026, month: 2, day: 29))
        XCTAssertNil(LocalDate(year: 1900, month: 2, day: 29))
        XCTAssertNotNil(LocalDate(year: 2000, month: 2, day: 29))
        XCTAssertNil(LocalDate(year: 2026, month: 4, day: 31))
        XCTAssertNil(LocalDate(year: 2026, month: 13, day: 1))
        XCTAssertNil(LocalDate(year: 2026, month: 0, day: 1))
        XCTAssertNil(LocalDate(year: 2026, month: 1, day: 0))
    }

    func testLocalDateParsingAndPrinting() {
        XCTAssertEqual(LocalDate(iso: "2026-01-05")?.description, "2026-01-05")
        XCTAssertEqual(LocalDate(iso: "0099-12-31")?.description, "0099-12-31")
        for text in ["", "2026-1-5", "2026-01", "2026-01-05-01", "26-01-05", "2026/01/05", "2026-01-0x", "2026-02-30",
                     "2026-01-05T10:00"] {
            XCTAssertNil(LocalDate(iso: text), text)
        }
    }

    func testLocalDateOrdering() {
        XCTAssertLessThan(LocalDate(iso: "2025-12-31")!, LocalDate(iso: "2026-01-01")!)
        XCTAssertLessThan(LocalDate(iso: "2026-01-31")!, LocalDate(iso: "2026-02-01")!)
        XCTAssertLessThan(LocalDate(iso: "2026-02-01")!, LocalDate(iso: "2026-02-02")!)
    }

    func testLocalTimeParsingAndPrinting() {
        XCTAssertEqual(LocalTime(iso: "09:05")?.description, "09:05")
        XCTAssertEqual(LocalTime(iso: "09:05:00")?.description, "09:05")
        XCTAssertEqual(LocalTime(iso: "23:59:59")?.description, "23:59:59")
        XCTAssertEqual(LocalTime(iso: "00:00"), LocalTime(hour: 0, minute: 0))
        for text in ["", "9:05", "09", "24:00", "09:60", "09:05:60", "09:05:07.5", "09:05:07:01", "ab:cd"] {
            XCTAssertNil(LocalTime(iso: text), text)
        }
        XCTAssertNil(LocalTime(hour: -1, minute: 0))
    }

    func testLocalTimeOrdering() {
        XCTAssertLessThan(LocalTime(iso: "09:59:59")!, LocalTime(iso: "10:00")!)
        XCTAssertLessThan(LocalTime(iso: "10:00")!, LocalTime(iso: "10:00:01")!)
    }
}
