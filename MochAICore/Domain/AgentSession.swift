import Foundation

public struct TimelineEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var title: String
    public var state: AgentState

    public init(id: UUID = UUID(), timestamp: Date, title: String, state: AgentState) {
        self.id = id
        self.timestamp = timestamp
        self.title = title
        self.state = state
    }
}

public struct StateInterval: Codable, Equatable, Sendable {
    public var state: AgentState
    public var startedAt: Date
    public var endedAt: Date?

    public func duration(until now: Date) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }
}

public struct LimitInfo: Codable, Equatable, Sendable {
    public var detectedAt: Date
    public var resetAt: Date?
    public var errorCode: String?
    public var attempt: Int
    public var nextAttemptAt: Date?
    public var retriesExhausted: Bool

    public init(
        detectedAt: Date,
        resetAt: Date? = nil,
        errorCode: String? = nil,
        attempt: Int = 0,
        nextAttemptAt: Date? = nil,
        retriesExhausted: Bool = false
    ) {
        self.detectedAt = detectedAt
        self.resetAt = resetAt
        self.errorCode = errorCode
        self.attempt = attempt
        self.nextAttemptAt = nextAttemptAt
        self.retriesExhausted = retriesExhausted
    }
}

public struct ResumeMetadata: Codable, Equatable, Sendable {
    public var providerSessionID: String?
    public var executablePath: String?
    public var repositoryRoot: String?
    public var originURL: String?
    public var continuationPrompt: String?
    public var exactResumeAvailable: Bool
    public var manuallyCancelled: Bool
    public var readiness: ResumeReadiness
    public var blockedReason: String?

    public init(
        providerSessionID: String? = nil,
        executablePath: String? = nil,
        repositoryRoot: String? = nil,
        originURL: String? = nil,
        continuationPrompt: String? = nil,
        exactResumeAvailable: Bool = false,
        manuallyCancelled: Bool = false,
        readiness: ResumeReadiness = .none,
        blockedReason: String? = nil
    ) {
        self.providerSessionID = providerSessionID
        self.executablePath = executablePath
        self.repositoryRoot = repositoryRoot
        self.originURL = originURL
        self.continuationPrompt = continuationPrompt
        self.exactResumeAvailable = exactResumeAvailable
        self.manuallyCancelled = manuallyCancelled
        self.readiness = readiness
        self.blockedReason = blockedReason
    }
}

public struct AgentSession: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var provider: ProviderID
    public var processID: Int32?
    public var parentProcessID: Int32?
    public var providerSessionID: String?
    public var projectDirectory: String?
    public var repositoryName: String?
    public var repositoryRoot: String?
    public var branch: String?
    public var hasRepositoryChanges: Bool
    public var state: AgentState
    public var outcome: SessionOutcome
    public var lastEventSummary: String
    public var taskSummary: String?
    public var startedAt: Date
    public var lastActivityAt: Date
    public var completedAt: Date?
    public var usage: ProviderUsage?
    public var preventsSleep: Bool
    public var terminalApp: String?
    public var limit: LimitInfo?
    public var resume: ResumeMetadata
    public var timeline: [TimelineEntry]
    public var intervals: [StateInterval]
    public var executablePath: String?
    public var awakeSeconds: TimeInterval

    public init(
        id: UUID = UUID(),
        provider: ProviderID,
        processID: Int32? = nil,
        parentProcessID: Int32? = nil,
        providerSessionID: String? = nil,
        projectDirectory: String? = nil,
        repositoryName: String? = nil,
        repositoryRoot: String? = nil,
        branch: String? = nil,
        hasRepositoryChanges: Bool = false,
        state: AgentState,
        outcome: SessionOutcome = .ongoing,
        lastEventSummary: String,
        taskSummary: String? = nil,
        startedAt: Date,
        lastActivityAt: Date,
        completedAt: Date? = nil,
        usage: ProviderUsage? = nil,
        preventsSleep: Bool? = nil,
        terminalApp: String? = nil,
        limit: LimitInfo? = nil,
        resume: ResumeMetadata = ResumeMetadata(),
        timeline: [TimelineEntry] = [],
        intervals: [StateInterval] = [],
        executablePath: String? = nil,
        awakeSeconds: TimeInterval = 0
    ) {
        self.id = id
        self.provider = provider
        self.processID = processID
        self.parentProcessID = parentProcessID
        self.providerSessionID = providerSessionID
        self.projectDirectory = projectDirectory
        self.repositoryName = repositoryName
        self.repositoryRoot = repositoryRoot
        self.branch = branch
        self.hasRepositoryChanges = hasRepositoryChanges
        self.state = state
        self.outcome = outcome
        self.lastEventSummary = lastEventSummary
        self.taskSummary = taskSummary
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.completedAt = completedAt
        self.usage = usage
        self.preventsSleep = preventsSleep ?? state.preventsSystemSleep
        self.terminalApp = terminalApp
        self.limit = limit
        self.resume = resume
        self.timeline = timeline
        self.intervals = intervals
        self.executablePath = executablePath
        self.awakeSeconds = awakeSeconds
    }

    public var projectTitle: String {
        if let repositoryName, !repositoryName.isEmpty { return repositoryName }
        if let projectDirectory {
            return URL(fileURLWithPath: projectDirectory).lastPathComponent
        }
        return "Unknown project"
    }

    public var displayPath: String {
        MochaiFormat.abbreviatedPath(projectDirectory ?? repositoryRoot ?? "")
    }

    public func time(in states: Set<AgentState>, now: Date) -> TimeInterval {
        intervals.filter { states.contains($0.state) }.reduce(0) { $0 + $1.duration(until: now) }
    }

    public func workingTime(now: Date) -> TimeInterval {
        time(in: [.working, .runningTool, .runningCommand], now: now)
    }

    public func waitingTime(now: Date) -> TimeInterval {
        time(in: [.waitingForUser, .waitingForPermission, .idle], now: now)
    }

    public func limitedTime(now: Date) -> TimeInterval {
        time(in: [.rateLimited, .waitingForReset], now: now)
    }
}
