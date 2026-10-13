import Foundation

public struct PowerToken: Hashable, Sendable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

public protocol PowerAssertionControlling: AnyObject, Sendable {
    func begin(reason: String) -> PowerToken
    func end(_ token: PowerToken)
}

public final class SystemPowerAssertionController: PowerAssertionControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var activities: [UUID: NSObjectProtocol] = [:]

    public init() {}

    public func begin(reason: String) -> PowerToken {
        let token = PowerToken()
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: reason
        )
        lock.lock()
        activities[token.id] = activity
        lock.unlock()
        MochaiLog.power.info("Acquired sleep assertion")
        return token
    }

    public func end(_ token: PowerToken) {
        lock.lock()
        let activity = activities.removeValue(forKey: token.id)
        lock.unlock()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            MochaiLog.power.info("Released sleep assertion")
        }
    }

    deinit {
        let leftover: [NSObjectProtocol]
        lock.lock()
        leftover = Array(activities.values)
        activities.removeAll()
        lock.unlock()
        for activity in leftover {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }
}

public struct SleepStatus: Equatable, Sendable {
    public var holding: Bool
    public var reason: String
    public var displayMaySleep: Bool

    public init(holding: Bool, reason: String, displayMaySleep: Bool = true) {
        self.holding = holding
        self.reason = reason
        self.displayMaySleep = displayMaySleep
    }

    public static let napping = SleepStatus(
        holding: false,
        reason: "MochAI can nap",
        displayMaySleep: true
    )
}

@MainActor
public final class SleepManager {
    private let controller: PowerAssertionControlling
    private var token: PowerToken?
    public private(set) var status: SleepStatus = .napping
    public private(set) var assertionCount = 0

    public init(controller: PowerAssertionControlling = SystemPowerAssertionController()) {
        self.controller = controller
    }

    public func update(
        sessions: [AgentSession],
        projects: [ProjectPolicy],
        mode: KeepAwakeMode,
        until: Date?,
        batteryPolicy: BatteryKeepAwake,
        battery: BatterySnapshot,
        now: Date = Date()
    ) {
        let hold = KeepAwakePolicy.shouldHold(
            sessions: sessions,
            projects: projects,
            mode: mode,
            until: until,
            batteryPolicy: batteryPolicy,
            battery: battery,
            now: now
        )
        if hold {
            if token == nil {
                token = controller.begin(reason: AppIdentity.sleepReason)
                assertionCount += 1
            }
            status = SleepStatus(
                holding: true,
                reason: mode == .automatic
                    ? "MochAI is keeping your Mac awake"
                    : "MochAI is keeping your Mac awake",
                displayMaySleep: true
            )
        } else if let token {
            controller.end(token)
            self.token = nil
            status = .napping
        } else {
            status = .napping
        }
    }

    public func release() {
        if let token {
            controller.end(token)
            self.token = nil
        }
        status = .napping
    }

    public var isHolding: Bool { token != nil }
}
