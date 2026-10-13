import Foundation

public enum ResetSchedule {
    /// Offsets from the predicted reset. After the last one, aggressive retries stop.
    public static let offsets: [TimeInterval] = [0, 15, 60, 180, 300]

    public static func nextAttemptDate(attempt: Int, resetAt: Date) -> Date? {
        guard attempt >= 0, attempt < offsets.count else { return nil }
        return resetAt.addingTimeInterval(offsets[attempt])
    }

    public static func isDue(attempt: Int, resetAt: Date, now: Date) -> Bool {
        guard let when = nextAttemptDate(attempt: attempt, resetAt: resetAt) else { return false }
        return now >= when
    }
}

public struct UsagePrediction: Equatable, Sendable {
    public var message: String
    public var estimatedExhaustion: Date?

    public init(message: String, estimatedExhaustion: Date? = nil) {
        self.message = message
        self.estimatedExhaustion = estimatedExhaustion
    }
}

public enum UsageEstimator {
    public static func predictWeekly(
        snapshots: [(date: Date, used: Double)],
        now: Date = Date()
    ) -> UsagePrediction? {
        let points = snapshots.filter { $0.used >= 0 && $0.used <= 1.5 }.sorted { $0.date < $1.date }
        guard let first = points.first, let last = points.last else { return nil }
        let elapsed = last.date.timeIntervalSince(first.date)
        guard elapsed >= 30 * 60 else { return nil }
        let delta = last.used - first.used
        guard delta > 0.01, last.used < 1 else { return nil }
        let rate = delta / elapsed
        let remaining = 1 - last.used
        let seconds = remaining / rate
        let when = last.date.addingTimeInterval(seconds)
        guard when > now else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE h:mm a"
        let label = formatter.string(from: when)
        return UsagePrediction(
            message: "At your current usage rate, this allowance may run out \(label).",
            estimatedExhaustion: when
        )
    }
}
