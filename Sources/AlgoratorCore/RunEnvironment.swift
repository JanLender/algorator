import Foundation

/// What a run (and every time-zone-dependent coercion) needs from the outside world.
/// Supply a fixed `timeZone` and `now` to make runs deterministic.
public struct RunEnvironment: Sendable {
    public var timeZone: TimeZone
    public var now: @Sendable () -> Date
    /// How deep `call script` may nest before the run fails (a cycle would otherwise never end).
    public var maxCallDepth: Int
    /// Polled before every statement; when it answers `true` the run ends as cancelled.
    public var isCancelled: @Sendable () -> Bool

    public init(timeZone: TimeZone = .current, now: @escaping @Sendable () -> Date = { Date() },
                maxCallDepth: Int = 30, isCancelled: @escaping @Sendable () -> Bool = { false }) {
        self.timeZone = timeZone
        self.now = now
        self.maxCallDepth = maxCallDepth
        self.isCancelled = isCancelled
    }
}
