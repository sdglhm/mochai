import Foundation

public enum AvailabilityCheck {
    public enum Result: Equatable, Sendable {
        case available
        case limited(Date?)
        case unknown
    }

    public static func evaluate(usage: ProviderUsage, now: Date) -> Result {
        guard usage.confidence != .unavailable, !usage.windows.isEmpty else { return .unknown }
        let current = usage.windows.filter { $0.isCurrent(at: now) }
        guard !current.isEmpty else { return .unknown }
        let fullest = current.max { ($0.resolvedUsed ?? 0) < ($1.resolvedUsed ?? 0) }
        if let used = fullest?.resolvedUsed, used >= 0.995 {
            return .limited(fullest?.resetAt)
        }
        if let reset = fullest?.resetAt, reset > now, (fullest?.resolvedUsed ?? 0) >= 0.98 {
            return .limited(reset)
        }
        return .available
    }
}

public struct ResetDecision: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case wait
        case stillLimited(nextAttempt: Int, exhausted: Bool)
        case ready(automatic: Bool)
        case unconfirmed
    }

    public var action: Action
    public var message: String

    public init(action: Action, message: String) {
        self.action = action
        self.message = message
    }
}

public enum ResetCoordinator {
    public static func decide(
        attempt: Int,
        resetAt: Date?,
        usage: ProviderUsage,
        resume: ResumeDecision,
        now: Date
    ) -> ResetDecision {
        let anchor = resetAt ?? now
        guard ResetSchedule.isDue(attempt: attempt, resetAt: anchor, now: now) else {
            return ResetDecision(action: .wait, message: "Still waiting for the reset.")
        }
        switch AvailabilityCheck.evaluate(usage: usage, now: now) {
        case .limited:
            let next = attempt + 1
            let exhausted = ResetSchedule.nextAttemptDate(attempt: next, resetAt: anchor) == nil
            let message = exhausted
                ? "MochAI stopped checking automatically. You can try continuing when you're ready."
                : "The provider still looks limited."
            return ResetDecision(action: .stillLimited(nextAttempt: next, exhausted: exhausted), message: message)
        case .available:
            if resume.automaticAllowed {
                return ResetDecision(action: .ready(automatic: true), message: "Usage is available again.")
            }
            return ResetDecision(action: .ready(automatic: false), message: resume.reason ?? "Usage is available again.")
        case .unknown:
            return ResetDecision(
                action: .unconfirmed,
                message: "The reset time has passed, but MochAI couldn't confirm that usage is available."
            )
        }
    }
}
