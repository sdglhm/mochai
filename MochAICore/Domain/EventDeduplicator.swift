import Foundation

public struct EventDeduplicator: Sendable {
    private var seen: [String: Date] = [:]
    public var window: TimeInterval

    public init(window: TimeInterval = 1.5) {
        self.window = window
    }

    public mutating func accept(_ event: NormalizedEvent, now: Date = Date()) -> Bool {
        prune(now: now)
        if let previous = seen[event.id], now.timeIntervalSince(previous) < window {
            return false
        }
        seen[event.id] = now
        return true
    }

    public mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-(window * 4))
        seen = seen.filter { $0.value >= cutoff }
    }
}
