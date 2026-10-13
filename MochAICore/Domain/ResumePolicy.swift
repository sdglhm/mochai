import Foundation

public struct ResumeDecision: Equatable, Sendable {
    public var mode: ResumeMode
    public var automaticAllowed: Bool
    public var reason: String?

    public init(mode: ResumeMode, automaticAllowed: Bool, reason: String? = nil) {
        self.mode = mode
        self.automaticAllowed = automaticAllowed
        self.reason = reason
    }
}

public struct ResumeContext: Equatable, Sendable {
    public var globalMode: ResumeMode
    public var providerMode: ResumeMode?
    public var projectMode: ResumeMode?
    public var providerEnabled: Bool
    public var sensitiveProject: Bool
    public var repositoryExists: Bool
    public var identityMatches: Bool
    public var manuallyCancelled: Bool
    public var duplicateResume: Bool
    public var providerLimited: Bool
    public var integrationHealthy: Bool
    public var metadataValid: Bool
    public var executableValid: Bool
    public var notifyOnly: Bool { false }

    public init(
        globalMode: ResumeMode,
        providerMode: ResumeMode? = nil,
        projectMode: ResumeMode? = nil,
        providerEnabled: Bool = true,
        sensitiveProject: Bool = false,
        repositoryExists: Bool = true,
        identityMatches: Bool = true,
        manuallyCancelled: Bool = false,
        duplicateResume: Bool = false,
        providerLimited: Bool = false,
        integrationHealthy: Bool = true,
        metadataValid: Bool = true,
        executableValid: Bool = true
    ) {
        self.globalMode = globalMode
        self.providerMode = providerMode
        self.projectMode = projectMode
        self.providerEnabled = providerEnabled
        self.sensitiveProject = sensitiveProject
        self.repositoryExists = repositoryExists
        self.identityMatches = identityMatches
        self.manuallyCancelled = manuallyCancelled
        self.duplicateResume = duplicateResume
        self.providerLimited = providerLimited
        self.integrationHealthy = integrationHealthy
        self.metadataValid = metadataValid
        self.executableValid = executableValid
    }
}

public enum ResumePolicy {
    public static func resolvedMode(_ context: ResumeContext) -> ResumeMode {
        if let project = context.projectMode { return project }
        if context.sensitiveProject { return .ask }
        if let provider = context.providerMode { return provider }
        return context.globalMode
    }

    public static func evaluate(_ context: ResumeContext) -> ResumeDecision {
        let mode = resolvedMode(context)
        if let reason = blockReason(context) {
            return ResumeDecision(mode: mode, automaticAllowed: false, reason: reason)
        }
        switch mode {
        case .automatic:
            return ResumeDecision(mode: mode, automaticAllowed: true, reason: nil)
        case .ask:
            return ResumeDecision(mode: mode, automaticAllowed: false, reason: "Waiting for you to continue.")
        case .notifyOnly:
            return ResumeDecision(mode: mode, automaticAllowed: false, reason: "Notifications only for this project.")
        }
    }

    public static func blockReason(_ context: ResumeContext) -> String? {
        if !context.providerEnabled { return "This provider is turned off." }
        if context.manuallyCancelled { return "You cancelled this session." }
        if !context.repositoryExists { return "The project folder is no longer there." }
        if !context.identityMatches { return "The repository identity changed." }
        if context.duplicateResume { return "This session is already resuming." }
        if context.providerLimited { return "The provider still looks limited." }
        if !context.integrationHealthy { return "The integration needs a repair." }
        if !context.metadataValid { return "The saved session is incomplete." }
        if !context.executableValid { return "The agent executable could not be verified." }
        return nil
    }
}
