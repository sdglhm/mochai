import Foundation

public enum UsageConfidence: String, Codable, Sendable {
    case exact
    case providerReported
    case locallyEstimated
    case unavailable

    public var label: String {
        switch self {
        case .exact: "Exact"
        case .providerReported: "Provider reported"
        case .locallyEstimated: "Estimated locally"
        case .unavailable: "Unavailable"
        }
    }
}

public struct UsageWindow: Codable, Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var usedFraction: Double?
    public var remainingFraction: Double?
    public var resetAt: Date?
    public var windowMinutes: Int?

    public init(
        name: String,
        usedFraction: Double? = nil,
        remainingFraction: Double? = nil,
        resetAt: Date? = nil,
        windowMinutes: Int? = nil
    ) {
        self.name = name
        self.usedFraction = usedFraction
        self.remainingFraction = remainingFraction
        self.resetAt = resetAt
        self.windowMinutes = windowMinutes
    }

    public var resolvedUsed: Double? {
        if let usedFraction { return min(1, max(0, usedFraction)) }
        if let remainingFraction { return min(1, max(0, 1 - remainingFraction)) }
        return nil
    }

    /// A window whose reset time has passed is the previous allowance, not the new one.
    public func isCurrent(at now: Date) -> Bool {
        guard let resetAt else { return true }
        return resetAt > now
    }

    public var shortLabel: String {
        switch name {
        case "5-hour allowance", "Current window", "Session": "5-hour"
        case "Weekly": "Weekly"
        default: name
        }
    }

    /// Compact menu line. Codex callers pass `.remaining` so 91% consumed reads as "9% left".
    public func menuLine(at now: Date, reading: AllowanceReading) -> String {
        if let used = resolvedUsed, used >= 0.995 {
            guard let reset = resetAt, reset > now else { return "Limit reached" }
            return "Limit reached · \(MochaiFormat.countdown(reset.timeIntervalSince(now)))"
        }
        let figure = headline(reading: reading)
        guard let reset = resetAt else { return figure ?? "Not available yet" }
        if reset > now {
            let prefix = figure.map { "\($0) · " } ?? ""
            return "\(prefix)\(MochaiFormat.countdown(reset.timeIntervalSince(now)))"
        }
        return "Reset \(MochaiFormat.clock(reset, now: now))"
    }

    public func headline(reading: AllowanceReading) -> String? {
        guard let used = resolvedUsed else { return nil }
        if used >= 0.995 { return "Limit reached" }
        switch reading {
        case .used:
            return "\(MochaiFormat.percent(used)) used"
        case .remaining:
            return "\(MochaiFormat.percent(1 - used)) left"
        }
    }

    /// Bar fill matches the headline: used grows as the allowance is spent, remaining shrinks.
    public func meterFill(reading: AllowanceReading) -> Double? {
        guard let used = resolvedUsed else { return nil }
        switch reading {
        case .used:
            return used
        case .remaining:
            return used >= 0.995 ? 0 : 1 - used
        }
    }
}

public struct TokenCost: Codable, Equatable, Sendable {
    public var usd: Double
    /// Shown beside the amount, such as "This month" or "This cycle".
    public var period: String
    public var estimated: Bool

    public init(usd: Double, period: String, estimated: Bool) {
        self.usd = usd
        self.period = period
        self.estimated = estimated
    }

    public var line: String {
        let amount = MochaiFormat.dollars(usd)
        return estimated ? "\(period) · about \(amount)" : "\(period) · \(amount)"
    }
}

public struct ProviderUsage: Codable, Equatable, Sendable {
    public var windows: [UsageWindow]
    public var updatedAt: Date
    public var confidence: UsageConfidence
    public var detail: String?
    public var tokenCost: TokenCost?

    public init(
        windows: [UsageWindow],
        updatedAt: Date,
        confidence: UsageConfidence,
        detail: String? = nil,
        tokenCost: TokenCost? = nil
    ) {
        self.windows = windows
        self.updatedAt = updatedAt
        self.confidence = confidence
        self.detail = detail
        self.tokenCost = tokenCost
    }

    public static func unavailable(at date: Date, detail: String) -> ProviderUsage {
        ProviderUsage(windows: [], updatedAt: date, confidence: .unavailable, detail: detail)
    }

    public var lowestRemaining: Double? {
        let remaining = windows.compactMap { window -> Double? in
            if let remaining = window.remainingFraction { return remaining }
            if let used = window.usedFraction { return 1 - used }
            return nil
        }
        return remaining.min()
    }

    public var soonestReset: Date? {
        windows.compactMap(\.resetAt).min()
    }

    /// The 5-hour allowance and the weekly allowance, then any extra pool the provider reported.
    /// Providers without those windows, such as Cursor's monthly pools, show every reported window.
    public func allowanceWindows() -> [UsageWindow] {
        let fiveHour = windows.first { $0.name == "5-hour allowance" || $0.name == "Current window" }
            ?? windows.first { $0.windowMinutes == 300 }
        let weekly = windows.first { $0.name == "Weekly" }
            ?? windows.first { ($0.windowMinutes ?? 0) >= 10_000 }
        let picked = [fiveHour, weekly].compactMap { $0 }
        if picked.isEmpty { return windows }
        let pickedNames = Set(picked.map(\.name))
        let extras = windows.filter { !pickedNames.contains($0.name) }
        return picked + extras
    }

    /// A current window that the provider has already marked as spent.
    public func exhaustedWindow(at now: Date) -> UsageWindow? {
        windows.first { window in
            guard window.isCurrent(at: now), let used = window.resolvedUsed else { return false }
            return used >= 0.995
        }
    }

    /// The one allowance to show for this provider: the 5-hour window when Codex or Claude reports one.
    public func featuredWindow(at now: Date = Date()) -> UsageWindow? {
        let preferred = ["5-hour allowance", "Current window", "Session"]
        if let match = windows.first(where: { preferred.contains($0.name) }) {
            return match
        }
        let current = windows.filter { $0.isCurrent(at: now) && $0.resetAt != nil }
        if let soonest = current.min(by: { ($0.resetAt ?? .distantFuture) < ($1.resetAt ?? .distantFuture) }) {
            return soonest
        }
        return windows.first
    }
}
