import Foundation

public enum EventKind: String, Codable, CaseIterable, Sendable {
    case providerStarted
    case providerStopped
    case sessionStarted
    case sessionEnded
    case promptSubmitted
    case generationStarted
    case generationStopped
    case toolStarted
    case toolFinished
    case commandStarted
    case commandFinished
    case waitingForUser
    case permissionRequested
    case rateLimitReached
    case usageUpdated
    case resumeStarted
    case resumeFinished
    case error
}

public struct NormalizedEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var provider: ProviderID
    public var kind: EventKind
    public var sessionID: String?
    public var cwd: String?
    public var toolCategory: String?
    public var commandName: String?
    public var timestamp: Date
    public var resetAt: Date?
    public var errorCode: String?
    public var processID: Int32?

    public init(
        id: String? = nil,
        provider: ProviderID,
        kind: EventKind,
        sessionID: String? = nil,
        cwd: String? = nil,
        toolCategory: String? = nil,
        commandName: String? = nil,
        timestamp: Date = Date(),
        resetAt: Date? = nil,
        errorCode: String? = nil,
        processID: Int32? = nil
    ) {
        self.provider = provider
        self.kind = kind
        self.sessionID = sessionID
        self.cwd = cwd
        self.toolCategory = toolCategory
        self.commandName = commandName
        self.timestamp = timestamp
        self.resetAt = resetAt
        self.errorCode = errorCode
        self.processID = processID
        self.id = id ?? Self.dedupeKey(
            provider: provider,
            kind: kind,
            sessionID: sessionID,
            timestamp: timestamp,
            toolCategory: toolCategory
        )
    }

    public static func dedupeKey(
        provider: ProviderID,
        kind: EventKind,
        sessionID: String?,
        timestamp: Date,
        toolCategory: String?
    ) -> String {
        let second = Int(timestamp.timeIntervalSince1970.rounded())
        return [
            provider.rawValue,
            kind.rawValue,
            sessionID ?? "-",
            toolCategory ?? "-",
            String(second)
        ].joined(separator: "|")
    }
}
