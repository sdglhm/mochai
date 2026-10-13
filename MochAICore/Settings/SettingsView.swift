import SwiftUI

public struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var page: SettingsPage = .general

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $page) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            Form {
                switch page {
                case .general: general
                case .behaviour: behaviour
                case .notifications: notifications
                case .providers: providers
                case .projects: ProjectsPane()
                case .privacy: privacy
                case .diagnostics: DiagnosticsView()
                case .about: AboutView()
                }
            }
            .formStyle(.grouped)
            .padding(8)
        }
        .frame(minWidth: 720, minHeight: 480)
        .accessibilityIdentifier("settings")
    }

    private var general: some View {
        Group {
            Toggle("Launch MochAI at login", isOn: Binding(
                get: { app.settings.launchAtLogin },
                set: { app.settings.updateLogin($0) }
            ))
            Text(app.settings.loginError ?? app.settings.loginStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Show Dock icon", isOn: Binding(
                get: { app.settings.showDockIcon },
                set: { app.settings.showDockIcon = $0; app.applySettings() }
            ))
            Toggle("Show token cost", isOn: Binding(
                get: { app.settings.showTokenCost },
                set: { app.settings.showTokenCost = $0; app.applySettings() }
            ))
            Text("Claude and Codex show an estimate for this month. Cursor shows the spend it reports.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Menu bar display", selection: Binding(
                get: { app.settings.menuBarDisplay },
                set: { app.settings.menuBarDisplay = $0; app.applySettings() }
            )) {
                ForEach(MenuBarDisplayMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
        }
    }

    private var behaviour: some View {
        Group {
            Picker("Keep Mac awake", selection: Binding(
                get: { app.settings.keepAwakeMode },
                set: { app.settings.selectKeepAwake($0); app.applySettings() }
            )) {
                ForEach(KeepAwakeMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            Picker("When usage resets", selection: Binding(
                get: { app.settings.resumeMode },
                set: { app.settings.resumeMode = $0; app.applySettings() }
            )) {
                ForEach(ResumeMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            Stepper(value: Binding(
                get: { app.settings.autoResumeDelay },
                set: { app.settings.autoResumeDelay = $0; app.applySettings() }
            ), in: 0...60, step: 1) {
                Text("Wait \(Int(app.settings.autoResumeDelay)) seconds before continuing")
            }
            Picker("Keep awake on battery", selection: Binding(
                get: { app.settings.batteryPolicy },
                set: { app.settings.batteryPolicy = $0; app.applySettings() }
            )) {
                ForEach(BatteryKeepAwake.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            TextField("Message when continuing", text: Binding(
                get: { app.settings.continuationPrompt },
                set: { app.settings.continuationPrompt = $0; app.applySettings() }
            ), axis: .vertical)
            .lineLimit(3...6)
        }
    }

    private var notifications: some View {
        Group {
            Toggle("Completion", isOn: preference(\.completion))
            Toggle("Needs input", isOn: preference(\.needsInput))
            Toggle("Rate limits", isOn: preference(\.rateLimits))
            Toggle("Resume", isOn: preference(\.resume))
            Toggle("Errors", isOn: preference(\.errors))
        }
    }

    private var providers: some View {
        Group {
            ForEach(ProviderID.allCases.filter(\.isUserFacing)) { provider in
                Section(provider.displayName) {
                    Toggle("Enabled", isOn: Binding(
                        get: { app.settings.providerEnabled(provider) },
                        set: { enabled in
                            var override = app.settings.providerOverrides[provider.rawValue] ?? ProviderOverride()
                            override.enabled = enabled
                            app.settings.providerOverrides[provider.rawValue] = override
                            app.applySettings()
                        }
                    ))
                    Picker("Resume", selection: Binding(
                        get: { app.settings.providerResume(provider) },
                        set: { mode in
                            var override = app.settings.providerOverrides[provider.rawValue] ?? ProviderOverride()
                            override.resumeMode = mode
                            app.settings.providerOverrides[provider.rawValue] = override
                            app.applySettings()
                        }
                    )) {
                        Text("Same as Behaviour").tag(ResumeMode?.none)
                        ForEach(ResumeMode.allCases) { mode in
                            Text(mode.label).tag(Optional(mode))
                        }
                    }
                }
            }
        }
    }

    private var privacy: some View {
        Group {
            Picker("History retention", selection: Binding(
                get: { app.settings.historyRetention },
                set: { app.settings.historyRetention = $0; app.applySettings() }
            )) {
                ForEach(HistoryRetention.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            Toggle("Remember command names", isOn: Binding(
                get: { app.settings.storeCommandNames },
                set: { app.settings.storeCommandNames = $0; app.applySettings() }
            ))
            Text("Leave this off to keep command names out of history.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Prompts and code stay on this Mac. An allowance check uses the sign-in already here, and sends it only to that provider.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func preference(_ keyPath: WritableKeyPath<NotificationPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { app.settings.notifications[keyPath: keyPath] },
            set: { value in
                app.settings.notifications[keyPath: keyPath] = value
                app.applySettings()
            }
        )
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, behaviour, notifications, providers, projects, privacy, diagnostics, about
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "switch.2"
        case .behaviour: "cup.and.saucer"
        case .notifications: "bell"
        case .providers: "person.2"
        case .projects: "folder"
        case .privacy: "hand.raised"
        case .diagnostics: "waveform.path.ecg"
        case .about: "info.circle"
        }
    }
    var title: String {
        switch self {
        case .general: "General"
        case .behaviour: "Behaviour"
        case .notifications: "Notifications"
        case .providers: "Agents"
        case .projects: "Projects"
        case .privacy: "Privacy"
        case .diagnostics: "Status"
        case .about: "About"
        }
    }
}
