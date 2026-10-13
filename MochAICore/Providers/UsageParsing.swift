import Foundation

public enum UsageTextParser {
    /// Parses explicit percentage lines. Returns nil when the text does not
    /// contain a clear usage figure, so callers can show "unavailable".
    public static func parse(providerText text: String, now: Date = Date()) -> ProviderUsage? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        var windows: [UsageWindow] = []
        for line in lines {
            guard let window = parseLine(line, now: now) else { continue }
            windows.append(window)
        }
        guard !windows.isEmpty else { return nil }
        return ProviderUsage(
            windows: windows,
            updatedAt: now,
            confidence: .providerReported,
            detail: "Parsed from provider status text."
        )
    }

    private static func parseLine(_ line: String, now: Date) -> UsageWindow? {
        let pattern = #"(?i)(5-hour|session|weekly|current|[a-z][a-z \-]{2,24})\s*(?:allowance|limit|usage)?[^0-9%]{0,24}(\d{1,3}(?:\.\d+)?)\s*%\s*(used|remaining)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let nameRange = Range(match.range(at: 1), in: line),
              let numberRange = Range(match.range(at: 2), in: line),
              let value = Double(line[numberRange]) else { return nil }
        let qualifier: String
        if match.numberOfRanges > 3, let q = Range(match.range(at: 3), in: line) {
            qualifier = String(line[q]).lowercased()
        } else {
            qualifier = "used"
        }
        let fraction = min(100, max(0, value)) / 100
        let used = qualifier == "remaining" ? 1 - fraction : fraction
        let name = String(line[nameRange]).trimmingCharacters(in: .whitespaces)
        let titled = name.lowercased() == "5-hour" ? "5-hour allowance" : name.capitalized
        return UsageWindow(
            name: titled,
            usedFraction: used,
            remainingFraction: 1 - used,
            resetAt: LimitDetector.parseReset(in: line, now: now)
        )
    }
}

public enum CodexUsageParser {
    public static func parse(rateLimits object: [String: Any], updatedAt: Date) -> ProviderUsage? {
        var windows: [UsageWindow] = []
        if let primary = window(object["primary"], fallback: "Current window") { windows.append(primary) }
        if let secondary = window(object["secondary"], fallback: "Weekly") { windows.append(secondary) }
        for key in object.keys.sorted() where key != "primary" && key != "secondary" {
            if let extra = window(object[key], fallback: key.replacingOccurrences(of: "_", with: " ").capitalized) {
                windows.append(extra)
            }
        }
        guard !windows.isEmpty else { return nil }
        var notes = ["Read from Codex session metadata on this Mac."]
        if let reached = object["rate_limit_reached_type"] as? String, !reached.isEmpty {
            windows = reachedPrimary(windows)
            notes = ["Codex reported the 5-hour limit is reached."]
        } else {
            if let plan = object["plan_type"] as? String, !plan.isEmpty {
                notes.insert("\(plan.capitalized) plan.", at: 0)
            }
            if let limit = object["limit_id"] as? String, !limit.isEmpty, limit != "codex" {
                notes.insert(limit.capitalized, at: 0)
            }
        }
        return ProviderUsage(
            windows: windows,
            updatedAt: updatedAt,
            confidence: .providerReported,
            detail: notes.joined(separator: " ")
        )
    }

