import Foundation

public struct ClaudeProvider: AgentProvider {
    public let id: ProviderID = .claude
    public let displayName = "Claude Code"
    public var settingsURL: URL
    public var homeDirectory: String

    public init(settingsURL: URL = AppPaths.claudeSettingsURL, homeDirectory: String = NSHomeDirectory()) {
        self.settingsURL = settingsURL
        self.homeDirectory = homeDirectory
    }

    public func detectInstallation() async -> ProviderInstallation {
        let executable = ExecutableLocator.locate("claude")
        let version = executable.flatMap { ExecutableLocator.version(of: $0) }
        let hook = ConfigMerger.containsMarker((try? Data(contentsOf: settingsURL)) ?? Data(), marker: AppIdentity.hookCommandMarker)
        return ProviderInstallation(
            provider: .claude,
            installed: executable != nil,
            executablePath: executable?.path,
            version: version,
            hookInstalled: hook
        )
    }

    public func discoverSessions() async throws -> [DiscoveredSession] { [] }

    public func currentUsage() async throws -> ProviderUsage {
        if let live = await ClaudeLiveUsage.fetch(home: homeDirectory) {
            return live
        }
        if let structured = ClaudeUsageReader.read(home: homeDirectory) {
            return structured
        }
        return .unavailable(
            at: Date(),
            detail: "Claude's limits appear after the next reply."
        )
    }

    public func resume(session: AgentSession, prompt: String) async throws -> ResumeLaunch {
        guard let directory = session.projectDirectory ?? session.repositoryRoot else { throw ResumeError.missingDirectory }
        guard FileManager.default.fileExists(atPath: directory) else { throw ResumeError.missingDirectory }
        guard let executable = resolveExecutable(stored: session.executablePath) else { throw ResumeError.missingExecutable }
        var arguments: [String]
        let exact: Bool
        if let sessionID = session.providerSessionID ?? session.resume.providerSessionID, !sessionID.isEmpty {
            arguments = ["--resume", sessionID, prompt]
            exact = true
        } else {
            arguments = ["--continue", prompt]
            exact = false
        }
        let summary = try TerminalLauncher.openCommand(
            executable: executable,
            arguments: arguments,
            directory: directory,
            preferredTerminal: session.terminalApp
        )
        if exact {
            return ResumeLaunch(exact: true, summary: summary)
        }
        return ResumeLaunch(exact: false, summary: "Resume uses Claude's latest session in this project. \(summary)")
    }

    public func validateIntegration(socketAlive: Bool, lastEventAt: Date?) async -> IntegrationHealth {
        let installation = await detectInstallation()
        return health(
            installation: installation,
            configURL: settingsURL,
            socketAlive: socketAlive,
            lastEventAt: lastEventAt,
            resumeAvailable: true
        )
    }

    public func installPlan(command: String, statusLineCommand: String? = nil) -> HookInstallPlan {
        HookInstallPlan(events: ProviderHookEvents.claude, command: command, statusLineCommand: statusLineCommand)
    }

    private func resolveExecutable(stored: String?) -> URL? {
        if let stored, ExecutableLocator.isValidExecutable(stored, names: ["claude"]) {
            return URL(fileURLWithPath: stored)
        }
        return ExecutableLocator.locate("claude")
    }
}

enum ClaudeUsageReader {
    static func read(home: String, snapshotURL: URL = AppPaths.claudeUsageSnapshotURL, now: Date = Date()) -> ProviderUsage? {
        let candidates = [
            snapshotURL,
            URL(fileURLWithPath: home).appendingPathComponent(".claude/usage.json"),
            URL(fileURLWithPath: home).appendingPathComponent(".claude/stats-cache.json")
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let usage = decode(object, updatedAt: now) else { continue }
            return usage
        }
        return nil
    }

    static func decode(_ object: Any, updatedAt: Date = Date()) -> ProviderUsage? {
        guard let dict = object as? [String: Any] else { return nil }
        let recordedAt = (dict["updatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? updatedAt
        if let limits = dict["rate_limits"] as? [String: Any] {
            let windows = claudeWindows(limits)
            if !windows.isEmpty {
                return ProviderUsage(
                    windows: windows,
                    updatedAt: recordedAt,
                    confidence: .providerReported,
                    detail: "Updated \(MochaiFormat.clock(recordedAt, now: updatedAt))"
                )
            }
        }
        if let windows = dict["windows"] as? [[String: Any]] {
            let parsed = windows.compactMap { item -> UsageWindow? in
                guard let name = item["name"] as? String else { return nil }
                return usageWindow(name: name, item: item)
            }
            if !parsed.isEmpty {
                return ProviderUsage(windows: parsed, updatedAt: recordedAt, confidence: .providerReported, detail: "Updated \(MochaiFormat.clock(recordedAt, now: updatedAt))")
            }
        }
        return nil
    }

    private static func claudeWindows(_ limits: [String: Any]) -> [UsageWindow] {
        let preferred = ["five_hour", "seven_day"]
        let keys = preferred + limits.keys.filter { !preferred.contains($0) }.sorted()
        var windows: [UsageWindow] = []
        for key in keys {
            guard let item = limits[key] as? [String: Any],
                  let window = usageWindow(name: windowName(key), item: item) else { continue }
            windows.append(window)
        }
        return windows
    }

    private static func usageWindow(name: String, item: [String: Any]) -> UsageWindow? {
        let percentPoints = (item["used_percentage"] as? NSNumber)?.doubleValue ?? (item["used_percent"] as? NSNumber)?.doubleValue
        let utilization = (item["utilization"] as? NSNumber)?.doubleValue
        let used = percentPoints.map { min(1, max(0, $0 / 100)) } ?? utilization.map(ClaudeLiveUsageParser.usedFraction(from:))
        let reset = resetDate(item["resets_at"])
        guard used != nil || reset != nil else { return nil }
        return UsageWindow(
            name: name,
            usedFraction: used,
            remainingFraction: used.map { 1 - $0 },
            resetAt: reset
        )
    }

    private static func resetDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        if let text = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }
        return nil
    }

    private static func windowName(_ key: String) -> String {
        switch key {
        case "five_hour": "5-hour allowance"
        case "seven_day": "Weekly"
        case "seven_day_sonnet": "Sonnet"
        case "seven_day_opus": "Opus"
        default: key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
