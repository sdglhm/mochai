import Foundation
import SwiftData

@Model
public final class StoredSession {
    @Attribute(.unique) public var id: UUID
    public var provider: String
    public var state: String
    public var projectPath: String
    public var updatedAt: Date
    public var archived: Bool
    public var payload: Data

    public init(id: UUID, provider: String, state: String, projectPath: String, updatedAt: Date, archived: Bool, payload: Data) {
        self.id = id
        self.provider = provider
        self.state = state
        self.projectPath = projectPath
        self.updatedAt = updatedAt
        self.archived = archived
        self.payload = payload
    }
}

@Model
public final class StoredProject {
    @Attribute(.unique) public var id: String
    public var name: String
    public var updatedAt: Date
    public var payload: Data

    public init(id: String, name: String, updatedAt: Date, payload: Data) {
        self.id = id
        self.name = name
        self.updatedAt = updatedAt
        self.payload = payload
    }
}

@Model
public final class StoredUsageSnapshot {
    public var id: UUID
    public var provider: String
    public var windowName: String
    public var usedFraction: Double
    public var recordedAt: Date

    public init(id: UUID = UUID(), provider: String, windowName: String, usedFraction: Double, recordedAt: Date) {
        self.id = id
        self.provider = provider
        self.windowName = windowName
        self.usedFraction = usedFraction
        self.recordedAt = recordedAt
    }
}

public enum MochaiSchemaV1: VersionedSchema {
    public static var versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [StoredSession.self, StoredProject.self, StoredUsageSnapshot.self]
    }
}

public enum MochaiMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [MochaiSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}

public enum SessionCoding {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
