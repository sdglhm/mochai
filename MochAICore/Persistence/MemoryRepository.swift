import Foundation

@MainActor
public protocol SessionRepository: AnyObject {
    func loadActive() throws -> [AgentSession]
    func loadHistory() throws -> [AgentSession]
    func saveActive(_ sessions: [AgentSession]) throws
    func saveHistory(_ sessions: [AgentSession]) throws
    func loadProjects() throws -> [ProjectPolicy]
    func saveProjects(_ projects: [ProjectPolicy]) throws
    func appendUsage(provider: ProviderID, usage: ProviderUsage) throws
    func usageHistory(provider: ProviderID, since: Date) throws -> [(date: Date, used: Double)]
    func pruneHistory(before date: Date?) throws
}

@MainActor
public final class MemoryRepository: SessionRepository {
    public var active: [AgentSession] = []
    public var history: [AgentSession] = []
    public var projects: [ProjectPolicy] = []
    public var snapshots: [(provider: ProviderID, date: Date, used: Double)] = []

    public init() {}

    public func loadActive() throws -> [AgentSession] { active }
    public func loadHistory() throws -> [AgentSession] { history }
    public func saveActive(_ sessions: [AgentSession]) throws { active = sessions }
    public func saveHistory(_ sessions: [AgentSession]) throws { history = sessions }
    public func loadProjects() throws -> [ProjectPolicy] { projects }
    public func saveProjects(_ projects: [ProjectPolicy]) throws { self.projects = projects }

    public func appendUsage(provider: ProviderID, usage: ProviderUsage) throws {
        guard let used = usage.windows.first?.resolvedUsed else { return }
        snapshots.append((provider, usage.updatedAt, used))
    }

    public func usageHistory(provider: ProviderID, since: Date) throws -> [(date: Date, used: Double)] {
        snapshots.filter { $0.provider == provider && $0.date >= since }.map { ($0.date, $0.used) }
    }

    public func pruneHistory(before date: Date?) throws {
        guard let date else { return }
        history.removeAll { ($0.completedAt ?? $0.lastActivityAt) < date }
    }
}
