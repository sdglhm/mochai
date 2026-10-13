import Foundation

public enum MenuBarPhase: String, Sendable {
    case idle
    case working
    case waiting
    case limited
    case attention
}

public enum MascotPose: String, Sendable {
    case idle
    case working
    case coffee
    case sleeping
    case waiting
    case celebrate
    case error
}

public struct QueueEntry: Identifiable, Equatable, Sendable {
    public enum Phase: String, Sendable {
        case waiting
        case ready
        case completed
    }

    public var id: UUID
    public var phase: Phase
    public var session: AgentSession

    public init(phase: Phase, session: AgentSession) {
        self.id = session.id
        self.phase = phase
        self.session = session
    }
}

public enum StatusPresentation {
    public static func phase(sessions: [AgentSession]) -> MenuBarPhase {
        let live = sessions.filter { $0.outcome == .ongoing || $0.state.isLimited }
        if live.contains(where: \.state.preventsSystemSleep) { return .working }
        if live.contains(where: \.state.isLimited) { return .limited }
        if live.contains(where: \.state.needsAttention) { return .attention }
        if live.contains(where: { $0.state == .waitingForPermission }) {
            return .waiting
        }
        if live.contains(where: { $0.state == .failed }) { return .attention }
        return .idle
    }

    public static func mascot(phase: MenuBarPhase, recentlyCompleted: Bool) -> MascotPose {
        if recentlyCompleted, phase == .idle { return .celebrate }
        switch phase {
        case .idle: return .idle
        case .working: return .coffee
        case .waiting: return .waiting
        case .limited: return .sleeping
        case .attention: return .error
        }
    }

    public static func headline(sessions: [AgentSession]) -> String {
        let live = sessions.filter { $0.outcome == .ongoing || $0.state.isLimited || $0.state == .failed }
        let working = live.filter { $0.state.preventsSystemSleep }
        if working.count == 1, let session = working.first {
            return "\(session.provider.displayName) is working."
        }
        if working.count > 1 {
            return "\(working.count) agents working"
        }
        if let limited = live.first(where: \.state.isLimited) {
            return "\(limited.provider.displayName) is taking a quota nap."
        }
        if let waiting = live.first(where: { $0.state == .waitingForPermission }) {
            return "\(waiting.provider.displayName) needs you."
        }
        if let failed = live.first(where: { $0.state == .failed }) {
            return "\(failed.provider.displayName) stopped unexpectedly."
        }
        if sessions.contains(where: { $0.outcome == .completed && Date().timeIntervalSince($0.completedAt ?? .distantPast) < 60 * 20 }) {
            return "All done."
        }
        return "Everything's quiet."
    }

    public static func detail(sleeping: Bool, sessions: [AgentSession]) -> String {
        if sleeping {
            return "Your Mac will stay awake. The display can still sleep."
        }
        if sessions.contains(where: \.state.isLimited) {
            return "MochAI can let this Mac sleep."
        }
        if sessions.contains(where: { $0.state == .waitingForPermission }) {
            return "Your Mac can sleep while the agent waits."
        }
        return "Start Claude or Codex and MochAI will keep an eye on it."
    }

    public static func queue(active: [AgentSession], history: [AgentSession], now: Date) -> [QueueEntry] {
        var entries: [QueueEntry] = []
        for session in active where session.state.isLimited {
            entries.append(QueueEntry(phase: .waiting, session: session))
        }
        for session in active where session.resume.readiness == .ready && !session.state.isLimited {
            entries.append(QueueEntry(phase: .ready, session: session))
        }
        for session in history where session.outcome == .completed || session.outcome == .interrupted {
            guard let completed = session.completedAt, now.timeIntervalSince(completed) < 12 * 3600 else { continue }
            entries.append(QueueEntry(phase: .completed, session: session))
        }
        return entries
    }

    public static func menuBarText(
        mode: MenuBarDisplayMode,
        sessions: [AgentSession],
        usage: [ProviderID: ProviderUsage],
        holding: Bool,
        now: Date
    ) -> String? {
        switch mode {
        case .iconOnly:
            return nil
        case .lowestUsage:
            let remaining = usage.values.compactMap(\.lowestRemaining).min()
            guard let remaining else { return nil }
            return MochaiFormat.percent(remaining)
        case .claudeUsage:
            return usageText(.claude, usage: usage)
        case .codexUsage:
            return usageText(.codex, usage: usage)
        case .agentCount:
            let count = sessions.filter { $0.outcome == .ongoing && $0.state != .unknown }.count
            return "\(count)"
        case .nextReset:
            let resets = usage.values.compactMap(\.soonestReset).filter { $0 > now }
            guard let next = resets.min() else { return nil }
            return MochaiFormat.countdown(next.timeIntervalSince(now))
        case .keepAwake:
            return holding ? "Awake" : "Nap"
        }
    }

    private static func usageText(_ provider: ProviderID, usage: [ProviderID: ProviderUsage]) -> String? {
        guard let value = usage[provider]?.lowestRemaining else { return nil }
        return MochaiFormat.percent(value)
    }
}
