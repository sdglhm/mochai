import Foundation

public struct OpenCodeGoProvider: AgentProvider {
    public let id: ProviderID = .openCodeGo
    public let displayName = "OpenCode Go"
    public var homeDirectory: String

    public init(homeDirectory: String = NSHomeDirectory()) {
        self.homeDirectory = homeDirectory
    }

    public func detectInstallation() async -> ProviderInstallation {
        let executable = ExecutableLocator.locate("opencode")
        let version = executable.flatMap { ExecutableLocator.version(of: $0) }
        let connected = OpenCodeGoLogin.apiKey(home: URL(fileURLWithPath: homeDirectory)) != nil
        return ProviderInstallation(
            provider: .openCodeGo,
            installed: executable != nil || connected,
            executablePath: executable?.path,
            version: version,
            hookInstalled: false
        )
    }

    public func discoverSessions() async throws -> [DiscoveredSession] { [] }

    public func currentUsage() async throws -> ProviderUsage {
        let now = Date()
        guard let key = OpenCodeGoLogin.apiKey(home: URL(fileURLWithPath: homeDirectory)) else {
            return .unavailable(at: now, detail: "Connect OpenCode Go to see its allowance.")
        }
        do {
            let data = try await OpenCodeGoUsageClient.fetch(apiKey: key)
            if let usage = OpenCodeGoUsageParser.parse(data, now: now) {
                return usage
            }
            return .unavailable(at: now, detail: "OpenCode Go hasn't reported an allowance yet.")
        } catch {
            MochaiLog.usage.error("OpenCode Go allowance request failed")
            return .unavailable(at: now, detail: "OpenCode Go's allowance isn't available right now.")
        }
    }

    public func resume(session: AgentSession, prompt: String) async throws -> ResumeLaunch {
        throw ResumeError.blocked("OpenCode Go sessions continue in OpenCode.")
    }

    public func validateIntegration(socketAlive: Bool, lastEventAt: Date?) async -> IntegrationHealth {
        let installation = await detectInstallation()
        let checks = [
            DiagnosticCheck(id: "cli", title: "Installed", passed: installation.installed, detail: installation.installed ? "Ready" : "Not installed"),
            DiagnosticCheck(id: "usage", title: "Allowance", passed: installation.installed, detail: installation.installed ? "Shown when OpenCode Go is connected" : "Not available")
        ]
        return IntegrationHealth(
            provider: .openCodeGo,
            checks: checks,
            summary: installation.installed ? "Ready." : "OpenCode Go is not installed."
        )
    }
}

enum OpenCodeGoLogin {
    /// The key already saved by OpenCode, or the environment OpenCode itself reads.
    /// It stays in memory for the usage request and is not stored or logged.
    static func apiKey(home: URL) -> String? {
        for file in authFiles(home: home) {
            if let data = try? Data(contentsOf: file), let key = apiKey(in: data) {
                return key
            }
        }
        let environment = ProcessInfo.processInfo.environment
        if let key = accepted(environment["OPENCODE_GO_API_KEY"]) { return key }
        if let key = accepted(environment["OPENCODE_API_KEY"]) { return key }
        return nil
    }

    static func apiKey(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return credential(in: object["opencode-go"])
    }

    private static func authFiles(home: URL) -> [URL] {
        var files: [URL] = []
        if let dataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !dataHome.isEmpty {
            files.append(URL(fileURLWithPath: dataHome).appendingPathComponent("opencode/auth.json"))
        }
        files.append(home.appendingPathComponent(".local/share/opencode/auth.json"))
        return files
    }

    private static func credential(in value: Any?) -> String? {
        if let text = value as? String { return accepted(text) }
        guard let entry = value as? [String: Any] else { return nil }
        if let type = entry["type"] as? String, type != "api" { return nil }
        return accepted(entry["key"] as? String) ?? accepted(entry["apiKey"] as? String)
    }

    private static func accepted(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 10, !trimmed.contains(where: \.isWhitespace), !trimmed.contains("${") else { return nil }
        return trimmed
    }
}

enum OpenCodeGoUsageClient {
    static func fetch(apiKey: String) async throws -> Data {
        guard let url = URL(string: "https://opencode.ai/zen/go/v1/usage") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MochAI", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              response.url?.host == "opencode.ai",
              data.count <= 1_048_576 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

public enum OpenCodeGoUsageParser {
    /// `percent` on this endpoint is used, from 0 to 100. A value of 1 is 1% used.
    public static func parse(_ data: Data, now: Date = Date()) -> ProviderUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = object["usage"] as? [String: Any] else { return nil }
        var windows: [UsageWindow] = []
        if let rolling = window(usage["rolling"], name: "5-hour allowance", minutes: 300) {
            windows.append(rolling)
        }
        if let weekly = window(usage["weekly"], name: "Weekly", minutes: 10_080) {
            windows.append(weekly)
        }
        if let monthly = window(usage["monthly"], name: "Monthly", minutes: nil) {
            windows.append(monthly)
        }
        guard !windows.isEmpty else { return nil }
        return ProviderUsage(
            windows: windows,
            updatedAt: now,
            confidence: .providerReported,
            detail: "OpenCode Go allowance."
        )
    }

    private static func window(_ value: Any?, name: String, minutes: Int?) -> UsageWindow? {
        guard let dict = value as? [String: Any], let points = number(dict["percent"]) else { return nil }
        let used = min(1, max(0, points / 100))
        return UsageWindow(
            name: name,
            usedFraction: used,
            remainingFraction: 1 - used,
            resetAt: resetDate(dict["resetsAt"]),
            windowMinutes: minutes
        )
    }

    private static func resetDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber else { return nil }
        let number = value.doubleValue
        return number.isFinite ? number : nil
    }
}
