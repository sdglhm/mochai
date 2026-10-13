import Foundation

public struct AntigravityProvider: AgentProvider {
    public let id: ProviderID = .antigravity
    public let displayName = "Antigravity"

    public init() {}

    public func detectInstallation() async -> ProviderInstallation {
        let executable = ExecutableLocator.locate("agy")
        let version = executable.flatMap { ExecutableLocator.version(of: $0) }
        let app = AntigravityPaths.application
        let installed = executable != nil || FileManager.default.fileExists(atPath: app.path)
        return ProviderInstallation(
            provider: .antigravity,
            installed: installed,
            executablePath: executable?.path ?? (installed ? app.path : nil),
            version: version,
            hookInstalled: false
        )
    }

    public func discoverSessions() async throws -> [DiscoveredSession] { [] }

    public func currentUsage() async throws -> ProviderUsage {
        let now = Date()
        guard await detectInstallation().installed else {
            return .unavailable(at: now, detail: "Antigravity is not installed.")
        }
        if let live = await AntigravityLiveUsage.fetch(now: now) {
            return live
        }
        return .unavailable(at: now, detail: "Open Antigravity to see its allowance.")
    }

    public func resume(session: AgentSession, prompt: String) async throws -> ResumeLaunch {
        throw ResumeError.blocked("Antigravity sessions continue in the Antigravity app.")
    }

    public func validateIntegration(socketAlive: Bool, lastEventAt: Date?) async -> IntegrationHealth {
        let installation = await detectInstallation()
        let checks = [
            DiagnosticCheck(id: "app", title: "Installed", passed: installation.installed, detail: installation.installed ? "Ready" : "Not installed"),
            DiagnosticCheck(id: "usage", title: "Allowance", passed: installation.installed, detail: installation.installed ? "Shown while Antigravity is open" : "Not available")
        ]
        return IntegrationHealth(
            provider: .antigravity,
            checks: checks,
            summary: installation.installed ? "Ready." : "Antigravity is not installed."
        )
    }
}

enum AntigravityPaths {
    static var application: URL {
        let home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/Antigravity.app")
        if FileManager.default.fileExists(atPath: home.path) { return home }
        let ide = URL(fileURLWithPath: "/Applications/Antigravity IDE.app")
        if FileManager.default.fileExists(atPath: ide.path) { return ide }
        return URL(fileURLWithPath: "/Applications/Antigravity.app")
    }
}

enum AntigravityLiveUsage {
    /// Asks a local Antigravity or `agy` process that is already running.
    /// Nothing is launched, and the local token is not stored or logged.
    static func fetch(now: Date = Date()) async -> ProviderUsage? {
        for server in AntigravityLocalServers.discover() {
            if let usage = await server.usage(now: now) { return usage }
        }
        return nil
    }
}

struct AntigravityLocalServer: Sendable {
    var httpsPorts: [Int]
    var httpPort: Int?
    var csrfToken: String?

    func usage(now: Date) async -> ProviderUsage? {
        for port in httpsPorts {
            if let usage = await post(url: "https://127.0.0.1:\(port)", secure: true, now: now) { return usage }
        }
        if let httpPort, let usage = await post(url: "http://127.0.0.1:\(httpPort)", secure: false, now: now) {
            return usage
        }
        return nil
    }

    private func post(url base: String, secure: Bool, now: Date) async -> ProviderUsage? {
        let paths = [
            "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary",
            "/exa.language_server_pb.LanguageServerService/GetUserStatus"
        ]
        for path in paths {
            guard let url = URL(string: base + path), url.host == "127.0.0.1" else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 4
            request.httpBody = Data(#"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown"}}"#.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            if let csrfToken, !csrfToken.isEmpty {
                request.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
            }
            let session = secure ? AntigravityLoopback.session : URLSession.shared
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  response.url?.host == "127.0.0.1",
                  data.count <= 1_048_576,
                  let usage = AntigravityUsageParser.parse(data, now: now) else { continue }
            return usage
        }
        return nil
    }
}

