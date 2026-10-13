import Foundation

public struct LimitSignal: Equatable, Sendable {
    public var resetAt: Date?
    public var errorCode: String

    public init(resetAt: Date?, errorCode: String = "rate_limit") {
        self.resetAt = resetAt
        self.errorCode = errorCode
    }
}

public enum LimitDetector {
    private static let limitTokens = [
        "rate_limit", "rate limit", "usage limit", "hit your limit", "too many requests",
        "quota", "429", "limit reached"
    ]

    public static func signal(errorCode: String?, message: String?, now: Date = Date()) -> LimitSignal? {
        let code = errorCode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let text = message ?? ""
        let haystack = ((code ?? "") + " " + text).lowercased()
        let matched = code == "rate_limit" || limitTokens.contains { haystack.contains($0) }
        guard matched else { return nil }
        return LimitSignal(resetAt: parseReset(in: text, now: now), errorCode: code ?? "rate_limit")
    }

    public static func parseReset(in text: String, now: Date = Date()) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        if let date = isoDate(in: trimmed) { return date }
        if let unix = unixDate(in: trimmed) { return unix }
        if let relative = relativeInterval(in: trimmed) { return now.addingTimeInterval(relative) }
        if let clock = clockTime(in: trimmed, now: now) { return clock }
        return nil
    }

    private static func isoDate(in text: String) -> Date? {
        let pattern = #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})"#
        guard let match = firstMatch(pattern, in: text) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: match) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: match)
    }

    private static func unixDate(in text: String) -> Date? {
        let pattern = #"(?:resets_at|reset_at|resetAt)["\s:=]+(\d{10})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text),
              let seconds = TimeInterval(text[valueRange]) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func relativeInterval(in text: String) -> TimeInterval? {
        let pattern = #"(?i)(?:in|after)\s+(?:(\d+)\s*h(?:ours?)?)?\s*(?:(\d+)\s*m(?:in(?:ute)?s?)?)?\s*(?:(\d+)\s*s(?:ec(?:ond)?s?)?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        func group(_ index: Int) -> Double {
            guard match.numberOfRanges > index, let r = Range(match.range(at: index), in: text) else { return 0 }
            return Double(text[r]) ?? 0
        }
        let hours = group(1)
        let minutes = group(2)
        let seconds = group(3)
        let total = hours * 3600 + minutes * 60 + seconds
        return total > 0 ? total : nil
    }

    private static func clockTime(in text: String, now: Date) -> Date? {
        let pattern = #"(?i)\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let hourRange = Range(match.range(at: 1), in: text),
              var hour = Int(text[hourRange]) else { return nil }
        var minute = 0
        if match.numberOfRanges > 2, let minuteRange = Range(match.range(at: 2), in: text), !minuteRange.isEmpty {
            minute = Int(text[minuteRange]) ?? 0
        }
        let ampm = Range(match.range(at: 3), in: text).map { text[$0].lowercased() } ?? "am"
        if ampm == "pm", hour < 12 { hour += 12 }
        if ampm == "am", hour == 12 { hour = 0 }
        var calendar = Calendar.current
        calendar.timeZone = .current
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard var date = calendar.date(from: components) else { return nil }
        if date <= now {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return date
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), let r = Range(match.range, in: text) else { return nil }
        return String(text[r])
    }
}
