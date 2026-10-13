import Foundation

public enum SessionReducer {
    public static let generationQuietInterval: TimeInterval = 180
    public static let commandQuietInterval: TimeInterval = 15 * 60
    public static let toolQuietInterval: TimeInterval = 10 * 60
    public static let unknownQuietInterval: TimeInterval = 90

    public static func apply(event: NormalizedEvent, to sessions: [AgentSession]) -> [AgentSession] {
        var sessions = sessions
        let match = index(of: event, in: sessions)
        var session = match.map { sessions[$0] } ?? makeSession(from: event)
        absorb(event, into: &session)
        if let match {
            sessions[match] = session
        } else {
            sessions.append(session)
        }
        return sessions
    }

    public static func reconcile(
        sessions: [AgentSession],
        processes: [TrackedProcess],
        now: Date
    ) -> [AgentSession] {
        var sessions = sessions
        var consumed = Set<Int32>()

        for index in sessions.indices {
            guard sessions[index].state.isLive || sessions[index].state == .resuming else { continue }
            if let pid = sessions[index].processID,
               let process = processes.first(where: { $0.pid == pid && $0.provider == sessions[index].provider }) {
                consumed.insert(pid)
                attach(process, to: &sessions[index], now: now)
                quietIfStale(&sessions[index], now: now)
            } else if let sid = sessions[index].providerSessionID,
                      let process = processes.first(where: {
                          $0.provider == sessions[index].provider && $0.providerSessionID == sid
                      }) {
                consumed.insert(process.pid)
                sessions[index].processID = process.pid
                attach(process, to: &sessions[index], now: now)
                quietIfStale(&sessions[index], now: now)
            } else if sessions[index].processID != nil {
                noteProcessGone(&sessions[index], now: now)
            } else {
                quietIfStale(&sessions[index], now: now)
            }
        }

        for process in processes where !consumed.contains(process.pid) {
            if process.provider == .cursor, !process.cpuActive { continue }
            if sessions.contains(where: { $0.processID == process.pid && $0.provider == process.provider && $0.outcome == .ongoing }) {
                continue
            }
            var session = AgentSession(
                provider: process.provider,
                processID: process.pid,
                parentProcessID: process.parentPID,
                providerSessionID: process.providerSessionID,
                projectDirectory: process.workingDirectory,
                state: .unknown,
                lastEventSummary: "Process detected. Waiting for activity.",
                taskSummary: process.taskSummary,
                startedAt: process.startedAt ?? now,
                lastActivityAt: now,
                terminalApp: process.terminalApp,
                executablePath: process.executablePath
            )
            transition(&session, to: .unknown, title: "Process detected", at: now)
            if process.cpuActive {
                transition(&session, to: .working, title: "Activity detected", at: now)
            }
            sessions.append(session)
        }
        return sessions
    }

    /// A finished turn is not an approval request. Codex's Stop hook used to leave the session
    /// looking like it needed the user, even when the Codex icon had no approval badge.
    public static func releaseFinishedTurns(sessions: [AgentSession], now: Date) -> [AgentSession] {
        var sessions = sessions
        for index in sessions.indices {
            guard sessions[index].outcome == .ongoing, sessions[index].state == .waitingForUser else { continue }
            transition(&sessions[index], to: .idle, title: "Turn finished", at: now)
        }
        return sessions
    }

    /// A permission or input prompt left over after the allowance is already spent is not a real request.
    public static func releaseExhaustedAttention(
        sessions: [AgentSession],
        usage: [ProviderID: ProviderUsage],
        now: Date
    ) -> [AgentSession] {
        var sessions = sessions
        for index in sessions.indices {
            let session = sessions[index]
            guard session.outcome == .ongoing else { continue }
            guard session.state == .waitingForUser || session.state == .waitingForPermission else { continue }
            guard let exhausted = usage[session.provider]?.exhaustedWindow(at: now) else { continue }
            var updated = session
            updated.limit = LimitInfo(
                detectedAt: now,
                resetAt: exhausted.resetAt,
                errorCode: "rate_limit",
                nextAttemptAt: exhausted.resetAt
            )
            updated.outcome = .limited
            updated.resume.readiness = .scheduled
            transition(&updated, to: .waitingForReset, title: "Usage limit reached", at: now)
            sessions[index] = updated
        }
        return sessions
    }

