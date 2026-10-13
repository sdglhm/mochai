import Foundation
import ServiceManagement

public protocol LoginItemControlling: Sendable {
    var isEnabled: Bool { get }
    var statusDescription: String { get }
    func setEnabled(_ enabled: Bool) throws
}

public struct SystemLoginItemController: LoginItemControlling {
    public init() {}

    public var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: "MochAI opens when you log in."
        case .requiresApproval: "macOS needs your approval in System Settings."
        case .notRegistered: "MochAI will not open at login."
        case .notFound: "MochAI will not open at login."
        default: "MochAI will not open at login."
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

public final class DisabledLoginItemController: LoginItemControlling, @unchecked Sendable {
    public var enabled = false
    public init() {}
    public var isEnabled: Bool { enabled }
    public var statusDescription: String { "MochAI will not open at login." }
    public func setEnabled(_ enabled: Bool) throws { self.enabled = enabled }
}

@MainActor
@Observable
public final class SettingsStore {
    public var launchAtLogin: Bool
    public var showDockIcon: Bool
    public var menuBarDisplay: MenuBarDisplayMode
    public var keepAwakeMode: KeepAwakeMode
    public var keepAwakeUntil: Date?
    public var resumeMode: ResumeMode
    public var autoResumeDelay: TimeInterval
    public var allowDisplaySleep: Bool
    public var batteryPolicy: BatteryKeepAwake
    public var notifications: NotificationPreferences
    public var providerOverrides: [String: ProviderOverride]
    public var historyRetention: HistoryRetention
    public var storeCommandNames: Bool
    public var verboseLogging: Bool
    public var crashReportsOptIn: Bool
    public var hasCompletedOnboarding: Bool
    public var continuationPrompt: String
    public var showTokenCost: Bool
    public var keepAwakeWhileWaitingForPermission: Bool
    public var loginStatus: String
    public var loginError: String?

    private let defaults: UserDefaults
    private let loginItems: LoginItemControlling

    public init(defaults: UserDefaults = .standard, loginItems: LoginItemControlling = SystemLoginItemController()) {
        self.defaults = defaults
        self.loginItems = loginItems
        launchAtLogin = loginItems.isEnabled
        showDockIcon = defaults.bool(forKey: Keys.showDock)
        menuBarDisplay = MenuBarDisplayMode(rawValue: defaults.string(forKey: Keys.menuBar) ?? "") ?? .iconOnly
        keepAwakeMode = KeepAwakeMode(rawValue: defaults.string(forKey: Keys.keepAwake) ?? "") ?? .automatic
        keepAwakeUntil = defaults.object(forKey: Keys.keepAwakeUntil) as? Date
        resumeMode = ResumeMode(rawValue: defaults.string(forKey: Keys.resume) ?? "") ?? .ask
        autoResumeDelay = defaults.object(forKey: Keys.delay) == nil ? 3 : defaults.double(forKey: Keys.delay)
        allowDisplaySleep = defaults.object(forKey: Keys.displaySleep) == nil ? true : defaults.bool(forKey: Keys.displaySleep)
        batteryPolicy = BatteryKeepAwake(rawValue: defaults.string(forKey: Keys.battery) ?? "") ?? .always
        if let data = defaults.data(forKey: Keys.notifications),
           let decoded = try? JSONDecoder().decode(NotificationPreferences.self, from: data) {
            notifications = decoded
        } else {
            notifications = NotificationPreferences()
        }
        if let data = defaults.data(forKey: Keys.providers),
           let decoded = try? JSONDecoder().decode([String: ProviderOverride].self, from: data) {
            providerOverrides = decoded
        } else {
            providerOverrides = [
                ProviderID.claude.rawValue: ProviderOverride(),
                ProviderID.codex.rawValue: ProviderOverride()
            ]
        }
        historyRetention = HistoryRetention(rawValue: defaults.string(forKey: Keys.retention) ?? "") ?? .ninetyDays
        storeCommandNames = defaults.bool(forKey: Keys.commands)
        verboseLogging = defaults.bool(forKey: Keys.verbose)
        crashReportsOptIn = defaults.bool(forKey: Keys.crash)
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarding)
        continuationPrompt = defaults.string(forKey: Keys.prompt) ?? AppIdentity.defaultContinuationPrompt
        showTokenCost = defaults.object(forKey: Keys.tokenCost) == nil ? true : defaults.bool(forKey: Keys.tokenCost)
        keepAwakeWhileWaitingForPermission = defaults.bool(forKey: Keys.permissionAwake)
        loginStatus = loginItems.statusDescription
    }

