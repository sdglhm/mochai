import Foundation

public enum AgentState: String, Codable, CaseIterable, Sendable {
    case notRunning
    case starting
    case working
    case runningTool
    case runningCommand
    case waitingForPermission
    case waitingForUser
    case idle
    case rateLimited
    case waitingForReset
    case resuming
    case completed
    case failed
    case unknown

    /// Sleep is held only while useful work is actually happening.
    /// Starting and resuming do not count until generation, a tool, or a command begins.
    public var preventsSystemSleep: Bool {
        switch self {
        case .working, .runningTool, .runningCommand:
            true
        case .notRunning, .starting, .waitingForPermission, .waitingForUser, .idle,
             .rateLimited, .waitingForReset, .resuming, .completed, .failed, .unknown:
            false
        }
    }

    public var isLive: Bool {
        switch self {
        case .completed, .failed, .notRunning:
            false
        default:
            true
        }
    }

    public var isLimited: Bool {
        self == .rateLimited || self == .waitingForReset
    }

    public var needsAttention: Bool {
        self == .failed || self == .waitingForPermission
    }

    public var label: String {
        switch self {
        case .notRunning: "Not running"
        case .starting: "Starting"
        case .working: "Working"
        case .runningTool: "Using a tool"
        case .runningCommand: "Running a command"
        case .waitingForPermission: "Needs permission"
        case .waitingForUser: "Needs you"
        case .idle: "Idle"
        case .rateLimited: "Usage limit"
        case .waitingForReset: "Waiting for reset"
        case .resuming: "Resuming"
        case .completed: "Completed"
        case .failed: "Stopped"
        case .unknown: "Checking"
        }
    }

    public var symbolName: String {
        switch self {
        case .notRunning: "circle"
        case .starting, .resuming: "arrow.triangle.2.circlepath"
        case .working: "circle.fill"
        case .runningTool: "wrench.and.screwdriver"
        case .runningCommand: "terminal"
        case .waitingForPermission: "hand.raised"
        case .waitingForUser: "person"
        case .idle: "moon"
        case .rateLimited, .waitingForReset: "pause.circle"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .unknown: "questionmark.circle"
        }
    }
}

public enum SessionOutcome: String, Codable, Sendable {
    case ongoing
    case completed
    case interrupted
    case failed
    case limited

    public var label: String {
        switch self {
        case .ongoing: "In progress"
        case .completed: "Completed"
        case .interrupted: "Interrupted"
        case .failed: "Stopped"
        case .limited: "On a limit"
        }
    }
}

public enum ResumeReadiness: String, Codable, Sendable {
    case none
    case scheduled
    case ready
    case resuming
    case resumed
    case cancelled
    case blocked
}
