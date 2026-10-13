import Foundation

public struct DiscoveredSession: Equatable, Sendable {
    public var provider: ProviderID
    public var providerSessionID: String?
    public var directory: String?
    public var title: String?

    public init(provider: ProviderID, providerSessionID: String? = nil, directory: String? = nil, title: String? = nil) {
        self.provider = provider
        self.providerSessionID = providerSessionID
        self.directory = directory
        self.title = title
    }
}

public struct ResumeLaunch: Equatable, Sendable {
    public var exact: Bool
    public var summary: String

    public init(exact: Bool, summary: String) {
        self.exact = exact
        self.summary = summary
    }
}

public protocol AgentProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    func detectInstallation() async -> ProviderInstallation
    func discoverSessions() async throws -> [DiscoveredSession]
    func currentUsage() async throws -> ProviderUsage
    func resume(session: AgentSession, prompt: String) async throws -> ResumeLaunch
    func validateIntegration(socketAlive: Bool, lastEventAt: Date?) async -> IntegrationHealth
}

public extension AgentProvider {
    func health(
        installation: ProviderInstallation,
        configURL: URL,
        socketAlive: Bool,
        lastEventAt: Date?,
        resumeAvailable: Bool
    ) -> IntegrationHealth {
        let configData = (try? Data(contentsOf: configURL)) ?? Data()
        let hookInstalled = ConfigMerger.containsMarker(configData, marker: AppIdentity.hookCommandMarker)
        let helper = FileManager.default.isExecutableFile(atPath: AppPaths.hookBinaryURL.path)
        let checks = [
            DiagnosticCheck(id: "cli", title: "Installed", passed: installation.installed, detail: installation.version ?? (installation.installed ? "Ready" : "Not installed")),
            DiagnosticCheck(id: "hook", title: "Watching", passed: hookInstalled && helper, detail: hookInstalled ? "MochAI is connected" : "Not connected"),
            DiagnosticCheck(id: "socket", title: "Ready", passed: socketAlive, detail: socketAlive ? "Listening for activity" : "Starting up"),
            DiagnosticCheck(
                id: "events",
                title: "Recent activity",
                passed: lastEventAt != nil,
                detail: lastEventAt.map { "Last seen \(MochaiFormat.clock($0))" } ?? "Nothing yet"
            ),
            DiagnosticCheck(id: "resume", title: "Continue", passed: resumeAvailable, detail: resumeAvailable ? "Can continue a session" : "Will ask before continuing")
        ]
        let healthy = installation.installed && hookInstalled && helper && socketAlive
        return IntegrationHealth(
            provider: id,
            checks: checks,
            summary: healthy ? "Ready." : "MochAI can still notice when it is running."
        )
    }
}