enum AntigravityLocalServers {
    static func discover() -> [AntigravityLocalServer] {
        guard let listing = CommandRunner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-ax", "-o", "pid=,command="],
            timeout: 3
        ) else { return [] }
        var servers: [AntigravityLocalServer] = []
        for line in listing.split(whereSeparator: \.isNewline) {
            guard servers.count < 4, let server = server(from: String(line)) else { continue }
            servers.append(server)
        }
        return servers
    }

    static func server(from line: String) -> AntigravityLocalServer? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(where: \.isWhitespace) else { return nil }
        guard let pid = Int32(trimmed[..<space]) else { return nil }
        let command = String(trimmed[space...]).trimmingCharacters(in: .whitespaces)
        guard isAntigravity(command) else { return nil }
        let ports = listeningPorts(pid: pid)
        let httpPort = flag("extension_server_port", in: command).flatMap(Int.init)
        let httpsPorts = ports.filter { $0 != httpPort }
        guard !httpsPorts.isEmpty || httpPort != nil else { return nil }
        return AntigravityLocalServer(
            httpsPorts: Array(httpsPorts.prefix(4)),
            httpPort: httpPort,
            csrfToken: flag("extension_server_csrf_token", in: command) ?? flag("csrf_token", in: command)
        )
    }

    private static func isAntigravity(_ command: String) -> Bool {
        let lower = command.lowercased()
        if lower.contains("antigravity") { return true }
        return command.split(whereSeparator: \.isWhitespace).contains { token in
            token == "agy" || token.hasSuffix("/agy")
        }
    }

    private static func flag(_ name: String, in command: String) -> String? {
        let parts = command.split(whereSeparator: \.isWhitespace).map(String.init)
        for (index, part) in parts.enumerated() {
            if part == "--\(name)", index + 1 < parts.count { return parts[index + 1] }
            let prefix = "--\(name)="
            if part.hasPrefix(prefix) { return String(part.dropFirst(prefix.count)) }
        }
        return nil
    }

    private static func listeningPorts(pid: Int32) -> [Int] {
        guard let output = CommandRunner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)],
            timeout: 3
        ) else { return [] }
        var ports: [Int] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: #"127\.0\.0\.1:(\d+)"#, options: .regularExpression)
                ?? line.range(of: #"localhost:(\d+)"#, options: .regularExpression)
                ?? line.range(of: #"\[::1\]:(\d+)"#, options: .regularExpression) else { continue }
            let match = line[range]
            guard let digits = match.split(separator: ":").last, let port = Int(digits), !ports.contains(port) else { continue }
            ports.append(port)
        }
        return ports
    }
}

private final class AntigravityLoopback: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        return URLSession(configuration: configuration, delegate: AntigravityLoopback(), delegateQueue: nil)
    }()

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let host = challenge.protectionSpace.host
        guard host == "127.0.0.1" || host == "localhost" || host == "::1",
              let trust = challenge.protectionSpace.serverTrust else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

