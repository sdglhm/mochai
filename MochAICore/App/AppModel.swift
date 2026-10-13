import Foundation

@MainActor
@Observable
public final class AppModel {
    public let settings: SettingsStore
    public private(set) var sessions: [AgentSession] = []
    public private(set) var history: [AgentSession] = []
    public private(set) var projects: [ProjectPolicy] = []
    public private(set) var usage: [ProviderID: ProviderUsage] = [:]
    public private(set) var tokenCosts: [ProviderID: TokenCost] = [:]
    public private(set) var installations: [ProviderID: ProviderInstallation] = [:]
    public private(set) var health: [ProviderID: IntegrationHealth] = [:]
    public private(set) var sleepStatus: SleepStatus = .napping
    public private(set) var battery: BatterySnapshot = .unknown
    public private(set) var banner: String?
    public var selectedSessionID: UUID?
    public private(set) var started = false
    /// True while Cursor's Agents window is open, so a short burst of work is not averaged away.
    private var watchingCursor = false

    public var liveSessions: [AgentSession] {
        sessions.filter { $0.outcome == .ongoing || $0.state.isLimited || $0.state == .failed }
    }

    public func isWorking(_ provider: ProviderID) -> Bool {
        liveSessions.contains { $0.provider == provider && $0.state.preventsSystemSleep }
    }

    /// The green mark follows a working agent, and also stays while keep-awake is holding on its own.
    public var showsActivityDot: Bool {
        sleepStatus.holding || liveSessions.contains { $0.state.preventsSystemSleep }
    }

    public var phase: MenuBarPhase { StatusPresentation.phase(sessions: liveSessions) }
    public var headline: String {
        let recent = history.filter { session in
            guard let completed = session.completedAt else { return false }
            return Date().timeIntervalSince(completed) < 20 * 60
        }
        return StatusPresentation.headline(sessions: sessions + recent)
    }
    public var detail: String { StatusPresentation.detail(sleeping: sleepStatus.holding, sessions: liveSessions) }
    public var mascot: MascotPose {
        let recent = history.contains { session in
            guard let completed = session.completedAt else { return false }
            return Date().timeIntervalSince(completed) < 20 * 60
        }
        return StatusPresentation.mascot(phase: phase, recentlyCompleted: recent && liveSessions.isEmpty)
    }
    public var queue: [QueueEntry] { StatusPresentation.queue(active: sessions, history: history, now: Date()) }
    public var menuBarText: String? {
        StatusPresentation.menuBarText(
            mode: settings.menuBarDisplay,
            sessions: liveSessions,
            usage: usage,
            holding: sleepStatus.holding,
            now: Date()
        )
    }

    private let repository: any SessionRepository
    private let registry: ProviderRegistry
    private let sleep: SleepManager
    private let processes: ProcessWatch
    private let events: LocalEventServer
    private let notifications: NotificationManager
    private var deduplicator = EventDeduplicator()
    private var lastTick = Date()
    private var dirty = false
    private var gitCache: [String: (date: Date, info: GitInfo?)] = [:]
    private var lastUsageRefresh = Date.distantPast
    private var lastCostScan = Date.distantPast
    private var usageCheckAttempts: [String: Int] = [:]
    private var resumingIDs = Set<String>()
    private var notified = Set<String>()
    private var loopTask: Task<Void, Never>?
    private let launch: LaunchOptions

    public init(
        settings: SettingsStore? = nil,
        repository: (any SessionRepository)? = nil,
        registry: ProviderRegistry = ProviderRegistry(),
        sleep: SleepManager? = nil,
        processes: ProcessWatch = ProcessWatch(),
        events: LocalEventServer = LocalEventServer(),
        notifications: NotificationManager? = nil,
        launch: LaunchOptions = LaunchOptions()
    ) {
        let loginItems: LoginItemControlling = launch.uiTesting || Bundle.main.bundleURL.pathExtension != "app"
            ? DisabledLoginItemController()
            : SystemLoginItemController()
        self.settings = settings ?? SettingsStore(defaults: .standard, loginItems: loginItems)
        if let repository {
            self.repository = repository
        } else if let stored = try? SwiftDataRepository.make() {
            self.repository = stored
        } else {
            self.repository = MemoryRepository()
        }
        self.registry = registry
        self.sleep = sleep ?? SleepManager()
        self.processes = processes
        self.events = events
        self.notifications = notifications ?? NotificationManager()
        self.launch = launch
    }

