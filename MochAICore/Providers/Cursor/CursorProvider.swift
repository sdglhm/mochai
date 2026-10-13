import Foundation

public struct CursorProvider: AgentProvider {
    public let id: ProviderID = .cursor
    public let displayName = "Cursor"
    public var databaseURL: URL

    public init(databaseURL: URL = CursorPaths.stateDatabase) {
        self.databaseURL = databaseURL
    }

    public func detectInstallation() async -> ProviderInstallation {
        let app = CursorPaths.application
        let installed = FileManager.default.fileExists(atPath: app.path) || FileManager.default.fileExists(atPath: databaseURL.path)
        let executable = ExecutableLocator.locate("cursor")
        let version = executable.flatMap { ExecutableLocator.version(of: $0) }
        return ProviderInstallation(
            provider: .cursor,
            installed: installed,
            executablePath: executable?.path ?? (installed ? app.path : nil),
            version: version,
            hookInstalled: false
        )
    }

    public func discoverSessions() async throws -> [DiscoveredSession] { [] }

    public func currentUsage() async throws -> ProviderUsage {
        let now = Date()
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return .unavailable(at: now, detail: "Cursor is not installed.")
        }
        guard let token = CursorLogin.readAccessToken(databaseURL: databaseURL) else {
            return .unavailable(at: now, detail: "Sign in to Cursor to see this month's allowance.")
        }
        do {
            let data = try await CursorUsageClient.fetch(token: token)
            if let usage = CursorUsageParser.parse(data, now: now) {
                return usage
            }
            return .unavailable(at: now, detail: "Cursor hasn't reported an allowance yet.")
        } catch {
            MochaiLog.usage.error("Cursor allowance request failed")
            return .unavailable(at: now, detail: "Cursor's allowance isn't available right now.")
        }
    }

    public func resume(session: AgentSession, prompt: String) async throws -> ResumeLaunch {
        throw ResumeError.blocked("Cursor sessions continue in the Cursor app.")
    }

    public func validateIntegration(socketAlive: Bool, lastEventAt: Date?) async -> IntegrationHealth {
        let installation = await detectInstallation()
        let checks = [
            DiagnosticCheck(id: "app", title: "Installed", passed: installation.installed, detail: installation.installed ? "Ready" : "Not installed"),
            DiagnosticCheck(id: "usage", title: "Allowance", passed: installation.installed, detail: installation.installed ? "Shown when you are signed in" : "Not available")
        ]
        return IntegrationHealth(
            provider: .cursor,
            checks: checks,
            summary: installation.installed ? "Ready." : "Cursor is not installed."
        )
    }
}

public enum CursorPaths {
    public static var application: URL {
        URL(fileURLWithPath: "/Applications/Cursor.app")
    }

    public static var stateDatabase: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }
}

enum CursorLogin {
    /// Reads Cursor's existing sign-in so MochAI can ask Cursor for allowance figures.
    /// The value stays in memory for that request and is not stored or logged.
    static func readAccessToken(databaseURL: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        let encoded = databaseURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? databaseURL.path
        let uri = "file:\(encoded)?mode=ro"
        process.arguments = [uri, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let token = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, token.count > 20, !token.contains(where: \.isWhitespace) else { return nil }
        return token
    }
}

enum CursorUsageClient {
    static func fetch(token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 1_048_576 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

public enum CursorUsageParser {
    public static func parse(_ data: Data, now: Date = Date()) -> ProviderUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let plan = planObject(in: object)
        let reset = billingDate(object["billingCycleEnd"])
        var windows: [UsageWindow] = []
        if let plan {
            if let used = percent(plan["autoPercentUsed"]) {
                windows.append(window("Cursor models", used: used, reset: reset))
            }
            if let used = percent(plan["apiPercentUsed"]) {
                windows.append(window("Other models", used: used, reset: reset))
            }
            if windows.isEmpty, let used = percent(plan["totalPercentUsed"]) {
                windows.append(window("Included", used: used, reset: reset))
            }
        }
        if windows.isEmpty, let used = centsFraction(overall(in: object)) {
            windows.append(fractionWindow("Included", used: used, reset: reset))
        }
        if let used = centsFraction(onDemand(in: object)) {
            windows.append(fractionWindow("On-demand", used: used, reset: reset))
        }
        guard !windows.isEmpty else { return nil }
        return ProviderUsage(
            windows: windows,
            updatedAt: now,
            confidence: .providerReported,
            detail: "This month's allowance.",
            tokenCost: reportedCost(in: object)
        )
    }

    private static func planObject(in object: [String: Any]) -> [String: Any]? {
        if let plan = object["planUsage"] as? [String: Any] { return plan }
        if let individual = object["individualUsage"] as? [String: Any],
           let plan = individual["plan"] as? [String: Any] {
            return plan
        }
        return nil
    }

    private static func window(_ name: String, used: Double, reset: Date?) -> UsageWindow {
        UsageWindow(name: name, usedFraction: used, remainingFraction: 1 - used, resetAt: reset)
    }

    private static func fractionWindow(_ name: String, used: Double, reset: Date?) -> UsageWindow {
        let fraction = min(1, max(0, used))
        return UsageWindow(name: name, usedFraction: fraction, remainingFraction: 1 - fraction, resetAt: reset)
    }

    /// On-demand spend is a dollar cap, shown only when Cursor reports both the spend and the cap.
    private static func onDemand(in object: [String: Any]) -> [String: Any]? {
        let individual = object["individualUsage"] as? [String: Any]
        return individual?["onDemand"] as? [String: Any] ?? object["onDemand"] as? [String: Any]
    }

    /// Team accounts can report a personal cap instead of the two model pools.
    private static func overall(in object: [String: Any]) -> [String: Any]? {
        let individual = object["individualUsage"] as? [String: Any]
        return individual?["overall"] as? [String: Any]
    }

    /// Included spend plus on-demand spend, in the dollars Cursor reports for this billing cycle.
    private static func reportedCost(in object: [String: Any]) -> TokenCost? {
        let plan = planObject(in: object)
        let included = cents(plan?["used"]) ?? cents(overall(in: object)?["used"])
        let extra = cents(onDemand(in: object)?["used"])
        guard included != nil || extra != nil else { return nil }
        return TokenCost(usd: (included ?? 0) + (extra ?? 0), period: "This cycle", estimated: false)
    }

    private static func cents(_ value: Any?) -> Double? {
        guard let number = number(value), number.isFinite, number >= 0 else { return nil }
        return number / 100
    }

    private static func centsFraction(_ block: [String: Any]?) -> Double? {
        guard let block else { return nil }
        if let enabled = block["enabled"] as? Bool, enabled == false { return nil }
        guard let limit = number(block["limit"]), limit > 0, let used = number(block["used"]), used.isFinite else { return nil }
        return min(1, max(0, used / limit))
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func percent(_ value: Any?) -> Double? {
        let number: Double?
        if let value = value as? NSNumber {
            number = value.doubleValue
        } else if let text = value as? String {
            number = Double(text)
        } else {
            number = nil
        }
        guard let number, number.isFinite, number >= 0 else { return nil }
        return min(1, number / 100)
    }

    private static func billingDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            return epoch(number.doubleValue)
        }
        guard let text = value as? String else { return nil }
        if let number = Double(text) {
            return epoch(number)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func epoch(_ raw: Double) -> Date? {
        if raw > 1_000_000_000_000 { return Date(timeIntervalSince1970: raw / 1000) }
        if raw > 1_000_000_000 { return Date(timeIntervalSince1970: raw) }
        return nil
    }
}
