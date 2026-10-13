import Foundation

public struct HookInstallPlan: Equatable, Sendable {
    public var events: [String]
    public var command: String
    public var timeout: Int
    public var marker: String
    public var statusLineCommand: String?

    public init(
        events: [String],
        command: String,
        timeout: Int = 5,
        marker: String = AppIdentity.hookCommandMarker,
        statusLineCommand: String? = nil
    ) {
        self.events = events
        self.command = command
        self.timeout = timeout
        self.marker = marker
        self.statusLineCommand = statusLineCommand
    }
}

public enum ConfigMergerError: Error, Equatable {
    case invalidJSON
    case unexpectedShape
}

public enum ConfigMerger {
    public static func mergeHooks(into original: Data, plan: HookInstallPlan) throws -> Data {
        let root = try parseObject(original.isEmpty ? Data("{}".utf8) : original)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in plan.events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups = groups.compactMap { group -> [String: Any]? in
                var group = group
                let handlers = (group["hooks"] as? [[String: Any]] ?? []).filter { handler in
                    !command(handler).contains(plan.marker)
                }
                if handlers.isEmpty && ((group["hooks"] as? [[String: Any]])?.contains { command($0).contains(plan.marker) } == true) {
                    return nil
                }
                group["hooks"] = handlers
                return handlers.isEmpty ? nil : group
            }
            groups.removeAll { group in
                let handlers = group["hooks"] as? [[String: Any]] ?? []
                return handlers.contains { command($0).contains(plan.marker) }
            }
            groups.append(mochaiGroup(plan))
            hooks[event] = groups
        }
        var updated = root
        updated["hooks"] = hooks
        if let statusLineCommand = plan.statusLineCommand {
            updated["statusLine"] = statusLineEntry(command: statusLineCommand, existing: root["statusLine"], marker: plan.marker)
        }
        try validatePreservedKeys(original: root, updated: updated)
        return try serialize(updated)
    }

    public static func mergeStatusLine(into original: Data, command: String, marker: String) throws -> Data {
        let root = try parseObject(original.isEmpty ? Data("{}".utf8) : original)
        var updated = root
        updated["statusLine"] = statusLineEntry(command: command, existing: root["statusLine"], marker: marker)
        try validatePreservedKeys(original: root, updated: updated)
        return try serialize(updated)
    }

    public static func removeHooks(from original: Data, marker: String) throws -> Data {
        if original.isEmpty { return original }
        let root = try parseObject(original)
        guard var hooks = root["hooks"] as? [String: Any] else {
            return try serialize(root)
        }
        for key in Array(hooks.keys) {
            guard var groups = hooks[key] as? [[String: Any]] else { continue }
            groups = groups.compactMap { group in
                var group = group
                let handlers = (group["hooks"] as? [[String: Any]] ?? []).filter { !command($0).contains(marker) }
                guard !handlers.isEmpty else { return nil }
                group["hooks"] = handlers
                return group
            }
            if groups.isEmpty {
                hooks.removeValue(forKey: key)
            } else {
                hooks[key] = groups
            }
        }
        var updated = root
        if hooks.isEmpty {
            updated.removeValue(forKey: "hooks")
        } else {
            updated["hooks"] = hooks
        }
        updated = removingStatusLine(from: updated, marker: marker)
        return try serialize(updated)
    }

    public static func containsMarker(_ data: Data, marker: String) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(marker)
    }

    public static func topLevelKeys(_ data: Data) throws -> Set<String> {
        Set(try parseObject(data.isEmpty ? Data("{}".utf8) : data).keys)
    }

    private static func statusLineEntry(command: String, existing: Any?, marker: String) -> [String: Any] {
        let previous = (existing as? [String: Any])?["command"] as? String
        var entry: [String: Any] = [
            "type": "command",
            "command": wrappedStatusLine(base: command, existing: previous, marker: marker)
        ]
        if let padding = (existing as? [String: Any])?["padding"] {
            entry["padding"] = padding
        }
        return entry
    }

    static func wrappedStatusLine(base: String, existing: String?, marker: String) -> String {
        guard let existing, !existing.isEmpty else { return base }
        if existing.contains(marker) {
            guard let preserved = extractThen(existing) else { return base }
            return base + " --then " + ShellQuoting.singleQuote(preserved)
        }
        return base + " --then " + ShellQuoting.singleQuote(existing)
    }

    static func extractThen(_ command: String) -> String? {
        guard let range = command.range(of: " --then ") else { return nil }
        return posixUnquote(String(command[range.upperBound...]))
    }

    private static func removingStatusLine(from root: [String: Any], marker: String) -> [String: Any] {
        var updated = root
        guard let status = root["statusLine"] as? [String: Any],
              let command = status["command"] as? String,
              command.contains(marker) else { return updated }
        if let preserved = extractThen(command) {
            var restored: [String: Any] = ["type": "command", "command": preserved]
            if let padding = status["padding"] { restored["padding"] = padding }
            updated["statusLine"] = restored
        } else {
            updated.removeValue(forKey: "statusLine")
        }
        return updated
    }

    private static func posixUnquote(_ value: String) -> String? {
        var result = ""
        var index = value.startIndex
        guard index < value.endIndex, value[index] == "'" else { return value }
        index = value.index(after: index)
        while index < value.endIndex {
            if value[index] == "'" {
                let slash = value.index(after: index)
                let quote = slash < value.endIndex ? value.index(after: slash) : value.endIndex
                if slash < value.endIndex, value[slash] == "\\", quote < value.endIndex, value[quote] == "'" {
                    result.append("'")
                    index = value.index(after: quote)
                    continue
                }
                return result
            }
            result.append(value[index])
            index = value.index(after: index)
        }
        return nil
    }

    private static func mochaiGroup(_ plan: HookInstallPlan) -> [String: Any] {
        [
            "hooks": [[
                "type": "command",
                "command": plan.command,
                "timeout": plan.timeout
            ]]
        ]
    }

    private static func command(_ handler: [String: Any]) -> String {
        handler["command"] as? String ?? ""
    }

    private static func parseObject(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty else { return [:] }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else { throw ConfigMergerError.unexpectedShape }
        return dictionary
    }

    private static func serialize(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw ConfigMergerError.invalidJSON }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return data
    }

    private static func validatePreservedKeys(original: [String: Any], updated: [String: Any]) throws {
        for key in original.keys where key != "hooks" {
            if updated[key] == nil { throw ConfigMergerError.unexpectedShape }
        }
    }
}
