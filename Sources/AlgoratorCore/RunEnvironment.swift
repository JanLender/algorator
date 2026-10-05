import Foundation

/// What a run (and every time-zone-dependent coercion) needs from the outside world.
/// Supply a fixed `timeZone` and `now` to make runs deterministic.
public struct RunEnvironment: Sendable {
    public var timeZone: TimeZone
    public var now: @Sendable () -> Date

    public init(timeZone: TimeZone = .current, now: @escaping @Sendable () -> Date = { Date() }) {
        self.timeZone = timeZone
        self.now = now
    }
}
