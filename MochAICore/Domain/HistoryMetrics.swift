import Foundation

public struct HistoryMetrics: Equatable, Sendable {
    public var activeTime: TimeInterval
    public var toolTime: TimeInterval
    public var waitingTime: TimeInterval
    public var limitedTime: TimeInterval
    public var awakeTime: TimeInterval
    public var completed: Int
    public var interrupted: Int
    public var failed: Int
    public var resumed: Int

    public init(
        activeTime: TimeInterval = 0,
        toolTime: TimeInterval = 0,
        waitingTime: TimeInterval = 0,
        limitedTime: TimeInterval = 0,
        awakeTime: TimeInterval = 0,
        completed: Int = 0,
        interrupted: Int = 0,
        failed: Int = 0,
        resumed: Int = 0
    ) {
        self.activeTime = activeTime
        self.toolTime = toolTime
        self.waitingTime = waitingTime
        self.limitedTime = limitedTime
        self.awakeTime = awakeTime
        self.completed = completed
        self.interrupted = interrupted
        self.failed = failed
        self.resumed = resumed
    }
}

public enum HistoryCalculator {
    public static func metrics(for sessions: [AgentSession], now: Date = Date()) -> HistoryMetrics {
        var result = HistoryMetrics()
        for session in sessions {
            result.activeTime += session.workingTime(now: now)
            result.toolTime += session.time(in: [.runningTool, .runningCommand], now: now)
            result.waitingTime += session.waitingTime(now: now)
            result.limitedTime += session.limitedTime(now: now)
            result.awakeTime += session.awakeSeconds
            switch session.outcome {
            case .completed: result.completed += 1
            case .interrupted: result.interrupted += 1
            case .failed: result.failed += 1
            case .ongoing, .limited: break
            }
            if session.resume.readiness == .resumed { result.resumed += 1 }
        }
        return result
    }
}
