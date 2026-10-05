import Foundation

/// A calendar day with no time and no time zone (never stored as an instant).
public struct LocalDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Fails for a day that does not exist in the proleptic Gregorian calendar.
    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month),
              (1...LocalDate.daysInMonth(month, year: year)).contains(day) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `yyyy-MM-dd`.
    public init?(iso: String) {
        let parts = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let y = ISO.digits(parts[0], count: 4),
              let m = ISO.digits(parts[1], count: 2),
              let d = ISO.digits(parts[2], count: 2) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (a: LocalDate, b: LocalDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    static func daysInMonth(_ month: Int, year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }
}

/// A time of day with no date and no time zone, to the second.
public struct LocalTime: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let hour: Int
    public let minute: Int
    public let second: Int

    public init?(hour: Int, minute: Int, second: Int = 0) {
        guard (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        self.hour = hour
        self.minute = minute
        self.second = second
    }

    /// Parses `HH:mm` or `HH:mm:ss`.
    public init?(iso: String) {
        let parts = iso.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let h = ISO.digits(parts[0], count: 2),
              let m = ISO.digits(parts[1], count: 2) else { return nil }
        var s = 0
        if parts.count == 3 {
            guard let parsed = ISO.digits(parts[2], count: 2) else { return nil }
            s = parsed
        }
        self.init(hour: h, minute: m, second: s)
    }

    /// `HH:mm`, or `HH:mm:ss` when the seconds are not zero.
    public var description: String {
        second == 0 ? String(format: "%02d:%02d", hour, minute)
                    : String(format: "%02d:%02d:%02d", hour, minute, second)
    }

    public static func < (a: LocalTime, b: LocalTime) -> Bool {
        (a.hour, a.minute, a.second) < (b.hour, b.minute, b.second)
    }
}

/// ISO 8601 parsing/formatting and conversions between instants and local date/time.
enum ISO {
    static let utc = TimeZone(secondsFromGMT: 0)!

    static func digits(_ s: Substring, count: Int) -> Int? {
        guard s.count == count, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(s)
    }

    static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    static func instant(_ date: LocalDate, _ time: LocalTime, in zone: TimeZone) -> Date? {
        let components = DateComponents(year: date.year, month: date.month, day: date.day,
                                        hour: time.hour, minute: time.minute, second: time.second)
        return calendar(zone).date(from: components)
    }

    static func localDate(of instant: Date, in zone: TimeZone) -> LocalDate? {
        let c = calendar(zone).dateComponents([.year, .month, .day], from: instant)
        return LocalDate(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)
    }

    static func localTime(of instant: Date, in zone: TimeZone) -> LocalTime? {
        let c = calendar(zone).dateComponents([.hour, .minute, .second], from: instant)
        return LocalTime(hour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0)
    }

    /// `yyyy-MM-ddTHH:mm:ss[.SSS]±HH:mm` in `zone` (`Z` instead of the offset when `zulu`).
    /// Milliseconds are printed only when not zero.
    static func format(_ instant: Date, in zone: TimeZone, zulu: Bool = false) -> String {
        let totalMs = Int64((instant.timeIntervalSince1970 * 1000).rounded())
        let ms = ((totalMs % 1000) + 1000) % 1000
        let whole = Date(timeIntervalSince1970: Double((totalMs - ms) / 1000))
        let c = calendar(zone).dateComponents([.year, .month, .day, .hour, .minute, .second], from: whole)
        var text = String(format: "%04d-%02d-%02dT%02d:%02d:%02d",
                          c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        if ms != 0 { text += String(format: ".%03d", ms) }
        if zulu { return text + "Z" }
        let offset = zone.secondsFromGMT(for: whole)
        let minutes = abs(offset) / 60
        return text + String(format: "%@%02d:%02d", offset < 0 ? "-" : "+", minutes / 60, minutes % 60)
    }

    /// Parses `yyyy-MM-dd(T| )HH:mm[:ss[.fff]][Z|±HH[:mm]]`. Without a zone the text is local to `defaultZone`.
    static func parseTimestamp(_ text: String, defaultZone: TimeZone) -> Date? {
        let s = Substring(text.trimmingCharacters(in: .whitespaces))
        guard s.count >= 16, let date = LocalDate(iso: String(s.prefix(10))) else { return nil }
        let separator = s[s.index(s.startIndex, offsetBy: 10)]
        guard separator == "T" || separator == "t" || separator == " " else { return nil }
        var rest = s.dropFirst(11)

        var offset: Int?
        if rest.last == "Z" || rest.last == "z" {
            offset = 0
            rest = rest.dropLast()
        } else if let signIndex = rest.lastIndex(where: { $0 == "+" || $0 == "-" }) {
            let zoneText = rest[rest.index(after: signIndex)...].filter { $0 != ":" }
            guard zoneText.count == 2 || zoneText.count == 4,
                  let hours = digits(Substring(zoneText.prefix(2)), count: 2), hours <= 23 else { return nil }
            var minutes = 0
            if zoneText.count == 4 {
                guard let parsed = digits(Substring(zoneText.suffix(2)), count: 2), parsed <= 59 else { return nil }
                minutes = parsed
            }
            offset = (rest[signIndex] == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)
            rest = rest[..<signIndex]
        }

        var fraction = 0.0
        if let dot = rest.firstIndex(of: ".") {
            let fractionText = rest[rest.index(after: dot)...]
            guard !fractionText.isEmpty, fractionText.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let parsed = Double("0." + fractionText) else { return nil }
            fraction = parsed
            rest = rest[..<dot]
        }
        guard let time = LocalTime(iso: String(rest)),
              let base = instant(date, time, in: offset == nil ? defaultZone : utc) else { return nil }
        return base.addingTimeInterval(fraction - Double(offset ?? 0))
    }
}