public enum AntigravityUsageParser {
    public static func parse(_ data: Data, now: Date = Date()) -> ProviderUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let windows = summaryWindows(object)
        let resolved = windows.isEmpty ? legacyWindows(object) : windows
        guard !resolved.isEmpty else { return nil }
        return ProviderUsage(
            windows: resolved,
            updatedAt: now,
            confidence: .providerReported,
            detail: "Antigravity allowance."
        )
    }

    private static func summaryWindows(_ object: [String: Any]) -> [UsageWindow] {
        let groups = groups(in: object)
        var best: [String: (remaining: Double, minutes: Int, reset: Date?)] = [:]
        var order: [String] = []
        for group in groups {
            let family = familyName(group["displayName"] as? String)
            let buckets = group["buckets"] as? [[String: Any]] ?? []
            for bucket in buckets {
                guard let remaining = remainingFraction(bucket) else { continue }
                let identity = bucketIdentity(bucket)
                guard let cadence = cadence(identity) else { continue }
                let name = "\(family) \(cadence.label)"
                let reset = resetDate(bucket["resetTime"])
                if let current = best[name], current.remaining <= remaining { continue }
                if best[name] == nil { order.append(name) }
                best[name] = (remaining, cadence.minutes, reset)
            }
        }
        return order.compactMap { name in
            guard let item = best[name] else { return nil }
            return window(name: name, remaining: item.remaining, minutes: item.minutes, reset: item.reset)
        }
    }

    private static func legacyWindows(_ object: [String: Any]) -> [UsageWindow] {
        let configs = clientModels(in: object)
        var best: [String: (remaining: Double, reset: Date?)] = [:]
        var order: [String] = []
        for config in configs {
            let quota = config["quotaInfo"] as? [String: Any] ?? config
            guard let remaining = number(quota["remainingFraction"]) else { continue }
            let label = string(config["label"]) ?? string(config["model"]) ?? string(config["displayName"]) ?? "Antigravity"
            let name = familyName(label)
            let reset = resetDate(quota["resetTime"])
            let fraction = fraction(remaining)
            if let current = best[name], current.remaining <= fraction { continue }
            if best[name] == nil { order.append(name) }
            best[name] = (fraction, reset ?? best[name]?.reset)
        }
        return order.compactMap { name in
            guard let item = best[name] else { return nil }
            return window(name: name, remaining: item.remaining, minutes: nil, reset: item.reset)
        }
    }

    private static func groups(in object: [String: Any]) -> [[String: Any]] {
        if let groups = object["groups"] as? [[String: Any]] { return groups }
        if let response = object["response"] as? [String: Any], let groups = response["groups"] as? [[String: Any]] {
            return groups
        }
        return []
    }

    private static func clientModels(in object: [String: Any]) -> [[String: Any]] {
        let status = object["userStatus"] as? [String: Any] ?? object
        let cascade = status["cascadeModelConfigData"] as? [String: Any]
        return cascade?["clientModelConfigs"] as? [[String: Any]] ?? []
    }

    private static func window(name: String, remaining: Double, minutes: Int?, reset: Date?) -> UsageWindow {
        let left = fraction(remaining)
        return UsageWindow(
            name: name,
            usedFraction: 1 - left,
            remainingFraction: left,
            resetAt: reset,
            windowMinutes: minutes
        )
    }

    private static func remainingFraction(_ bucket: [String: Any]) -> Double? {
        if let value = number(bucket["remainingFraction"]) { return value }
        if let remaining = bucket["remaining"] as? [String: Any] {
            return number(remaining["remainingFraction"])
        }
        return nil
    }

    private static func bucketIdentity(_ bucket: [String: Any]) -> String {
        [string(bucket["bucketId"]), string(bucket["displayName"])].compactMap { $0 }.joined(separator: " ")
    }

    private static func cadence(_ text: String) -> (label: String, minutes: Int)? {
        let lower = text.lowercased()
        if lower.contains("week") { return ("weekly", 10_080) }
        if lower.contains("session") || lower.contains("hour") || lower.contains("5h") || lower.contains("five") {
            return ("5-hour", 300)
        }
        return nil
    }

    private static func familyName(_ value: String?) -> String {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lower = text.lowercased()
        if lower.contains("claude") || lower.contains("gpt") { return "Claude and GPT" }
        if lower.contains("gemini") { return "Gemini" }
        return text.isEmpty ? "Antigravity" : text
    }

    private static func fraction(_ value: Double) -> Double {
        let raw = value > 1 ? value / 100 : value
        return min(1, max(0, raw))
    }

    private static func resetDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, number.doubleValue > 1_000_000_000 {
            let seconds = number.doubleValue > 10_000_000_000 ? number.doubleValue / 1000 : number.doubleValue
            return Date(timeIntervalSince1970: seconds)
        }
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

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
