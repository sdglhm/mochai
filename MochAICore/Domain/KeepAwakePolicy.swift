import Foundation

public struct BatterySnapshot: Equatable, Sendable {
    public var onBattery: Bool
    public var percent: Double?
    public var charging: Bool

    public init(onBattery: Bool, percent: Double?, charging: Bool) {
        self.onBattery = onBattery
        self.percent = percent
        self.charging = charging
    }

    public static let pluggedIn = BatterySnapshot(onBattery: false, percent: nil, charging: true)
    public static let unknown = BatterySnapshot(onBattery: false, percent: nil, charging: false)
}

public enum KeepAwakePolicy {
    public static func shouldHold(
        sessions: [AgentSession],
        projects: [ProjectPolicy],
        mode: KeepAwakeMode,
        until: Date?,
        batteryPolicy: BatteryKeepAwake,
        battery: BatterySnapshot,
        now: Date
    ) -> Bool {
        switch mode {
        case .never:
            return false
        case .untilTurnedOff:
            return true
        case .thirtyMinutes, .oneHour:
            if let until, until > now { return batteryAllows(batteryPolicy, battery) }
            return automaticNeed(sessions: sessions, projects: projects) && batteryAllows(batteryPolicy, battery)
        case .automatic:
            return automaticNeed(sessions: sessions, projects: projects) && batteryAllows(batteryPolicy, battery)
        }
    }

    public static func automaticNeed(sessions: [AgentSession], projects: [ProjectPolicy]) -> Bool {
        sessions.contains { session in
            guard session.state.preventsSystemSleep else { return false }
            guard session.outcome == .ongoing else { return false }
            if let path = session.repositoryRoot ?? session.projectDirectory,
               let project = projects.first(where: { $0.path == path || $0.id == path }),
               project.preventSleep == false {
                return false
            }
            return true
        }
    }

    public static func batteryAllows(_ policy: BatteryKeepAwake, _ battery: BatterySnapshot) -> Bool {
        guard battery.onBattery else { return true }
        switch policy {
        case .always:
            return true
        case .neverOnBattery:
            return false
        case .aboveTwenty:
            guard let percent = battery.percent else { return true }
            return percent >= 20
        }
    }
}
