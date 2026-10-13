import Charts
import SwiftUI

public enum DashboardSection: String, CaseIterable, Identifiable {
    case overview
    case agents
    case usage
    case history
    case projects
    case integrations

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: "Overview"
        case .agents: "Agents"
        case .usage: "Allowance"
        case .history: "History"
        case .projects: "Projects"
        case .integrations: "Connections"
        }
    }

    public var symbol: String {
        switch self {
        case .overview: "circle.hexagongrid"
        case .agents: "person.2"
        case .usage: "chart.bar"
        case .history: "clock"
        case .projects: "folder"
        case .integrations: "link"
        }
    }
}

public struct DashboardView: View {
    @Environment(AppModel.self) private var app
    @State private var section: DashboardSection = .overview
    @State private var selectedID: UUID?

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(DashboardSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
                    .accessibilityIdentifier("dashboard.\(item.rawValue)")
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .listStyle(.sidebar)
        } detail: {
            switch section {
            case .overview: OverviewPane(openAgents: { section = .agents })
            case .agents: AgentsPane(selectedID: $selectedID)
            case .usage: UsagePane()
            case .history: HistoryPane(selectedID: $selectedID)
            case .projects: ProjectsPane()
            case .integrations: IntegrationsPane()
            }
        }
        .navigationTitle(section.title)
        .frame(minWidth: 860, minHeight: 560)
    }
}

struct OverviewPane: View {
    @Environment(AppModel.self) private var app
    var openAgents: () -> Void

    var body: some View {
        let metrics = app.metrics(since: Calendar.current.startOfDay(for: Date()))
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 16) {
                    MascotView(pose: app.mascot, size: 88)
                        .overlay(alignment: .bottomTrailing) {
                            if app.showsActivityDot {
                                AwakeDot(diameter: 88 * 6 / 18)
                            }
                        }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Today")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(app.headline)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                        Text(app.detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    MetricTile(title: "AI Work", value: MochaiFormat.duration(metrics.activeTime))
                    MetricTile(title: "Mac Kept Awake", value: MochaiFormat.duration(metrics.awakeTime))
                    MetricTile(title: "Waiting for AI", value: MochaiFormat.duration(metrics.waitingTime))
                    MetricTile(title: "On a limit", value: MochaiFormat.duration(metrics.limitedTime))
                    MetricTile(title: "Active Agents", value: "\(app.liveSessions.filter(\.state.preventsSystemSleep).count)")
                    MetricTile(title: "Completed", value: "\(metrics.completed)")
                }
                Text("Current Agents")
                    .font(.headline)
                if app.liveSessions.isEmpty {
                    Text("No agent is working right now.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(app.liveSessions) { session in
                        Button(action: openAgents) {
                            QuietCard {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(session.provider.displayName).font(.system(size: 12)).foregroundStyle(.secondary)
                                            if session.state.preventsSystemSleep {
                                                AwakeDot(diameter: 7)
                                            }
                                        }
                                        Text(session.projectTitle).font(.system(size: 14, weight: .medium))
                                    }
                                    Spacer(minLength: 8)
                                    StatusPill(state: session.state)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(session.provider.displayName), \(session.projectTitle), \(session.state.label)")
                    }
                }
                Text("Upcoming Resets")
                    .font(.headline)
                let resets = ProviderID.allCases.filter { app.showsInMenu($0) && app.usage[$0]?.soonestReset != nil }
                if resets.isEmpty {
                    Text("No reset time yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(resets) { provider in
                        if let reset = app.usage[provider]?.soonestReset {
                            HStack(spacing: 8) {
                                ProviderIcon(provider: provider, size: 14)
                                Text(provider.displayName)
                                Spacer()
                                Text(MochaiFormat.clock(reset))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .font(.system(size: 13))
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MetricTile: View {
    var title: String
    var value: String

    var body: some View {
        QuietCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
            }
        }
    }
}

struct AgentsPane: View {
    @Environment(AppModel.self) private var app
    @Binding var selectedID: UUID?

    var body: some View {
        HSplitView {
            List(app.liveSessions + Array(app.history.prefix(20)), selection: $selectedID) { session in
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.projectTitle)
                    HStack(spacing: 6) {
                        Text("\(session.provider.displayName) · \(session.state.label)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if session.state.preventsSystemSleep {
                            AwakeDot(diameter: 6)
                        }
                    }
                }
                .tag(session.id)
            }
            .frame(minWidth: 240)
            if let id = selectedID, let session = app.session(id) {
                SessionDetailView(session: session)
            } else {
                ContentUnavailableView("Select an agent", systemImage: "person.crop.circle", description: Text("Choose one to see what it has been doing."))
            }
        }
    }
}

public struct SessionDetailView: View {
    @Environment(AppModel.self) private var app
    var session: AgentSession

