import Foundation

public struct TrackedProcess: Equatable, Sendable, Identifiable {
    public var pid: Int32
    public var parentPID: Int32?
    public var provider: ProviderID
    public var executablePath: String
    public var workingDirectory: String?
    public var startedAt: Date?
    public var terminalApp: String?
    public var cpuActive: Bool
    public var providerSessionID: String?
    public var taskSummary: String?

    public var id: Int32 { pid }

    public init(
        pid: Int32,
        parentPID: Int32? = nil,
        provider: ProviderID,
        executablePath: String,
        workingDirectory: String? = nil,
        startedAt: Date? = nil,
        terminalApp: String? = nil,
        cpuActive: Bool = false,
        providerSessionID: String? = nil,
        taskSummary: String? = nil
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.provider = provider
        self.executablePath = executablePath
        self.workingDirectory = workingDirectory
        self.startedAt = startedAt
        self.terminalApp = terminalApp
        self.cpuActive = cpuActive
        self.providerSessionID = providerSessionID
        self.taskSummary = taskSummary
    }
}
