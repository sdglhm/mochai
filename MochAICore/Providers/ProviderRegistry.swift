import Foundation

public struct MockProvider: AgentProvider {
    public let id: ProviderID = .mock
    public let displayName = "Preview Agent"

    public init() {}

    public func detectInstallation() async -> ProviderInstallation {
        ProviderInstallation(provider: .mock, installed: true, executablePath: nil, version: "debug", hookInstalled: true)
    }

    public func discoverSessions() async throws -> [DiscoveredSession] { [] }

    public func currentUsage() async throws -> ProviderUsage {
        ProviderUsage(
            windows: [
                UsageWindow(name: "5-hour allowance", usedFraction: 0.22, remainingFraction: 0.78, resetAt: Date().addingTimeInterval(3600)),
                UsageWindow(name: "Weekly", usedFraction: 0.56, remainingFraction: 0.44, resetAt: Date().addingTimeInterval(86_400))
            ],
            updatedAt: Date(),
            confidence: .locallyEstimated,
            detail: "Preview data for development."
        )
    }

    public func resume(session: AgentSession, prompt: String) async throws -> ResumeLaunch {
        ResumeLaunch(exact: true, summary: "Preview resume recorded locally.")
    }

    public func validateIntegration(socketAlive: Bool, lastEventAt: Date?) async -> IntegrationHealth {
        IntegrationHealth(provider: .mock, checks: [], summary: "Preview provider.")
    }
}

public final class ProviderRegistry: @unchecked Sendable {
    public let claude: ClaudeProvider
    public let codex: CodexProvider
    public let cursor: CursorProvider
    public let openCodeGo: OpenCodeGoProvider
    public let antigravity: AntigravityProvider
    public let mock: MockProvider

    public init(
        claude: ClaudeProvider = ClaudeProvider(),
        codex: CodexProvider = CodexProvider(),
        cursor: CursorProvider = CursorProvider(),
        openCodeGo: OpenCodeGoProvider = OpenCodeGoProvider(),
        antigravity: AntigravityProvider = AntigravityProvider(),
        mock: MockProvider = MockProvider()
    ) {
        self.claude = claude
        self.codex = codex
        self.cursor = cursor
        self.openCodeGo = openCodeGo
        self.antigravity = antigravity
        self.mock = mock
    }

    public func provider(for id: ProviderID) -> any AgentProvider {
        switch id {
        case .claude: claude
        case .codex: codex
        case .cursor: cursor
        case .openCodeGo: openCodeGo
        case .antigravity: antigravity
        case .mock: mock
        }
    }

    public var userFacing: [any AgentProvider] { [claude, codex, cursor, openCodeGo, antigravity] }
}
