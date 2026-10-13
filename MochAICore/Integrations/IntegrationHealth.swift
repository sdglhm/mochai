import Foundation

public struct DiagnosticCheck: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var passed: Bool
    public var detail: String

    public init(id: String, title: String, passed: Bool, detail: String) {
        self.id = id
        self.title = title
        self.passed = passed
        self.detail = detail
    }
}

public struct IntegrationHealth: Equatable, Sendable {
    public var provider: ProviderID
    public var checks: [DiagnosticCheck]
    public var summary: String

    public init(provider: ProviderID, checks: [DiagnosticCheck], summary: String) {
        self.provider = provider
        self.checks = checks
        self.summary = summary
    }

    public var isHealthy: Bool {
        checks.allSatisfy(\.passed)
    }
}

public struct ProviderInstallation: Equatable, Sendable {
    public var provider: ProviderID
    public var installed: Bool
    public var executablePath: String?
    public var version: String?
    public var hookInstalled: Bool
    public var lastEventAt: Date?

    public init(
        provider: ProviderID,
        installed: Bool,
        executablePath: String? = nil,
        version: String? = nil,
        hookInstalled: Bool = false,
        lastEventAt: Date? = nil
    ) {
        self.provider = provider
        self.installed = installed
        self.executablePath = executablePath
        self.version = version
        self.hookInstalled = hookInstalled
        self.lastEventAt = lastEventAt
    }
}
