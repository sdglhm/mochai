import Foundation

public struct CodexProvider: AgentProvider {
    public let id: ProviderID = .codex
    public let displayName = "Codex"
    public var hooksURL: URL
    public var sessionsDirectory: URL

    public init(
        hooksURL: URL = AppPaths.codexHooksURL,
        sessionsDirectory: URL = AppPaths.codexSessionsDirectory
    ) {
        self.hooksURL = hooksURL
        self.sessionsDirectory = sessionsDirectory
    }

    public func detectInstallation() async -> ProviderInstallation {
        let executable = ExecutableLocator.locate("codex")
        let version = executable.flatMap { ExecutableLocator.version(of: $0) }
        let hook = ConfigMerger.containsMarker((try? Data(contentsOf: hooksURL)) ?? Data(), marker: AppIdentity.hookCommandMarker)
        return ProviderInstallation(
            provider: .codex,
            installed: executable != nil,
            executablePath: executable?.path,
            version: version,
            hookInstalled: hook
        )
    }

    public func discoverSessions() async throws -> [DiscoveredSession] {
        CodexMetadata.sessionTitles().map { id, title in
            DiscoveredSession(provider: .codex, providerSessionID: id, title: title)
        }
    }

    public func currentUsage() async throws -> ProviderUsage {
        let home = sessionsDirectory.deletingLastPathComponent()
        if let live = await CodexLiveUsage.fetch(home: home) {
            return live
        }
        return CodexMetadata.currentUsage(sessionsDirectory: sessionsDirectory)
    }

    public func resume(session: AgentSession, prompt: String) async throws -> ResumeLaunch {
        guard let directory = session.projectDirectory ?? session.repositoryRoot else { throw ResumeError.missingDirectory }
        guard FileManager.default.fileExists(atPath: directory) else { throw ResumeError.missingDirectory }
        guard let executable = resolveExecutable(stored: session.executablePath) else { throw ResumeError.missingExecutable }
        if let sessionID = session.providerSessionID ?? session.resume.providerSessionID, !sessionID.isEmpty {
            let summary = try TerminalLauncher.openCommand(
                executable: executable,
                arguments: ["resume", sessionID, prompt],
                directory: directory,
                preferredTerminal: session.terminalApp
            )
            return ResumeLaunch(exact: true, summary: summary)
        }
        let summary = try TerminalLauncher.openCommand(
            executable: executable,
            arguments: [],
            directory: directory,
            preferredTerminal: session.terminalApp
        )
        return ResumeLaunch(
            exact: false,
            summary: "Resume requires confirmation. Codex opened in the project without an exact session id. \(summary)"
        )
    }

    public func validateIntegration(socketAlive: Bool, lastEventAt: Date?) async -> IntegrationHealth {
        let installation = await detectInstallation()
        return health(
            installation: installation,
            configURL: hooksURL,
            socketAlive: socketAlive,
            lastEventAt: lastEventAt,
            resumeAvailable: true
        )
    }

    public func installPlan(command: String) -> HookInstallPlan {
        HookInstallPlan(events: ProviderHookEvents.codex, command: command)
    }

    private func resolveExecutable(stored: String?) -> URL? {
        if let stored, ExecutableLocator.isValidExecutable(stored, names: ["codex"]) {
            return URL(fileURLWithPath: stored)
        }
        return ExecutableLocator.locate("codex")
    }
}