    public func persist() {
        defaults.set(showDockIcon, forKey: Keys.showDock)
        defaults.set(menuBarDisplay.rawValue, forKey: Keys.menuBar)
        defaults.set(keepAwakeMode.rawValue, forKey: Keys.keepAwake)
        defaults.set(keepAwakeUntil, forKey: Keys.keepAwakeUntil)
        defaults.set(resumeMode.rawValue, forKey: Keys.resume)
        defaults.set(autoResumeDelay, forKey: Keys.delay)
        defaults.set(allowDisplaySleep, forKey: Keys.displaySleep)
        defaults.set(batteryPolicy.rawValue, forKey: Keys.battery)
        if let data = try? JSONEncoder().encode(notifications) {
            defaults.set(data, forKey: Keys.notifications)
        }
        if let data = try? JSONEncoder().encode(providerOverrides) {
            defaults.set(data, forKey: Keys.providers)
        }
        defaults.set(historyRetention.rawValue, forKey: Keys.retention)
        defaults.set(storeCommandNames, forKey: Keys.commands)
        defaults.set(verboseLogging, forKey: Keys.verbose)
        defaults.set(crashReportsOptIn, forKey: Keys.crash)
        defaults.set(hasCompletedOnboarding, forKey: Keys.onboarding)
        defaults.set(continuationPrompt, forKey: Keys.prompt)
        defaults.set(showTokenCost, forKey: Keys.tokenCost)
        defaults.set(keepAwakeWhileWaitingForPermission, forKey: Keys.permissionAwake)
        writeHookPreferences()
    }

    public func updateLogin(_ enabled: Bool) {
        do {
            try loginItems.setEnabled(enabled)
            launchAtLogin = loginItems.isEnabled
            loginError = nil
        } catch {
            launchAtLogin = loginItems.isEnabled
            loginError = "macOS didn't accept the login item change. You can also add MochAI in System Settings."
            MochaiLog.app.error("Login item update failed")
        }
        loginStatus = loginItems.statusDescription
    }

    public func selectKeepAwake(_ mode: KeepAwakeMode, now: Date = Date()) {
        keepAwakeMode = mode
        switch mode {
        case .thirtyMinutes:
            keepAwakeUntil = now.addingTimeInterval(30 * 60)
        case .oneHour:
            keepAwakeUntil = now.addingTimeInterval(60 * 60)
        default:
            keepAwakeUntil = nil
        }
        persist()
    }

    public func providerEnabled(_ id: ProviderID) -> Bool {
        providerOverrides[id.rawValue]?.enabled ?? true
    }

    public func providerResume(_ id: ProviderID) -> ResumeMode? {
        providerOverrides[id.rawValue]?.resumeMode
    }

    private func writeHookPreferences() {
        let prefs = HookPreferences(storeCommandNames: storeCommandNames)
        guard let data = try? JSONEncoder().encode(prefs) else { return }
        try? AppPaths.ensureSupportDirectories()
        try? data.write(to: AppPaths.hookPreferencesURL, options: .atomic)
    }

    private enum Keys {
        static let showDock = "showDockIcon"
        static let menuBar = "menuBarDisplay"
        static let keepAwake = "keepAwakeMode"
        static let keepAwakeUntil = "keepAwakeUntil"
        static let resume = "resumeMode"
        static let delay = "autoResumeDelay"
        static let displaySleep = "allowDisplaySleep"
        static let battery = "batteryPolicy"
        static let notifications = "notificationPreferences"
        static let providers = "providerOverrides"
        static let retention = "historyRetention"
        static let commands = "storeCommandNames"
        static let verbose = "verboseLogging"
        static let crash = "crashReportsOptIn"
        static let onboarding = "hasCompletedOnboarding"
        static let prompt = "continuationPrompt"
        static let tokenCost = "showTokenCost"
        static let permissionAwake = "keepAwakeWhileWaitingForPermission"
    }
}
