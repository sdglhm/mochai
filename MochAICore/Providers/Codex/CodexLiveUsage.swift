import Foundation

/// Live Codex allowance from the sign-in already on this Mac.
/// The token is used for one request and is not stored or logged.
enum CodexLiveUsage {
    static func fetch(home: URL, now: Date = Date()) async -> ProviderUsage? {
        guard let credential = credential(in: home.appendingPathComponent("auth.json")) else { return nil }
        var request = URLRequest(url: usageURL(home: home))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let account = credential.accountID, !account.isEmpty {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 1_048_576 else { return nil }
            return CodexLiveUsageParser.parse(data, now: now)
        } catch {
            MochaiLog.usage.error("Codex allowance request failed")
            return nil
        }
    }

    private static func credential(in file: URL) -> (accessToken: String, accountID: String?)? {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let access = string(tokens["access_token"]) else { return nil }
        return (access, string(tokens["account_id"]))
    }

    private static func usageURL(home: URL) -> URL {
        let fallback = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        let config = home.appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return fallback }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), trimmed.contains("chatgpt_base_url") else { continue }
            guard let value = trimmed.split(separator: "=", maxSplits: 1).last else { continue }
            let raw = value.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .replacingOccurrences(of: "\\", with: "")
            guard let base = URL(string: raw), base.scheme == "https" else { continue }
            if base.path.hasSuffix("/wham/usage") { return base }
            return base.appendingPathComponent("wham/usage")
        }
        return fallback
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum CodexLiveUsageParser {
    public static func parse(_ data: Data, now: Date = Date()) -> ProviderUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let rate = object["rate_limit"] as? [String: Any] ?? object["rateLimit"] as? [String: Any]
        var windows: [UsageWindow] = []
        if let primary = window(rate?["primary_window"] ?? rate?["primaryWindow"], slot: "5-hour allowance") {
            windows.append(primary)
        }
        if let secondary = window(rate?["secondary_window"] ?? rate?["secondaryWindow"], slot: "Weekly") {
            windows.append(secondary)
        }
        if let extras = object["additional_rate_limits"] as? [[String: Any]] {
            for entry in extras {
                windows.append(contentsOf: extraWindows(entry))
            }
        }
        guard !windows.isEmpty else { return nil }
        return ProviderUsage(
            windows: windows,
            updatedAt: now,
            confidence: .providerReported,
            detail: "Updated just now."
        )
    }

    private static func extraWindows(_ entry: [String: Any]) -> [UsageWindow] {
        let raw = string(entry["limit_name"]) ?? string(entry["metered_feature"]) ?? "Extra"
        let title = raw.lowercased().contains("spark") ? "Spark" : String(raw.prefix(24))
        let rate = entry["rate_limit"] as? [String: Any] ?? [:]
        return [
            window(rate["primary_window"], slot: "5-hour allowance", label: title),
            window(rate["secondary_window"], slot: "Weekly", label: title)
        ].compactMap { $0 }
    }

    private static func window(_ value: Any?, slot: String, label: String? = nil) -> UsageWindow? {
        guard let dict = value as? [String: Any] else { return nil }
        let used = number(dict["used_percent"])
        let reset = number(dict["reset_at"]) ?? number(dict["resets_at"])
        let seconds = number(dict["limit_window_seconds"])
        guard used != nil || reset != nil else { return nil }
        let minutes = seconds.map { Int(($0 / 60).rounded()) }
        let base: String
        if minutes == 300 || (minutes != nil && (minutes ?? 0) > 0 && (minutes ?? 0) <= 360) {
            base = "5-hour allowance"
        } else if let minutes, minutes >= 10_000 {
            base = "Weekly"
        } else {
            base = slot
        }
        let name = label.map { base == "Weekly" ? "\($0) weekly" : "\($0) 5-hour" } ?? base
        let fraction = used.map { min(1, max(0, $0 / 100)) }
        return UsageWindow(
            name: name,
            usedFraction: fraction,
            remainingFraction: fraction.map { 1 - $0 },
            resetAt: reset.map { Date(timeIntervalSince1970: $0) },
            windowMinutes: minutes
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber {
            let number = value.doubleValue
            return number.isFinite ? number : nil
        }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
