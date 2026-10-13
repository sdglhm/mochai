import OSLog

public enum MochaiLog {
    public static let app = Logger(subsystem: AppIdentity.logSubsystem, category: "app")
    public static let claude = Logger(subsystem: AppIdentity.logSubsystem, category: "provider.claude")
    public static let codex = Logger(subsystem: AppIdentity.logSubsystem, category: "provider.codex")
    public static let agents = Logger(subsystem: AppIdentity.logSubsystem, category: "agents")
    public static let power = Logger(subsystem: AppIdentity.logSubsystem, category: "power")
    public static let hooks = Logger(subsystem: AppIdentity.logSubsystem, category: "hooks")
    public static let usage = Logger(subsystem: AppIdentity.logSubsystem, category: "usage")
    public static let resume = Logger(subsystem: AppIdentity.logSubsystem, category: "resume")
    public static let notifications = Logger(subsystem: AppIdentity.logSubsystem, category: "notifications")
}