    public static func parseTail(_ data: Data, updatedAt: Date) -> ProviderUsage? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var searchEnd = text.endIndex
        while searchEnd > text.startIndex {
            let region = text[..<searchEnd]
            guard let range = region.range(of: "\"rate_limits\"", options: .backwards) else { return nil }
            if let object = object(after: range.upperBound, in: text),
               var usage = parse(rateLimits: object, updatedAt: updatedAt) {
                if text[range.upperBound...].contains("usage_limit_exceeded") {
                    usage = ProviderUsage(
                        windows: reachedPrimary(usage.windows),
                        updatedAt: usage.updatedAt,
                        confidence: .providerReported,
                        detail: "Codex reported the 5-hour limit is reached."
                    )
                }
                return usage
            }
            searchEnd = range.lowerBound
        }
        return nil
    }

    /// Codex can report 97% and then refuse the turn because the allowance is already spent.
    private static func reachedPrimary(_ windows: [UsageWindow]) -> [UsageWindow] {
        windows.map { window in
            guard window.name == "5-hour allowance" || window.windowMinutes == 300 else { return window }
            return UsageWindow(
                name: window.name,
                usedFraction: 1,
                remainingFraction: 0,
                resetAt: window.resetAt,
                windowMinutes: window.windowMinutes
            )
        }
    }

    private static func object(after index: String.Index, in text: String) -> [String: Any]? {
        guard let start = text[index...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var end = start
        var closed = false
        for cursor in text[start...].indices {
            let character = text[cursor]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            if character == "\"" { inString = true }
            else if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 {
                    end = cursor
                    closed = true
                    break
                }
            }
        }
        guard closed else { return nil }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private static func window(_ value: Any?, fallback: String) -> UsageWindow? {
        guard let dict = value as? [String: Any] else { return nil }
        let used = (dict["used_percent"] as? NSNumber)?.doubleValue
        let minutes = (dict["window_minutes"] as? NSNumber)?.intValue
        let reset = (dict["resets_at"] as? NSNumber)?.doubleValue
        guard used != nil || reset != nil else { return nil }
        let name: String
        if minutes == 300 {
            name = "5-hour allowance"
        } else if let minutes, minutes >= 10_000 {
            name = "Weekly"
        } else {
            name = fallback
        }
        return UsageWindow(
            name: name,
            usedFraction: used.map { min(1, max(0, $0 / 100)) },
            remainingFraction: used.map { min(1, max(0, 1 - $0 / 100)) },
            resetAt: reset.map { Date(timeIntervalSince1970: $0) },
            windowMinutes: minutes
        )
    }
}

public enum CodexMetadata {
    public static func currentUsage(sessionsDirectory: URL = AppPaths.codexSessionsDirectory, now: Date = Date()) -> ProviderUsage {
        let files = recentSessionFiles(in: sessionsDirectory, limit: 8)
        guard !files.isEmpty else {
            return .unavailable(at: now, detail: "Codex hasn't reported a limit yet.")
        }
        for file in files {
            guard let data = tailContainingUsage(of: file),
                  let usage = CodexUsageParser.parseTail(data, updatedAt: fileDate(file) ?? now),
                  !usage.windows.isEmpty else { continue }
            return usage
        }
        return .unavailable(at: now, detail: "Codex hasn't reported a limit yet.")
    }

    public static func sessionTitles(indexURL: URL = AppPaths.codexSessionIndexURL) -> [String: String] {
        guard let handle = try? FileHandle(forReadingFrom: indexURL) else { return [:] }
        defer { try? handle.close() }
        let data: Data
        if let end = try? handle.seekToEnd(), end > 256 * 1024 {
            try? handle.seek(toOffset: end - 256 * 1024)
            data = (try? handle.readToEnd()) ?? Data()
        } else {
            try? handle.seek(toOffset: 0)
            data = (try? handle.readToEnd()) ?? Data()
        }
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var titles: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = object["id"] as? String,
                  let name = object["thread_name"] as? String else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 80 else { continue }
            titles[id] = trimmed
        }
        return titles
    }

    private static func recentSessionFiles(in directory: URL, limit: Int) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var ranked: [(date: Date, url: URL)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let date = values?.contentModificationDate else { continue }
            ranked.append((date, url))
        }
        return ranked.sorted { $0.date > $1.date }.prefix(limit).map(\.url)
    }

    /// Reads backward until a usage figure appears. The end of a long session
    /// can be tool output, with the latest rate limits a megabyte or more earlier.
    private static func tailContainingUsage(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let chunk = 512 * 1024
        let maxBytes = 4 * 1024 * 1024
        guard let end = try? handle.seekToEnd() else { return nil }
        var collected = Data()
        var offset = end
        var scanned = 0
        while offset > 0, scanned < maxBytes {
            let start: UInt64 = offset > UInt64(chunk) ? offset - UInt64(chunk) : 0
            try? handle.seek(toOffset: start)
            let piece = (try? handle.read(upToCount: Int(offset - start))) ?? Data()
            collected.insert(contentsOf: piece, at: 0)
            scanned += piece.count
            if let text = String(data: collected, encoding: .utf8),
               text.contains("\"used_percent\"") || text.contains("\"resets_at\"") {
                return collected
            }
            if start == 0 { break }
            offset = start
        }
        return collected.isEmpty ? nil : collected
    }

    private static func fileDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