    public static func transition(_ session: inout AgentSession, to state: AgentState, title: String, at date: Date) {
        if session.intervals.isEmpty {
            session.intervals.append(StateInterval(state: state, startedAt: date, endedAt: nil))
            session.state = state
        } else if session.state != state {
            session.intervals[session.intervals.count - 1].endedAt = date
            session.intervals.append(StateInterval(state: state, startedAt: date, endedAt: nil))
            session.state = state
        }
        session.preventsSleep = state.preventsSystemSleep
        session.lastActivityAt = date
        session.lastEventSummary = title
        let last = session.timeline.last
        if last?.title != title || last?.state != state {
            session.timeline.append(TimelineEntry(timestamp: date, title: title, state: state))
            if session.timeline.count > 200 {
                session.timeline.removeFirst(session.timeline.count - 200)
            }
        }
    }

    private static func absorb(_ event: NormalizedEvent, into session: inout AgentSession) {
        let when = event.timestamp
        if let cwd = event.cwd, !cwd.isEmpty {
            session.projectDirectory = cwd
            if session.repositoryName == nil {
                session.repositoryName = URL(fileURLWithPath: cwd).lastPathComponent
            }
        }
        if let sid = event.sessionID, !sid.isEmpty {
            session.providerSessionID = sid
            session.resume.providerSessionID = sid
        }
        if let pid = event.processID {
            session.processID = pid
        }
        if let command = event.commandName, !command.isEmpty, session.taskSummary == nil {
            session.taskSummary = command
        }

        switch event.kind {
        case .sessionStarted:
            transition(&session, to: .starting, title: "Session started", at: when)
        case .promptSubmitted, .generationStarted:
            transition(&session, to: .working, title: "Working", at: when)
        case .generationStopped:
            transition(&session, to: .idle, title: "Turn finished", at: when)
        case .toolStarted:
            transition(&session, to: .runningTool, title: toolTitle(event, finished: false), at: when)
        case .toolFinished:
            transition(&session, to: .working, title: toolTitle(event, finished: true), at: when)
        case .commandStarted:
            transition(&session, to: .runningCommand, title: commandTitle(event, finished: false), at: when)
        case .commandFinished:
            transition(&session, to: .working, title: commandTitle(event, finished: true), at: when)
        case .waitingForUser:
            transition(&session, to: .idle, title: "Turn finished", at: when)
        case .permissionRequested:
            transition(&session, to: .waitingForPermission, title: "Waiting for permission", at: when)
        case .rateLimitReached:
            transition(&session, to: .rateLimited, title: "Usage limit reached", at: when)
            session.limit = LimitInfo(
                detectedAt: when,
                resetAt: event.resetAt,
                errorCode: event.errorCode ?? "rate_limit",
                nextAttemptAt: event.resetAt
            )
            session.outcome = .limited
            session.resume.readiness = .scheduled
            transition(&session, to: .waitingForReset, title: "Waiting for usage to reset", at: when)
        case .sessionEnded:
            if !session.state.isLimited {
                session.outcome = .completed
                session.completedAt = when
                transition(&session, to: .completed, title: "Session ended", at: when)
            }
        case .error:
            session.outcome = .failed
            session.completedAt = when
            transition(&session, to: .failed, title: "Stopped unexpectedly", at: when)
        case .resumeStarted:
            session.resume.readiness = .resuming
            transition(&session, to: .resuming, title: "Resuming", at: when)
        case .resumeFinished:
            session.resume.readiness = .resumed
            session.outcome = .ongoing
            transition(&session, to: .working, title: "Resumed", at: when)
        case .usageUpdated, .providerStarted, .providerStopped:
            session.lastActivityAt = when
        }
    }

