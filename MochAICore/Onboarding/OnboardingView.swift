import SwiftUI

public struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @State private var page = 0
    public var onFinish: () -> Void

    public init(onFinish: @escaping () -> Void = {}) {
        self.onFinish = onFinish
    }

    public var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: welcome
                case 1: detect
                case 2: install
                case 3: awake
                case 4: resume
                case 5: notifications
                default: complete
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)
            ZStack {
                pageDots
                HStack {
                    if page > 0 && page < 6 {
                        Button("Back") { page -= 1 }
                            .keyboardShortcut(.cancelAction)
                    }
                    Spacer()
                    if page == 0 {
                        Button("Hello") { page += 1 }
                            .keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("onboarding.continue")
                    } else if page < 6 {
                        Button("Continue") { page += 1 }
                            .keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("onboarding.continue")
                    } else {
                        Button("Start") {
                            app.finishOnboarding()
                            onFinish()
                        }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("onboarding.start")
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 640, height: 520)
        .accessibilityIdentifier("onboarding")
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { index in
                Circle()
                    .fill(index == page ? MochaiTheme.accent : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            MascotView(pose: .coffee, size: 120)
            Text("Hello.")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .accessibilityIdentifier("onboarding.title")
            Text("I'm MochAI.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Text("I keep an eye on your coding agents, hold your Mac awake while they work, and show how much allowance is left.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
        }
    }

    private var detect: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your tools")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            Text("These are the ones already on your Mac.")
                .foregroundStyle(.secondary)
            ForEach(ProviderID.allCases.filter(\.isUserFacing)) { provider in
                let installed = app.installations[provider]?.installed == true
                HStack {
                    Text(provider.displayName)
                    Spacer()
                    Label(installed ? "Detected" : "Not found", systemImage: installed ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(installed ? Color.green : Color.secondary)
                }
                .padding(12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var install: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            Text("Connect Claude and Codex so MochAI can tell when they are working. Your current setup stays in place, and you can undo this later.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Set up Claude") { Task { await app.installIntegration(.claude) } }
                Button("Set up Codex") { Task { await app.installIntegration(.codex) } }
            }
        }
    }

    private var awake: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keep Awake")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            Text("When an AI agent is working, MochAI can prevent your Mac from going to sleep. Your display can still turn off normally.")
                .foregroundStyle(.secondary)
            Toggle("Enable automatic keep-awake", isOn: awakeBinding)
                .toggleStyle(.switch)
        }
    }

    private var awakeBinding: Binding<Bool> {
        Binding(
            get: { app.settings.keepAwakeMode != .never },
            set: { enabled in
                app.settings.selectKeepAwake(enabled ? .automatic : .never)
                app.applySettings()
            }
        )
    }

    private var resume: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("When a limit resets")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            Text("When an AI limit resets:")
                .foregroundStyle(.secondary)
            Picker("Resume", selection: resumeBinding) {
                ForEach(ResumeMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    private var resumeBinding: Binding<ResumeMode> {
        Binding(
            get: { app.settings.resumeMode },
            set: { mode in
                app.settings.resumeMode = mode
                app.applySettings()
            }
        )
    }

    private var notifications: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Notifications")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            Text("MochAI can tell you when an agent finishes, needs you, reaches a limit, or is ready to continue.")
                .foregroundStyle(.secondary)
            Button("Enable Notifications") { Task { await app.requestNotifications() } }
                .accessibilityIdentifier("onboarding.notifications")
        }
    }

    private var complete: some View {
        VStack(spacing: 16) {
            MascotView(pose: .coffee, size: 120)
            Text("MochAI is ready.")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
            Text("You can walk away. MochAI will notice when an agent is working, when it needs you, and when your Mac can sleep.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
        }
    }
}