    public init(session: AgentSession) {
        self.session = session
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(session.provider.displayName).font(.caption).foregroundStyle(.secondary)
                Text(session.projectTitle).font(.title2.weight(.semibold))
                if !session.displayPath.isEmpty {
                    Text(session.displayPath).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
                HStack {
                    StatusPill(state: session.state)
                    if let branch = session.branch { Text(branch).font(.caption) }
                    if session.hasRepositoryChanges { Text("Changes present").font(.caption).foregroundStyle(.secondary) }
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    MetricTile(title: "Started", value: MochaiFormat.clock(session.startedAt))
                    MetricTile(title: "Working", value: MochaiFormat.duration(session.workingTime(now: Date())))
                    MetricTile(title: "Waiting", value: MochaiFormat.duration(session.waitingTime(now: Date())))
                    MetricTile(title: "Kept Mac awake", value: MochaiFormat.duration(session.awakeSeconds))
                }
                if let usage = session.usage ?? app.usage[session.provider] {
                    Text("Allowance").font(.headline)
                    if usage.confidence == .unavailable || usage.allowanceWindows().isEmpty {
                        Text(usage.detail ?? "Usage unavailable").foregroundStyle(.secondary)
                    } else {
                        ForEach(usage.allowanceWindows()) { window in
                            UsageMeter(window: window, confidence: usage.confidence, reading: session.provider.allowanceReading)
                        }
                    }
                }
                HStack(spacing: 8) {
                    if let path = session.projectDirectory ?? session.repositoryRoot {
                        Button("Open in Finder") { TerminalLauncher.reveal(path) }
                        Button("Copy Path") { TerminalLauncher.copyPath(path) }
                        Button("Open in Editor") { _ = TerminalLauncher.openInEditor(path) }
                    }
                    if session.resume.readiness == .ready || session.state.isLimited {
                        Button("Continue") { Task { await app.continueSession(session.id) } }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                Text("Timeline").font(.headline)
                ForEach(session.timeline) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        Text(MochaiFormat.clock(entry.timestamp))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 88, alignment: .leading)
                        Text(entry.title)
                            .font(.system(size: 13))
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct UsagePane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(ProviderID.allCases.filter { app.showsInMenu($0) }) { provider in
                    QuietCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                ProviderIcon(provider: provider, size: 18)
                                Text(provider.displayName).font(.headline)
                                if app.isWorking(provider) {
                                    AwakeDot(diameter: 8)
                                }
                            }
                            if let usage = app.usage[provider], usage.confidence != .unavailable, !usage.allowanceWindows().isEmpty {
                                ForEach(usage.allowanceWindows()) { window in
                                    UsageMeter(window: window, confidence: usage.confidence, reading: provider.allowanceReading)
                                }
                                chart(for: provider)
                                if let prediction = UsageEstimator.predictWeekly(snapshots: app.usageSeries(for: provider)) {
                                    Text(prediction.message)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text(app.usage[provider]?.detail ?? "Usage unavailable")
                                    .foregroundStyle(.secondary)
                            }
                            if app.settings.showTokenCost, let cost = app.tokenCosts[provider] {
                                Text(cost.line)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private func chart(for provider: ProviderID) -> some View {
        let series = app.usageSeries(for: provider)
        if series.count >= 2 {
            Chart(series, id: \.date) { point in
                LineMark(x: .value("Time", point.date), y: .value("Used", point.used))
                    .foregroundStyle(MochaiTheme.accent)
            }
            .chartYScale(domain: 0...1)
            .frame(height: 140)
            .accessibilityLabel("\(provider.displayName) usage over time")
        }
    }
}

struct HistoryPane: View {
    @Environment(AppModel.self) private var app
    @Binding var selectedID: UUID?
    @State private var range: HistoryRange = .today
    @State private var provider: ProviderID?

    var body: some View {
        let rows = filtered
        VStack {
            HStack {
                Picker("Range", selection: $range) {
                    ForEach(HistoryRange.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                Picker("Provider", selection: $provider) {
                    Text("All").tag(ProviderID?.none)
                    ForEach(ProviderID.allCases.filter(\.isUserFacing)) { item in
                        Text(item.displayName).tag(Optional(item))
                    }
                }
                .frame(width: 180)
                Spacer()
            }
            .padding([.horizontal, .top], 16)
            List(rows, selection: $selectedID) { session in
                HStack {
                    VStack(alignment: .leading) {
                        Text(session.provider.displayName).font(.caption).foregroundStyle(.secondary)
                        Text(session.projectTitle)
                        Text("\(MochaiFormat.duration(session.workingTime(now: Date()))) working · \(MochaiFormat.duration(session.waitingTime(now: Date()))) waiting")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(session.outcome.label)
                    if let completed = session.completedAt {
                        Text(MochaiFormat.clock(completed)).foregroundStyle(.secondary)
                    }
                }
                .tag(session.id)
            }
        }
    }

    private var filtered: [AgentSession] {
        let start = range.start
        return app.history.filter { session in
            let stamp = session.completedAt ?? session.startedAt
            guard stamp >= start else { return false }
            if let provider, session.provider != provider { return false }
            return true
        }
    }
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case today, week, month
    var id: String { rawValue }
    var label: String {
        switch self {
        case .today: "Today"
        case .week: "7 days"
        case .month: "30 days"
        }
    }
    var start: Date {
        let calendar = Calendar.current
        switch self {
        case .today: return calendar.startOfDay(for: Date())
        case .week: return Date().addingTimeInterval(-7 * 24 * 3600)
        case .month: return Date().addingTimeInterval(-30 * 24 * 3600)
        }
    }
}

struct ProjectsPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List(app.projects) { project in
            ProjectEditor(project: project)
        }
        .overlay {
            if app.projects.isEmpty {
                ContentUnavailableView("No projects yet", systemImage: "folder", description: Text("They show up when an agent starts working in one."))
            }
        }
    }
}

struct ProjectEditor: View {
    @Environment(AppModel.self) private var app
    @State var project: ProjectPolicy

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(project.name).font(.headline)
            Text(MochaiFormat.abbreviatedPath(project.path)).font(.caption).foregroundStyle(.secondary)
            Picker("When a limit resets", selection: $project.autoResume) {
                Text("Same as Behaviour").tag(ResumeMode?.none)
                ForEach(ResumeMode.allCases) { mode in
                    Text(mode.label).tag(Optional(mode))
                }
            }
            Toggle("Prevent sleep for this project", isOn: $project.preventSleep)
            Toggle("Sensitive", isOn: $project.sensitive)
            Text(project.sensitive ? "This project asks before continuing." : "This project follows your usual choice.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .onChange(of: project) { _, updated in
            app.updateProject(updated)
        }
    }
}

struct IntegrationsPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connect Claude and Codex so MochAI can see when they are working. You can undo this later.")
                    .foregroundStyle(.secondary)
                ForEach(ProviderID.allCases.filter(\.isUserFacing)) { provider in
                    IntegrationCard(provider: provider)
                }
            }
            .padding(24)
        }
    }
}

struct IntegrationCard: View {
    @Environment(AppModel.self) private var app
    var provider: ProviderID

    var body: some View {
        let installation = app.installations[provider]
        let report = app.health[provider]
        QuietCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProviderIcon(provider: provider, size: 18)
                    Text(provider.displayName).font(.headline)
                }
                labeled("Installed", installation?.installed == true ? "Yes" : "No")
                if let version = installation?.version {
                    labeled("Version", version)
                }
                if provider.supervisesSessions {
                    labeled("Connected", installation?.hookInstalled == true ? "Yes" : "No")
                }
                if let summary = report?.summary {
                    Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if provider.supervisesSessions {
                    HStack {
                        Button("Set up") { Task { await app.installIntegration(provider) } }
                        Button("Remove") { Task { await app.removeIntegration(provider) } }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.system(size: 13))
    }
}