    public func start() async {
        guard !started else { return }
        started = true
        AppRuntime.model = self
        try? AppPaths.ensureSupportDirectories()
        settings.persist()
        await restore()
        notifications.registerCategories()
        notifications.onAction = { [weak self] action, sessionID in
            self?.handle(action, sessionID: sessionID)
        }
        events.onPayload = { [weak self] data in
            Task { @MainActor in
                self?.ingest(data)
            }
        }
        if !launch.uiTesting {
            try? ensureClaudeStatusLine()
            do {
                try events.start(socketPath: AppPaths.socketURL.path)
            } catch {
                banner = "MochAI will catch up in a moment."
                MochaiLog.hooks.error("Socket failed to start")
            }
        }
        await refreshProviders()
        settleAttention(now: Date())
        recompute(now: Date())
        loopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.tick()
                let nanoseconds = await MainActor.run { self.nanosecondsUntilNextTick() }
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
        }
        if launch.useMock {
            simulate(.working)
        }
    }

    public func flush() {
        persist()
    }

    public func shutdown() {
        loopTask?.cancel()
        events.stop()
        sleep.release()
        persist()
    }

    public func handleWake() async {
        await refreshProviders()
        await tick()
    }

    public func installIntegration(_ provider: ProviderID) async {
        do {
            let command = try prepareHookCommand(for: provider)
            let plan: HookInstallPlan
            let config: URL
            switch provider {
            case .claude:
                plan = registry.claude.installPlan(command: command, statusLineCommand: statusLineCommand(from: command))
                config = registry.claude.settingsURL
            case .codex:
                plan = registry.codex.installPlan(command: command)
                config = registry.codex.hooksURL
            case .cursor, .openCodeGo, .antigravity, .mock:
                return
            }
            let result = try HookInstaller.install(
                configURL: config,
                plan: plan,
                backupDirectory: AppPaths.backupsDirectory
            )
            try saveReceipt(IntegrationReceipt(
                provider: provider.rawValue,
                configPath: result.configPath,
                createdFile: result.createdFile,
                installedAt: Date(),
                command: command
            ))
            banner = "\(provider.displayName) is connected."
            await refreshProviders()
        } catch {
            banner = error.localizedDescription
            MochaiLog.hooks.error("Integration install failed")
        }
    }

    public func removeIntegration(_ provider: ProviderID) async {
        let receipts = loadReceipts()
        let receipt = receipts.first { $0.provider == provider.rawValue }
        let config: URL
        switch provider {
        case .claude: config = registry.claude.settingsURL
        case .codex: config = registry.codex.hooksURL
        case .cursor, .openCodeGo, .antigravity, .mock: return
        }
        do {
            try HookInstaller.uninstall(
                configURL: receipt.map { URL(fileURLWithPath: $0.configPath) } ?? config,
                marker: AppIdentity.hookCommandMarker,
                createdFile: receipt?.createdFile ?? false,
                backupDirectory: AppPaths.backupsDirectory
            )
            try saveReceipts(receipts.filter { $0.provider != provider.rawValue })
            banner = "Removed MochAI from \(provider.displayName)."
            await refreshProviders()
        } catch {
            banner = error.localizedDescription
        }
    }

    public func repairIntegration(_ provider: ProviderID) async {
        await removeIntegration(provider)
        await installIntegration(provider)
    }

    public func continueSession(_ id: UUID) async {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        await resume(index: index, automatic: false)
    }

    public func cancelSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].resume.manuallyCancelled = true
        sessions[index].resume.readiness = .cancelled
        SessionReducer.transition(&sessions[index], to: .completed, title: "Cancelled", at: Date())
        sessions[index].outcome = .interrupted
        sessions[index].completedAt = Date()
        archiveIfNeeded(id)
        banner = "MochAI won't resume that session."
        recompute(now: Date())
    }

    public func armAutomaticResume(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        if let path = session.repositoryRoot ?? session.projectDirectory {
            upsertProject(path: path) { project in
                project.autoResume = .automatic
                project.providerResume[session.provider.rawValue] = .automatic
            }
        }
        banner = "MochAI will continue \(session.projectTitle) when usage is available."
    }

    public func notifyOnly(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let path = sessions[index].repositoryRoot ?? sessions[index].projectDirectory
        if let path {
            upsertProject(path: path) { project in
                project.autoResume = .notifyOnly
            }
        } else {
            settings.resumeMode = .notifyOnly
            settings.persist()
        }
        banner = "MochAI will only notify you when usage returns."
    }

    public func updateProject(_ project: ProjectPolicy) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.append(project)
        }
        persist()
        recompute(now: Date())
    }

    public func applySettings() {
        settings.persist()
        if !settings.showTokenCost { tokenCosts = [:] }
        recompute(now: Date())
        Task { await refreshTokenCosts(force: true) }
    }

    public func finishOnboarding() {
        settings.hasCompletedOnboarding = true
        settings.persist()
    }

    public func requestNotifications() async {
        _ = await notifications.requestAuthorization()
    }

    public func handle(_ action: MochaiNotificationAction, sessionID: UUID?) {
        guard let sessionID else { return }
        switch action {
        case .openProject:
            if let path = session(sessionID)?.projectDirectory ?? session(sessionID)?.repositoryRoot {
                TerminalLauncher.openFolder(path)
            }
        case .openTerminal:
            if let path = session(sessionID)?.projectDirectory {
                TerminalLauncher.openFolder(path)
            }
        case .resumeAtReset, .continueSession:
            Task { await continueSession(sessionID) }
        case .notifyOnly:
            notifyOnly(sessionID)
        case .viewDetails:
            selectedSessionID = sessionID
        }
    }

    public func simulate(_ state: AgentState) {
        let now = Date()
        var session = AgentSession(
            provider: .claude,
            providerSessionID: "preview-\(UUID().uuidString.prefix(8))",
            projectDirectory: NSHomeDirectory() + "/Projects/preview",
            repositoryName: "Preview",
            state: state,
            lastEventSummary: state.label,
            taskSummary: "Preview task",
            startedAt: now.addingTimeInterval(-600),
            lastActivityAt: now,
            terminalApp: "Ghostty",
            resume: ResumeMetadata(exactResumeAvailable: true, readiness: state.isLimited ? .scheduled : .none)
        )
        if state.isLimited {
            session.limit = LimitInfo(detectedAt: now, resetAt: now.addingTimeInterval(30), errorCode: "rate_limit")
            session.outcome = .limited
        }
        SessionReducer.transition(&session, to: state, title: state.label, at: now)
        session.usage = ProviderUsage(
            windows: [UsageWindow(name: "5-hour allowance", usedFraction: 1, remainingFraction: 0, resetAt: now.addingTimeInterval(30))],
            updatedAt: now,
            confidence: .locallyEstimated,
            detail: "Preview data."
        )
        sessions.append(session)
        recompute(now: now)
    }

    public func metrics(since date: Date) -> HistoryMetrics {
        let relevant = (sessions + history).filter { $0.startedAt >= date || ($0.completedAt ?? .distantPast) >= date }
        return HistoryCalculator.metrics(for: relevant)
    }

    public func usageSeries(for provider: ProviderID) -> [(date: Date, used: Double)] {
        (try? repository.usageHistory(provider: provider, since: Date().addingTimeInterval(-30 * 24 * 3600))) ?? []
    }

    public func session(_ id: UUID) -> AgentSession? {
        sessions.first { $0.id == id } ?? history.first { $0.id == id }
    }

    private func tick() async {
        let now = Date()
        LocalEventServer.drainFallbackDirectory(AppPaths.eventsDirectory) { [weak self] data in
            Task { @MainActor in self?.ingest(data) }
        }
        if !launch.uiTesting {
            let tracked = processes.snapshot()
            watchingCursor = tracked.contains { $0.provider == .cursor }
            sessions = SessionReducer.reconcile(sessions: sessions, processes: tracked, now: now)
            enrich(tracked, now: now)
        }
        let due = dueUsageChecks(now: now)
        if now.timeIntervalSince(lastUsageRefresh) >= 60 || !due.isEmpty || sessionResetIsDue(now: now) {
            lastUsageRefresh = now
            await refreshProviders()
        }
        advanceUsageChecks(due, now: now)
        settleAttention(now: now)
        await considerResets(now: now)
        recompute(now: now)
        if dirty { persist() }
    }

    private func ingest(_ data: Data) {
        guard let event = HookEventTranslator.translate(data) else { return }
        guard deduplicator.accept(event) else { return }
        guard settings.providerEnabled(event.provider) else { return }
        let before = sessions.first { $0.providerSessionID == event.sessionID && $0.provider == event.provider }?.state
        sessions = SessionReducer.apply(event: event, to: sessions)
        if let index = sessions.lastIndex(where: { $0.provider == event.provider && ($0.providerSessionID == event.sessionID || event.sessionID == nil) }) {
            noteTransition(from: before, session: sessions[index])
            if event.kind == .rateLimitReached {
                usage[event.provider] = usage[event.provider] ?? ProviderUsage(
                    windows: [UsageWindow(name: "Current limit", usedFraction: nil, resetAt: event.resetAt)],
                    updatedAt: event.timestamp,
                    confidence: event.resetAt == nil ? .unavailable : .providerReported,
                    detail: "Reported by the provider when the limit was reached."
                )
            }
        }
        if settings.verboseLogging {
            MochaiLog.agents.debug("Accepted \(event.kind.rawValue, privacy: .public) from \(event.provider.rawValue, privacy: .public)")
        }
        dirty = true
        recompute(now: Date())
    }

    private func nanosecondsUntilNextTick(now: Date = Date()) -> UInt64 {
        let active = liveSessions.contains { $0.outcome == .ongoing }
        var interval: TimeInterval = active || watchingCursor ? 2 : 8
        var upcoming = [lastUsageRefresh.addingTimeInterval(60)]
        for (provider, snapshot) in usage {
            for window in snapshot.windows {
                guard let reset = window.resetAt else { continue }
                let attempt = usageCheckAttempts[usageCheckKey(provider, window)] ?? 0
                if let when = ResetSchedule.nextAttemptDate(attempt: attempt, resetAt: reset) {
                    upcoming.append(when)
                }
            }
        }
        for session in sessions where session.state == .waitingForReset {
            if let limit = session.limit, let reset = limit.resetAt, limit.retriesExhausted != true,
               let when = ResetSchedule.nextAttemptDate(attempt: limit.attempt, resetAt: reset) {
                upcoming.append(when)
            }
        }
        if let next = upcoming.filter({ $0 > now }).min() {
            interval = min(interval, max(0.5, next.timeIntervalSince(now)))
        }
        return UInt64(interval * 1_000_000_000)
    }

    private struct UsageCheck {
        var key: String
        var reset: Date
    }

    private func dueUsageChecks(now: Date) -> [UsageCheck] {
        var checks: [UsageCheck] = []
        for (provider, snapshot) in usage {
            for window in snapshot.windows {
                guard let reset = window.resetAt else { continue }
                let key = usageCheckKey(provider, window)
                let attempt = usageCheckAttempts[key] ?? 0
                if ResetSchedule.isDue(attempt: attempt, resetAt: reset, now: now) {
                    checks.append(UsageCheck(key: key, reset: reset))
                }
            }
        }
        return checks
    }

    private func advanceUsageChecks(_ checks: [UsageCheck], now: Date) {
        for check in checks {
            var attempt = usageCheckAttempts[check.key] ?? 0
            while ResetSchedule.isDue(attempt: attempt, resetAt: check.reset, now: now) {
                attempt += 1
                if attempt >= ResetSchedule.offsets.count { break }
            }
            usageCheckAttempts[check.key] = attempt
        }
        var live = Set<String>()
        for (provider, snapshot) in usage {
            for window in snapshot.windows where window.resetAt != nil {
                live.insert(usageCheckKey(provider, window))
            }
        }
        usageCheckAttempts = usageCheckAttempts.filter { live.contains($0.key) }
    }

    private func usageCheckKey(_ provider: ProviderID, _ window: UsageWindow) -> String {
        let reset = window.resetAt?.timeIntervalSince1970 ?? 0
        return "\(provider.rawValue)|\(window.name)|\(Int(reset))"
    }

    private func sessionResetIsDue(now: Date) -> Bool {
        sessions.contains { session in
            guard session.state == .waitingForReset,
                  let limit = session.limit,
                  limit.retriesExhausted != true,
                  let reset = limit.resetAt else { return false }
            return ResetSchedule.isDue(attempt: limit.attempt, resetAt: reset, now: now)
        }
    }

    private func considerResets(now: Date) async {
        for index in sessions.indices where sessions[index].state == .waitingForReset && sessions[index].limit?.retriesExhausted != true {
            guard var limit = sessions[index].limit else { continue }
            let provider = sessions[index].provider
            let current = usage[provider] ?? .unavailable(at: now, detail: "Usage has not been read yet.")
            let decision = resumeDecision(for: sessions[index])
            let result = ResetCoordinator.decide(
                attempt: limit.attempt,
                resetAt: limit.resetAt,
                usage: current,
                resume: decision,
                now: now
            )
            switch result.action {
            case .wait:
                continue
            case .stillLimited(let next, let exhausted):
                limit.attempt = next
                limit.retriesExhausted = exhausted
                limit.nextAttemptAt = limit.resetAt.flatMap { ResetSchedule.nextAttemptDate(attempt: next, resetAt: $0) }
                sessions[index].limit = limit
                dirty = true
            case .ready(let automatic):
                sessions[index].resume.readiness = .ready
                SessionReducer.transition(&sessions[index], to: .idle, title: "Ready again", at: now)
                sessions[index].outcome = .ongoing
                notifyOnce("ready-\(sessions[index].id.uuidString)", title: "\(provider.displayName) is ready again.", body: result.message, category: "available", session: sessions[index])
                dirty = true
                if automatic {
                    let delay = settings.autoResumeDelay
                    let id = sessions[index].id
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        await self?.continueSession(id)
                    }
                }
            case .unconfirmed:
                sessions[index].resume.readiness = .ready
                limit.retriesExhausted = true
                sessions[index].limit = limit
                SessionReducer.transition(&sessions[index], to: .idle, title: "Reset time passed", at: now)
                notifyOnce("unconfirmed-\(sessions[index].id.uuidString)", title: "\(provider.displayName) may be available.", body: result.message, category: "available", session: sessions[index])
                dirty = true
            }
        }
    }

    private func resume(index: Int, automatic: Bool) async {
        var session = sessions[index]
        let provider = registry.provider(for: session.provider)
        let decision = resumeDecision(for: session)
        if let reason = decision.reason, !decision.automaticAllowed && automatic {
            session.resume.readiness = .blocked
            session.resume.blockedReason = reason
            sessions[index] = session
            banner = reason
            return
        }
        if let reason = ResumePolicy.blockReason(context(for: session)), automatic || reason.contains("cancelled") || reason.contains("identity") || reason.contains("folder") {
            session.resume.blockedReason = reason
            sessions[index] = session
            banner = reason
            return
        }
        let key = session.providerSessionID ?? session.id.uuidString
        if resumingIDs.contains(key) {
            banner = "This session is already resuming."
            return
        }
        resumingIDs.insert(key)
        SessionReducer.transition(&sessions[index], to: .resuming, title: "Resuming", at: Date())
        let prompt = settings.continuationPrompt
        do {
            let launch = try await provider.resume(session: session, prompt: prompt)
            sessions[index].resume.exactResumeAvailable = launch.exact
            sessions[index].resume.readiness = .resuming
            banner = launch.exact ? "MochAI resumed your session." : launch.summary
            if settings.notifications.resume {
                notifications.post(
                    identifier: "resumed-\(session.id.uuidString)",
                    title: "MochAI resumed \(session.provider.displayName).",
                    body: "\(session.projectTitle) is starting again.",
                    sessionID: session.id,
                    category: "available"
                )
            }
        } catch {
            SessionReducer.transition(&sessions[index], to: .failed, title: "Couldn't resume", at: Date())
            banner = error.localizedDescription
        }
        resumingIDs.remove(key)
        dirty = true
        recompute(now: Date())
    }

    private func resumeDecision(for session: AgentSession) -> ResumeDecision {
        ResumePolicy.evaluate(context(for: session))
    }

    private func context(for session: AgentSession) -> ResumeContext {
        let path = session.repositoryRoot ?? session.projectDirectory
        let project = path.flatMap { value in projects.first { $0.path == value || $0.id == value } }
        let directory = path ?? ""
        let exists = directory.isEmpty ? false : FileManager.default.fileExists(atPath: directory)
        var identityMatches = true
        if let stored = session.resume.originURL, exists, let info = GitInspector.inspect(directory: directory), let origin = info.origin {
            identityMatches = origin == stored
        }
        let names = session.provider.executableNames
        let executableOK = session.provider == .mock || ExecutableLocator.isValidExecutable(session.executablePath ?? ExecutableLocator.locate(names.first ?? "")?.path ?? "", names: names)
        let duplicate = session.providerSessionID.map { resumingIDs.contains($0) } ?? false
        let limited = AvailabilityCheck.evaluate(usage: usage[session.provider] ?? .unavailable(at: Date(), detail: ""), now: Date()) 
        let stillLimited: Bool = {
            if case .limited = limited { return true }
            return false
        }()
        return ResumeContext(
            globalMode: settings.resumeMode,
            providerMode: settings.providerResume(session.provider),
            projectMode: project?.providerResume[session.provider.rawValue] ?? project?.autoResume,
            providerEnabled: settings.providerEnabled(session.provider),
            sensitiveProject: project?.sensitive ?? false,
            repositoryExists: exists || session.provider == .mock,
            identityMatches: identityMatches,
            manuallyCancelled: session.resume.manuallyCancelled,
            duplicateResume: duplicate,
            providerLimited: stillLimited,
            integrationHealthy: health[session.provider]?.isHealthy ?? true,
            metadataValid: session.providerSessionID != nil || session.projectDirectory != nil,
            executableValid: executableOK || session.provider == .mock
        )
    }

    private func noteTransition(from previous: AgentState?, session: AgentSession) {
        guard previous != session.state else { return }
        let prefs = notificationPrefs(for: session)
        switch session.state {
        case .waitingForPermission:
            if prefs.needsInput {
                notifyOnce("input-\(session.id.uuidString)-\(session.state.rawValue)", title: "\(session.provider.displayName) needs you.", body: session.projectTitle, category: "input", session: session)
            }
        case .waitingForReset:
            if prefs.rateLimits {
                let when = session.limit?.resetAt.map { "Resets at \(MochaiFormat.clock($0))." } ?? "Reset time wasn't reported."
                notifyOnce("limit-\(session.id.uuidString)", title: "\(session.provider.displayName) reached its usage limit.", body: when, category: "limit", session: session)
            }
        case .completed:
            if prefs.completion, session.outcome == .completed {
                notifyOnce("done-\(session.id.uuidString)", title: "\(session.provider.displayName) finished.", body: session.projectTitle, category: "completion", session: session)
            }
        case .failed:
            if prefs.errors {
                notifyOnce("fail-\(session.id.uuidString)", title: "\(session.provider.displayName) exited unexpectedly.", body: session.projectTitle, category: "failed", session: session)
            }
        default:
            break
        }
    }

    private func notifyOnce(_ key: String, title: String, body: String, category: String, session: AgentSession) {
        guard notified.insert(key).inserted else { return }
        notifications.post(identifier: key, title: title, body: body, sessionID: session.id, category: category)
    }

    private func notificationPrefs(for session: AgentSession) -> NotificationPreferences {
        let path = session.repositoryRoot ?? session.projectDirectory
        if let path, let project = projects.first(where: { $0.path == path }), let custom = project.notifications {
            return custom
        }
        return settings.notifications
    }

    private func enrich(_ tracked: [TrackedProcess], now: Date) {
        let titles = CodexMetadata.sessionTitles()
        for index in sessions.indices where sessions[index].outcome == .ongoing {
            if sessions[index].provider == .codex, let sid = sessions[index].providerSessionID, sessions[index].taskSummary == nil {
                sessions[index].taskSummary = titles[sid]
            }
            guard let directory = sessions[index].projectDirectory else { continue }
            let cached = gitCache[directory]
            if cached == nil || now.timeIntervalSince(cached?.date ?? .distantPast) > 30 {
                let info = GitInspector.inspect(directory: directory)
                gitCache[directory] = (now, info)
            }
            if let info = gitCache[directory]?.info {
                sessions[index].repositoryRoot = info.root
                sessions[index].repositoryName = URL(fileURLWithPath: info.root).lastPathComponent
                sessions[index].branch = info.branch
                sessions[index].hasRepositoryChanges = info.hasChanges
                sessions[index].resume.repositoryRoot = info.root
                sessions[index].resume.originURL = info.origin ?? sessions[index].resume.originURL
                ensureProject(path: info.root, name: sessions[index].repositoryName ?? "Project")
            } else {
                ensureProject(path: directory, name: sessions[index].projectTitle)
            }
            if let match = tracked.first(where: { $0.pid == sessions[index].processID }) {
                sessions[index].executablePath = match.executablePath
                sessions[index].resume.executablePath = match.executablePath
            }
        }
    }

    private func ensureProject(path: String, name: String) {
        guard projects.contains(where: { $0.path == path }) == false else { return }
        projects.append(ProjectPolicy(name: name, path: path))
        dirty = true
    }

    private func upsertProject(path: String, mutate: (inout ProjectPolicy) -> Void) {
        if let index = projects.firstIndex(where: { $0.path == path }) {
            mutate(&projects[index])
        } else {
            var project = ProjectPolicy(name: URL(fileURLWithPath: path).lastPathComponent, path: path)
            mutate(&project)
            projects.append(project)
        }
        dirty = true
        persist()
    }

    private func recompute(now: Date) {
        let delta = max(0, min(30, now.timeIntervalSince(lastTick)))
        if sleepStatus.holding {
            for index in sessions.indices where sessions[index].state.preventsSystemSleep {
                sessions[index].awakeSeconds += delta
            }
        }
        lastTick = now
        battery = launch.uiTesting ? .pluggedIn : BatteryMonitor.snapshot()
        sleep.update(
            sessions: sessions,
            projects: projects,
            mode: settings.keepAwakeMode,
            until: settings.keepAwakeUntil,
            batteryPolicy: settings.batteryPolicy,
            battery: battery,
            now: now
        )
        sleepStatus = sleep.status
        archiveFinished()
        if battery.onBattery, settings.batteryPolicy == .neverOnBattery, liveSessions.contains(where: \.state.preventsSystemSleep) {
            banner = "An agent is working, and keep-awake is off while you're on battery."
        }
    }

    private func archiveFinished() {
        let finished = sessions.filter { $0.outcome == .completed || $0.outcome == .interrupted }
        guard !finished.isEmpty else { return }
        let keepLimited = sessions.filter { $0.outcome == .ongoing || $0.outcome == .limited || $0.state == .waitingForReset || $0.resume.readiness == .ready || $0.resume.readiness == .resuming }
        let removed = Set(finished.map(\.id)).subtracting(keepLimited.map(\.id))
        guard !removed.isEmpty else { return }
        history.append(contentsOf: sessions.filter { removed.contains($0.id) })
        sessions.removeAll { removed.contains($0.id) }
        dirty = true
    }

    private func archiveIfNeeded(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        history.append(session)
        sessions.removeAll { $0.id == id }
        dirty = true
    }

    private func restore() async {
        sessions = (try? repository.loadActive()) ?? []
        history = (try? repository.loadHistory()) ?? []
        projects = (try? repository.loadProjects()) ?? []
        if let seconds = settings.historyRetention.seconds {
            try? repository.pruneHistory(before: Date().addingTimeInterval(-seconds))
            history = (try? repository.loadHistory()) ?? history
        }
    }

    private func persist() {
        do {
            try repository.saveActive(sessions)
            try repository.saveHistory(history)
            try repository.saveProjects(projects)
            dirty = false
        } catch {
            MochaiLog.app.error("Could not save local history")
        }
    }

    private func settleAttention(now: Date) {
        let finished = SessionReducer.releaseFinishedTurns(sessions: sessions, now: now)
        let next = SessionReducer.releaseExhaustedAttention(sessions: finished, usage: usage, now: now)
        guard next != sessions else { return }
        sessions = next
        dirty = true
    }

    public func showsInMenu(_ provider: ProviderID) -> Bool {
        guard provider.isUserFacing, settings.providerEnabled(provider) else { return false }
        if provider.appearsWhenInstalled {
            return installations[provider]?.installed == true
        }
        return true
    }

    private func refreshProviders() async {
        for provider in registry.userFacing {
            let installation = await provider.detectInstallation()
            installations[provider.id] = installation
            if settings.providerEnabled(provider.id) {
                if let current = try? await provider.currentUsage() {
                    usage[provider.id] = current
                    try? repository.appendUsage(provider: provider.id, usage: current)
                }
            }
            let last = sessions.filter { $0.provider == provider.id }.map(\.lastActivityAt).max()
            health[provider.id] = await provider.validateIntegration(socketAlive: events.isRunning, lastEventAt: last)
        }
        await refreshTokenCosts()
    }

    private func refreshTokenCosts(force: Bool = false) async {
        guard settings.showTokenCost else {
            tokenCosts = [:]
            return
        }
        var next = tokenCosts
        next[.cursor] = usage[.cursor]?.tokenCost
        let due = force || Date().timeIntervalSince(lastCostScan) >= 15 * 60
        if due {
            lastCostScan = Date()
            let catalog = await TokenCostCatalogStore.load()
            let claudeDirectory = URL(fileURLWithPath: registry.claude.homeDirectory).appendingPathComponent(".claude/projects")
            let codexDirectory = registry.codex.sessionsDirectory
            let scanned = await Task.detached(priority: .utility) {
                (
                    TokenCostScanner.monthToDate(provider: .claude, directory: claudeDirectory, catalog: catalog),
                    TokenCostScanner.monthToDate(provider: .codex, directory: codexDirectory, catalog: catalog)
                )
            }.value
            next[.claude] = scanned.0
            next[.codex] = scanned.1
        }
        tokenCosts = next
    }

    private func ensureClaudeStatusLine() throws {
        let settings = registry.claude.settingsURL
        guard let data = try? Data(contentsOf: settings),
              ConfigMerger.containsMarker(data, marker: AppIdentity.hookCommandMarker) else { return }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let status = object["statusLine"] as? [String: Any],
           let command = status["command"] as? String,
           command.contains("--statusline") {
            return
        }
        let command = try prepareHookCommand(for: .claude)
        let plan = registry.claude.installPlan(command: command, statusLineCommand: statusLineCommand(from: command))
        _ = try HookInstaller.install(configURL: settings, plan: plan, backupDirectory: AppPaths.backupsDirectory)
        banner = "Claude's limits will appear after the next reply."
    }

    private func statusLineCommand(from hookCommand: String) -> String {
        if let range = hookCommand.range(of: " --provider ") {
            return String(hookCommand[..<range.lowerBound]) + " --statusline"
        }
        return hookCommand + " --statusline"
    }

    private func prepareHookCommand(for provider: ProviderID) throws -> String {
        guard let source = Bundle.main.url(forAuxiliaryExecutable: "mochai-hook") else {
            throw HookInstallerError.binaryMissing
        }
        let destination = AppPaths.hookBinaryURL
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return "\(ShellQuoting.singleQuote(destination.path)) --provider \(provider.rawValue)"
    }

    private func loadReceipts() -> [IntegrationReceipt] {
        guard let data = try? Data(contentsOf: AppPaths.integrationReceiptURL),
              let decoded = try? JSONDecoder().decode([IntegrationReceipt].self, from: data) else { return [] }
        return decoded
    }

    private func saveReceipt(_ receipt: IntegrationReceipt) throws {
        var items = loadReceipts().filter { $0.provider != receipt.provider }
        items.append(receipt)
        try saveReceipts(items)
    }

    private func saveReceipts(_ items: [IntegrationReceipt]) throws {
        let data = try JSONEncoder().encode(items)
        try data.write(to: AppPaths.integrationReceiptURL, options: .atomic)
    }
}

public struct LaunchOptions: Sendable {
    public var uiTesting: Bool
    public var showOnboarding: Bool
    public var showDashboard: Bool
    public var showSettings: Bool
    public var useMock: Bool

    public init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        uiTesting = arguments.contains("--mochai-ui-testing")
        showOnboarding = arguments.contains("--show-onboarding")
        showDashboard = arguments.contains("--show-dashboard")
        showSettings = arguments.contains("--show-settings")
        useMock = arguments.contains("--use-mock")
    }
}

@MainActor
public enum AppRuntime {
    public static weak var model: AppModel?
}
