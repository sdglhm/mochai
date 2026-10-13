import Foundation

/// Live Claude allowance from the sign-in already on this Mac.
/// The token is used for one request and is not stored or logged.
enum ClaudeLiveUsage {
    static func fetch(home: String, now: Date = Date()) async -> ProviderUsage? {
        let file = URL(fileURLWithPath: home).appendingPathComponent(".claude/.credentials.json")
        guard let accessToken = accessToken(in: file, now: now) else { return nil }
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-cli/0.0.0 (external, cli)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 1_048_576 else { return nil }
            return ClaudeLiveUsageParser.parse(data, now: now)
        } catch {
            MochaiLog.usage.error("Claude allowance request failed")
            return nil
        }
    }

    private static func accessToken(in file: URL, now: Date) -> String? {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let oauth = object["claudeAiOauth"] as? [String: Any] ?? object["claudeAiOAuth"] as? [String: Any]
        guard let oauth, let access = string(oauth["accessToken"] ?? oauth["access_token"]) else { return nil }
        if let expiry = number(oauth["expiresAt"] ?? oauth["expires_at"]), let date = epoch(expiry), date <= now {
            return nil
        }
        return access
    }

    private static func epoch(_ raw: Double) -> Date? {
        if raw > 1_000_000_000_000 { return Date(timeIntervalSince1970: raw / 1000) }
        if raw > 1_000_000_000 { return Date(timeIntervalSince1970: raw) }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum ClaudeLiveUsageParser {
    public static func parse(_ data: Data, now: Date = Date()) -> ProviderUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var windows: [UsageWindow] = []
        if let window = window(object["five_hour"], name: "5-hour allowance", minutes: 300) {
            windows.append(window)
        }
        if let window = window(object["seven_day"], name: "Weekly", minutes: 10_080) {
            windows.append(window)
        }
        for (key, name) in [("seven_day_sonnet", "Sonnet"), ("seven_day_opus", "Opus")] {
            if let window = window(object[key], name: name, minutes: 10_080) {
                windows.append(window)
            }
        }
        if windows.isEmpty, let limits = object["limits"] as? [[String: Any]] {
            windows.append(contentsOf: limitWindows(limits))
        }
        guard !windows.isEmpty else { return nil }
        return ProviderUsage(
            windows: windows,
            updatedAt: now,
            confidence: .providerReported,
            detail: "Updated just now."
        )
    }

    /// `utilization` is either a fraction (`0.235`) or a percent (`23.5`).
    public static func usedFraction(from utilization: Double) -> Double {
        let fraction = utilization > 1 ? utilization / 100 : utilization
        return min(1, max(0, fraction))
    }

    private static func window(_ value: Any?, name: String, minutes: Int) -> UsageWindow? {
        guard let dict = value as? [String: Any] else { return nil }
        let used = number(dict["utilization"]).map(usedFraction(from:))
            ?? number(dict["used_percentage"]).map { min(1, max(0, $0 / 100)) }
        let reset = resetDate(dict["resets_at"])
        guard used != nil || reset != nil else { return nil }
        return UsageWindow(
            name: name,
            usedFraction: used,
            remainingFraction: used.map { 1 - $0 },
            resetAt: reset,
            windowMinutes: minutes
        )
    }

    private static func limitWindows(_ limits: [[String: Any]]) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        var seen = Set<String>()
        for entry in limits {
            if entry["is_active"] as? Bool == false { continue }
            guard let percent = number(entry["percent"]) else { continue }
            let model = ((entry["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
            let name: String
            if let model, !model.isEmpty {
                name = model
            } else if entry["group"] as? String == "weekly" {
                name = "Weekly"
            } else {
                name = "5-hour allowance"
            }
            guard seen.insert(name).inserted else { continue }
            let minutes = name == "Weekly" || name == "Sonnet" || name == "Opus" ? 10_080 : 300
            windows.append(UsageWindow(
                name: name,
                usedFraction: usedFraction(from: percent),
                remainingFraction: 1 - usedFraction(from: percent),
                resetAt: resetDate(entry["resets_at"]),
                windowMinutes: minutes
            ))
        }
        return windows
    }

    private static func resetDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, number.doubleValue > 1_000_000_000 {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber {
            let number = value.doubleValue
            return number.isFinite ? number : nil
        }
        if let text = value as? String { return Double(text) }
        return nil
    }
}
