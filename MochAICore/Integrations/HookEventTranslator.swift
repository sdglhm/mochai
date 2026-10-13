import Foundation

public struct HookPreferences: Codable, Equatable, Sendable {
    public var storeCommandNames: Bool

    public init(storeCommandNames: Bool = false) {
        self.storeCommandNames = storeCommandNames
    }
}

public enum HookEventTranslator {
    public static let maxFieldLength = 512

    public static func translate(_ data: Data, now: Date = Date()) -> NormalizedEvent? {
        guard data.count <= 65_536 else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let version = object["version"] as? Int ?? 1
        guard version == 1 else { return nil }
        guard let providerRaw = string(object["provider"]), let provider = ProviderID(rawValue: providerRaw), provider != .mock else {
            return nil
        }
        guard let eventRaw = string(object["event"]), let kind = kind(for: eventRaw) else { return nil }
        let session = string(object["session_id"])
        let cwd = string(object["cwd"])
        if let cwd, !cwd.hasPrefix("/") { return nil }
        let tool = string(object["tool_category"])
        let command = string(object["command_name"])
        let error = string(object["error_code"])
        let reset = date(object["reset_at"], now: now)
        let timestamp = date(object["timestamp"], now: now) ?? now
        return NormalizedEvent(
            provider: provider,
            kind: kind,
            sessionID: session,
            cwd: cwd,
            toolCategory: tool,
            commandName: command,
            timestamp: timestamp,
            resetAt: reset,
            errorCode: error
        )
    }

    public static func kind(for raw: String) -> EventKind? {
        switch raw {
        case "provider_started": .providerStarted
        case "provider_stopped": .providerStopped
        case "session_started": .sessionStarted
        case "session_ended": .sessionEnded
        case "prompt_submitted": .promptSubmitted
        case "generation_started": .generationStarted
        case "generation_stopped": .generationStopped
        case "tool_started": .toolStarted
        case "tool_finished": .toolFinished
        case "command_started": .commandStarted
        case "command_finished": .commandFinished
        case "waiting_for_user": .waitingForUser
        case "permission_requested": .permissionRequested
        case "rate_limit_reached": .rateLimitReached
        case "usage_updated": .usageUpdated
        case "resume_started": .resumeStarted
        case "resume_finished": .resumeFinished
        case "error": .error
        default: nil
        }
    }

    private static func string(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxFieldLength else { return nil }
        if trimmed.contains("\0") { return nil }
        return trimmed
    }

    private static func date(_ value: Any?, now: Date) -> Date? {
        if let number = value as? TimeInterval {
            return Date(timeIntervalSince1970: number)
        }
        if let number = value as? Int {
            return Date(timeIntervalSince1970: TimeInterval(number))
        }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text) ?? LimitDetector.parseReset(in: text, now: now)
    }
}

public enum ProviderHookEvents {
    public static let claude = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "Notification", "Stop", "StopFailure", "PermissionRequest"
    ]

    public static let codex = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "Stop", "PermissionRequest"
    ]
}
