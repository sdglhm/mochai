import Foundation
import SwiftData

@MainActor
public final class SwiftDataRepository: SessionRepository {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    public static func make(inMemory: Bool = false, url: URL? = nil) throws -> SwiftDataRepository {
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        } else {
            configuration = ModelConfiguration(url: url ?? AppPaths.storeURL)
        }
        let container = try ModelContainer(
            for: StoredSession.self,
            StoredProject.self,
            StoredUsageSnapshot.self,
            migrationPlan: MochaiMigrationPlan.self,
            configurations: configuration
        )
        return SwiftDataRepository(context: ModelContext(container))
    }

    public func loadActive() throws -> [AgentSession] {
        try decode(archived: false)
    }

    public func loadHistory() throws -> [AgentSession] {
        try decode(archived: true)
    }

    public func saveActive(_ sessions: [AgentSession]) throws {
        try replace(sessions, archived: false)
    }

    public func saveHistory(_ sessions: [AgentSession]) throws {
        try replace(sessions, archived: true)
    }

    public func loadProjects() throws -> [ProjectPolicy] {
        let stored = try context.fetch(FetchDescriptor<StoredProject>())
        return stored.compactMap { try? SessionCoding.decoder.decode(ProjectPolicy.self, from: $0.payload) }
    }

    public func saveProjects(_ projects: [ProjectPolicy]) throws {
        let existing = try context.fetch(FetchDescriptor<StoredProject>())
        for item in existing { context.delete(item) }
        for project in projects {
            let payload = try SessionCoding.encoder.encode(project)
            context.insert(StoredProject(id: project.id, name: project.name, updatedAt: Date(), payload: payload))
        }
        try context.save()
    }

    public func appendUsage(provider: ProviderID, usage: ProviderUsage) throws {
        for window in usage.windows {
            guard let used = window.resolvedUsed else { continue }
            context.insert(StoredUsageSnapshot(
                provider: provider.rawValue,
                windowName: window.name,
                usedFraction: used,
                recordedAt: usage.updatedAt
            ))
        }
        try context.save()
    }

    public func usageHistory(provider: ProviderID, since: Date) throws -> [(date: Date, used: Double)] {
        let providerID = provider.rawValue
        let predicate = #Predicate<StoredUsageSnapshot> { snapshot in
            snapshot.provider == providerID && snapshot.recordedAt >= since
        }
        let stored = try context.fetch(FetchDescriptor(predicate: predicate))
        return stored
            .map { ($0.recordedAt, $0.usedFraction) }
            .sorted { $0.date < $1.date }
    }

    public func pruneHistory(before date: Date?) throws {
        guard let date else { return }
        var history = try loadHistory()
        history.removeAll { ($0.completedAt ?? $0.lastActivityAt) < date }
        try saveHistory(history)
    }

    private func decode(archived: Bool) throws -> [AgentSession] {
        let flag = archived
        let predicate = #Predicate<StoredSession> { $0.archived == flag }
        let stored = try context.fetch(FetchDescriptor(predicate: predicate))
        return stored.compactMap { record in
            do {
                return try SessionCoding.decoder.decode(AgentSession.self, from: record.payload)
            } catch {
                MochaiLog.app.error("Skipped a stored session that could not be read")
                return nil
            }
        }
    }

    private func replace(_ sessions: [AgentSession], archived: Bool) throws {
        let flag = archived
        let predicate = #Predicate<StoredSession> { $0.archived == flag }
        let existing = try context.fetch(FetchDescriptor(predicate: predicate))
        for item in existing { context.delete(item) }
        for session in sessions {
            let payload = try SessionCoding.encoder.encode(session)
            context.insert(StoredSession(
                id: session.id,
                provider: session.provider.rawValue,
                state: session.state.rawValue,
                projectPath: session.projectDirectory ?? "",
                updatedAt: session.lastActivityAt,
                archived: archived,
                payload: payload
            ))
        }
        try context.save()
    }
}