    private static func attach(_ process: TrackedProcess, to session: inout AgentSession, now: Date) {
        session.parentProcessID = process.parentPID
        session.executablePath = process.executablePath
        session.terminalApp = process.terminalApp ?? session.terminalApp
        if let cwd = process.workingDirectory, session.projectDirectory == nil {
            session.projectDirectory = cwd
        }
        if let summary = process.taskSummary, session.taskSummary == nil {
            session.taskSummary = summary
        }
        if session.providerSessionID == nil {
            session.providerSessionID = process.providerSessionID
        }
        if process.cpuActive {
            if session.state == .unknown || session.state == .idle || session.state == .starting {
                transition(&session, to: .working, title: "Activity detected", at: now)
            } else if session.state.preventsSystemSleep {
                session.lastActivityAt = now
            }
        }
    }

    private static func noteProcessGone(_ session: inout AgentSession, now: Date) {
        session.processID = nil
        switch session.state {
        case .rateLimited, .waitingForReset, .completed, .failed:
            return
        case .waitingForUser, .waitingForPermission, .idle:
            session.outcome = .interrupted
            session.completedAt = now
            transition(&session, to: .completed, title: "Session closed", at: now)
        case .resuming:
            return
        default:
            session.outcome = .failed
            session.completedAt = now
            transition(&session, to: .failed, title: "Process ended unexpectedly", at: now)
        }
    }

    private static func quietIfStale(_ session: inout AgentSession, now: Date) {
        let idleFor = now.timeIntervalSince(session.lastActivityAt)
        let limit: TimeInterval
        switch session.state {
        case .runningCommand: limit = commandQuietInterval
        case .runningTool: limit = toolQuietInterval
        case .working, .starting, .resuming:
            limit = session.provider == .cursor ? 45 : generationQuietInterval
        case .unknown: limit = unknownQuietInterval
        default: return
        }
        if idleFor > limit {
            transition(&session, to: .idle, title: "Quiet", at: now)
        }
    }

    private static func makeSession(from event: NormalizedEvent) -> AgentSession {
        let directory = event.cwd
        let name = directory.map { URL(fileURLWithPath: $0).lastPathComponent }
        return AgentSession(
            provider: event.provider,
            processID: event.processID,
            providerSessionID: event.sessionID,
            projectDirectory: directory,
            repositoryName: name,
            state: .starting,
            lastEventSummary: "Session started",
            startedAt: event.timestamp,
            lastActivityAt: event.timestamp,
            resume: ResumeMetadata(providerSessionID: event.sessionID, exactResumeAvailable: event.sessionID != nil)
        )
    }

    private static func index(of event: NormalizedEvent, in sessions: [AgentSession]) -> Int? {
        if let sid = event.sessionID, !sid.isEmpty,
           let index = sessions.firstIndex(where: {
               $0.provider == event.provider && $0.providerSessionID == sid && $0.outcome == .ongoing
           }) {
            return index
        }
        if let pid = event.processID,
           let index = sessions.firstIndex(where: {
               $0.provider == event.provider && $0.processID == pid && $0.outcome == .ongoing
           }) {
            return index
        }
        if let cwd = event.cwd,
           let index = sessions.lastIndex(where: {
               $0.provider == event.provider && $0.projectDirectory == cwd && $0.outcome == .ongoing && $0.providerSessionID == nil
           }) {
            return index
        }
        return nil
    }

    private static func toolTitle(_ event: NormalizedEvent, finished: Bool) -> String {
        let category = event.toolCategory ?? "tool"
        switch category {
        case "edit": return finished ? "Finished editing" : "Editing files"
        case "read": return finished ? "Finished reading" : "Reading files"
        case "search": return finished ? "Search finished" : "Searching"
        case "test": return finished ? "Tests finished" : "Running tests"
        case "build": return finished ? "Build finished" : "Building"
        default: return finished ? "Tool finished" : "Using a tool"
        }
    }

    private static func commandTitle(_ event: NormalizedEvent, finished: Bool) -> String {
        if event.toolCategory == "test" { return finished ? "Tests finished" : "Running tests" }
        if event.toolCategory == "build" { return finished ? "Build finished" : "Building" }
        if let name = event.commandName, !name.isEmpty {
            return finished ? "\(name) finished" : "Running \(name)"
        }
        return finished ? "Command finished" : "Running a command"
    }
}
