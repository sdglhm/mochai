import Foundation

public enum AppPaths {
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["MOCHAI_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MochAI", isDirectory: true)
    }

    public static var socketURL: URL {
        supportDirectory.appendingPathComponent("mochai.sock")
    }

    public static var eventsDirectory: URL {
        supportDirectory.appendingPathComponent("events", isDirectory: true)
    }

    public static var backupsDirectory: URL {
        supportDirectory.appendingPathComponent("backups", isDirectory: true)
    }

    public static var hookBinaryURL: URL {
        supportDirectory.appendingPathComponent("bin/mochai-hook")
    }

    public static var claudeUsageSnapshotURL: URL {
        supportDirectory.appendingPathComponent("claude-usage.json")
    }

    public static var hookPreferencesURL: URL {
        supportDirectory.appendingPathComponent("hook-preferences.json")
    }

    public static var integrationReceiptURL: URL {
        supportDirectory.appendingPathComponent("integrations.json")
    }

    public static var storeURL: URL {
        supportDirectory.appendingPathComponent("MochAI.store")
    }

    public static func ensureSupportDirectories() throws {
        let fm = FileManager.default
        for url in [supportDirectory, eventsDirectory, backupsDirectory, hookBinaryURL.deletingLastPathComponent()] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    public static var claudeSettingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    }

    public static var codexDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex", isDirectory: true)
    }

    public static var codexHooksURL: URL {
        codexDirectory.appendingPathComponent("hooks.json")
    }

    public static var codexSessionsDirectory: URL {
        codexDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    public static var codexSessionIndexURL: URL {
        codexDirectory.appendingPathComponent("session_index.jsonl")
    }
}
