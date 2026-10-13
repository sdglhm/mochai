import Foundation

public enum ResumeMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case notifyOnly
    case ask
    case automatic

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .notifyOnly: "Notify only"
        case .ask: "Ask before resuming"
        case .automatic: "Resume automatically"
        }
    }

    public var shortLabel: String {
        switch self {
        case .notifyOnly: "Notify"
        case .ask: "Ask"
        case .automatic: "Auto resume"
        }
    }
}

public enum KeepAwakeMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case thirtyMinutes
    case oneHour
    case untilTurnedOff
    case never

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .automatic: "Automatic"
        case .thirtyMinutes: "For 30 minutes"
        case .oneHour: "For 1 hour"
        case .untilTurnedOff: "Until turned off"
        case .never: "Never"
        }
    }
}

public enum BatteryKeepAwake: String, Codable, CaseIterable, Identifiable, Sendable {
    case always
    case aboveTwenty
    case neverOnBattery

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .always: "Always while work is active"
        case .aboveTwenty: "Only above 20%"
        case .neverOnBattery: "Never on battery"
        }
    }
}

public enum HistoryRetention: String, Codable, CaseIterable, Identifiable, Sendable {
    case week
    case thirtyDays
    case ninetyDays
    case forever

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .week: "7 days"
        case .thirtyDays: "30 days"
        case .ninetyDays: "90 days"
        case .forever: "Forever"
        }
    }

    public var seconds: TimeInterval? {
        switch self {
        case .week: 7 * 24 * 3600
        case .thirtyDays: 30 * 24 * 3600
        case .ninetyDays: 90 * 24 * 3600
        case .forever: nil
        }
    }
}

public enum MenuBarDisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case iconOnly
    case lowestUsage
    case claudeUsage
    case codexUsage
    case agentCount
    case nextReset
    case keepAwake

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .iconOnly: "Icon only"
        case .lowestUsage: "Lowest remaining usage"
        case .claudeUsage: "Claude usage"
        case .codexUsage: "Codex usage"
        case .agentCount: "Current agent count"
        case .nextReset: "Next reset countdown"
        case .keepAwake: "Keep-awake status"
        }
    }
}

public struct NotificationPreferences: Codable, Equatable, Sendable {
    public var completion: Bool
    public var needsInput: Bool
    public var rateLimits: Bool
    public var resume: Bool
    public var errors: Bool

    public init(
        completion: Bool = true,
        needsInput: Bool = true,
        rateLimits: Bool = true,
        resume: Bool = true,
        errors: Bool = true
    ) {
        self.completion = completion
        self.needsInput = needsInput
        self.rateLimits = rateLimits
        self.resume = resume
        self.errors = errors
    }
}

public struct ProviderOverride: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var resumeMode: ResumeMode?

    public init(enabled: Bool = true, resumeMode: ResumeMode? = nil) {
        self.enabled = enabled
        self.resumeMode = resumeMode
    }
}

public struct ProjectPolicy: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var path: String
    public var autoResume: ResumeMode?
    public var preventSleep: Bool
    public var notifications: NotificationPreferences?
    public var sensitive: Bool
    public var historyRetention: HistoryRetention?
    public var providerResume: [String: ResumeMode]

    public init(
        id: String? = nil,
        name: String,
        path: String,
        autoResume: ResumeMode? = nil,
        preventSleep: Bool = true,
        notifications: NotificationPreferences? = nil,
        sensitive: Bool = false,
        historyRetention: HistoryRetention? = nil,
        providerResume: [String: ResumeMode] = [:]
    ) {
        self.path = path
        self.id = id ?? path
        self.name = name
        self.autoResume = autoResume
        self.preventSleep = preventSleep
        self.notifications = notifications
        self.sensitive = sensitive
        self.historyRetention = historyRetention
        self.providerResume = providerResume
    }
}
